# frozen_string_literal: true

module Kalshi
  class WeatherPaperTrader
    ACTIVE_STRATEGY = "paper_active".freeze
    CHALLENGER_STRATEGY = "paper_challenger".freeze
    STRATEGIES = {
      ACTIVE_STRATEGY => :active,
      CHALLENGER_STRATEGY => :challenger
    }.freeze
    MAX_CANDIDATES = 240
    MIN_CLOSE_BUFFER = 15.minutes

    class << self
      def call(organization:)
        new(organization: organization).call
      end
    end

    def initialize(organization:)
      @organization = organization
      @harness = WeatherCalibrationHarness.new(organization: organization)
    end

    def call
      return status(error: "paper wager storage not ready") unless storage_ready?

      results = STRATEGIES.map do |strategy_key, strategy|
        run_strategy(strategy_key, strategy)
      rescue StandardError => error
        Rails.logger.warn("[WeatherPaperTrader] organization=#{organization.id} strategy=#{strategy_key} failed: #{error.class}: #{error.message}")
        { strategy_key: strategy_key, strategy: strategy.to_s, status: "error", error: "#{error.class}: #{error.message}" }
      end
      status(strategies: results)
    end

    private

    attr_reader :organization, :harness

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        defined?(KalshiWeatherWager) &&
        KalshiWeatherWager.storage_ready?
    end

    def run_strategy(strategy_key, strategy)
      existing_today = organization.kalshi_weather_wagers
        .paper
        .for_strategy(strategy_key)
        .budgeted
        .where(budget_date: Date.current)
        .recent_first
        .first
      if existing_today.present?
        return {
          strategy_key: strategy_key,
          strategy: strategy.to_s,
          status: "already_allocated",
          wager_id: existing_today.id,
          market_ticker: existing_today.market_ticker,
          risk: wager_total_risk(existing_today)
        }
      end

      evaluations = candidates.map do |prediction|
        [
          prediction,
          harness.evaluate(
            prediction,
            strategy: strategy,
            enforce_live_gate: strategy != :active
          )
        ]
      end
      eligible = evaluations.select { |_prediction, evaluation| evaluation[:ok] }
      selected = eligible.max_by do |prediction, evaluation|
        [
          strategy == :active ? evaluation[:conservative_edge].to_f : evaluation[:point_edge].to_f,
          evaluation[:calibrated_probability].to_f,
          -evaluation[:price].to_f,
          -prediction.id
        ]
      end

      if selected.blank?
        return {
          strategy_key: strategy_key,
          strategy: strategy.to_s,
          status: "watching",
          evaluated: evaluations.length,
          eligible: 0,
          top_reasons: evaluations.map { |_prediction, evaluation| evaluation[:reason].to_s }.reject(&:blank?).tally.sort_by { |_reason, count| -count }.first(4).to_h
        }
      end

      prediction, evaluation = selected
      wager = record_wager(prediction, evaluation, strategy_key: strategy_key, strategy: strategy)
      {
        strategy_key: strategy_key,
        strategy: strategy.to_s,
        status: "paper_position_opened",
        evaluated: evaluations.length,
        eligible: eligible.length,
        wager_id: wager.id,
        market_ticker: wager.market_ticker,
        contracts: wager.contracts,
        risk: wager_total_risk(wager),
        calibrated_probability: evaluation[:calibrated_probability],
        conservative_edge: evaluation[:conservative_edge],
        point_edge: evaluation[:point_edge]
      }
    end

    def candidates
      @candidates ||= organization.kalshi_weather_predictions
        .open_predictions
        .where("close_time IS NULL OR close_time > ?", MIN_CLOSE_BUFFER.from_now)
        .order(Arel.sql("prediction_date ASC, edge DESC NULLS LAST, confidence DESC NULLS LAST, ask ASC NULLS LAST"))
        .limit(MAX_CANDIDATES)
        .to_a
    end

    def record_wager(prediction, evaluation, strategy_key:, strategy:)
      wager = organization.kalshi_weather_wagers.find_or_initialize_by(
        kalshi_weather_prediction: prediction,
        execution_mode: "dry_run",
        strategy_key: strategy_key
      )
      return wager if wager.persisted? && wager.status.in?(%w[pending placed filled won lost pushed void])

      contracts = evaluation.fetch(:contracts).to_i
      price = evaluation.fetch(:price).to_f
      premium = (contracts * price).round(2)
      estimated_fee = evaluation.fetch(:estimated_fee).to_f.round(2)
      wager.assign_attributes(
        status: "pending",
        execution_mode: "dry_run",
        strategy_key: strategy_key,
        strategy_version: WeatherCalibrationHarness::STRATEGY_VERSION,
        side: "yes",
        action: "buy",
        market_ticker: prediction.market_ticker,
        contracts: contracts,
        filled_contracts: contracts,
        price: price,
        max_cost: premium,
        actual_cost: premium,
        budget_date: Date.current,
        placed_at: Time.current,
        filled_at: Time.current,
        opportunity_tier: strategy == :active ? "paper_active_shadow" : "paper_calibrated_challenger",
        reason: evaluation.fetch(:reason),
        metadata: wager.metadata.to_h.merge(
          "paper_only" => true,
          "external_order_created" => false,
          "strategy_key" => strategy_key,
          "strategy_version" => WeatherCalibrationHarness::STRATEGY_VERSION,
          "calibration_harness_version" => WeatherCalibrationHarness::VERSION,
          "estimated_taker_fee" => estimated_fee,
          "total_risk" => evaluation.fetch(:total_risk).to_f.round(2),
          "decision_snapshot" => paper_decision_snapshot(prediction, evaluation),
          "paper_recorded_at" => Time.current.iso8601
        )
      )
      wager.save!
      wager
    end

    def paper_decision_snapshot(prediction, evaluation)
      prediction.metadata.to_h.slice(
        "forecast_coordinate_version",
        "forecast_event_date_aligned",
        "forecast_station_id",
        "forecast_source_count",
        "forecast_source_spread_f",
        "probability_model_version",
        "probability_training_sample_size",
        "probability_model_ready",
        "blind_edge_mode",
        "gate_reasons"
      ).merge(
        "captured_at" => Time.current.iso8601,
        "prediction_id" => prediction.id,
        "market_ticker" => prediction.market_ticker,
        "event_ticker" => prediction.event_ticker,
        "prediction_date" => prediction.prediction_date&.iso8601,
        "forecast_high_f" => prediction.forecast_high_f,
        "adjusted_high_f" => prediction.adjusted_high_f,
        "market_floor_strike" => prediction.market_floor_strike,
        "market_cap_strike" => prediction.market_cap_strike,
        "model_probability" => prediction.confidence,
        "market_price" => prediction.ask,
        "calibrated_probability" => evaluation[:calibrated_probability],
        "calibrated_lower_bound" => evaluation[:calibrated_lower_bound],
        "point_edge" => evaluation[:point_edge],
        "conservative_edge" => evaluation[:conservative_edge],
        "calibration_training_events" => evaluation[:training_events],
        "calibration_training_scope" => evaluation[:training_scope]
      ).compact
    end

    def wager_total_risk(wager)
      wager.metadata.to_h["total_risk"].presence&.to_f ||
        (wager.max_cost.to_f + wager.metadata.to_h["estimated_taker_fee"].to_f).round(2)
    end

    def status(strategies: [], error: nil)
      {
        paper_only: true,
        external_orders: false,
        stake_cap: WeatherCalibrationHarness::STAKE_CAP,
        strategy_version: WeatherCalibrationHarness::STRATEGY_VERSION,
        strategies: strategies,
        error: error,
        ran_at: Time.current
      }.compact
    end
  end
end
