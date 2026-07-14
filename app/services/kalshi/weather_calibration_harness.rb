# frozen_string_literal: true

module Kalshi
  class WeatherCalibrationHarness
    VERSION = "market_offset_platt_v3".freeze
    STRATEGY_VERSION = "walk_forward_weather_v2".freeze
    STAKE_CAP = 5.0
    MIN_FIT_EVENTS = 24
    MIN_LIVE_TRAINING_EVENTS = 60
    MIN_LIVE_OOS_EVENTS = 30
    MIN_LIVE_OOS_DATES = 7
    MIN_LIVE_OOS_TRADES = 12
    RIDGE_PENALTY = 4.0
    LOWER_BOUND_Z = 1.28
    MIN_DECISION_BUFFER = 15.minutes
    CHALLENGER_MIN_EDGE = 0.03
    LIVE_MIN_EDGE = 0.08
    CHALLENGER_PRICE_RANGE = (0.05..0.85).freeze
    LIVE_PRICE_RANGE = (0.10..0.65).freeze
    NORMAL_MODEL_VERSIONS = [
      WeatherBucketProbability::MODEL_VERSION,
      WeatherBucketProbability::BLIND_MODEL_VERSION
    ].freeze

    class << self
      def call(organization:)
        new(organization: organization).call
      end

      def evaluate(organization:, prediction:, strategy: :challenger, enforce_live_gate: true)
        new(organization: organization).evaluate(
          prediction,
          strategy: strategy,
          enforce_live_gate: enforce_live_gate
        )
      end

      def taker_fee(price:, contracts:)
        return 0.0 unless contracts.to_i.positive?

        raw = 0.07 * contracts.to_i * price.to_f * (1.0 - price.to_f)
        ((raw * 100.0).ceil / 100.0).round(2)
      end

      def contracts_within_cap(price:, cap: STAKE_CAP)
        price = price.to_f
        cap = cap.to_f
        return 0 unless price.positive? && price < 1.0 && cap.positive?

        contracts = (cap / price).floor
        contracts -= 1 while contracts.positive? && total_risk(price: price, contracts: contracts) > cap + 0.0001
        contracts
      end

      def total_risk(price:, contracts:)
        ((price.to_f * contracts.to_i) + taker_fee(price: price, contracts: contracts)).round(2)
      end
    end

    def initialize(organization:)
      @organization = organization
    end

    def call
      return @summary if defined?(@summary)

      rows = decision_rows
      policy_contracts = policy_rows
      walk_forward = walk_forward_metrics(rows, policy_contracts)
      prospective = prospective_active_shadow_metrics
      gate = validation_gate(rows, walk_forward, prospective)
      @summary = {
        version: VERSION,
        strategy_version: STRATEGY_VERSION,
        integrity: "one deterministic market-price representative per independent city-day trains calibration; all immutable contracts are evaluated; every walk-forward estimate trains only on earlier event dates",
        stake_cap: STAKE_CAP,
        training_events: rows.length,
        training_dates: rows.map { |row| row.fetch(:date) }.compact.uniq.length,
        policy_contracts: policy_contracts.length,
        date_range: [rows.first&.dig(:date)&.iso8601, rows.last&.dig(:date)&.iso8601],
        raw_model: probability_metrics(rows, :confidence),
        market: probability_metrics(rows, :ask),
        fitted: fitted_metrics(rows),
        walk_forward: walk_forward,
        prospective_active_shadow: prospective,
        live_gate: gate,
        generated_at: Time.current
      }
    rescue StandardError => error
      Rails.logger.warn("[WeatherCalibrationHarness] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      @summary = {
        version: VERSION,
        strategy_version: STRATEGY_VERSION,
        stake_cap: STAKE_CAP,
        training_events: 0,
        walk_forward: empty_walk_forward,
        live_gate: {
          clear: false,
          status: "blocked",
          reasons: ["calibration harness failed safely: #{error.class}"],
          manual_promotion_required: true
        },
        error: "#{error.class}: #{error.message}",
        generated_at: Time.current
      }
    end

    def evaluate(prediction, strategy: :challenger, enforce_live_gate: true)
      strategy = strategy.to_sym
      price = normalized_probability(prediction.ask)
      raw_probability = normalized_probability(prediction.confidence)
      return rejected(strategy, "price unavailable") if price.blank?
      return rejected(strategy, "model probability unavailable") if raw_probability.blank?

      metadata = prediction.metadata.to_h
      training = training_rows_for(
        model_version: metadata["probability_model_version"],
        before_date: prediction.prediction_date
      )
      estimate = calibrated_estimate(
        raw_probability: raw_probability,
        market_probability: price,
        training_rows: training
      )
      contracts = self.class.contracts_within_cap(price: price)
      fee = self.class.taker_fee(price: price, contracts: contracts)
      fee_per_contract = contracts.positive? ? fee / contracts : 1.0
      point_edge = estimate.fetch(:probability) - price - fee_per_contract
      conservative_edge = estimate.fetch(:lower_bound) - price - fee_per_contract
      common = {
        strategy: strategy.to_s,
        strategy_version: STRATEGY_VERSION,
        harness_version: VERSION,
        price: price.round(4),
        raw_probability: raw_probability.round(4),
        calibrated_probability: estimate.fetch(:probability).round(4),
        calibrated_lower_bound: estimate.fetch(:lower_bound).round(4),
        point_edge: point_edge.round(4),
        conservative_edge: conservative_edge.round(4),
        training_events: training.length,
        training_scope: estimate.fetch(:training_scope),
        contracts: contracts,
        estimated_fee: fee,
        total_risk: self.class.total_risk(price: price, contracts: contracts),
        calibration: estimate.except(:probability, :lower_bound)
      }

      gate_reason = data_gate_reason(prediction, metadata, strategy: strategy)
      return common.merge(ok: false, reason: gate_reason) if gate_reason.present?
      return common.merge(ok: false, reason: "fewer than #{MIN_FIT_EVENTS} earlier immutable events") if training.length < MIN_FIT_EVENTS
      return common.merge(ok: false, reason: "the $5 paper cap cannot cover one contract plus the rounded fee") unless contracts.positive?

      if strategy == :active
        if enforce_live_gate
          validation = call.fetch(:live_gate)
          return common.merge(ok: false, reason: Array(validation[:reasons]).first || "walk-forward live validation is blocked") unless validation[:clear]
        end
        return common.merge(ok: false, reason: "conservative fee-adjusted edge below #{(LIVE_MIN_EDGE * 100).round} points") if conservative_edge < LIVE_MIN_EDGE
      else
        return common.merge(ok: false, reason: "calibrated fee-adjusted edge below #{(CHALLENGER_MIN_EDGE * 100).round} points") if point_edge < CHALLENGER_MIN_EDGE
      end

      reason =
        if strategy == :active && enforce_live_gate
          "walk-forward live gate and conservative edge cleared"
        elsif strategy == :active
          "active-policy shadow cleared local conservative gates; no live order is authorized"
        else
          "paper challenger cleared calibrated point-edge gates"
        end

      common.merge(ok: true, reason: reason)
    end

    private

    attr_reader :organization

    def decision_rows
      @decision_rows ||= policy_rows
        .group_by { |row| row.fetch(:event_key) }
        .values
        .filter_map do |event_rows|
          event_rows.min_by do |row|
            [(row.fetch(:ask) - 0.50).abs, row.fetch(:market_ticker), row.fetch(:id)]
          end
        end
        .sort_by { |row| [row.fetch(:date), row.fetch(:captured_at), row.fetch(:id)] }
    end

    def policy_rows
      @policy_rows ||= begin
        snapshots = KalshiWeatherPredictionSnapshot
          .joins(:kalshi_weather_prediction)
          .where(organization_id: organization.id)
          .where(kalshi_weather_predictions: { result_status: %w[won lost] })
          .includes(:kalshi_weather_prediction)
          .order(:captured_at, :id)
          .to_a
          .select { |snapshot| eligible_snapshot?(snapshot) }

        snapshots
          .group_by(&:kalshi_weather_prediction_id)
          .values
          .map(&:first)
          .filter_map { |snapshot| row_from_snapshot(snapshot) }
          .sort_by { |row| [row.fetch(:date), row.fetch(:captured_at), row.fetch(:id)] }
      end
    end

    def eligible_snapshot?(snapshot)
      prediction = snapshot.kalshi_weather_prediction
      return false unless snapshot.action.in?(%w[paper_yes watch])
      return false unless snapshot.payload.to_h["forecast_coordinate_version"] == WeatherBucketProbability::COORDINATE_VERSION
      return false unless snapshot_event_date_aligned?(snapshot)
      return false unless NORMAL_MODEL_VERSIONS.include?(snapshot.payload.to_h["probability_model_version"])
      return false if snapshot.ask.blank? || snapshot.confidence.blank?
      return false if prediction.close_time.present? && snapshot.captured_at > prediction.close_time - MIN_DECISION_BUFFER

      true
    end

    def snapshot_event_date_aligned?(snapshot)
      payload = snapshot.payload.to_h
      return true if payload["forecast_event_date_aligned"] == true

      # Older immutable snapshots predate the explicit alignment flag. They remain
      # usable only when every stored source carries an ISO date matching the event;
      # mutable prediction metadata and ambiguous labels such as "Today" never count.
      sources = Array(payload["forecast_sources"])
      return false if sources.blank?

      source_dates = sources.map do |source|
        raw = source.to_h["forecast_date"].presence || source.to_h["period"].presence
        Date.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end
      source_dates.none?(&:nil?) && source_dates.all? { |date| date == snapshot.prediction_date }
    end

    def row_from_snapshot(snapshot)
      prediction = snapshot.kalshi_weather_prediction
      {
        id: snapshot.id,
        event_key: snapshot.event_ticker.presence || snapshot.market_ticker,
        market_ticker: snapshot.market_ticker,
        date: snapshot.prediction_date,
        captured_at: snapshot.captured_at,
        city: [prediction.city, prediction.state].compact_blank.join(", "),
        model_version: snapshot.payload.to_h["probability_model_version"],
        blind: snapshot.payload.to_h["blind_edge_mode"] == true,
        confidence: normalized_probability(snapshot.confidence),
        ask: normalized_probability(snapshot.ask),
        won: prediction.result_status == "won",
        source_count: snapshot.forecast_source_count.to_i,
        source_spread_f: snapshot.forecast_source_spread_f&.to_f,
        model_ready: snapshot.payload.to_h["probability_model_ready"] == true
      }
    end

    def training_rows_for(model_version:, before_date:)
      eligible = decision_rows
      eligible = eligible.select { |row| row.fetch(:date) < before_date } if before_date.present?
      exact = eligible.select { |row| row.fetch(:model_version) == model_version }
      exact.length >= MIN_FIT_EVENTS ? exact : eligible
    end

    def fit(rows)
      rows = Array(rows)
      intercept = 0.0
      slope = 0.0

      30.times do
        gradient_0 = -RIDGE_PENALTY * intercept
        gradient_1 = -RIDGE_PENALTY * slope
        information_00 = RIDGE_PENALTY
        information_01 = 0.0
        information_11 = RIDGE_PENALTY

        rows.each do |row|
          offset = logit(row.fetch(:ask))
          feature = model_delta(row.fetch(:confidence), row.fetch(:ask))
          probability = logistic(offset + intercept + (slope * feature))
          residual = (row.fetch(:won) ? 1.0 : 0.0) - probability
          weight = [probability * (1.0 - probability), 0.0001].max
          gradient_0 += residual
          gradient_1 += residual * feature
          information_00 += weight
          information_01 += weight * feature
          information_11 += weight * feature * feature
        end

        determinant = (information_00 * information_11) - (information_01 * information_01)
        break if determinant.abs < 1e-10

        delta_0 = ((information_11 * gradient_0) - (information_01 * gradient_1)) / determinant
        delta_1 = ((information_00 * gradient_1) - (information_01 * gradient_0)) / determinant
        intercept += delta_0
        slope += delta_1
        break if delta_0.abs < 1e-7 && delta_1.abs < 1e-7
      end

      information = information_matrix(rows, intercept: intercept, slope: slope)
      covariance = invert_2x2(information)
      {
        intercept: intercept.round(6),
        slope: slope.round(6),
        covariance: covariance,
        sample_size: rows.length
      }
    end

    def information_matrix(rows, intercept:, slope:)
      i00 = RIDGE_PENALTY
      i01 = 0.0
      i11 = RIDGE_PENALTY
      Array(rows).each do |row|
        feature = model_delta(row.fetch(:confidence), row.fetch(:ask))
        probability = logistic(logit(row.fetch(:ask)) + intercept + (slope * feature))
        weight = [probability * (1.0 - probability), 0.0001].max
        i00 += weight
        i01 += weight * feature
        i11 += weight * feature * feature
      end
      [[i00, i01], [i01, i11]]
    end

    def invert_2x2(matrix)
      a = matrix.dig(0, 0).to_f
      b = matrix.dig(0, 1).to_f
      d = matrix.dig(1, 1).to_f
      determinant = (a * d) - (b * b)
      return [[1.0, 0.0], [0.0, 1.0]] if determinant.abs < 1e-10

      [[d / determinant, -b / determinant], [-b / determinant, a / determinant]]
    end

    def calibrated_estimate(raw_probability:, market_probability:, training_rows:)
      if training_rows.length < MIN_FIT_EVENTS
        return {
          probability: market_probability,
          lower_bound: market_probability,
          training_scope: "market_only_until_minimum_sample",
          intercept: 0.0,
          slope: 0.0,
          adjustment_strength: 0.0,
          standard_error_logit: nil
        }
      end

      fitted = fit(training_rows)
      feature = model_delta(raw_probability, market_probability)
      strength = training_rows.length.to_f / (training_rows.length + 40.0)
      adjustment = strength * (fitted.fetch(:intercept) + (fitted.fetch(:slope) * feature))
      eta = logit(market_probability) + adjustment
      covariance = fitted.fetch(:covariance)
      variance = strength**2 * (
        covariance.dig(0, 0).to_f +
        (2.0 * feature * covariance.dig(0, 1).to_f) +
        (feature**2 * covariance.dig(1, 1).to_f)
      )
      standard_error = Math.sqrt([variance, 0.0].max)
      {
        probability: logistic(eta),
        lower_bound: logistic(eta - (LOWER_BOUND_Z * standard_error)),
        training_scope: training_rows.map { |row| row.fetch(:model_version) }.uniq.length == 1 ? "exact_model" : "pooled_station_normal",
        intercept: fitted.fetch(:intercept),
        slope: fitted.fetch(:slope),
        adjustment_strength: strength.round(4),
        standard_error_logit: standard_error.round(4)
      }
    end

    def walk_forward_metrics(training_rows, evaluation_rows)
      estimates = []
      evaluation_rows.group_by { |row| row.fetch(:date) }.sort.each do |date, date_rows|
        prior = training_rows.select { |row| row.fetch(:date) < date }
        next if prior.length < MIN_FIT_EVENTS

        date_rows.each do |row|
          model_rows = prior.select { |item| item.fetch(:model_version) == row.fetch(:model_version) }
          training = model_rows.length >= MIN_FIT_EVENTS ? model_rows : prior
          estimate = calibrated_estimate(
            raw_probability: row.fetch(:confidence),
            market_probability: row.fetch(:ask),
            training_rows: training
          )
          estimates << row.merge(
            calibrated_probability: estimate.fetch(:probability),
            calibrated_lower_bound: estimate.fetch(:lower_bound),
            calibration_training_events: training.length
          )
        end
      end

      challenger = historical_daily_allocations(estimates, strategy: :challenger)
      active = historical_daily_allocations(estimates, strategy: :active)
      {
        events: estimates.length,
        dates: estimates.map { |row| row.fetch(:date) }.uniq.length,
        raw_model: probability_metrics(estimates, :confidence),
        market: probability_metrics(estimates, :ask),
        calibrated: probability_metrics(estimates, :calibrated_probability),
        challenger: strategy_performance(challenger),
        active_shadow: strategy_performance(active)
      }
    end

    def fitted_metrics(rows)
      return probability_metrics([], :confidence) if rows.length < MIN_FIT_EVENTS

      fitted_rows = rows.map do |row|
        estimate = calibrated_estimate(
          raw_probability: row.fetch(:confidence),
          market_probability: row.fetch(:ask),
          training_rows: rows
        )
        row.merge(calibrated_probability: estimate.fetch(:probability))
      end
      probability_metrics(fitted_rows, :calibrated_probability)
    end

    def historical_candidate?(row, strategy:)
      price_range = strategy == :active ? LIVE_PRICE_RANGE : CHALLENGER_PRICE_RANGE
      return false unless price_range.cover?(row.fetch(:ask))
      return false if row.fetch(:source_count).to_i < (strategy == :active ? 3 : 2)
      return false if row[:source_spread_f].blank? || row.fetch(:source_spread_f).to_f > (strategy == :active ? 2.5 : 3.0)
      return false if strategy == :active && row.fetch(:blind)

      contracts = self.class.contracts_within_cap(price: row.fetch(:ask))
      return false unless contracts.positive?

      fee_per_contract = self.class.taker_fee(price: row.fetch(:ask), contracts: contracts) / contracts
      probability = strategy == :active ? row.fetch(:calibrated_lower_bound) : row.fetch(:calibrated_probability)
      minimum = strategy == :active ? LIVE_MIN_EDGE : CHALLENGER_MIN_EDGE
      probability - row.fetch(:ask) - fee_per_contract >= minimum
    end

    def historical_daily_allocations(rows, strategy:)
      Array(rows)
        .select { |row| historical_candidate?(row, strategy: strategy) }
        .group_by { |row| row.fetch(:date) }
        .values
        .filter_map do |date_rows|
          date_rows.max_by do |row|
            edge = if strategy == :active
              row.fetch(:calibrated_lower_bound) - row.fetch(:ask)
            else
              row.fetch(:calibrated_probability) - row.fetch(:ask)
            end
            [edge, row.fetch(:calibrated_probability), -row.fetch(:ask), -row.fetch(:id)]
          end
        end
        .sort_by { |row| [row.fetch(:date), row.fetch(:id)] }
    end

    def prospective_active_shadow_metrics
      return strategy_performance([]).merge(dates: 0) unless KalshiWeatherWager.storage_ready?

      wagers = organization.kalshi_weather_wagers
        .paper
        .for_strategy(Kalshi::WeatherPaperTrader::ACTIVE_STRATEGY)
        .where(status: %w[won lost])
        .order(:budget_date, :id)
        .to_a
      risk = wagers.sum do |wager|
        wager.max_cost.to_f + wager.metadata.to_h["estimated_taker_fee"].to_f
      end
      profit = wagers.sum { |wager| wager.realized_profit.to_f }
      {
        trades: wagers.length,
        wins: wagers.count { |wager| wager.display_result_status == "won" },
        losses: wagers.count { |wager| wager.display_result_status == "lost" },
        dates: wagers.map(&:budget_date).compact.uniq.length,
        risk: risk.round(2),
        profit: profit.round(2),
        roi_percent: risk.positive? ? ((profit / risk) * 100.0).round(1) : nil
      }
    rescue StandardError => error
      Rails.logger.warn("[WeatherCalibrationHarness] prospective active shadow unavailable: #{error.class}: #{error.message}")
      strategy_performance([]).merge(dates: 0)
    end

    def strategy_performance(rows)
      tickets = Array(rows).map { |row| ticket_result(row) }
      risk = tickets.sum { |ticket| ticket.fetch(:risk) }
      profit = tickets.sum { |ticket| ticket.fetch(:profit) }
      {
        trades: tickets.length,
        wins: tickets.count { |ticket| ticket.fetch(:won) },
        losses: tickets.count { |ticket| !ticket.fetch(:won) },
        risk: risk.round(2),
        profit: profit.round(2),
        roi_percent: risk.positive? ? ((profit / risk) * 100.0).round(1) : nil
      }
    end

    def ticket_result(row)
      price = row.fetch(:ask)
      contracts = self.class.contracts_within_cap(price: price)
      fee = self.class.taker_fee(price: price, contracts: contracts)
      premium = contracts * price
      profit = if row.fetch(:won)
        (contracts * (1.0 - price)) - fee
      else
        -premium - fee
      end
      { won: row.fetch(:won), risk: (premium + fee).round(2), profit: profit.round(2) }
    end

    def probability_metrics(rows, key)
      rows = Array(rows).select { |row| row[key].present? }
      return { events: 0, brier: nil, log_loss: nil, average_probability: nil, hit_rate: nil } if rows.blank?

      outcomes = rows.map { |row| row.fetch(:won) ? 1.0 : 0.0 }
      probabilities = rows.map { |row| normalized_probability(row.fetch(key)) }
      brier = probabilities.zip(outcomes).sum { |probability, outcome| (probability - outcome)**2 } / rows.length
      log_loss = probabilities.zip(outcomes).sum do |probability, outcome|
        probability = probability.clamp(0.001, 0.999)
        -((outcome * Math.log(probability)) + ((1.0 - outcome) * Math.log(1.0 - probability)))
      end / rows.length
      {
        events: rows.length,
        brier: brier.round(4),
        log_loss: log_loss.round(4),
        average_probability: (probabilities.sum / rows.length).round(4),
        hit_rate: (outcomes.sum / rows.length).round(4)
      }
    end

    def validation_gate(rows, walk_forward, prospective)
      reasons = []
      reasons << "need #{MIN_LIVE_TRAINING_EVENTS} immutable training events (have #{rows.length})" if rows.length < MIN_LIVE_TRAINING_EVENTS
      reasons << "need #{MIN_LIVE_OOS_EVENTS} walk-forward events (have #{walk_forward[:events]})" if walk_forward[:events].to_i < MIN_LIVE_OOS_EVENTS
      reasons << "need #{MIN_LIVE_OOS_DATES} walk-forward dates (have #{walk_forward[:dates]})" if walk_forward[:dates].to_i < MIN_LIVE_OOS_DATES

      calibrated_brier = walk_forward.dig(:calibrated, :brier)
      market_brier = walk_forward.dig(:market, :brier)
      if calibrated_brier.blank? || market_brier.blank? || calibrated_brier >= market_brier
        reasons << "calibrated walk-forward Brier must beat the market-price baseline"
      end

      active = walk_forward.fetch(:active_shadow)
      reasons << "need #{MIN_LIVE_OOS_TRADES} walk-forward active-policy days (have #{active[:trades]})" if active[:trades].to_i < MIN_LIVE_OOS_TRADES
      reasons << "walk-forward active-policy fee-adjusted profit must be positive" unless active[:profit].to_f.positive?
      reasons << "need #{MIN_LIVE_OOS_TRADES} settled prospective $5 paper-active days (have #{prospective[:trades]})" if prospective[:trades].to_i < MIN_LIVE_OOS_TRADES
      reasons << "prospective paper-active fee-adjusted profit must be positive" unless prospective[:profit].to_f.positive?

      {
        clear: reasons.blank?,
        status: reasons.blank? ? "clear" : "blocked",
        reasons: reasons,
        manual_promotion_required: true,
        evaluated_at: Time.current
      }
    end

    def data_gate_reason(prediction, metadata, strategy:)
      price_range = strategy == :active ? LIVE_PRICE_RANGE : CHALLENGER_PRICE_RANGE
      price = normalized_probability(prediction.ask)
      return "entry price outside #{(price_range.begin * 100).round}-#{(price_range.end * 100).round}c strategy range" unless price_range.cover?(price)
      return "forecast is not aligned to the market event date" unless metadata["forecast_event_date_aligned"] == true
      return "settlement-station coordinate metadata missing" unless metadata["forecast_coordinate_version"] == WeatherBucketProbability::COORDINATE_VERSION
      return "blind probabilities are research-only" if strategy == :active && metadata["blind_edge_mode"] == true
      return "station probability model is not ready" if strategy == :active && metadata["probability_model_ready"] != true
      return "forecast source count below #{strategy == :active ? 3 : 2}" if metadata["forecast_source_count"].to_i < (strategy == :active ? 3 : 2)

      spread = metadata["forecast_source_spread_f"]
      maximum_spread = strategy == :active ? 2.5 : 3.0
      return "forecast spread is unavailable" if spread.blank?
      return "forecast spread above #{maximum_spread}F" if spread.to_f > maximum_spread

      hard_gate = Array(metadata["gate_reasons"]).compact_blank.find do |reason|
        normalized = reason.to_s.downcase
        normalized.include?("stale") || normalized.include?("benched") || normalized.include?("missing") || normalized.include?("unavailable")
      end
      return "forecast gate blocking: #{hard_gate}" if hard_gate.present?

      nil
    end

    def rejected(strategy, reason)
      { ok: false, strategy: strategy.to_s, strategy_version: STRATEGY_VERSION, harness_version: VERSION, reason: reason }
    end

    def model_delta(raw_probability, market_probability)
      (logit(raw_probability) - logit(market_probability)).clamp(-6.0, 6.0)
    end

    def normalized_probability(value)
      return nil if value.blank?

      value.to_f.clamp(0.001, 0.999)
    end

    def logit(probability)
      probability = normalized_probability(probability)
      Math.log(probability / (1.0 - probability))
    end

    def logistic(value)
      return 1.0 if value > 35.0
      return 0.0 if value < -35.0

      1.0 / (1.0 + Math.exp(-value))
    end

    def empty_walk_forward
      {
        events: 0,
        dates: 0,
        raw_model: probability_metrics([], :confidence),
        market: probability_metrics([], :ask),
        calibrated: probability_metrics([], :calibrated_probability),
        challenger: strategy_performance([]),
        active_shadow: strategy_performance([])
      }
    end
  end
end
