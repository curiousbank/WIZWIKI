# frozen_string_literal: true

require "digest"
require "json"

module Kalshi
  class WeatherOutcomeAnalysis
    DEFAULT_LIMIT = 80
    RECENT_CASE_LIMIT = 12
    MAX_ATTEMPTS_PER_DIGEST = 2
    SURFACE = "weather_outcome_analysis".freeze
    ANALYSIS_VERSION = "structured_station_calibration_v6".freeze

    class << self
      def enqueue!(organization:, limit: DEFAULT_LIMIT)
        new(organization: organization, limit: limit).enqueue!
      end

      def current_batch_digest(organization:, limit: DEFAULT_LIMIT)
        analyst = new(organization: organization, limit: limit)
        rows = analyst.send(:scored_predictions)
        rows.present? ? analyst.send(:batch_digest, rows) : nil
      end
    end

    def initialize(organization:, limit:)
      @organization = organization
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
    end

    def enqueue!
      return status("prediction storage not ready") unless storage_ready?
      return status("autos worker disabled") unless Autos::WorkerQueue.enabled?

      rows = scored_predictions
      return status("no officially settled station-model predictions") if rows.blank?

      digest = batch_digest(rows)
      existing = analyses_for(digest).order(created_at: :desc).first
      return status("analysis already queued", existing) if existing.present? && reusable_existing_analysis?(existing, digest, rows.length)
      return status("analysis retry limit reached", existing) if attempts_for(digest) >= MAX_ATTEMPTS_PER_DIGEST

      user = organization.users.order(:id).first
      return status("no organization user for analysis ownership") if user.blank?

      question = organization.autos_questions.create!(
        user: user,
        status: "queued",
        question: analysis_prompt(digest: digest, sample_size: rows.length),
        context: analysis_context(rows, digest: digest),
        metadata: {
          "surface" => SURFACE,
          "origin" => "weather",
          "source" => "weather",
          "skip_ui_broadcast" => true,
          "skip_chat_memory" => false,
          "weather_learning_memory" => true,
          "weather_analysis_version" => ANALYSIS_VERSION,
          "weather_knowledge_version" => Kalshi::WeatherAnalysisKnowledge::VERSION,
          "weather_schema_version" => Kalshi::WeatherAnalysisContract::SCHEMA_VERSION,
          "weather_batch_digest" => digest,
          "weather_sample_size" => rows.length,
          "weather_prediction_ids" => rows.map(&:id),
          "model_lane" => "weather_calibration_qwen_30b",
          "writer_model" => weather_model,
          "writer_model_label" => weather_model_label,
          "memory" => {
            "brain_type" => "weather_calibration",
            "scope" => "weather_calibration"
          }
        }
      )
      Autos::WorkerQueue.queue!(question)
      status("queued", question)
    end

    private

    attr_reader :organization, :limit

    def analyses_for(digest)
      organization.autos_questions
        .where("metadata ->> 'surface' = ?", SURFACE)
        .where("metadata ->> 'weather_analysis_version' = ?", ANALYSIS_VERSION)
        .where("metadata ->> 'weather_batch_digest' = ?", digest)
    end

    def attempts_for(digest)
      analyses_for(digest).where(status: %w[answered failed]).count
    end

    def reusable_existing_analysis?(question, digest, sample_size)
      return true if question.status.to_s.in?(%w[queued processing])
      return false unless question.status.to_s == "answered"

      Kalshi::WeatherAnalysisContract.valid?(
        question.answer,
        expected_digest: digest,
        expected_sample_size: sample_size
      )
    end

    def weather_model
      Autos::WorkerQueue.weather_calibration_model
    rescue StandardError
      "qwen3:30b"
    end

    def weather_model_label
      if defined?(WizwikiSettings)
        WizwikiSettings.report_model_display_label(weather_model)
      else
        "Qwen 3 30B // local weather calibration"
      end
    rescue StandardError
      "Qwen 3 30B // local weather calibration"
    end

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        organization.respond_to?(:kalshi_weather_predictions) &&
        defined?(AutosQuestion)
    end

    def scored_predictions
      rows = organization.kalshi_weather_predictions
        .where(result_status: %w[won lost pushed void])
        .where.not(observed_high_f: nil)
        .where("metadata ? 'official_market_reconciled_at'")
        .where("metadata ->> 'forecast_coordinate_version' = ?", coordinate_version)
        .order(prediction_date: :desc, updated_at: :desc)
        .limit(limit * 3)
        .to_a

      rows
        .group_by { |row| row.event_ticker.presence || row.market_ticker }
        .values
        .map { |event_rows| event_rows.max_by(&:updated_at) }
        .sort_by { |row| [row.prediction_date || Date.new(1970, 1, 1), row.id] }
        .last(limit)
    end

    def coordinate_version
      Kalshi::WeatherAnalysisKnowledge.payload.dig(:live_validation, :coordinate_version)
    end

    def batch_digest(rows)
      evidence = rows.sort_by(&:id).map do |row|
        metadata = row.metadata.to_h
        [
          row.id,
          row.event_ticker,
          row.prediction_date&.iso8601,
          row.action,
          row.result_status,
          row.observed_high_f,
          row.adjusted_high_f,
          row.confidence,
          metadata["confidence_lower_bound"],
          row.ask,
          metadata["official_market_result"],
          metadata["forecast_coordinate_version"],
          metadata["probability_model_version"]
        ]
      end
      Digest::SHA256.hexdigest(JSON.generate([ANALYSIS_VERSION, Kalshi::WeatherAnalysisKnowledge::VERSION, evidence]))
    end

    def analysis_prompt(digest:, sample_size:)
      <<~TEXT.squish
        /no_think You are the local senior quantitative weather-market calibration analyst. Analyze only the supplied, officially settled, exact-station evidence. Arithmetic and settlement facts in the evidence are authoritative. Find source, city, regime, calibration, and data-quality patterns; distinguish evidence from hypotheses; never recommend or execute a wager. Return exactly one JSON object with no markdown or prose. Required keys: schema_version=#{Kalshi::WeatherAnalysisContract::SCHEMA_VERSION.inspect}, knowledge_version=#{Kalshi::WeatherAnalysisKnowledge::VERSION.inspect}, batch_digest=#{digest.inspect}, sample_size=#{sample_size}, analysis_complete=true, verdict (insufficient_data|negative|uncertain|promising), risk_gate (block|clear), summary, findings (1-5 objects with type, evidence, confidence from 0 to 1), data_quality_flags (array), next_instrumentation, and rule_ack with settlement_source=final_nws_daily_climate_report, one_sided_strikes=strict, between_bounds=inclusive, objective=fee_adjusted_out_of_sample_ev. Below 30 independent events, verdict must be insufficient_data and risk_gate must be block.
      TEXT
    end

    def analysis_context(rows, digest:)
      JSON.generate(
        generated_at: Time.current.iso8601,
        batch_digest: digest,
        sample_size: rows.length,
        canonical_knowledge: Kalshi::WeatherAnalysisKnowledge.payload,
        dataset_quality: dataset_quality(rows),
        overall_metrics: metrics_for(rows),
        city_metrics: grouped_metrics(rows, &:city),
        source_metrics: source_metrics(rows),
        unavailable_sources: unavailable_source_counts(rows),
        prior_validated_analyses: prior_validated_analyses(excluding_digest: digest),
        recent_cases: rows.last(RECENT_CASE_LIMIT).reverse.map { |row| case_payload(row) }
      )
    end

    def prior_validated_analyses(excluding_digest:)
      organization.autos_questions
        .where("metadata ->> 'surface' = ?", SURFACE)
        .where("metadata ->> 'weather_analysis_version' = ?", ANALYSIS_VERSION)
        .where(status: "answered")
        .order(updated_at: :desc)
        .limit(8)
        .filter_map do |question|
          metadata = question.metadata.to_h
          digest = metadata["weather_batch_digest"].to_s
          next if digest.blank? || digest == excluding_digest

          validation = Kalshi::WeatherAnalysisContract.validate(
            question.answer,
            expected_digest: digest,
            expected_sample_size: metadata["weather_sample_size"]
          )
          next unless validation.fetch(:valid)

          validation.fetch(:payload).slice(
            "batch_digest",
            "sample_size",
            "verdict",
            "risk_gate",
            "summary",
            "findings",
            "data_quality_flags",
            "next_instrumentation"
          )
        end
        .first(3)
    end

    def dataset_quality(rows)
      {
        independent_events: rows.length,
        minimum_live_events: Kalshi::WeatherAnalysisKnowledge.payload.dig(:live_validation, :minimum_independent_station_events),
        event_date_aligned: rows.count { |row| row.metadata.to_h["forecast_event_date_aligned"] == true },
        probability_model_ready: rows.count { |row| row.metadata.to_h["probability_model_ready"] == true },
        source_conflicts: rows.count { |row| row.metadata.to_h["forecast_agreement_label"] == "source conflict" },
        cities: rows.map(&:city).compact.uniq.sort,
        date_range: [rows.first&.prediction_date&.iso8601, rows.last&.prediction_date&.iso8601]
      }
    end

    def grouped_metrics(rows)
      rows.group_by { |row| yield(row).presence || "unknown" }.transform_values { |group| metrics_for(group) }
    end

    def metrics_for(rows)
      decided = rows.select { |row| row.result_status.in?(%w[won lost]) }
      forecast_errors = rows.filter_map do |row|
        next if row.observed_high_f.blank? || row.adjusted_high_f.blank?

        row.observed_high_f.to_f - row.adjusted_high_f.to_f
      end
      brier_rows = decided.filter_map do |row|
        probability = row.confidence
        next if probability.blank?

        outcome = row.result_status == "won" ? 1.0 : 0.0
        (probability.to_f.clamp(0.0, 1.0) - outcome)**2
      end
      performance = fee_adjusted_performance(decided.select { |row| row.action == "paper_yes" })

      {
        events: rows.length,
        decided_contracts: decided.length,
        forecast_mae_f: average(forecast_errors.map(&:abs)),
        forecast_bias_f: average(forecast_errors),
        brier_score: average(brier_rows),
        source_spread_avg_f: average(rows.filter_map { |row| row.metadata.to_h["forecast_source_spread_f"] }),
        paper_yes: performance
      }
    end

    def fee_adjusted_performance(rows)
      entries = rows.filter_map do |row|
        price = normalized_price(row)
        next if price.blank?

        fee = estimated_fee(price)
        risk = price + fee
        profit = row.result_status == "won" ? 1.0 - price - fee : -risk
        { result: row.result_status, risk: risk, profit: profit }
      end
      risk = entries.sum { |entry| entry.fetch(:risk) }
      profit = entries.sum { |entry| entry.fetch(:profit) }

      {
        entries: entries.length,
        wins: entries.count { |entry| entry[:result] == "won" },
        losses: entries.count { |entry| entry[:result] == "lost" },
        risk: risk.round(4),
        net_profit: profit.round(4),
        roi_percent: risk.positive? ? ((profit / risk) * 100).round(2) : nil
      }
    end

    def source_metrics(rows)
      observations = Hash.new { |hash, key| hash[key] = [] }
      rows.each do |row|
        next if row.observed_high_f.blank?

        Array(row.metadata.to_h["forecast_sources"]).each do |source|
          source = source.to_h
          next if source["high_f"].blank?

          key = source["key"].presence || source["label"].presence || "unknown"
          observations[key] << source["high_f"].to_f - row.observed_high_f.to_f
        end
      end

      observations.transform_values do |errors|
        {
          samples: errors.length,
          mae_f: average(errors.map(&:abs)),
          bias_f: average(errors)
        }
      end
    end

    def unavailable_source_counts(rows)
      rows.flat_map { |row| Array(row.metadata.to_h["forecast_unavailable_sources"]) }
        .group_by { |source| source.to_h["key"].presence || source.to_h["label"].presence || "unknown" }
        .transform_values(&:length)
    end

    def case_payload(row)
      metadata = row.metadata.to_h
      {
        prediction_id: row.id,
        event: row.event_ticker,
        city: row.city,
        date: row.prediction_date&.iso8601,
        station: metadata["forecast_station_id"],
        market: row.market_band_label,
        action: row.action,
        result: row.result_status,
        forecast_high_f: row.adjusted_high_f,
        observed_high_f: row.observed_high_f,
        residual_f: row.observed_high_f.present? && row.adjusted_high_f.present? ? (row.observed_high_f.to_f - row.adjusted_high_f.to_f).round(2) : nil,
        probability: row.confidence,
        probability_lower_bound: metadata["confidence_lower_bound"],
        ask: normalized_price(row),
        fee_adjusted_contract_profit: contract_profit(row),
        source_spread_f: metadata["forecast_source_spread_f"],
        sources: Array(metadata["forecast_sources"]).map { |source| source.to_h.slice("key", "high_f") },
        unavailable_sources: Array(metadata["forecast_unavailable_sources"]).map { |source| source.to_h.slice("key", "reason") }
      }.compact
    end

    def contract_profit(row)
      return nil unless row.action == "paper_yes" && row.result_status.in?(%w[won lost])

      price = normalized_price(row)
      return nil if price.blank?

      fee = estimated_fee(price)
      (row.result_status == "won" ? 1.0 - price - fee : -(price + fee)).round(4)
    end

    def normalized_price(row)
      value = row.ask.presence || row.metadata.to_h["ask"].presence
      return nil if value.blank?

      price = value.to_f
      price /= 100.0 if price > 1.0
      price.positive? && price <= 1.0 ? price.round(4) : nil
    end

    def estimated_fee(price)
      if defined?(Kalshi::WeatherAutopilot)
        Kalshi::WeatherAutopilot.estimated_taker_fee_per_contract(price)
      else
        (0.07 * price * (1.0 - price)).round(4)
      end
    end

    def average(values)
      values = Array(values).compact.map(&:to_f)
      values.present? ? (values.sum / values.length).round(3) : nil
    end

    def status(reason, question = nil)
      validation = if question&.status == "answered"
        Kalshi::WeatherAnalysisContract.validate(
          question.answer,
          expected_digest: question.metadata.to_h["weather_batch_digest"],
          expected_sample_size: question.metadata.to_h["weather_sample_size"]
        )
      end
      {
        reason: reason,
        question_id: question&.id,
        question_status: question&.status,
        queued: question.present? && question.status == "queued",
        answered: question.present? && question.status == "answered",
        validated: validation&.fetch(:valid, false),
        ran_at: Time.current
      }.compact
    end
  end
end
