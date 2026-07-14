# frozen_string_literal: true

require "test_helper"

module Kalshi
  class PaperBankrollSimulatorTest < ActiveSupport::TestCase
    Row = Struct.new(
      :id,
      :action,
      :ask,
      :confidence,
      :edge,
      :metadata,
      :raw_payload,
      :prediction_date,
      :close_time,
      :created_at,
      :result_status,
      keyword_init: true
    )

    test "qualified but not strong paper picks are capped at half the daily budget" do
      date = Date.new(2026, 6, 30)
      row = row(id: 1, date: date, ask: 0.50, confidence: 0.50, edge: 0.09, result_status: "won")

      simulation = PaperBankrollSimulator.call(rows: [row], as_of: date, start_date: date)
      entry = simulation[:entries_by_id].fetch(1)

      assert_equal "half_day_qualified", entry[:opportunity_tier]
      assert_equal 19, entry[:contracts]
      assert_equal 9.5, entry[:stake]
      assert_equal 0.34, entry[:estimated_fees]
      assert_equal 9.84, entry[:total_risk]
      assert_equal 10.16, simulation[:reserve_balance]
    end

    test "strong paper picks can deploy accrued reserve" do
      start_date = Date.new(2026, 6, 28)
      wager_date = Date.new(2026, 6, 30)
      row = row(id: 2, date: wager_date, ask: 0.25, confidence: 0.62, edge: 0.18, result_status: "lost")

      simulation = PaperBankrollSimulator.call(rows: [row], as_of: wager_date, start_date: start_date)
      entry = simulation[:entries_by_id].fetch(2)

      assert_equal "reserve_deploy_good_opportunity", entry[:opportunity_tier]
      assert_equal 228, entry[:contracts]
      assert_equal 57.0, entry[:stake]
      assert_equal 3.0, entry[:estimated_fees]
      assert_equal 60.0, entry[:total_risk]
      assert_equal 0.0, simulation[:reserve_balance]
    end

    test "blank days accrue reserve without creating a wager" do
      start_date = Date.new(2026, 6, 28)
      as_of = Date.new(2026, 6, 30)

      simulation = PaperBankrollSimulator.call(rows: [], as_of: as_of, start_date: start_date)

      assert_empty simulation[:entries]
      assert_equal 60.0, simulation[:reserve_balance]
      assert_equal %w[reserve_only reserve_only reserve_only], simulation[:daily].map { |day| day[:opportunity_tier] }
    end

    test "live tracking cutoff excludes older saved paper decisions" do
      date = Date.new(2026, 6, 30)
      cutoff = Time.zone.parse("2026-06-30T12:24:11-05:00")
      old_row = row(id: 3, date: date, ask: 0.25, confidence: 0.62, edge: 0.18, result_status: "won", created_at: cutoff - 1.second)
      new_row = row(id: 4, date: date, ask: 0.25, confidence: 0.62, edge: 0.18, result_status: "lost", created_at: cutoff + 1.second)

      simulation = PaperBankrollSimulator.call(
        rows: [old_row, new_row],
        as_of: date,
        start_date: date,
        tracking_started_at: cutoff,
        seed_bankroll: 100.0
      )

      assert_nil simulation[:entries_by_id][3]
      assert_equal 4, simulation[:entries].sole[:id]
      assert_equal 20.0, simulation[:total_credited]
    end

    test "seed bankroll releases one daily budget at a time" do
      start_date = Date.new(2026, 6, 30)
      as_of = Date.new(2026, 7, 10)

      simulation = PaperBankrollSimulator.call(rows: [], as_of: as_of, start_date: start_date, seed_bankroll: 100.0)

      assert_equal 100.0, simulation[:total_credited]
      assert_equal 100.0, simulation[:reserve_balance]
      assert_equal [20.0, 20.0, 20.0, 20.0, 20.0, 0.0], simulation[:daily].first(6).map { |day| day[:daily_credit] }
    end

    private

    def row(id:, date:, ask:, confidence:, edge:, result_status:, created_at: nil)
      Row.new(
        id: id,
        action: "paper_yes",
        ask: ask,
        confidence: confidence,
        edge: edge,
        metadata: {
          "forecast_source_count" => 3,
          "forecast_source_spread_f" => 1.5
        },
        raw_payload: {},
        prediction_date: date,
        created_at: created_at,
        result_status: result_status
      )
    end
  end
end
