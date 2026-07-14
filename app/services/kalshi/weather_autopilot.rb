# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "set"
require "uri"

module Kalshi
  class WeatherAutopilot
    HARD_LIVE_DAILY_CAP = 5.0
    LIVE_STRATEGY_KEY = "live_active".freeze
    LIVE_STRATEGY_VERSION = "calibrated_live_v3".freeze
    DEFAULT_LIMIT = 240
    DEFAULT_DAILY_CAP = HARD_LIVE_DAILY_CAP
    DEFAULT_MIN_DAILY_SPEND = 0.0
    DEFAULT_PER_ORDER_CAP = HARD_LIVE_DAILY_CAP
    DEFAULT_MIN_EDGE = 0.12
    DEFAULT_QUALIFIED_MIN_EDGE = 0.08
    DEFAULT_QUALIFIED_DAILY_CAP = HARD_LIVE_DAILY_CAP
    DEFAULT_MIN_CONFIDENCE = 0.55
    DEFAULT_MAX_ASK = 0.65
    DEFAULT_MAX_SOURCE_SPREAD_F = 3.0
    DEFAULT_MIN_SOURCE_COUNT = 2
    DEFAULT_MAX_SCAN_SPEND = HARD_LIVE_DAILY_CAP
    DEFAULT_QUALIFIED_MAX_SCAN_SPEND = HARD_LIVE_DAILY_CAP
    DEFAULT_MAX_POSITIONS_PER_SCAN = 3
    DEFAULT_MAX_MARKET_SHARE = 0.6
    DEFAULT_MIN_SCALE_INTERVAL_MINUTES = 20
    DEFAULT_EXPLORATION_DAILY_CAP = HARD_LIVE_DAILY_CAP
    DEFAULT_EXPLORATION_MAX_SCAN_SPEND = HARD_LIVE_DAILY_CAP
    DEFAULT_EXPLORATION_MIN_EDGE = 0.08
    DEFAULT_EXPLORATION_LONGSHOT_MIN_EDGE = 0.10
    DEFAULT_EXPLORATION_MIN_CONFIDENCE = 0.20
    DEFAULT_EXPLORATION_LONGSHOT_MIN_CONFIDENCE = 0.20
    DEFAULT_EXPLORATION_MAX_ASK = 0.25
    DEFAULT_EXPLORATION_MAX_SOURCE_SPREAD_F = 3.0
    DEFAULT_EXPLORATION_LONGSHOT_MAX_SOURCE_SPREAD_F = 2.0
    DEFAULT_EXPLORATION_MIN_SOURCE_COUNT = 3
    DEFAULT_REVIEW_AUTO_DAILY_CAP = HARD_LIVE_DAILY_CAP
    DEFAULT_REVIEW_AUTO_MAX_SCAN_SPEND = HARD_LIVE_DAILY_CAP
    DEFAULT_REVIEW_AUTO_MIN_EDGE = 0.08
    DEFAULT_REVIEW_AUTO_MIN_CONFIDENCE = 0.15
    DEFAULT_REVIEW_AUTO_MAX_ASK = 0.25
    DEFAULT_REVIEW_AUTO_MAX_SOURCE_SPREAD_F = 3.0
    DEFAULT_REVIEW_AUTO_MIN_SOURCE_COUNT = 3
    DEFAULT_MANUAL_BUY_MAX = HARD_LIVE_DAILY_CAP
    DEFAULT_LIVE_ORDER_PRICE_FLOOR = 0.01
    DEFAULT_MAX_EVENT_EXPOSURE = 5.0
    DEFAULT_MAX_CONSECUTIVE_LIVE_LOSSES = 3
    DEFAULT_LOSS_STREAK_COOLDOWN_HOURS = 24
    RISK_SETTINGS_KEY = "weather_autopilot".freeze
    REVIEW_AUTO_TIER = "autopilot_review_auto".freeze
    MANUAL_BUY_TIER = "autopilot_manual_buy".freeze
    DAILY_MINIMUM_TIER = "autopilot_daily_minimum".freeze
    MIN_CLOSE_BUFFER = 15.minutes
    QWEN_MAX_AGE = 24.hours
    KALSHI_BASE_URL = "https://external-api.kalshi.com".freeze

    class << self
      def call(organization:, limit: DEFAULT_LIMIT)
        new(organization: organization, limit: limit).call
      end

      def enabled?
        !truthy_false?(ENV["WIZWIKI_WEATHER_AUTOPILOT_ENABLED"])
      end

      def live_orders_enabled?
        defined?(Kalshi::AccountClient) && Kalshi::AccountClient.live_orders_enabled?
      end

      def daily_cap
        [money_env("WIZWIKI_WEATHER_AUTOPILOT_DAILY_CAP", DEFAULT_DAILY_CAP), HARD_LIVE_DAILY_CAP].min
      end

      def min_daily_spend
        0.0
      end

      def per_order_cap
        [money_env("WIZWIKI_WEATHER_AUTOPILOT_PER_ORDER_CAP", DEFAULT_PER_ORDER_CAP), HARD_LIVE_DAILY_CAP].min
      end

      def qualified_daily_cap
        [money_env("WIZWIKI_WEATHER_AUTOPILOT_QUALIFIED_DAILY_CAP", DEFAULT_QUALIFIED_DAILY_CAP), HARD_LIVE_DAILY_CAP].min
      end

      def exploration_daily_cap
        [money_env("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_DAILY_CAP", DEFAULT_EXPLORATION_DAILY_CAP), HARD_LIVE_DAILY_CAP].min
      end

      def live_order_price_floor
        money_env("WIZWIKI_WEATHER_AUTOPILOT_LIVE_ORDER_PRICE_FLOOR", DEFAULT_LIVE_ORDER_PRICE_FLOOR)
      end

      def exploration_enabled?
        !truthy_false?(ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_ENABLED", "false"))
      end

      def loss_streak_guard_enabled?
        !truthy_false?(ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_LOSS_STREAK_GUARD_ENABLED", "true"))
      end

      def model_validated?
        !truthy_false?(ENV.fetch("WIZWIKI_WEATHER_MODEL_VALIDATED", "false")) &&
          ENV["WIZWIKI_WEATHER_MODEL_VALIDATED_VERSION"].to_s.strip == LIVE_STRATEGY_VERSION
      end

      def blind_live_enabled?
        false
      end

      def max_event_exposure
        [money_env("WIZWIKI_WEATHER_AUTOPILOT_MAX_EVENT_EXPOSURE", DEFAULT_MAX_EVENT_EXPOSURE), HARD_LIVE_DAILY_CAP].min
      end

      def estimated_taker_fee_per_contract(price)
        price = price.to_f.clamp(0.0, 1.0)
        (0.07 * price * (1.0 - price)).round(4)
      end

      def estimated_taker_fee(price, contracts)
        return 0.0 unless contracts.to_i.positive?

        price = price.to_f.clamp(0.0, 1.0)
        raw = 0.07 * contracts.to_i * price * (1.0 - price)
        ((raw * 100.0).ceil / 100.0).round(2)
      end

      def contracts_within_cap(price, cap)
        price = price.to_f
        cap = [cap.to_f, HARD_LIVE_DAILY_CAP].min
        return 0 unless price.positive? && price < 1.0 && cap.positive?

        contracts = (cap / price).floor
        contracts -= 1 while contracts.positive? && ((contracts * price) + estimated_taker_fee(price, contracts)) > cap + 0.0001
        contracts
      end

      def fee_adjusted_edge(confidence:, price:)
        confidence.to_f - price.to_f - estimated_taker_fee_per_contract(price)
      end

      private

      def money_env(key, fallback)
        value = ENV.fetch(key, fallback).to_f
        value.positive? ? value.round(2) : fallback
      end

      def truthy_false?(value)
        value.to_s.strip.downcase.in?(%w[0 false no n off disabled])
      end
    end

    def initialize(organization:, limit:)
      @organization = organization
      requested_limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
      @limit = requested_limit.clamp(1, DEFAULT_LIMIT)
      @created = 0
      @updated = 0
      @placed = 0
      @settled = 0
      @skipped = 0
      @errors = []
    end

    def call
      return status("wager storage not ready") unless storage_ready?

      sync_account_settlements
      sync_settled_wagers
      return status("autopilot disabled") unless self.class.enabled?

      @portfolio_guard_status = portfolio_guard_status
      return status(@portfolio_guard_status[:reason]) unless @portfolio_guard_status[:allowed]
      return status(live_blocked_reason) unless live_execution_allowed?

      evaluate_portfolio

      status
    end

    def manual_buy(prediction_id:, amount:, user: nil)
      return { ok: false, error: "wager storage not ready" } unless storage_ready?

      guard = portfolio_guard_status
      return { ok: false, error: guard[:reason] } unless guard[:allowed]
      return { ok: false, error: live_blocked_reason } unless live_execution_allowed?

      prediction = organization.kalshi_weather_predictions
        .open_predictions
        .where("close_time IS NULL OR close_time > ?", MIN_CLOSE_BUFFER.from_now)
        .find_by(id: prediction_id)
      return { ok: false, error: "weather prediction is no longer open" } if prediction.blank?

      requested_budget = amount.to_f.round(2)
      return { ok: false, error: "choose a positive wager amount" } unless requested_budget.positive?

      allocation_budget = [requested_budget, manual_buy_max].min.round(2)
      verdict = manual_buy_candidate_verdict(prediction, requested_budget: requested_budget)
      return { ok: false, error: verdict.fetch(:reason) } unless verdict[:ok]

      wager = process_manual_allocation(prediction, verdict, allocation_budget, user: user)
      {
        ok: true,
        wager_id: wager.id,
        status: wager.status,
        market_ticker: wager.market_ticker,
        contracts: wager.contracts,
        max_cost: wager.max_cost.to_f.round(2),
        requested_budget: requested_budget,
        allocation_budget: allocation_budget,
        remaining_today: remaining_budget(Date.current).round(2),
        live_orders_enabled: live_orders_enabled?,
        qwen_ready: qwen_ready?
      }
    rescue StandardError => error
      Rails.logger.warn("[WeatherAutopilot] manual buy failed prediction=#{prediction_id}: #{error.class}: #{error.message}")
      { ok: false, error: "#{error.class}: #{error.message}" }
    end

    private

    attr_reader :organization, :limit

    def live_wagers
      organization.kalshi_weather_wagers.live
    end

    def live_strategy_wagers
      live_wagers.for_strategy(LIVE_STRATEGY_KEY)
    end

    def calibration_harness
      @calibration_harness ||= Kalshi::WeatherCalibrationHarness.new(organization: organization)
    end

    def calibration_gate
      calibration_harness.call.fetch(:live_gate)
    rescue StandardError => error
      {
        clear: false,
        status: "blocked",
        reasons: ["walk-forward calibration failed safely: #{error.class}"],
        manual_promotion_required: true
      }
    end

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        defined?(KalshiWeatherWager) &&
        KalshiWeatherWager.storage_ready? &&
        organization.respond_to?(:kalshi_weather_predictions) &&
        organization.respond_to?(:kalshi_weather_wagers)
    end

    def status(reason = nil)
      {
        created: @created,
        updated: @updated,
        placed: @placed,
        settled: @settled,
        skipped: @skipped,
        daily_cap: daily_cap,
        min_daily_spend: min_daily_spend,
        per_order_cap: per_order_cap,
        qualified_daily_cap: qualified_daily_cap,
        exploration_daily_cap: exploration_daily_cap,
        review_auto_daily_cap: review_auto_daily_cap,
        max_scan_spend: max_scan_spend,
        qualified_max_scan_spend: qualified_max_scan_spend,
        exploration_max_scan_spend: exploration_max_scan_spend,
        review_auto_max_scan_spend: review_auto_max_scan_spend,
        min_scale_interval_minutes: min_scale_interval_minutes,
        exploration_min_confidence: exploration_min_confidence,
        exploration_longshot_min_confidence: exploration_longshot_min_confidence,
        exploration_enabled: self.class.exploration_enabled?,
        review_auto_min_confidence: review_auto_min_confidence,
        portfolio_guard: @portfolio_guard_status || portfolio_guard_status,
        hard_live_cap: HARD_LIVE_DAILY_CAP,
        live_strategy_key: LIVE_STRATEGY_KEY,
        live_strategy_version: LIVE_STRATEGY_VERSION,
        calibration_gate: calibration_gate,
        live_orders_enabled: live_orders_enabled?,
        blind_edge_mode: blind_edge_mode?,
        blind_live_enabled: self.class.blind_live_enabled?,
        model_validated: self.class.model_validated?,
        max_event_exposure: max_event_exposure,
        qwen_ready: qwen_ready?,
        budget_start_date: budget_start_date&.iso8601,
        daily_budget_mode: "daily_only_no_rollover",
        accrued_budget: accrued_budget(Date.current).round(2),
        reserved_budget: budgeted_spend(Date.current).round(2),
        reserve_balance: remaining_budget(Date.current).round(2),
        remaining_today: remaining_budget(Date.current).round(2),
        target_spend_today: target_spend_today.round(2),
        errors: (reason.present? ? [reason] : @errors.first(5)),
        ran_at: Time.current
      }
    end

    def portfolio_guard_status
      return {
        allowed: true,
        status: "disabled",
        reason: "loss-streak guard disabled",
        consecutive_losses: 0,
        max_consecutive_losses: max_consecutive_live_losses,
        cooldown_until: nil
      } unless self.class.loss_streak_guard_enabled?

      reset_at = loss_guard_reset_at
      settled_scope = organization.kalshi_weather_wagers
        .where(execution_mode: "live", status: %w[won lost])
      settled_scope = settled_scope.where("COALESCE(settled_at, updated_at) > ?", reset_at) if reset_at.present?
      rows = settled_scope
        .order(Arel.sql("COALESCE(settled_at, updated_at) DESC"))
        .limit(12)
        .to_a
      consecutive_losses = rows.take_while { |wager| wager.display_result_status == "lost" }.length
      latest_settled_at = rows.first&.settled_at || rows.first&.updated_at
      cooldown_until = latest_settled_at&.+(loss_streak_cooldown_hours.hours)
      paused = consecutive_losses >= max_consecutive_live_losses
      guard_reason = if paused
        "automatic weather buys latched off after #{consecutive_losses} consecutive live losses; manual review and reset required"
      else
        "loss-streak guard active"
      end

      {
        allowed: !paused,
        status: paused ? "latched" : "active",
        reason: guard_reason,
        consecutive_losses: consecutive_losses,
        max_consecutive_losses: max_consecutive_live_losses,
        cooldown_until: cooldown_until,
        reset_at: reset_at,
        settled_sample: rows.length,
        realized_profit: rows.sum { |wager| wager.realized_profit.to_f }.round(2)
      }
    rescue StandardError => error
      {
        allowed: false,
        status: "error",
        reason: "automatic weather buys paused because portfolio safety could not be verified: #{error.class}",
        consecutive_losses: nil,
        max_consecutive_losses: max_consecutive_live_losses,
        cooldown_until: nil
      }
    end

    def fee_adjusted_edge_for(prediction, price)
      self.class.fee_adjusted_edge(confidence: execution_confidence(prediction), price: price)
    end

    def execution_confidence(prediction)
      value = metadata_for(prediction)["confidence_lower_bound"].presence
      value.present? ? value.to_f : 0.0
    end

    def percent_points(value)
      "#{(value.to_f * 100).round(1)} pt"
    end

    def candidates
      scope = organization.kalshi_weather_predictions
        .open_predictions
        .where("close_time IS NULL OR close_time > ?", MIN_CLOSE_BUFFER.from_now)
      if tracking_started_at.present?
        scope = scope.where("created_at >= ?", tracking_started_at)
      end
      scope
        .order(Arel.sql("edge DESC NULLS LAST, confidence DESC NULLS LAST, created_at DESC"))
        .limit(limit)
    end

    def exploration_candidates
      scope = organization.kalshi_weather_predictions
        .open_predictions
        .watch
        .where("close_time IS NULL OR close_time > ?", MIN_CLOSE_BUFFER.from_now)
        .where("edge >= ?", [exploration_min_edge, exploration_longshot_min_edge].min)
      if tracking_started_at.present?
        scope = scope.where("created_at >= ?", tracking_started_at)
      end
      scope
        .order(Arel.sql("edge DESC NULLS LAST, confidence DESC NULLS LAST, created_at DESC"))
        .limit(limit)
    end

    def daily_minimum_candidates
      scope = organization.kalshi_weather_predictions
        .open_predictions
        .watch
        .where("close_time IS NULL OR close_time > ?", MIN_CLOSE_BUFFER.from_now)
        .where("edge > 0")
      if tracking_started_at.present?
        scope = scope.where("created_at >= ?", tracking_started_at)
      end
      scope
        .order(Arel.sql("edge DESC NULLS LAST, confidence DESC NULLS LAST, ask ASC NULLS LAST, created_at DESC"))
        .limit(limit)
    end

    def evaluate_portfolio
      evaluated = candidates.map do |prediction|
        [prediction, candidate_verdict(prediction)]
      rescue StandardError => error
        @errors << "#{prediction.market_ticker}: #{error.class}: #{error.message}"
        mark_error(prediction, error)
        nil
      end.compact

      exploration_evaluated = if self.class.exploration_enabled?
        exploration_candidates.map do |prediction|
          [prediction, exploration_candidate_verdict(prediction)]
        rescue StandardError => error
          @errors << "#{prediction.market_ticker}: #{error.class}: #{error.message}"
          mark_error(prediction, error)
          nil
        end.compact
      else
        []
      end

      qualified = []
      evaluated.each do |prediction, verdict|
        if verdict[:ok]
          qualified << [prediction, verdict]
        else
          skip_or_note_prediction(prediction, verdict[:reason])
        end
      end
      exploration_evaluated.each do |prediction, verdict|
        if verdict[:ok]
          qualified << [prediction, verdict]
        elsif existing_budgeted_wager?(prediction)
          note_existing_budgeted_wager(prediction, verdict[:reason])
        end
      end
      allocations = portfolio_allocations(qualified)
      allocated_ids = allocations.map { |allocation| allocation.fetch(:prediction).id }.to_set

      qualified.each do |prediction, verdict|
        next if allocated_ids.include?(prediction.id)
        if existing_budgeted_wager?(prediction)
          note_existing_budgeted_wager(prediction, "one-entry rule: this market already has recorded exposure")
          next
        end
        next if exploration_verdict?(verdict)
        next if review_auto_verdict?(verdict)

        skip_prediction(prediction, "qualified but not selected: daily weather budget spread to stronger or earlier opportunities")
      end

      allocations.each do |allocation|
        process_allocation(
          allocation.fetch(:prediction),
          allocation.fetch(:verdict),
          allocation.fetch(:budget)
        )
      rescue StandardError => error
        prediction = allocation.fetch(:prediction)
        @errors << "#{prediction.market_ticker}: #{error.class}: #{error.message}"
        mark_error(prediction, error)
      end
    end

    def process_allocation(prediction, verdict, allocation_budget)
      budget_date = Date.current
      existing = live_strategy_wagers.find_by(kalshi_weather_prediction_id: prediction.id)
      any_existing = live_wagers.budgeted.find_by(kalshi_weather_prediction_id: prediction.id)
      if existing_position?(any_existing)
        return note_existing_budgeted_wager(prediction, "one-entry rule: this market already has recorded exposure")
      end
      reset_existing = resettable_unsubmitted_wager?(existing)
      if scaled_recently?(existing)
        return note_existing_budgeted_wager(
          prediction,
          "spacing out: same market scaled less than #{min_scale_interval_minutes} minutes ago"
        )
      end

      available = remaining_budget(budget_date, excluding: (reset_existing ? existing : nil))
      event_available = remaining_event_exposure(prediction, excluding: (reset_existing ? existing : nil))
      order_budget = [allocation_budget.to_f, available, event_available, per_order_cap].min.round(2)
      return skip_or_note_prediction(prediction, "daily cap already reserved") unless order_budget.positive?

      quoted_price = verdict.fetch(:price)
      order_price = executable_order_price(quoted_price)
      required_edge = verdict.fetch(:min_net_edge, 0.0).to_f
      contracts = self.class.contracts_within_cap(order_price, order_budget)
      return skip_or_note_prediction(prediction, "cap too small for one contract at #{format('%.2f', order_price)}") unless contracts.positive?

      max_cost = (contracts * order_price).round(2)
      estimated_fee = self.class.estimated_taker_fee(order_price, contracts)
      calibrated_lower_bound = verdict.dig(:metadata, "calibrated_lower_bound").to_f
      execution_edge = calibrated_lower_bound - order_price - (estimated_fee / contracts)
      return skip_or_note_prediction(prediction, "calibrated fee-adjusted edge fell below #{percent_points(required_edge)} at executable price") if execution_edge < required_edge

      wager = existing || organization.kalshi_weather_wagers.build(
        kalshi_weather_prediction: prediction,
        execution_mode: "live",
        strategy_key: LIVE_STRATEGY_KEY
      )
      was_new = wager.new_record?
      reset_wager = resettable_unsubmitted_wager?(wager)
      prior_contracts = reset_wager ? 0 : wager.contracts.to_i
      prior_cost = reset_wager ? 0.0 : wager.max_cost.to_f
      next_contracts = prior_contracts + contracts
      next_cost = (prior_cost + max_cost).round(2)
      order_client_id = next_client_order_id(wager, prediction)
      wager.assign_attributes(
        status: wager.status.in?(%w[won lost pushed void]) ? wager.status : "pending",
        execution_mode: "live",
        strategy_key: LIVE_STRATEGY_KEY,
        strategy_version: LIVE_STRATEGY_VERSION,
        side: "yes",
        action: "buy",
        market_ticker: prediction.market_ticker,
        client_order_id: reset_wager ? order_client_id : (wager.client_order_id.presence || order_client_id),
        contracts: next_contracts,
        price: average_price(next_cost, next_contracts),
        max_cost: next_cost,
        budget_date: budget_date,
        opportunity_tier: verdict.fetch(:tier),
        reason: verdict.fetch(:reason),
        metadata: wager.metadata.to_h.merge(verdict.fetch(:metadata)).merge(
          "autopilot_checked_at" => Time.current.iso8601,
          "live_orders_enabled" => live_orders_enabled?,
          "qwen_ready" => qwen_ready?,
          "live_blocked_reason" => live_blocked_reason,
          "daily_budget_mode" => "daily_only_no_rollover",
          "min_daily_spend" => min_daily_spend,
          "accrued_budget" => accrued_budget(budget_date).round(2),
          "reserved_budget" => budgeted_spend(budget_date, excluding: wager).round(2),
          "reserve_balance_before_order" => available.round(2),
          "event_exposure_before_order" => event_budgeted_spend(prediction, excluding: wager).round(2),
          "max_event_exposure" => max_event_exposure,
          "decision_snapshot" => wager.metadata.to_h["decision_snapshot"].presence || decision_snapshot_for(prediction, verdict, quoted_price),
          "last_allocation_budget" => allocation_budget.to_f.round(2),
          "last_incremental_contracts" => contracts,
          "last_incremental_cost" => max_cost,
          "last_incremental_estimated_fee" => estimated_fee,
          "estimated_taker_fee" => self.class.estimated_taker_fee(average_price(next_cost, next_contracts), next_contracts),
          "last_incremental_price" => order_price,
          "last_quoted_ask_price" => quoted_price,
          "last_executable_order_price" => order_price,
          "last_estimated_taker_fee_per_contract" => self.class.estimated_taker_fee_per_contract(order_price),
          "last_fee_adjusted_edge" => execution_edge.round(4),
          "live_order_price_floor" => live_order_price_floor,
          "reset_previous_unsubmitted_wager" => reset_wager,
          "last_scale_in_at" => Time.current.iso8601,
          "portfolio_allocator" => "daily_minimum_v5_city_diverse"
        ).compact
      )
      wager.save! if wager.changed?
      was_new ? @created += 1 : @updated += 1

      place_live_order(wager, contracts: contracts, price: order_price, client_order_id: order_client_id) if wager.status == "pending"
    end

    def process_manual_allocation(prediction, verdict, allocation_budget, user:)
      budget_date = Date.current
      existing = live_strategy_wagers.find_by(kalshi_weather_prediction_id: prediction.id)
      any_existing = live_wagers.budgeted.find_by(kalshi_weather_prediction_id: prediction.id)
      raise "one-entry rule: this market already has recorded exposure" if existing_position?(any_existing)
      reset_existing = resettable_unsubmitted_wager?(existing)
      available = remaining_budget(budget_date, excluding: (reset_existing ? existing : nil))
      event_available = remaining_event_exposure(prediction, excluding: (reset_existing ? existing : nil))
      order_budget = [allocation_budget.to_f, available, event_available, manual_buy_max].min.round(2)
      raise "daily cap already reserved" unless order_budget.positive?

      quoted_price = verdict.fetch(:price)
      order_price = executable_order_price(quoted_price)
      required_edge = verdict.fetch(:min_net_edge, 0.0).to_f
      contracts = self.class.contracts_within_cap(order_price, order_budget)
      raise "cap too small for one contract at #{format('%.2f', order_price)}" unless contracts.positive?

      max_cost = (contracts * order_price).round(2)
      estimated_fee = self.class.estimated_taker_fee(order_price, contracts)
      calibrated_lower_bound = verdict.dig(:metadata, "calibrated_lower_bound").to_f
      execution_edge = calibrated_lower_bound - order_price - (estimated_fee / contracts)
      raise "calibrated fee-adjusted edge fell below #{percent_points(required_edge)} at executable price" if execution_edge < required_edge

      wager = existing || organization.kalshi_weather_wagers.build(
        kalshi_weather_prediction: prediction,
        execution_mode: "live",
        strategy_key: LIVE_STRATEGY_KEY
      )
      was_new = wager.new_record?
      reset_wager = resettable_unsubmitted_wager?(wager)
      prior_contracts = reset_wager ? 0 : wager.contracts.to_i
      prior_cost = reset_wager ? 0.0 : wager.max_cost.to_f
      next_contracts = prior_contracts + contracts
      next_cost = (prior_cost + max_cost).round(2)
      order_client_id = next_client_order_id(wager, prediction)
      wager.assign_attributes(
        status: wager.status.in?(%w[won lost pushed void]) ? wager.status : "pending",
        execution_mode: "live",
        strategy_key: LIVE_STRATEGY_KEY,
        strategy_version: LIVE_STRATEGY_VERSION,
        side: "yes",
        action: "buy",
        market_ticker: prediction.market_ticker,
        client_order_id: reset_wager ? order_client_id : (wager.client_order_id.presence || order_client_id),
        contracts: next_contracts,
        price: average_price(next_cost, next_contracts),
        max_cost: next_cost,
        budget_date: budget_date,
        opportunity_tier: verdict.fetch(:tier),
        reason: verdict.fetch(:reason),
        metadata: wager.metadata.to_h.merge(verdict.fetch(:metadata)).merge(
          "manual_buy_requested_at" => Time.current.iso8601,
          "manual_buy_user_id" => user&.id,
          "manual_buy_user_email" => (user.respond_to?(:email) ? user.email : nil),
          "manual_buy_allocation_budget" => allocation_budget.to_f.round(2),
          "manual_buy_incremental_contracts" => contracts,
          "manual_buy_incremental_cost" => max_cost,
          "manual_buy_incremental_estimated_fee" => estimated_fee,
          "estimated_taker_fee" => self.class.estimated_taker_fee(average_price(next_cost, next_contracts), next_contracts),
          "manual_buy_incremental_price" => order_price,
          "manual_buy_quoted_ask_price" => quoted_price,
          "manual_buy_executable_order_price" => order_price,
          "manual_buy_estimated_taker_fee_per_contract" => self.class.estimated_taker_fee_per_contract(order_price),
          "manual_buy_fee_adjusted_edge" => execution_edge.round(4),
          "live_order_price_floor" => live_order_price_floor,
          "reset_previous_unsubmitted_wager" => reset_wager,
          "autopilot_checked_at" => Time.current.iso8601,
          "live_orders_enabled" => live_orders_enabled?,
          "qwen_ready" => qwen_ready?,
          "live_blocked_reason" => live_blocked_reason,
          "daily_budget_mode" => "daily_only_no_rollover",
          "reserved_budget" => budgeted_spend(budget_date, excluding: wager).round(2),
          "reserve_balance_before_order" => available.round(2),
          "event_exposure_before_order" => event_budgeted_spend(prediction, excluding: wager).round(2),
          "max_event_exposure" => max_event_exposure,
          "decision_snapshot" => wager.metadata.to_h["decision_snapshot"].presence || decision_snapshot_for(prediction, verdict, quoted_price),
          "portfolio_allocator" => "manual_weather_buy_v1"
        ).compact
      )
      wager.save!
      was_new ? @created += 1 : @updated += 1

      place_live_order(wager, contracts: contracts, price: order_price, client_order_id: order_client_id) if wager.status == "pending"
      wager.reload
    end

    def candidate_verdict(prediction)
      metadata = metadata_for(prediction)
      return reject("settlement-station forecast metadata missing") unless metadata["forecast_coordinate_version"] == Kalshi::WeatherBucketProbability::COORDINATE_VERSION
      return reject("blind probabilities are research-only") if blind_edge_mode? || metadata["blind_edge_mode"] == true
      return reject("station bucket probability model missing") unless metadata["probability_model_version"] == Kalshi::WeatherBucketProbability::MODEL_VERSION
      return reject("forecast date is not aligned to the market event") unless metadata["forecast_event_date_aligned"] == true
      return reject("station probability sample is not live-ready") unless metadata["probability_model_ready"] == true

      gate_reasons = Array(metadata["gate_reasons"]).compact_blank
      return reject("paper gate still blocking: #{gate_reasons.first}") if gate_reasons.present?

      evaluation = calibration_harness.evaluate(prediction, strategy: :active)
      return reject(evaluation.fetch(:reason)) unless evaluation[:ok]

      price = evaluation.fetch(:price)
      net_edge = evaluation.fetch(:conservative_edge)
      strong = net_edge >= min_edge
      {
        ok: true,
        price: price,
        min_net_edge: strong ? min_edge : qualified_min_edge,
        tier: strong ? "autopilot_strong" : "autopilot_qualified",
        reason: strong ? "strong fee-adjusted weather edge cleared live gates" : "qualified fee-adjusted weather edge cleared live gates",
        metadata: {
          "edge" => prediction.edge.to_f,
          "fee_adjusted_edge" => net_edge.round(4),
          "estimated_taker_fee" => evaluation[:estimated_fee],
          "confidence" => prediction.confidence.to_f,
          "confidence_lower_bound" => execution_confidence(prediction),
          "calibrated_probability" => evaluation[:calibrated_probability],
          "calibrated_lower_bound" => evaluation[:calibrated_lower_bound],
          "calibration_training_events" => evaluation[:training_events],
          "calibration_training_scope" => evaluation[:training_scope],
          "calibration_harness_version" => evaluation[:harness_version],
          "calibration_strategy_version" => evaluation[:strategy_version],
          "probability_model_version" => metadata["probability_model_version"],
          "probability_training_sample_size" => metadata["probability_training_sample_size"],
          "blind_edge_mode" => blind_edge_mode?,
          "forecast_source_count" => metadata["forecast_source_count"],
          "forecast_source_spread_f" => metadata["forecast_source_spread_f"],
          "daily_cap" => daily_cap,
          "per_order_cap" => per_order_cap,
          "qualified_daily_cap" => qualified_daily_cap,
          "exploration_daily_cap" => exploration_daily_cap,
          "review_auto_daily_cap" => review_auto_daily_cap,
          "max_scan_spend" => max_scan_spend,
          "qualified_max_scan_spend" => qualified_max_scan_spend,
          "exploration_max_scan_spend" => exploration_max_scan_spend,
          "review_auto_max_scan_spend" => review_auto_max_scan_spend,
          "min_scale_interval_minutes" => min_scale_interval_minutes,
          "min_edge" => min_edge,
          "qualified_min_edge" => qualified_min_edge,
          "min_confidence" => min_confidence,
          "max_ask" => max_ask,
          "qwen_analysis_id" => latest_qwen_analysis&.id,
          "qwen_analysis_updated_at" => latest_qwen_analysis&.updated_at&.iso8601
        }
      }
    end

    def reject(reason)
      { ok: false, reason: reason }
    end

    def manual_buy_candidate_verdict(prediction, requested_budget:)
      verdict = candidate_verdict(prediction)
      return verdict unless verdict[:ok]

      verdict.merge(
        tier: MANUAL_BUY_TIER,
        reason: "manual weather buy: #{verdict.fetch(:reason)}",
        metadata: verdict.fetch(:metadata).merge(
          "manual_buy" => true,
          "manual_buy_requested_budget" => requested_budget.to_f.round(2),
          "manual_buy_max" => manual_buy_max,
          "manual_buy_source_tier" => verdict.fetch(:tier),
          "manual_buy_source_reason" => verdict.fetch(:reason)
        )
      )
    end

    def exploration_candidate_verdict(prediction)
      return reject("live exploration is disabled; the calibrated challenger runs in the paper lane")

      price = entry_price(prediction)
      return reject("price unavailable") if price.blank?
      return reject("ask above #{(exploration_max_ask * 100).round}c exploration cap") if price > exploration_max_ask
      net_edge = fee_adjusted_edge_for(prediction, price)
      return reject("fee-adjusted edge below #{percent_points(exploration_min_edge)} exploration threshold") if net_edge < exploration_min_edge
      return reject("forecast source count below #{exploration_min_source_count} exploration threshold") if metadata_for(prediction)["forecast_source_count"].to_i < exploration_min_source_count

      spread = metadata_for(prediction)["forecast_source_spread_f"]
      return reject("forecast spread above #{exploration_max_source_spread_f}F exploration threshold") if spread.blank? || spread.to_f > exploration_max_source_spread_f

      gate_reasons = Array(metadata_for(prediction)["gate_reasons"]).compact_blank
      hard_gates = hard_exploration_gate_reasons(gate_reasons)
      return reject("exploration hard gate blocking: #{hard_gates.first}") if hard_gates.present?

      longshot_lab = longshot_exploration_candidate?(prediction, price, spread, gate_reasons)
      normal_exploration = prediction.confidence.to_f >= exploration_min_confidence
      unless normal_exploration || longshot_lab
        return reject("confidence below #{(exploration_min_confidence * 100).round}% exploration threshold")
      end

      {
        ok: true,
        price: price,
        min_net_edge: longshot_lab ? exploration_longshot_min_edge : exploration_min_edge,
        tier: longshot_lab ? "autopilot_exploration_longshot" : "autopilot_exploration",
        reason: longshot_lab ? "tiny long-shot exploration: 20%+ confidence with cheap price, 10pt edge, and tight sources" : "tiny exploration wager: 20%+ confidence with positive weather edge",
        metadata: {
          "edge" => prediction.edge.to_f,
          "fee_adjusted_edge" => net_edge.round(4),
          "estimated_taker_fee_per_contract" => self.class.estimated_taker_fee_per_contract(price),
          "confidence" => prediction.confidence.to_f,
          "forecast_source_count" => metadata_for(prediction)["forecast_source_count"],
          "forecast_source_spread_f" => metadata_for(prediction)["forecast_source_spread_f"],
          "daily_cap" => daily_cap,
          "per_order_cap" => per_order_cap,
          "exploration_daily_cap" => exploration_daily_cap,
          "exploration_max_scan_spend" => exploration_max_scan_spend,
          "exploration_min_edge" => exploration_min_edge,
          "exploration_longshot_min_edge" => exploration_longshot_min_edge,
          "exploration_min_confidence" => exploration_min_confidence,
          "exploration_longshot_min_confidence" => exploration_longshot_min_confidence,
          "exploration_max_ask" => exploration_max_ask,
          "exploration_gate_reasons_allowed" => gate_reasons,
          "qwen_analysis_id" => latest_qwen_analysis&.id,
          "qwen_analysis_updated_at" => latest_qwen_analysis&.updated_at&.iso8601
        }
      }
    end

    def daily_minimum_candidate_verdict(prediction)
      return reject("forced daily deployment is disabled; no-trade is a valid live decision")

      price = entry_price(prediction)
      return reject("price unavailable") if price.blank?
      return reject("ask above #{(exploration_max_ask * 100).round}c daily-minimum cap") if price > exploration_max_ask
      return reject("edge not positive enough for daily minimum") unless prediction.edge.to_f.positive?
      return reject("forecast source count below #{min_source_count} daily-minimum threshold") if metadata_for(prediction)["forecast_source_count"].to_i < min_source_count

      spread = metadata_for(prediction)["forecast_source_spread_f"]
      return reject("forecast spread above #{max_source_spread_f}F daily-minimum threshold") if spread.blank? || spread.to_f > max_source_spread_f

      gate_reasons = Array(metadata_for(prediction)["gate_reasons"]).compact_blank
      hard_gates = hard_exploration_gate_reasons(gate_reasons)
      return reject("daily-minimum hard gate blocking: #{hard_gates.first}") if hard_gates.present?

      {
        ok: true,
        price: price,
        tier: DAILY_MINIMUM_TIER,
        reason: "daily minimum weather wager: positive edge with cheap price and clean source spread",
        metadata: {
          "edge" => prediction.edge.to_f,
          "confidence" => prediction.confidence.to_f,
          "forecast_source_count" => metadata_for(prediction)["forecast_source_count"],
          "forecast_source_spread_f" => metadata_for(prediction)["forecast_source_spread_f"],
          "daily_cap" => daily_cap,
          "per_order_cap" => per_order_cap,
          "min_daily_spend" => min_daily_spend,
          "daily_minimum_tier" => DAILY_MINIMUM_TIER,
          "exploration_max_ask" => exploration_max_ask,
          "max_source_spread_f" => max_source_spread_f,
          "qwen_analysis_id" => latest_qwen_analysis&.id,
          "qwen_analysis_updated_at" => latest_qwen_analysis&.updated_at&.iso8601
        }
      }
    end

    def review_auto_candidate_verdict(prediction)
      return reject("review-auto is paper-only until the walk-forward gate passes")

      price = entry_price(prediction)
      return reject("price unavailable") if price.blank?
      return reject("ask above #{(review_auto_max_ask * 100).round}c review-auto cap") if price > review_auto_max_ask
      net_edge = fee_adjusted_edge_for(prediction, price)
      return reject("fee-adjusted edge below #{percent_points(review_auto_min_edge)} review-auto threshold") if net_edge < review_auto_min_edge
      return reject("confidence below #{(review_auto_min_confidence * 100).round}% review-auto threshold") if prediction.confidence.to_f < review_auto_min_confidence
      return reject("forecast source count below #{review_auto_min_source_count} review-auto threshold") if metadata_for(prediction)["forecast_source_count"].to_i < review_auto_min_source_count

      spread = metadata_for(prediction)["forecast_source_spread_f"]
      return reject("forecast spread above #{review_auto_max_source_spread_f}F review-auto cap") if spread.blank? || spread.to_f > review_auto_max_source_spread_f

      gate_reasons = Array(metadata_for(prediction)["gate_reasons"]).compact_blank
      hard_gates = hard_review_auto_gate_reasons(gate_reasons)
      return reject("review-auto hard gate blocking: #{hard_gates.first}") if hard_gates.present?

      {
        ok: true,
        price: price,
        min_net_edge: review_auto_min_edge,
        tier: REVIEW_AUTO_TIER,
        reason: "review-auto daily weather wager: positive edge with acceptable confidence and bounded caution gates",
        metadata: {
          "edge" => prediction.edge.to_f,
          "fee_adjusted_edge" => net_edge.round(4),
          "estimated_taker_fee_per_contract" => self.class.estimated_taker_fee_per_contract(price),
          "confidence" => prediction.confidence.to_f,
          "forecast_source_count" => metadata_for(prediction)["forecast_source_count"],
          "forecast_source_spread_f" => metadata_for(prediction)["forecast_source_spread_f"],
          "daily_cap" => daily_cap,
          "per_order_cap" => per_order_cap,
          "min_daily_spend" => min_daily_spend,
          "review_auto_daily_cap" => review_auto_daily_cap,
          "review_auto_max_scan_spend" => review_auto_max_scan_spend,
          "review_auto_min_edge" => review_auto_min_edge,
          "review_auto_min_confidence" => review_auto_min_confidence,
          "review_auto_max_ask" => review_auto_max_ask,
          "review_auto_max_source_spread_f" => review_auto_max_source_spread_f,
          "review_auto_gate_reasons_allowed" => gate_reasons,
          "qwen_analysis_id" => latest_qwen_analysis&.id,
          "qwen_analysis_updated_at" => latest_qwen_analysis&.updated_at&.iso8601
        }
      }
    end

    def portfolio_allocations(qualified)
      remaining = remaining_budget(Date.current).round(2)
      return [] unless remaining.positive?

      qualified = qualified.reject { |prediction, _verdict| existing_budgeted_wager?(prediction) }
      return [] if qualified.blank?

      strong = qualified.select { |_prediction, verdict| verdict[:tier] == "autopilot_strong" }
      normal = qualified.select { |_prediction, verdict| verdict[:tier] == "autopilot_qualified" }
      exploration = qualified.select { |_prediction, verdict| exploration_verdict?(verdict) }
      review_auto = qualified.select { |_prediction, verdict| review_auto_verdict?(verdict) }
      selected = strong.presence || normal.presence || exploration.presence || review_auto
      return [] if selected.blank?

      tier_cap = tier_cap_for(selected)
      scan_limit = scan_limit_for(selected)
      tier_remaining = tier_remaining_for(selected, tier_cap)
      scan_budget = [remaining, tier_remaining, scan_limit].min.round(2)
      return [] unless scan_budget.positive?

      selected = selected
        .sort_by { |prediction, verdict| [-prediction.edge.to_f, -prediction.confidence.to_f, verdict.fetch(:price).to_f] }
      selected = city_diverse_selection(selected).first(max_positions_per_scan)

      weighted_budget_allocations(selected, scan_budget)
    end

    def city_diverse_selection(ranked)
      primary = []
      overflow = []
      seen = Set.new

      ranked.each do |item|
        prediction = item.first
        key = city_key(prediction)
        if key.present? && !seen.include?(key)
          seen << key
          primary << item
        else
          overflow << item
        end
      end

      primary + overflow
    end

    def city_key(prediction)
      [prediction.city, prediction.state].compact_blank.map { |value| value.to_s.squish.downcase }.join("|")
    end

    def weighted_budget_allocations(selected, scan_budget)
      weights = selected.map { |prediction, verdict| allocation_weight(prediction, verdict) }
      total_weight = weights.sum
      return [] unless total_weight.positive?

      caps = selected.map { selected.length > 1 ? (scan_budget * max_market_share) : scan_budget }
      budgets = selected.map.with_index do |_item, index|
        raw_budget = scan_budget * (weights[index] / total_weight)
        [raw_budget, caps[index]].min
      end
      redistribute_unused_budget!(budgets, caps, weights, scan_budget)

      selected.map.with_index do |(prediction, verdict), index|
        { prediction: prediction, verdict: verdict, budget: budgets[index] }
      end
    end

    def redistribute_unused_budget!(budgets, caps, weights, scan_budget)
      remaining = scan_budget.to_f - budgets.sum
      4.times do
        break unless remaining > 0.005

        eligible = budgets.each_index.select { |index| budgets[index] < caps[index] - 0.005 }
        break if eligible.blank?

        total_weight = eligible.sum { |index| weights[index].to_f }
        break unless total_weight.positive?

        allocated = 0.0
        eligible.each do |index|
          room = caps[index] - budgets[index]
          extra = [remaining * (weights[index].to_f / total_weight), room].min
          budgets[index] += extra
          allocated += extra
        end
        break unless allocated > 0.005

        remaining -= allocated
      end
      budgets.map! { |budget| budget.round(2) }
    end

    def allocation_weight(prediction, verdict)
      if review_auto_verdict?(verdict)
        ask_bonus = [[review_auto_max_ask - verdict.fetch(:price).to_f, 0.0].max, 0.25].min
        return (fee_adjusted_edge_for(prediction, verdict.fetch(:price)) * 3.0) + (prediction.confidence.to_f * 4.0) + (ask_bonus * 0.5)
      end

      edge_weight = [fee_adjusted_edge_for(prediction, verdict.fetch(:price)), 0.01].max
      confidence_weight = [prediction.confidence.to_f, 0.01].max
      price = verdict.fetch(:price).to_f
      price_weight = price.positive? ? (1.0 / price) : 1.0
      (edge_weight * 3.0) + confidence_weight + (price_weight * 0.03)
    end

    def exploration_verdict?(verdict)
      verdict[:tier].to_s.start_with?("autopilot_exploration")
    end

    def review_auto_verdict?(verdict)
      verdict[:tier] == REVIEW_AUTO_TIER
    end

    def daily_minimum_verdict?(verdict)
      verdict[:tier] == DAILY_MINIMUM_TIER
    end

    def longshot_exploration_candidate?(prediction, price, spread, gate_reasons)
      price.to_f < 0.20 &&
        prediction.confidence.to_f >= exploration_longshot_min_confidence &&
        prediction.edge.to_f >= exploration_longshot_min_edge &&
        spread.to_f <= exploration_longshot_max_source_spread_f &&
        gate_reasons.present? &&
        gate_reasons.all? { |reason| cheap_longshot_gate?(reason) }
    end

    def hard_exploration_gate_reasons(gate_reasons)
      Array(gate_reasons).reject { |reason| cheap_longshot_gate?(reason) }
    end

    def hard_review_auto_gate_reasons(gate_reasons)
      Array(gate_reasons).select do |reason|
        normalized = reason.to_s.downcase
        normalized.include?("benched") ||
          normalized.include?("probation") ||
          normalized.include?("stale forecast") ||
          normalized.include?("stale-forecast") ||
          normalized.include?("cheap long-shot blocked") ||
          normalized.include?("edge below") ||
          normalized.include?("ask above") ||
          normalized.include?("source count below") ||
          normalized.include?("missing") ||
          normalized.include?("unavailable")
      end
    end

    def cheap_longshot_gate?(reason)
      reason.to_s.start_with?("cheap long-shot blocked")
    end

    def tier_cap_for(selected)
      return remaining_budget(Date.current) if blind_edge_mode?

      verdict = selected.first.last
      return remaining_budget(Date.current) if verdict[:tier] == "autopilot_strong"
      return review_auto_daily_cap if review_auto_verdict?(verdict)
      return min_daily_spend if daily_minimum_verdict?(verdict)
      return exploration_daily_cap if exploration_verdict?(verdict)

      qualified_daily_cap
    end

    def scan_limit_for(selected)
      return remaining_budget(Date.current) if blind_edge_mode?

      verdict = selected.first.last
      return strong_scan_limit if verdict[:tier] == "autopilot_strong"
      return review_auto_max_scan_spend if review_auto_verdict?(verdict)
      return min_daily_spend if daily_minimum_verdict?(verdict)
      return exploration_max_scan_spend if exploration_verdict?(verdict)

      qualified_max_scan_spend
    end

    def tier_remaining_for(selected, tier_cap)
      return remaining_budget(Date.current) if blind_edge_mode?

      verdict = selected.first.last
      return remaining_budget(Date.current) if verdict[:tier] == "autopilot_strong"
      return [min_daily_spend - budgeted_spend(Date.current), 0.0].max if daily_minimum_verdict?(verdict)

      tiers = if verdict[:tier] == "autopilot_strong"
        ["autopilot_strong"]
      elsif exploration_verdict?(verdict)
        ["autopilot_exploration", "autopilot_exploration_longshot"]
      elsif review_auto_verdict?(verdict)
        [REVIEW_AUTO_TIER]
      else
        ["autopilot_qualified"]
      end
      spent = live_wagers
        .budgeted
        .where(budget_date: Date.current, opportunity_tier: tiers)
        .to_a
        .sum { |wager| budgeted_wager_cost(wager) }
      [tier_cap.to_f - spent, 0.0].max
    end

    def scaled_recently?(wager)
      return false unless wager&.persisted?
      return false unless wager.status.in?(%w[pending placed filled])
      return false unless min_scale_interval_minutes.positive?

      last_scale = parsed_time(wager.metadata.to_h["last_scale_in_at"]) || wager.placed_at || wager.created_at
      last_scale.present? && last_scale > min_scale_interval_minutes.minutes.ago
    end

    def existing_budgeted_wager?(prediction)
      live_wagers
        .budgeted
        .exists?(kalshi_weather_prediction_id: prediction.id)
    end

    def existing_position?(wager)
      return false if wager.blank?

      wager.filled_contracts.to_i.positive? ||
        wager.actual_cost.to_f.positive? ||
        (wager.contracts.to_i.positive? && wager.status.in?(%w[pending placed filled]))
    end

    def remaining_event_exposure(prediction, excluding: nil)
      [max_event_exposure - event_budgeted_spend(prediction, excluding: excluding), 0.0].max
    end

    def event_budgeted_spend(prediction, excluding: nil)
      event_ticker = prediction.event_ticker.to_s.presence
      return 0.0 if event_ticker.blank?

      scope = live_wagers
        .joins(:kalshi_weather_prediction)
        .where(kalshi_weather_predictions: { event_ticker: event_ticker })
      scope = scope.where.not(id: excluding.id) if excluding&.persisted?
      scope.to_a.sum do |wager|
        next 0.0 unless wager.status.in?(%w[pending placed filled won lost pushed]) || wager.filled_contracts.to_i.positive? || wager.actual_cost.to_f.positive?

        budgeted_wager_cost(wager)
      end.round(2)
    end

    def decision_snapshot_for(prediction, verdict, quoted_price)
      metadata = metadata_for(prediction)
      {
        "captured_at" => Time.current.iso8601,
        "prediction_id" => prediction.id,
        "market_ticker" => prediction.market_ticker,
        "event_ticker" => prediction.event_ticker,
        "prediction_date" => prediction.prediction_date&.iso8601,
        "forecast_high_f" => prediction.forecast_high_f,
        "adjusted_high_f" => prediction.adjusted_high_f,
        "market_floor_strike" => prediction.market_floor_strike,
        "market_cap_strike" => prediction.market_cap_strike,
        "confidence" => prediction.confidence,
        "confidence_lower_bound" => execution_confidence(prediction),
        "calibrated_probability" => verdict.dig(:metadata, "calibrated_probability"),
        "calibrated_lower_bound" => verdict.dig(:metadata, "calibrated_lower_bound"),
        "ask" => quoted_price,
        "edge" => prediction.edge,
        "fee_adjusted_edge" => verdict.dig(:metadata, "fee_adjusted_edge"),
        "calibration_harness_version" => verdict.dig(:metadata, "calibration_harness_version"),
        "calibration_strategy_version" => verdict.dig(:metadata, "calibration_strategy_version"),
        "probability_model_version" => metadata["probability_model_version"],
        "probability_training_sample_size" => metadata["probability_training_sample_size"],
        "forecast_coordinate_version" => metadata["forecast_coordinate_version"],
        "forecast_station_id" => metadata["forecast_station_id"],
        "forecast_source_count" => metadata["forecast_source_count"],
        "forecast_source_spread_f" => metadata["forecast_source_spread_f"],
        "gate_reasons" => Array(metadata["gate_reasons"]),
        "tier" => verdict[:tier]
      }.compact
    end

    def skip_or_note_prediction(prediction, reason)
      return note_existing_budgeted_wager(prediction, reason) if existing_budgeted_wager?(prediction)

      skip_prediction(prediction, reason)
    end

    def note_existing_budgeted_wager(prediction, reason)
      wager = live_wagers.budgeted.find_by(kalshi_weather_prediction_id: prediction.id)
      return if wager.blank?

      wager.update!(
        metadata: wager.metadata.to_h.merge(
          "autopilot_checked_at" => Time.current.iso8601,
          "latest_allocator_note" => reason,
          "live_orders_enabled" => live_orders_enabled?,
          "qwen_ready" => qwen_ready?
        )
      )
    end

    def skip_prediction(prediction, reason)
      @skipped += 1
      live_strategy_wagers.find_or_initialize_by(kalshi_weather_prediction: prediction).tap do |wager|
        wager.assign_attributes(
          status: "skipped",
          execution_mode: "live",
          strategy_key: LIVE_STRATEGY_KEY,
          strategy_version: LIVE_STRATEGY_VERSION,
          side: "yes",
          action: "buy",
          market_ticker: prediction.market_ticker,
          contracts: 0,
          price: entry_price(prediction),
          max_cost: 0,
          budget_date: Date.current,
          reason: reason,
          metadata: wager.metadata.to_h.merge(
            "autopilot_checked_at" => Time.current.iso8601,
            "live_orders_enabled" => live_orders_enabled?,
            "qwen_ready" => qwen_ready?
          )
        )
        wager.save! if wager.changed?
      end
    end

    def place_live_order(wager, contracts:, price:, client_order_id:)
      market = fetch_market(wager.market_ticker)
      live_ask = market_price(market, "yes_ask_dollars", "yes_ask")
      raise "live ask unavailable before order" if live_ask.blank?
      raise "live ask moved above cap: #{live_ask}" if live_ask.to_f > price.to_f
      visible_contracts = numeric_from_hash(market, "yes_ask_size_fp", "yes_ask_size")&.floor
      contracts = [contracts.to_i, visible_contracts].min if visible_contracts.to_i.positive?
      raise "no visible contracts available at the live ask" unless contracts.positive?

      payload = {
        ticker: wager.market_ticker,
        client_order_id: client_order_id,
        side: wager.side,
        action: wager.action,
        type: "limit",
        count: contracts,
        price: price.to_f.round(4),
        time_in_force: "fill_or_kill"
      }
      response = begin
        Kalshi::AccountClient.new.create_order!(payload)
      rescue StandardError => error
        if unfilled_fill_or_kill_error?(error, wager)
          record_unfilled_fill_or_kill!(wager, payload, error, contracts: contracts, price: price)
          return
        end

        wager.update!(
          metadata: wager.metadata.to_h.merge(
            "live_order_error" => "#{error.class}: #{error.message}".truncate(280),
            "live_order_error_at" => Time.current.iso8601,
            "live_order_limit_price" => price.to_f.round(4),
            "live_order_price_floor" => live_order_price_floor
          ),
          raw_payload: append_order_payload(
            wager.raw_payload,
            payload,
            {
              "error_class" => error.class.name,
              "error_message" => error.message.to_s.truncate(500)
            }
          )
        )
        raise
      end
      order = response.to_h["order"].to_h.presence || response.to_h
      filled = fill_count(order)
      if filled <= 0
        record_unfilled_fill_or_kill!(wager, payload, nil, contracts: contracts, price: price, response: response)
        return
      end
      raw_payload = append_order_payload(wager.raw_payload, payload, response)
      next_filled_contracts = wager.filled_contracts.to_i + filled
      next_actual_cost = (wager.actual_cost.to_f + order_cost(order, contracts, price)).round(2)
      next_fee_paid = (stored_wager_actual_fee_paid(wager) + order_response_fee(order)).round(2)
      filled_average_price = average_price(next_actual_cost, next_filled_contracts)
      wager.update!(
        status: "filled",
        execution_mode: "live",
        kalshi_order_id: wager.kalshi_order_id.presence || order.values_at("order_id", "id").compact_blank.first,
        contracts: next_filled_contracts,
        filled_contracts: next_filled_contracts,
        price: filled_average_price || wager.price,
        max_cost: next_actual_cost,
        actual_cost: next_actual_cost,
        placed_at: wager.placed_at || Time.current,
        filled_at: Time.current,
        metadata: wager.metadata.to_h.except("live_order_error", "live_order_error_at").merge(
          "live_fees_paid" => next_fee_paid,
          "last_live_order_succeeded_at" => Time.current.iso8601
        ),
        raw_payload: raw_payload
      )
      @placed += 1
    end

    def sync_settled_wagers
      organization.kalshi_weather_wagers.open_journal.includes(:kalshi_weather_prediction).find_each do |wager|
        prediction = wager.kalshi_weather_prediction
        next if prediction.blank? || prediction.result_status == "pending"

        result = prediction.result_status.to_s
        wager.update!(
          status: result.in?(%w[won lost pushed void]) ? result : "error",
          realized_profit: realized_profit(wager, result),
          settled_at: Time.current,
          metadata: wager.metadata.to_h.merge(
            "settled_from_prediction_at" => Time.current.iso8601,
            "prediction_result_status" => result
          ).merge(prediction_settlement_training_metadata(prediction))
        )
        @settled += 1
      end
    end

    def sync_account_settlements
      return if Rails.env.test?
      return unless defined?(Kalshi::AccountClient) && Kalshi::AccountClient.configured?

      Array(Kalshi::AccountClient.settlements(limit: 100)).each do |settlement|
        sync_account_settlement(settlement)
      end
    rescue StandardError => error
      @errors << "Kalshi account settlement sync: #{error.class}: #{error.message}"
    end

    def sync_account_settlement(settlement)
      settlement = settlement.to_h.with_indifferent_access
      ticker = settlement[:ticker].to_s.squish
      return if ticker.blank?

      organization.kalshi_weather_wagers
        .where(execution_mode: "live", market_ticker: ticker)
        .includes(:kalshi_weather_prediction)
        .find_each do |wager|
          result = account_settlement_result(wager, settlement)
          next if result.blank?

          payout = account_settlement_payout(settlement)
          cost = account_settlement_cost(wager, settlement)
          fee = settlement[:fee_cost].to_f
          profit = (payout - cost - fee).round(2)
          settled_at = parse_account_settlement_time(settlement[:settled_time]) || Time.current
          previous_signature = [wager.status, wager.realized_profit.to_f.round(2), wager.settled_at&.to_i]

          sync_prediction_from_account_settlement(
            wager.kalshi_weather_prediction,
            settlement: settlement,
            result: result,
            payout: payout,
            profit: profit,
            settled_at: settled_at
          )

          wager.update!(
            status: result,
            realized_profit: profit,
            settled_at: settled_at,
            metadata: wager.metadata.to_h.merge(
              "settled_from_account_at" => Time.current.iso8601,
              "account_settlement_result_status" => result,
              "account_settlement_revenue_dollars" => payout.round(2),
              "account_settlement_cost_dollars" => cost.round(2),
              "account_settlement_fee_dollars" => fee.round(2),
              "account_settlement_profit_dollars" => profit,
              "account_settlement_payload" => account_settlement_payload(settlement)
            ).merge(prediction_settlement_training_metadata(wager.kalshi_weather_prediction))
          )

          current_signature = [wager.status, wager.realized_profit.to_f.round(2), wager.settled_at&.to_i]
          @settled += 1 if current_signature != previous_signature
        end
    end

    def sync_prediction_from_account_settlement(prediction, settlement:, result:, payout:, profit:, settled_at:)
      return if prediction.blank?

      prior_result = prediction.result_status
      prediction.update!(
        status: "settled",
        result_status: result,
        settlement_value: "Kalshi #{settlement[:market_result].to_s.upcase.presence || result}",
        metadata: prediction.metadata.to_h.merge(
          "kalshi_account_reconciled_at" => Time.current.iso8601,
          "kalshi_account_result_status" => result,
          "kalshi_account_previous_result_status" => prior_result,
          "kalshi_account_overrode_observed_result" => prior_result.present? && prior_result != result,
          "kalshi_account_settled_at" => settled_at.iso8601,
          "kalshi_account_revenue_dollars" => payout.round(2),
          "kalshi_account_profit_dollars" => profit,
          "kalshi_account_settlement_payload" => account_settlement_payload(settlement)
        ),
        training_note: account_settlement_training_note(prediction, result: result, payout: payout, profit: profit)
      )
    end

    def prediction_settlement_training_metadata(prediction)
      return {} if prediction.blank?

      {
        "observed_high_f" => prediction.observed_high_f,
        "prediction_forecast_high_f" => prediction.forecast_high_f,
        "prediction_adjusted_high_f" => prediction.adjusted_high_f,
        "prediction_market_floor_strike" => prediction.market_floor_strike,
        "prediction_market_cap_strike" => prediction.market_cap_strike,
        "prediction_forecast_error_f" => prediction.forecast_error_f,
        "prediction_adjusted_error_f" => prediction.adjusted_error_f,
        "prediction_market_distance_f" => prediction.market_distance_f,
        "prediction_observed_inside_market" => prediction.observed_inside_market?,
        "prediction_miss_cause" => prediction.miss_cause,
        "prediction_miss_cause_label" => prediction.miss_cause_label
      }.compact
    end

    def account_settlement_training_note(prediction, result:, payout:, profit:)
      note = "Live wager settled #{result} by Kalshi account settlement. Gross payout #{format('$%.2f', payout)}, net P/L #{format('$%.2f', profit)}. Official Kalshi settlement is the wager P/L source of truth."
      return "#{note} Observed weather backfill remains diagnostic." if prediction.blank? || prediction.observed_high_f.blank?

      "#{note} Weather diagnostic: actual high #{prediction.observed_high_f}F vs #{prediction.market_band_label}; market-distance miss #{prediction.market_distance_f || 'n/a'}F; AUTOS forecast error #{prediction.adjusted_error_f || 'n/a'}F; cause #{prediction.miss_cause_label}."
    end

    def account_settlement_result(wager, settlement)
      market_result = settlement[:market_result].to_s.downcase
      return nil unless market_result.in?(%w[yes no])

      side = wager.side.to_s.downcase.presence || "yes"
      side = "yes" if side == "bid"
      side = "no" if side == "ask"
      market_result == side ? "won" : "lost"
    end

    def account_settlement_payout(settlement)
      revenue = settlement[:revenue]
      return (revenue.to_f / 100.0).round(2) if revenue.present?

      side = settlement[:market_result].to_s.downcase == "no" ? "no" : "yes"
      count = settlement[:"#{side}_count_fp"].to_f
      value = settlement[:value].to_f
      (count * (value / 100.0)).round(2)
    end

    def account_settlement_cost(wager, settlement)
      side = wager.side.to_s.downcase == "no" ? "no" : "yes"
      settlement_cost = settlement[:"#{side}_total_cost_dollars"].presence
      return settlement_cost.to_f.round(2) if settlement_cost.present?

      (wager.actual_cost.presence || wager.max_cost.presence || (wager.price.to_f * wager.contracts.to_i)).to_f.round(2)
    end

    def account_settlement_payload(settlement)
      settlement.to_h.slice(
        "ticker", "event_ticker", "market_result", "value", "revenue", "settled_time",
        "yes_count_fp", "yes_total_cost_dollars", "no_count_fp", "no_total_cost_dollars", "fee_cost"
      )
    end

    def parse_account_settlement_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def mark_error(prediction, error)
      return unless defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?

      wager = live_strategy_wagers.find_or_initialize_by(kalshi_weather_prediction: prediction)
      retained_position = wager.filled_contracts.to_i.positive? || wager.actual_cost.to_f.positive?
      wager.update!(
        status: retained_position ? "filled" : "error",
        execution_mode: "live",
        strategy_key: LIVE_STRATEGY_KEY,
        strategy_version: LIVE_STRATEGY_VERSION,
        market_ticker: prediction.market_ticker,
        contracts: wager.contracts.to_i,
        max_cost: wager.max_cost.to_f,
        budget_date: wager.budget_date || Date.current,
        reason: retained_position ? wager.reason : "#{error.class}: #{error.message}".truncate(280),
        metadata: wager.metadata.to_h.merge(
          "autopilot_error_at" => Time.current.iso8601,
          "autopilot_error" => "#{error.class}: #{error.message}".truncate(280),
          "position_retained_after_error" => retained_position
        )
      )
    rescue StandardError
      nil
    end

    def live_execution_allowed?
      return false unless live_orders_enabled?
      return false if blind_edge_mode?

      self.class.model_validated? && calibration_gate[:clear] && qwen_ready?
    end

    def live_blocked_reason
      return nil if live_execution_allowed?
      return "Kalshi live order switches disabled" unless live_orders_enabled?
      return "blind probabilities are paper-research only" if blind_edge_mode?
      return "weather probability model has not passed live validation" unless self.class.model_validated?
      return Array(calibration_gate[:reasons]).first || "walk-forward calibration gate blocked" unless calibration_gate[:clear]
      return "fresh Qwen weather analysis missing" unless qwen_ready?

      nil
    end

    def live_orders_enabled?
      self.class.live_orders_enabled?
    end

    def qwen_ready?
      question = latest_qwen_analysis
      return false unless question.present? && question.status.to_s == "answered"
      return false unless question.updated_at >= QWEN_MAX_AGE.ago

      metadata = question.metadata.to_h
      digest = metadata["weather_batch_digest"].to_s
      return false if digest.blank?
      return false unless digest == Kalshi::WeatherOutcomeAnalysis.current_batch_digest(organization: organization)

      validation = Kalshi::WeatherAnalysisContract.validate(
        question.answer,
        expected_digest: digest,
        expected_sample_size: metadata["weather_sample_size"]
      )
      validation.fetch(:valid) && validation.dig(:payload, "risk_gate") == "clear"
    end

    def latest_qwen_analysis
      return nil unless defined?(AutosQuestion) && defined?(Kalshi::WeatherOutcomeAnalysis)

      @latest_qwen_analysis ||= organization.autos_questions
        .where("metadata ->> 'surface' = ?", Kalshi::WeatherOutcomeAnalysis::SURFACE)
        .where("metadata ->> 'weather_analysis_version' = ?", Kalshi::WeatherOutcomeAnalysis::ANALYSIS_VERSION)
        .where(status: "answered")
        .order(updated_at: :desc)
        .first
    end

    def remaining_budget(date, excluding: nil)
      [accrued_budget(date) - budgeted_spend(date, excluding: excluding), 0.0].max
    end

    def strong_scan_limit
      [max_scan_spend, daily_cap].min
    end

    def accrued_budget(date)
      date = normalize_budget_date(date)
      return 0.0 if date != Date.current

      daily_cap
    end

    def budgeted_spend(date, excluding: nil)
      date = normalize_budget_date(date)
      scope = live_wagers.budgeted.where(budget_date: date)
      scope = scope.where.not(id: excluding.id) if excluding&.persisted?
      scope.to_a.sum { |wager| budgeted_wager_cost(wager) }.round(2)
    end

    def budgeted_wager_cost(wager)
      (wager.max_cost.to_f + stored_wager_fee_paid(wager)).round(2)
    end

    def stored_wager_fee_paid(wager)
      actual_fee = stored_wager_actual_fee_paid(wager)
      return actual_fee if actual_fee.positive?

      numeric_from_hash(wager.metadata.to_h, "estimated_taker_fee").to_f.round(2)
    end

    def stored_wager_actual_fee_paid(wager)
      settlement_fee = numeric_from_hash(wager.metadata.to_h, "account_settlement_fee_dollars")
      return settlement_fee if settlement_fee.present?

      response_fees = Array(wager.raw_payload.to_h["order_responses"]).sum { |response| order_response_fee(response) }.round(2)
      return response_fees if response_fees.positive?

      metadata_fee = numeric_from_hash(wager.metadata.to_h, "live_fees_paid", "fees_paid_dollars", "fees_paid")
      return metadata_fee if metadata_fee.present?

      0.0
    end

    def order_response_fee(response)
      response = response.to_h
      total_fee = numeric_from_hash(response, "fees_paid_dollars", "fee_paid_dollars", "total_fee_paid", "fee_paid")
      return total_fee if total_fee.present?

      average_fee = numeric_from_hash(response, "average_fee_paid", "avg_fee_paid")
      return 0.0 if average_fee.blank?

      fill_count = numeric_from_hash(response, "fill_count", "filled_count", "fill_count_fp", "filled_count_fp").to_f
      (average_fee.to_f * fill_count).round(4)
    end

    def numeric_from_hash(hash, *keys)
      raw = keys.filter_map { |key| hash[key].presence || hash[key.to_sym].presence }.first
      return nil if raw.blank?

      raw.to_f
    end

    def budget_start_date
      Date.current
    end

    def normalize_budget_date(date)
      return date if date.is_a?(Date)
      return date.to_date if date.respond_to?(:to_date)

      Date.current
    end

    def live_seed_bankroll
      return nil unless defined?(Kalshi::PaperBankrollSimulator)

      Kalshi::PaperBankrollSimulator.live_seed_bankroll
    end

    def entry_price(prediction)
      value = prediction.ask.presence ||
        metadata_for(prediction)["ask"].presence ||
        prediction.raw_payload.to_h.dig("paper_pick", "ask").presence ||
        prediction.raw_payload.to_h.dig(:paper_pick, :ask).presence
      return nil if value.blank?

      price = value.to_f
      price = price / 100.0 if price > 1.0
      return nil unless price.positive?

      [price, 1.0].min.round(4)
    end

    def executable_order_price(price)
      normalized = price.to_f
      return nil unless normalized.positive?

      [normalized, live_order_price_floor].max.round(4)
    end

    def metadata_for(prediction)
      prediction.metadata.to_h
    end

    def fetch_market(ticker)
      uri = URI("#{base_url}/trade-api/v2/markets/#{URI.encode_www_form_component(ticker)}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (pre-order price check)"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 12) do |http|
        http.request(request)
      end
      raise "market HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body).to_h["market"].to_h
    end

    def market_price(market, dollars_key, cents_key)
      value = market[dollars_key].presence || market[cents_key].presence
      return nil if value.blank?

      price = value.to_f
      price = price / 100.0 if price > 1.0
      price.positive? ? price.round(4) : nil
    end

    def unfilled_fill_or_kill_error?(error, wager)
      error.message.to_s.include?("fill_or_kill_insufficient_resting_volume")
    end

    def record_unfilled_fill_or_kill!(wager, payload, error = nil, contracts:, price:, response: nil)
      @skipped += 1
      attempted_cost = (contracts.to_i * price.to_f).round(2)
      reason = if error.present?
        "unfilled fill-or-kill: insufficient resting volume"
      else
        "unfilled fill-or-kill: exchange reported zero fills"
      end
      error_description = if error.present?
        "#{error.class}: #{error.message}".truncate(280)
      else
        "successful order response reported zero filled contracts"
      end
      retained_position = wager.filled_contracts.to_i.positive? || wager.actual_cost.to_f.positive?
      wager.update!(
        status: retained_position ? "filled" : "skipped",
        execution_mode: "live",
        kalshi_order_id: retained_position ? wager.kalshi_order_id : nil,
        contracts: retained_position ? wager.filled_contracts.to_i : 0,
        filled_contracts: wager.filled_contracts.to_i,
        max_cost: retained_position ? wager.actual_cost.to_f : 0,
        actual_cost: wager.actual_cost.to_f,
        placed_at: retained_position ? wager.placed_at : nil,
        filled_at: retained_position ? wager.filled_at : nil,
        reason: retained_position ? wager.reason : reason,
        metadata: wager.metadata.to_h.merge(
          "live_order_unfilled_at" => Time.current.iso8601,
          "live_order_unfilled_reason" => reason,
          "live_order_unfilled_error" => error_description,
          "live_order_limit_price" => price.to_f.round(4),
          "live_order_price_floor" => live_order_price_floor,
          "unfilled_requested_contracts" => contracts.to_i,
          "unfilled_requested_cost" => attempted_cost,
          "position_retained_after_unfilled_order" => retained_position
        ),
        raw_payload: append_order_payload(
          wager.raw_payload,
          payload,
          response.presence || {
            "error_class" => error&.class&.name,
            "error_message" => error&.message.to_s.truncate(500),
            "unfilled" => true
          }
        )
      )
    end

    def fill_count(order)
      order.values_at("filled_count", "fill_count", "fill_count_fp", "filled_count_fp").compact_blank.first.to_i
    end

    def append_order_payload(raw_payload, request_payload, response_payload)
      payload = raw_payload.to_h.deep_dup
      payload["order_requests"] = Array(payload["order_requests"]) << request_payload.merge("requested_at" => Time.current.iso8601)
      payload["order_responses"] = Array(payload["order_responses"]) << response_payload
      payload["order_request"] = request_payload
      payload["order_response"] = response_payload
      payload
    end

    def order_cost(order, contracts, price)
      raw = order.values_at("cost", "cost_dollars", "fill_cost", "fill_cost_dollars").compact_blank.first
      return (fill_count(order) * average_fill_price(order, price)).round(2) if raw.blank?

      value = raw.to_f
      value > 100 ? (value / 100.0).round(2) : value.round(2)
    end

    def realized_profit(wager, result)
      actual_risk = wager.actual_cost.to_f.positive? ? wager.actual_cost.to_f : (wager.price.to_f * wager.contracts.to_i)
      actual_risk += stored_wager_fee_paid(wager)
      case result
      when "won"
        (wager.contracts.to_i - actual_risk).round(2)
      when "lost"
        -actual_risk.round(2)
      else
        0.0
      end
    end

    def average_fill_price(order, fallback)
      raw = order.values_at("average_fill_price", "avg_fill_price", "fill_price", "price").compact_blank.first
      return fallback.to_f if raw.blank?

      price = raw.to_f
      price > 1.0 ? price / 100.0 : price
    end

    def client_order_id(prediction)
      "autos-weather-#{prediction.id}-#{Time.current.to_i}-#{SecureRandom.hex(3)}"
    end

    def next_client_order_id(wager, prediction)
      return client_order_id(prediction) if wager.status.in?(%w[error skipped])
      return wager.client_order_id if wager.client_order_id.present? && wager.kalshi_order_id.blank?

      client_order_id(prediction)
    end

    def reset_failed_wager?(wager)
      wager&.persisted? &&
        wager.status == "error" &&
        wager.filled_contracts.to_i.zero? &&
        wager.actual_cost.to_f.zero?
    end

    def reset_unsubmitted_dry_run_wager?(wager)
      wager&.persisted? &&
        wager.status == "pending" &&
        wager.execution_mode == "dry_run" &&
        wager.kalshi_order_id.blank? &&
        Array(wager.raw_payload.to_h["order_requests"]).blank?
    end

    def resettable_unsubmitted_wager?(wager)
      reset_failed_wager?(wager) || reset_unsubmitted_dry_run_wager?(wager)
    end

    def average_price(total_cost, total_contracts)
      return nil unless total_contracts.to_i.positive?

      (total_cost.to_f / total_contracts.to_i).round(4)
    end

    def parsed_time(value)
      return value.to_time if value.respond_to?(:to_time)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def tracking_started_at
      defined?(Kalshi::PaperBankrollSimulator) ? Kalshi::PaperBankrollSimulator.live_tracking_started_at : nil
    end

    def daily_cap
      [weather_risk_amount("daily_cap", self.class.daily_cap), HARD_LIVE_DAILY_CAP].min
    end

    def live_order_price_floor
      self.class.live_order_price_floor
    end

    def max_event_exposure
      [self.class.max_event_exposure, daily_cap].min
    end

    def min_daily_spend
      0.0
    end

    def target_spend_today
      0.0
    end

    def per_order_cap
      [self.class.per_order_cap, daily_cap].min
    end

    def qualified_daily_cap
      [self.class.qualified_daily_cap, daily_cap].min
    end

    def exploration_daily_cap
      [self.class.exploration_daily_cap, daily_cap].min
    end

    def review_auto_daily_cap
      [ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_DAILY_CAP", DEFAULT_REVIEW_AUTO_DAILY_CAP).to_f, daily_cap].min
    end

    def manual_buy_max
      [weather_risk_amount(
        "manual_buy_max",
        ENV["WIZWIKI_WEATHER_AUTOPILOT_MANUAL_BUY_MAX"].presence || daily_cap
      ), daily_cap].min
    end

    def min_edge
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MIN_EDGE", DEFAULT_MIN_EDGE).to_f
    end

    def qualified_min_edge
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_QUALIFIED_MIN_EDGE", DEFAULT_QUALIFIED_MIN_EDGE).to_f
    end

    def min_confidence
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MIN_CONFIDENCE", DEFAULT_MIN_CONFIDENCE).to_f
    end

    def max_ask
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_ASK", DEFAULT_MAX_ASK).to_f
    end

    def max_source_spread_f
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_SOURCE_SPREAD_F", DEFAULT_MAX_SOURCE_SPREAD_F).to_f
    end

    def min_source_count
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MIN_SOURCE_COUNT", DEFAULT_MIN_SOURCE_COUNT).to_i
    end

    def max_scan_spend
      [ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_SCAN_SPEND", DEFAULT_MAX_SCAN_SPEND).to_f, daily_cap].min
    end

    def qualified_max_scan_spend
      [ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_QUALIFIED_MAX_SCAN_SPEND", DEFAULT_QUALIFIED_MAX_SCAN_SPEND).to_f, daily_cap].min
    end

    def max_positions_per_scan
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_POSITIONS_PER_SCAN", DEFAULT_MAX_POSITIONS_PER_SCAN).to_i.clamp(1, 8)
    end

    def max_consecutive_live_losses
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_CONSECUTIVE_LIVE_LOSSES", DEFAULT_MAX_CONSECUTIVE_LIVE_LOSSES).to_i.clamp(1, 12)
    end

    def loss_streak_cooldown_hours
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_LOSS_STREAK_COOLDOWN_HOURS", DEFAULT_LOSS_STREAK_COOLDOWN_HOURS).to_i.clamp(1, 168)
    end

    def max_market_share
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MAX_MARKET_SHARE", DEFAULT_MAX_MARKET_SHARE).to_f.clamp(0.1, 1.0)
    end

    def min_scale_interval_minutes
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_MIN_SCALE_INTERVAL_MINUTES", DEFAULT_MIN_SCALE_INTERVAL_MINUTES).to_i.clamp(0, 240)
    end

    def exploration_max_scan_spend
      [ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MAX_SCAN_SPEND", DEFAULT_EXPLORATION_MAX_SCAN_SPEND).to_f, daily_cap].min
    end

    def review_auto_max_scan_spend
      [ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MAX_SCAN_SPEND", DEFAULT_REVIEW_AUTO_MAX_SCAN_SPEND).to_f, daily_cap].min
    end

    def exploration_min_edge
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MIN_EDGE", DEFAULT_EXPLORATION_MIN_EDGE).to_f
    end

    def review_auto_min_edge
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MIN_EDGE", DEFAULT_REVIEW_AUTO_MIN_EDGE).to_f
    end

    def exploration_longshot_min_edge
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_LONGSHOT_MIN_EDGE", DEFAULT_EXPLORATION_LONGSHOT_MIN_EDGE).to_f
    end

    def exploration_min_confidence
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MIN_CONFIDENCE", DEFAULT_EXPLORATION_MIN_CONFIDENCE).to_f
    end

    def review_auto_min_confidence
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MIN_CONFIDENCE", DEFAULT_REVIEW_AUTO_MIN_CONFIDENCE).to_f
    end

    def exploration_longshot_min_confidence
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_LONGSHOT_MIN_CONFIDENCE", DEFAULT_EXPLORATION_LONGSHOT_MIN_CONFIDENCE).to_f
    end

    def exploration_max_ask
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MAX_ASK", DEFAULT_EXPLORATION_MAX_ASK).to_f
    end

    def review_auto_max_ask
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MAX_ASK", DEFAULT_REVIEW_AUTO_MAX_ASK).to_f
    end

    def exploration_max_source_spread_f
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MAX_SOURCE_SPREAD_F", DEFAULT_EXPLORATION_MAX_SOURCE_SPREAD_F).to_f
    end

    def review_auto_max_source_spread_f
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MAX_SOURCE_SPREAD_F", DEFAULT_REVIEW_AUTO_MAX_SOURCE_SPREAD_F).to_f
    end

    def exploration_longshot_max_source_spread_f
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_LONGSHOT_MAX_SOURCE_SPREAD_F", DEFAULT_EXPLORATION_LONGSHOT_MAX_SOURCE_SPREAD_F).to_f
    end

    def exploration_min_source_count
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_EXPLORATION_MIN_SOURCE_COUNT", DEFAULT_EXPLORATION_MIN_SOURCE_COUNT).to_i
    end

    def review_auto_min_source_count
      ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_REVIEW_AUTO_MIN_SOURCE_COUNT", DEFAULT_REVIEW_AUTO_MIN_SOURCE_COUNT).to_i
    end

    def base_url
      ENV.fetch("KALSHI_BASE_URL", KALSHI_BASE_URL).to_s.delete_suffix("/").sub(%r{/trade-api/v2\z}, "")
    end

    def weather_risk_settings
      @weather_risk_settings ||= organization.settings.to_h.fetch(RISK_SETTINGS_KEY, {}).to_h
    end

    def loss_guard_reset_at
      parsed_time(weather_risk_settings["loss_guard_reset_at"] || weather_risk_settings[:loss_guard_reset_at])
    end

    def blind_edge_mode?
      false
    end

    def weather_risk_amount(key, fallback, allow_zero: false)
      raw = weather_risk_settings[key.to_s].presence || weather_risk_settings[key.to_sym].presence || fallback
      amount = raw.to_f
      return 0.0 if allow_zero && amount.zero?

      amount.positive? ? amount.round(2) : fallback.to_f.round(2)
    end
  end
end
