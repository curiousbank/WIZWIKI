# frozen_string_literal: true

require "set"

module Kalshi
  class PaperBankrollSimulator
    DEFAULT_DAILY_BUDGET = 20.0
    DEFAULT_STRONG_EDGE = 0.12
    DEFAULT_STRONG_CONFIDENCE = 0.55
    DEFAULT_STRONG_SOURCE_SPREAD_F = 3.0
    DEFAULT_STRONG_MAX_ASK = 0.65
    DEFAULT_QUALIFIED_DAILY_FRACTION = 0.5
    DEFAULT_LIVE_TRACKING_STARTED_AT = "2026-06-30T12:24:11-05:00"
    DEFAULT_LIVE_SEED_BANKROLL = 100.0

    class << self
      def call(rows:, as_of: Time.zone.today, start_date: nil, tracking_started_at: nil, seed_bankroll: nil)
        new(
          rows: rows,
          as_of: as_of,
          start_date: start_date,
          tracking_started_at: tracking_started_at,
          seed_bankroll: seed_bankroll
        ).call
      end

      def live_tracking_started_at
        time_env("WIZWIKI_WEATHER_LIVE_TRACKING_STARTED_AT", DEFAULT_LIVE_TRACKING_STARTED_AT)
      end

      def live_seed_bankroll
        money_class_env("WIZWIKI_WEATHER_LIVE_SEED_BANKROLL", DEFAULT_LIVE_SEED_BANKROLL)
      end

      private

      def time_env(key, fallback)
        value = ENV.fetch(key, fallback).presence
        return nil if value.blank?

        return value.in_time_zone if value.respond_to?(:in_time_zone)

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        Time.zone.parse(fallback.to_s)
      end

      def money_class_env(key, fallback)
        value = ENV.fetch(key, fallback).to_f
        value.positive? ? value.round(2) : fallback
      end
    end

    def initialize(rows:, as_of:, start_date:, tracking_started_at:, seed_bankroll:)
      @rows = Array(rows).compact
      @as_of = normalize_date(as_of) || Time.zone.today
      @tracking_started_at = normalize_time(tracking_started_at)
      @start_date = normalize_date(start_date) || @tracking_started_at&.to_date
      @seed_bankroll = normalize_seed_bankroll(seed_bankroll)
      @daily_budget = money_env("WIZWIKI_WEATHER_PAPER_DAILY_BUDGET", DEFAULT_DAILY_BUDGET)
      @qualified_budget = (@daily_budget * qualified_daily_fraction).round(2)
      @reserve_deploy_threshold = money_env("WIZWIKI_WEATHER_PAPER_RESERVE_DEPLOY_THRESHOLD", @daily_budget)
      @strong_edge = decimal_env("WIZWIKI_WEATHER_PAPER_STRONG_EDGE", DEFAULT_STRONG_EDGE)
      @strong_confidence = decimal_env("WIZWIKI_WEATHER_PAPER_STRONG_CONFIDENCE", DEFAULT_STRONG_CONFIDENCE)
      @strong_source_spread_f = decimal_env("WIZWIKI_WEATHER_PAPER_STRONG_SOURCE_SPREAD_F", DEFAULT_STRONG_SOURCE_SPREAD_F)
      @strong_max_ask = decimal_env("WIZWIKI_WEATHER_PAPER_STRONG_MAX_ASK", DEFAULT_STRONG_MAX_ASK)
    end

    def call
      dated_rows = @rows.filter_map do |row|
        next if before_tracking_start?(row)

        date = row_date(row)
        next if date.blank?
        next if date > @as_of

        [date, row]
      end
      first_date = [@start_date, dated_rows.map(&:first).min, @as_of].compact.min
      last_date = @as_of
      rows_by_date = dated_rows.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      entries = []
      daily = []
      reserve = 0.0
      total_credited = 0.0

      (first_date..last_date).each do |date|
        daily_credit = daily_credit_for(total_credited)
        total_credited = round_money(total_credited + daily_credit)
        reserve = round_money(reserve + daily_credit)
        candidates = Array(rows_by_date[date]).filter_map { |row| candidate_for(row) }
        strong = candidates.select { |candidate| strong_opportunity?(candidate) }
        selected, budget_cap, tier, reason = day_selection(candidates, strong, reserve)
        allocations = allocate_budget(selected, budget_cap)
        selected_ids = selected.map { |candidate| candidate[:id] }.compact.to_set

        candidates.each do |candidate|
          allocation = allocations[candidate[:id]] || empty_allocation(candidate)
          if !selected_ids.include?(candidate[:id])
            allocation = allocation.merge(
              reason: strong.any? ? "not selected: stronger paper edge was available" : "not selected"
            )
          end
          entry = build_entry(candidate, allocation, tier, reason)
          entries << entry
        end

        daily_stake = entries.select { |entry| entry[:date] == date }.sum { |entry| entry[:total_risk].to_f }
        reserve = round_money(reserve - daily_stake)
        day_entries = entries.select { |entry| entry[:date] == date }
        daily << {
          date: date,
          daily_credit: daily_credit,
          stake_budget: budget_cap.round(2),
          stake: daily_stake.round(2),
          reserve_after: reserve.round(2),
          opportunity_tier: tier,
          reason: reason,
          candidates: candidates.length,
          strong_candidates: strong.length,
          selected: day_entries.count { |entry| entry[:contracts].to_i.positive? },
          daily_profit: day_entries.sum { |entry| entry[:profit].to_f }.round(2)
        }
      end

      entries_by_id = entries.index_by { |entry| entry[:id] }.compact
      total_staked = entries.sum { |entry| entry[:stake].to_f }
      total_fees = entries.sum { |entry| entry[:estimated_fees].to_f }
      total_risk = entries.sum { |entry| entry[:total_risk].to_f }
      total_profit = entries.sum { |entry| entry[:profit].to_f }

      {
        daily_budget: @daily_budget,
        half_day_budget: @qualified_budget,
        qualified_budget: @qualified_budget,
        reserve_deploy_threshold: @reserve_deploy_threshold,
        tracking_started_at: @tracking_started_at&.iso8601,
        seed_bankroll: @seed_bankroll&.round(2),
        total_credited: total_credited.round(2),
        strong_edge: @strong_edge,
        strong_confidence: @strong_confidence,
        strong_source_spread_f: @strong_source_spread_f,
        strong_max_ask: @strong_max_ask,
        reserve_balance: reserve.round(2),
        entries: entries,
        entries_by_id: entries_by_id,
        daily: daily,
        total_staked: total_staked.round(2),
        total_fees: total_fees.round(2),
        total_risk: total_risk.round(2),
        total_profit: total_profit.round(2),
        roi_percent: total_risk.positive? ? ((total_profit / total_risk) * 100).round(1) : nil,
        fees_included: true,
        paper_only: true,
        live_tracking: @tracking_started_at.present?,
        execution_policy: "Tracking simulation only. No deposits, orders, or real-money wagers are created by this code."
      }
    end

    private

    def daily_credit_for(total_credited)
      return @daily_budget if @seed_bankroll.blank?

      remaining = round_money(@seed_bankroll - total_credited.to_f)
      return 0.0 unless remaining.positive?

      [@daily_budget, remaining].min.round(2)
    end

    def day_selection(candidates, strong, reserve)
      if strong.present?
        budget = reserve >= @reserve_deploy_threshold ? reserve : [reserve, @daily_budget].min
        tier = reserve > @daily_budget ? "reserve_deploy_good_opportunity" : "full_day_good_opportunity"
        [strong, budget.round(2), tier, "strong paper edge cleared confidence, price, and source-spread gates"]
      elsif candidates.present? && @qualified_budget.positive?
        [[*candidates], [reserve, @qualified_budget].min.round(2), "half_day_qualified", "qualified paper pick exists, but no strong reserve-deploy edge"]
      elsif candidates.present?
        [[], 0.0, "qualified_watch_only", "qualified paper pick exists, but reserve is held until a strong edge clears"]
      else
        [[], 0.0, "reserve_only", "no qualifying paper opportunity; daily budget carried into reserve"]
      end
    end

    def candidate_for(row)
      price = entry_price(row)
      return nil if price.blank?
      action = value_for(row, :action).to_s
      return nil unless action == "paper_yes"

      {
        id: row_id(row),
        row: row,
        date: row_date(row),
        price: price,
        confidence: value_for(row, :confidence).to_f,
        edge: value_for(row, :edge).to_f,
        result: value_for(row, :result_status).to_s,
        action: action,
        placed_at: row_placed_at(row)&.iso8601,
        source_count: metadata_for(row)["forecast_source_count"].to_i,
        source_spread_f: metadata_for(row)["forecast_source_spread_f"].to_f,
        gate_reasons: Array(metadata_for(row)["gate_reasons"]).presence || Array(raw_payload_for(row).dig("paper_pick", "gate_reasons"))
      }
    end

    def strong_opportunity?(candidate)
      candidate[:action] == "paper_yes" &&
        candidate[:edge].to_f >= @strong_edge &&
        candidate[:confidence].to_f >= @strong_confidence &&
        candidate[:price].to_f <= @strong_max_ask &&
        candidate[:source_count].to_i >= 2 &&
        candidate[:source_spread_f].to_f <= @strong_source_spread_f &&
        candidate[:gate_reasons].blank?
    end

    def allocate_budget(candidates, budget)
      candidates = Array(candidates)
      return {} if candidates.blank? || budget.to_f <= 0.0

      scores = candidates.to_h { |candidate| [candidate[:id], allocation_score(candidate)] }
      total_score = scores.values.sum
      remaining = budget.to_f
      allocations = {}

      ranked = candidates.sort_by { |candidate| -scores.fetch(candidate[:id]).to_f }
      ranked.each do |candidate|
        target = budget.to_f * (scores.fetch(candidate[:id]).to_f / total_score)
        contracts = [
          max_contracts_for_budget(candidate[:price], target),
          max_contracts_for_budget(candidate[:price], remaining)
        ].min
        stake = contracts * candidate[:price].to_f
        estimated_fees = estimated_taker_fee(candidate[:price], contracts)
        total_risk = stake + estimated_fees
        remaining = round_money(remaining - total_risk)
        allocations[candidate[:id]] = {
          contracts: contracts,
          stake: round_money(stake),
          estimated_fees: round_money(estimated_fees),
          total_risk: round_money(total_risk),
          reason: contracts.positive? ? "paper stake sized from daily/reserve budget" : "budget too small for one contract"
        }
      end

      loop do
        candidate = ranked.find do |item|
          allocation = allocations.fetch(item[:id])
          incremental_risk_for(item[:price], allocation[:contracts]) <= remaining + 0.001
        end
        break if candidate.blank?

        allocation = allocations.fetch(candidate[:id])
        additional_risk = incremental_risk_for(candidate[:price], allocation[:contracts])
        allocation[:contracts] += 1
        allocation[:stake] = round_money(allocation[:stake].to_f + candidate[:price].to_f)
        allocation[:estimated_fees] = round_money(estimated_taker_fee(candidate[:price], allocation[:contracts]))
        allocation[:total_risk] = round_money(allocation[:stake].to_f + allocation[:estimated_fees].to_f)
        remaining = round_money(remaining - additional_risk)
      end

      allocations
    end

    def empty_allocation(candidate)
      {
        contracts: 0,
        stake: 0.0,
        estimated_fees: 0.0,
        total_risk: 0.0,
        reason: "no paper stake allocated at #{format('%.2f', candidate[:price])} entry price"
      }
    end

    def build_entry(candidate, allocation, tier, day_reason)
      contracts = allocation[:contracts].to_i
      stake = allocation[:stake].to_f
      estimated_fees = allocation[:estimated_fees].to_f
      total_risk = allocation[:total_risk].to_f
      profit = profit_for(candidate[:result], candidate[:price], contracts, estimated_fees)
      {
        id: candidate[:id],
        date: candidate[:date],
        price: candidate[:price],
        contracts: contracts,
        stake: stake.round(2),
        estimated_fees: estimated_fees.round(2),
        total_risk: total_risk.round(2),
        result: candidate[:result],
        profit: profit.round(2),
        opportunity_tier: tier,
        allocation_reason: allocation[:reason],
        day_reason: day_reason,
        placed_at: candidate[:placed_at],
        confidence: candidate[:confidence],
        edge: candidate[:edge],
        source_count: candidate[:source_count],
        source_spread_f: candidate[:source_spread_f]
      }
    end

    def allocation_score(candidate)
      edge = [candidate[:edge].to_f, 0.01].max
      confidence = [candidate[:confidence].to_f, 0.01].max
      source_bonus = candidate[:source_count].to_i >= 3 ? 1.15 : 1.0
      spread_penalty = candidate[:source_spread_f].to_f > 2.0 ? 0.85 : 1.0
      edge * confidence * source_bonus * spread_penalty
    end

    def profit_for(result_status, price, contracts, estimated_fees = 0.0)
      gross = case result_status.to_s
      when "won"
        (1.0 - price.to_f) * contracts.to_i
      when "lost"
        -price.to_f * contracts.to_i
      else
        0.0
      end
      gross - estimated_fees.to_f
    end

    def max_contracts_for_budget(price, budget)
      price = price.to_f
      budget = budget.to_f
      return 0 unless price.positive? && budget.positive?

      fee_rate = 0.07 * price * (1.0 - price)
      contracts = (budget / (price + fee_rate)).floor
      contracts -= 1 while contracts.positive? && total_risk_for(price, contracts) > budget + 0.001
      contracts += 1 while total_risk_for(price, contracts + 1) <= budget + 0.001
      contracts
    end

    def incremental_risk_for(price, current_contracts)
      total_risk_for(price, current_contracts.to_i + 1) - total_risk_for(price, current_contracts.to_i)
    end

    def total_risk_for(price, contracts)
      (price.to_f * contracts.to_i) + estimated_taker_fee(price, contracts)
    end

    def estimated_taker_fee(price, contracts)
      return 0.0 unless contracts.to_i.positive?

      raw_fee = 0.07 * contracts.to_i * price.to_f * (1.0 - price.to_f)
      ((raw_fee * 100).ceil / 100.0).round(2)
    end

    def entry_price(row)
      value = value_for(row, :ask).presence ||
        metadata_for(row)["ask"].presence ||
        raw_payload_for(row).dig("paper_pick", "ask").presence ||
        raw_payload_for(row).dig(:paper_pick, :ask).presence
      return nil if value.blank?

      price = value.to_f
      price = price / 100.0 if price > 1.0
      return nil unless price.positive?

      [price, 1.0].min.round(4)
    end

    def row_date(row)
      normalize_time(value_for(row, :created_at))&.to_date ||
        normalize_time(value_for(row, :updated_at))&.to_date ||
        normalize_date(value_for(row, :prediction_date)) ||
        normalize_date(value_for(row, :close_time))
    end

    def row_placed_at(row)
      normalize_time(value_for(row, :created_at)) ||
        normalize_time(value_for(row, :updated_at)) ||
        normalize_time(value_for(row, :close_time)) ||
        normalize_date(value_for(row, :prediction_date))&.in_time_zone
    end

    def before_tracking_start?(row)
      return false if @tracking_started_at.blank?

      placed_at = row_placed_at(row)
      placed_at.present? && placed_at < @tracking_started_at
    end

    def normalize_date(value)
      return value if value.is_a?(Date)
      return value.to_date if value.respond_to?(:to_date)
      return nil if value.blank?

      Time.zone.parse(value.to_s)&.to_date
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_time(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_seed_bankroll(value)
      return nil if value.blank?

      amount = value.to_f
      amount.positive? ? amount.round(2) : nil
    end

    def value_for(row, key)
      if row.respond_to?(key)
        row.public_send(key)
      elsif row.respond_to?(:[])
        fetch_row_value(row, key) || fetch_row_value(row, key.to_s)
      end
    end

    def fetch_row_value(row, key)
      row[key]
    rescue KeyError, IndexError, NameError, TypeError
      nil
    end

    def row_id(row)
      value_for(row, :id) || row.object_id
    end

    def metadata_for(row)
      value_for(row, :metadata).to_h
    end

    def raw_payload_for(row)
      value_for(row, :raw_payload).to_h
    end

    def money_env(key, fallback)
      value = ENV.fetch(key, fallback).to_f
      value.positive? ? value.round(2) : fallback
    end

    def decimal_env(key, fallback)
      value = ENV.fetch(key, fallback).to_f
      value.positive? ? value : fallback
    end

    def qualified_daily_fraction
      value = ENV.fetch("WIZWIKI_WEATHER_PAPER_QUALIFIED_DAILY_FRACTION", DEFAULT_QUALIFIED_DAILY_FRACTION).to_f
      return DEFAULT_QUALIFIED_DAILY_FRACTION if value.negative?

      [value, 1.0].min
    end

    def round_money(value)
      value.to_f.round(2)
    end
  end
end
