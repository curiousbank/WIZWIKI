# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Kalshi
  class WeatherAutopilotTest < ActiveSupport::TestCase
    test "weather event date comes from the market event ticker" do
      assert_equal Date.new(2026, 7, 4), KalshiWeatherPrediction.event_date_from_ticker("KXHIGHCHI-26JUL04")
      assert_equal Date.new(2026, 7, 4), KalshiWeatherPrediction.event_date_from_ticker("KXHIGHCHI-26JUL04-B91.5")
    end

    test "fee adjusted edge includes the general taker fee estimate" do
      fee = WeatherAutopilot.estimated_taker_fee_per_contract(0.50)
      edge = WeatherAutopilot.fee_adjusted_edge(confidence: 0.70, price: 0.50)

      assert_in_delta 0.0175, fee, 0.0001
      assert_in_delta 0.1825, edge, 0.0001
    end

    test "aggregate fee sizing keeps every live order inside the hard cap" do
      assert_equal 467, WeatherAutopilot.contracts_within_cap(0.01, 5.0)
      assert_equal 9, WeatherAutopilot.contracts_within_cap(0.50, 5.0)
      assert_operator((467 * 0.01) + WeatherAutopilot.estimated_taker_fee(0.01, 467), :<=, 5.0)
      assert_operator((468 * 0.01) + WeatherAutopilot.estimated_taker_fee(0.01, 468), :>, 5.0)
    end

    test "live validation approval is scoped to the exact strategy version" do
      keys = %w[WIZWIKI_WEATHER_MODEL_VALIDATED WIZWIKI_WEATHER_MODEL_VALIDATED_VERSION]
      previous = keys.index_with { |key| ENV[key] }
      ENV["WIZWIKI_WEATHER_MODEL_VALIDATED"] = "true"
      ENV["WIZWIKI_WEATHER_MODEL_VALIDATED_VERSION"] = "calibrated_live_v2"
      assert_equal false, WeatherAutopilot.model_validated?

      ENV["WIZWIKI_WEATHER_MODEL_VALIDATED_VERSION"] = WeatherAutopilot::LIVE_STRATEGY_VERSION
      assert_equal true, WeatherAutopilot.model_validated?
    ensure
      previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    test "scanner respects operator limits and caps oversized scans" do
      organization = Organization.create!(name: "Weather Limit Test", slug: "weather-limit-test-#{SecureRandom.hex(4)}")

      assert_equal 7, WeatherAutopilot.new(organization: organization, limit: 7).send(:limit)
      assert_equal WeatherAutopilot::DEFAULT_LIMIT,
        WeatherAutopilot.new(organization: organization, limit: 50_000).send(:limit)
    end

    test "order adapter treats a one-cent legacy price as one cent" do
      client = Kalshi::AccountClient.new
      legacy = client.send(:v2_order_payload, ticker: "KXHIGHMIA-26JUL13-T90", count: 10, yes_price: 1)
      explicit = client.send(:v2_order_payload, ticker: "KXHIGHMIA-26JUL13-T90", count: 10, price: 0.01)

      assert_equal "0.0100", legacy[:price]
      assert_equal "0.0100", explicit[:price]
      assert_equal "10.00", explicit[:count]
      assert_equal 0, explicit[:exchange_index]
    end

    test "estimated fee is not counted again when an actual fill fee arrives" do
      organization = Organization.create!(name: "Weather Fee Test", slug: "weather-fee-test-#{SecureRandom.hex(4)}")
      autopilot = WeatherAutopilot.new(organization: organization, limit: 1)
      wager = Struct.new(:metadata, :raw_payload).new(
        { "estimated_taker_fee" => 0.14 },
        { "order_responses" => [] }
      )

      assert_equal 0.14, autopilot.send(:stored_wager_fee_paid, wager)
      assert_equal 0.0, autopilot.send(:stored_wager_actual_fee_paid, wager)
      assert_equal 0.14, autopilot.send(:order_response_fee, { "average_fee_paid" => "0.014", "fill_count" => "10.00" })
    end

    test "blocked live autopilot never creates a pseudo dry run wager" do
      organization = Organization.create!(name: "Weather Autopilot Test", slug: "weather-autopilot-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHNY",
        event_ticker: "KXHIGHNY-26JUL01",
        market_ticker: "KXHIGHNY-26JUL01-B90.5",
        city: "New York City",
        state: "NY",
        market_title: "NYC high between 90 and 91",
        market_range: "90-91F",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 91,
        adjusted_high_f: 91,
        market_floor_strike: 90.5,
        market_cap_strike: 91.5,
        confidence: 0.70,
        ask: 0.50,
        edge: 0.20,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.70, spread: 1.5)
      )

      result = WeatherAutopilot.call(organization: organization)

      assert_equal 0, result[:created]
      assert_equal 0, organization.kalshi_weather_wagers.count
      assert_equal 5.0, result[:hard_live_cap]
      assert_equal 5.0, result[:remaining_today]
      assert_includes result[:errors], "Kalshi live order switches disabled"
    end

    test "repeated blocked scans do not create or scale a market position" do
      organization = Organization.create!(name: "Weather One Entry Test", slug: "weather-one-entry-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHNY",
        event_ticker: "KXHIGHNY-26JUL01",
        market_ticker: "KXHIGHNY-26JUL01-B90.5",
        city: "New York City",
        state: "NY",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        confidence: 0.70,
        ask: 0.50,
        edge: 0.20,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.70, spread: 1.0)
      )

      WeatherAutopilot.call(organization: organization)
      WeatherAutopilot.call(organization: organization)

      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "blocked live scanner does not write skipped rows" do
      organization = Organization.create!(name: "Weather Autopilot Skip Test", slug: "weather-autopilot-skip-test-#{SecureRandom.hex(4)}")
      organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL01",
        market_ticker: "KXHIGHCHI-26JUL01-B95.5",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 96,
        adjusted_high_f: 96,
        confidence: 0.50,
        ask: 0.40,
        edge: 0.05,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.50, spread: 1.5)
      )

      result = WeatherAutopilot.call(organization: organization)

      assert_equal 0, result[:skipped]
      assert_equal 0, organization.kalshi_weather_wagers.count
      assert_equal 5.0, result[:remaining_today]
    end

    test "organization weather risk settings cannot override the code locked cap" do
      organization = Organization.create!(
        name: "Weather Risk Settings Test",
        slug: "weather-risk-settings-test-#{SecureRandom.hex(4)}",
        settings: {
          "weather_autopilot" => {
            "min_daily_spend" => 15,
            "daily_cap" => 35
          }
        }
      )
      autopilot = WeatherAutopilot.new(organization: organization, limit: 1)

      assert_equal 5.0, autopilot.send(:daily_cap)
      assert_equal 0.0, autopilot.send(:min_daily_spend)
      assert_equal 5.0, autopilot.send(:remaining_budget, Date.current)
    end

    test "weather risk minimum is disabled even when legacy settings request it" do
      organization = Organization.create!(
        name: "Weather Risk Clamp Test",
        slug: "weather-risk-clamp-test-#{SecureRandom.hex(4)}",
        settings: {
          "weather_autopilot" => {
            "min_daily_spend" => 80,
            "daily_cap" => 30
          }
        }
      )
      autopilot = WeatherAutopilot.new(organization: organization, limit: 1)

      assert_equal 5.0, autopilot.send(:daily_cap)
      assert_equal 0.0, autopilot.send(:min_daily_spend)
    end

    test "three consecutive live losses activate the portfolio cooldown" do
      organization = Organization.create!(name: "Weather Guard Test", slug: "weather-guard-test-#{SecureRandom.hex(4)}")

      3.times do |index|
        prediction = organization.kalshi_weather_predictions.create!(
          series_ticker: "KXHIGHCHI",
          event_ticker: "KXHIGHCHI-26JUL0#{index + 1}",
          market_ticker: "KXHIGHCHI-26JUL0#{index + 1}-B9#{index}.5",
          city: "Chicago",
          state: "IL",
          action: "watch",
          side: "YES",
          size_label: "10 contracts",
          prediction_date: Time.zone.today - index.days,
          confidence: 0.25,
          ask: 0.20,
          edge: 0.05,
          status: "settled",
          result_status: "lost"
        )
        organization.kalshi_weather_wagers.create!(
          kalshi_weather_prediction: prediction,
          status: "lost",
          execution_mode: "live",
          side: "yes",
          action: "buy",
          market_ticker: prediction.market_ticker,
          contracts: 10,
          filled_contracts: 10,
          price: 0.20,
          max_cost: 2.0,
          actual_cost: 2.0,
          realized_profit: -2.14,
          budget_date: prediction.prediction_date,
          settled_at: (index + 1).hours.ago
        )
      end

      guard = WeatherAutopilot.new(organization: organization, limit: 1).send(:portfolio_guard_status)

      assert_equal false, guard[:allowed]
      assert_equal "latched", guard[:status]
      assert_equal 3, guard[:consecutive_losses]
      assert_match(/latched off after 3 consecutive live losses/, guard[:reason])

      organization.update!(
        settings: {
          "weather_autopilot" => {
            "loss_guard_reset_at" => Time.current.iso8601(6)
          }
        }
      )
      reset_guard = WeatherAutopilot.new(organization: organization, limit: 1).send(:portfolio_guard_status)

      assert_equal true, reset_guard[:allowed]
      assert_equal "active", reset_guard[:status]
      assert_equal 0, reset_guard[:consecutive_losses]
      assert_equal 0, reset_guard[:settled_sample]
    end

    test "daily minimum never forces a cheap positive-edge watch pick" do
      organization = Organization.create!(name: "Weather Autopilot Minimum Test", slug: "weather-autopilot-minimum-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHAUS",
        event_ticker: "KXHIGHAUS-26JUL01",
        market_ticker: "KXHIGHAUS-26JUL01-B99.5",
        city: "Austin",
        state: "TX",
        action: "watch",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 100,
        adjusted_high_f: 100,
        confidence: 0.12,
        ask: 0.10,
        edge: 0.03,
        status: "open",
        result_status: "pending",
        metadata: {
          "forecast_source_count" => 3,
          "forecast_source_spread_f" => 1.5,
          "gate_reasons" => []
        }
      )

      result = WeatherAutopilot.call(organization: organization)

      assert_equal 0, result[:created]
      assert_equal 0, organization.kalshi_weather_wagers.count
      assert_equal 5.0, result[:remaining_today]
    end

    test "review auto blocks historical caution gates and wide source spreads" do
      organization = Organization.create!(name: "Weather Review Auto Test", slug: "weather-review-auto-test-#{SecureRandom.hex(4)}")
      [
        {
          series_ticker: "KXHIGHCHI",
          event_ticker: "KXHIGHCHI-26JUL08",
          market_ticker: "KXHIGHCHI-26JUL08-B86.5",
          city: "Chicago",
          state: "IL",
          confidence: 0.33,
          ask: 0.20,
          edge: 0.13,
          spread: 4.5,
          gates: ["Chicago stale-forecast losses are elevated; require a fresher/tighter source stack"]
        },
        {
          series_ticker: "KXHIGHMIA",
          event_ticker: "KXHIGHMIA-26JUL07",
          market_ticker: "KXHIGHMIA-26JUL07-B88.5",
          city: "Miami",
          state: "FL",
          confidence: 0.18,
          ask: 0.03,
          edge: 0.15,
          spread: 2.7,
          gates: [
            "Miami on probation: 27% hit rate needs a stronger proof stack",
            "cheap long-shot blocked: <20c asks have underperformed the paper book"
          ]
        },
        {
          series_ticker: "KXHIGHLAX",
          event_ticker: "KXHIGHLAX-26JUL08",
          market_ticker: "KXHIGHLAX-26JUL08-T78",
          city: "Los Angeles",
          state: "CA",
          confidence: 0.15,
          ask: 0.06,
          edge: 0.09,
          spread: 1.7,
          gates: [
            "Los Angeles benched: 0% hit rate over 12 paper picks",
            "cheap long-shot blocked: <20c asks have underperformed the paper book"
          ]
        }
      ].each do |attrs|
        organization.kalshi_weather_predictions.create!(
          series_ticker: attrs[:series_ticker],
          event_ticker: attrs[:event_ticker],
          market_ticker: attrs[:market_ticker],
          city: attrs[:city],
          state: attrs[:state],
          action: "watch",
          side: "YES",
          size_label: "1 paper contract",
          prediction_date: Time.zone.today,
          close_time: 1.day.from_now,
          forecast_high_f: 88,
          adjusted_high_f: 88,
          confidence: attrs[:confidence],
          ask: attrs[:ask],
          edge: attrs[:edge],
          status: "open",
          result_status: "pending",
          metadata: {
            "forecast_source_count" => 3,
            "forecast_source_spread_f" => attrs[:spread],
            "gate_reasons" => attrs[:gates]
          }
        )
      end

      result = WeatherAutopilot.call(organization: organization)

      assert_equal 0, result[:created]
      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "clean watch rows remain watch-only when exploration is disabled" do
      organization = Organization.create!(name: "Weather Clean Review Auto Test", slug: "weather-clean-review-auto-test-#{SecureRandom.hex(4)}")
      [
        {
          series_ticker: "KXHIGHMIA",
          event_ticker: "KXHIGHMIA-26JUL08",
          market_ticker: "KXHIGHMIA-26JUL08-B89.5",
          city: "Miami",
          state: "FL",
          confidence: 0.18,
          ask: 0.03,
          edge: 0.17,
          spread: 2.5
        }
      ].each do |attrs|
        organization.kalshi_weather_predictions.create!(
          series_ticker: attrs[:series_ticker],
          event_ticker: attrs[:event_ticker],
          market_ticker: attrs[:market_ticker],
          city: attrs[:city],
          state: attrs[:state],
          action: "watch",
          side: "YES",
          size_label: "1 paper contract",
          prediction_date: Time.zone.today,
          close_time: 1.day.from_now,
          forecast_high_f: 88,
          adjusted_high_f: 88,
          confidence: attrs[:confidence],
          ask: attrs[:ask],
          edge: attrs[:edge],
          status: "open",
          result_status: "pending",
          metadata: {
            "forecast_source_count" => 3,
            "forecast_source_spread_f" => attrs[:spread],
            "gate_reasons" => []
          }
        )
      end

      result = WeatherAutopilot.call(organization: organization)
      assert_equal false, result[:exploration_enabled]
      assert_equal 0, result[:created]
      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "manual buy cannot create a simulated ticket when live execution is blocked" do
      organization = Organization.create!(name: "Weather Manual Buy Test", slug: "weather-manual-buy-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL08",
        market_ticker: "KXHIGHCHI-26JUL08-B86.5",
        city: "Chicago",
        state: "IL",
        action: "watch",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 87,
        adjusted_high_f: 87,
        confidence: 0.62,
        ask: 0.20,
        edge: 0.42,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.62, spread: 2.5)
      )

      result = WeatherAutopilot.new(organization: organization, limit: 1).manual_buy(prediction_id: prediction.id, amount: 40)

      assert_equal false, result[:ok]
      assert_equal "Kalshi live order switches disabled", result[:error]
      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "manual buy cannot create a penny ticket while live execution is blocked" do
      organization = Organization.create!(name: "Weather Manual Penny Test", slug: "weather-manual-penny-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHMIA",
        event_ticker: "KXHIGHMIA-26JUL08",
        market_ticker: "KXHIGHMIA-26JUL08-B89.5",
        city: "Miami",
        state: "FL",
        action: "watch",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 90,
        adjusted_high_f: 90,
        confidence: 0.62,
        ask: 0.01,
        edge: 0.61,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.62, spread: 2.5)
      )

      result = WeatherAutopilot.new(organization: organization, limit: 1).manual_buy(prediction_id: prediction.id, amount: 20)

      assert_equal false, result[:ok]
      assert_equal "Kalshi live order switches disabled", result[:error]
      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "manual buy cannot bypass review auto warning gates" do
      organization = Organization.create!(name: "Weather Manual Gate Test", slug: "weather-manual-gate-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHMIA",
        event_ticker: "KXHIGHMIA-26JUL08",
        market_ticker: "KXHIGHMIA-26JUL08-B89.5",
        city: "Miami",
        state: "FL",
        action: "watch",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        forecast_high_f: 90,
        adjusted_high_f: 90,
        confidence: 0.18,
        ask: 0.01,
        edge: 0.17,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(
          lower_confidence: 0.18,
          spread: 2.5,
          gates: [
            "Miami on probation: 27% hit rate needs a stronger proof stack",
            "cheap long-shot blocked: <20c asks have underperformed the paper book"
          ]
        )
      )

      result = WeatherAutopilot.new(organization: organization, limit: 1).manual_buy(prediction_id: prediction.id, amount: 20)

      assert_equal false, result[:ok]
      assert_equal "Kalshi live order switches disabled", result[:error]
      assert_equal 0, organization.kalshi_weather_wagers.count
    end

    test "official account settlement overrides weather backfill for live wager pnl" do
      organization = Organization.create!(name: "Weather Settlement Test", slug: "weather-settlement-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHAUS",
        event_ticker: "KXHIGHAUS-26JUL06",
        market_ticker: "KXHIGHAUS-26JUL06-B98.5",
        city: "Austin",
        state: "TX",
        action: "watch",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Date.new(2026, 7, 6),
        forecast_high_f: 98,
        adjusted_high_f: 98,
        observed_high_f: 97,
        market_floor_strike: 98,
        market_cap_strike: 99,
        confidence: 0.22,
        ask: 0.10,
        edge: 0.03,
        status: "settled",
        result_status: "lost"
      )
      wager = organization.kalshi_weather_wagers.create!(
        kalshi_weather_prediction: prediction,
        status: "lost",
        execution_mode: "live",
        side: "yes",
        action: "buy",
        market_ticker: prediction.market_ticker,
        contracts: 100,
        filled_contracts: 100,
        price: 0.10,
        max_cost: 10.0,
        actual_cost: 10.0,
        realized_profit: -10.63,
        budget_date: prediction.prediction_date
      )
      settlement = {
        "ticker" => prediction.market_ticker,
        "event_ticker" => prediction.event_ticker,
        "market_result" => "yes",
        "revenue" => 10_000,
        "yes_count_fp" => "100.00",
        "yes_total_cost_dollars" => "10.000000",
        "fee_cost" => "0.630000",
        "settled_time" => "2026-07-07T12:01:04.448877Z"
      }

      WeatherAutopilot.new(organization: organization, limit: 1).send(:sync_account_settlement, settlement)

      assert_equal "won", wager.reload.status
      assert_equal 89.37, wager.realized_profit.to_f
      assert_equal "won", prediction.reload.result_status
      assert_equal true, prediction.metadata["kalshi_account_overrode_observed_result"]
      assert_equal 100.0, wager.metadata["account_settlement_revenue_dollars"]
      assert_equal 1.0, wager.metadata["prediction_market_distance_f"]
      assert_equal(-1.0, wager.metadata["prediction_adjusted_error_f"])
      assert_includes prediction.training_note, "Weather diagnostic: actual high 97F"
    end

    test "portfolio allocation remains dormant until the global live gate clears" do
      organization = Organization.create!(name: "Weather Autopilot City Test", slug: "weather-autopilot-city-test-#{SecureRandom.hex(4)}")
      max_positions = ENV["WIZWIKI_WEATHER_AUTOPILOT_MAX_POSITIONS_PER_SCAN"]
      ENV["WIZWIKI_WEATHER_AUTOPILOT_MAX_POSITIONS_PER_SCAN"] = "2"

      organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL01",
        market_ticker: "KXHIGHCHI-26JUL01-B95.5",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Date.new(2026, 7, 1),
        close_time: 1.day.from_now,
        forecast_high_f: 96,
        adjusted_high_f: 96,
        confidence: 0.72,
        ask: 0.50,
        edge: 0.30,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.72, spread: 1.0)
      )
      organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL01",
        market_ticker: "KXHIGHCHI-26JUL01-B97.5",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Date.new(2026, 7, 1),
        close_time: 1.day.from_now,
        forecast_high_f: 98,
        adjusted_high_f: 98,
        confidence: 0.71,
        ask: 0.50,
        edge: 0.29,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.71, spread: 1.0)
      )
      organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHNY",
        event_ticker: "KXHIGHNY-26JUL01",
        market_ticker: "KXHIGHNY-26JUL01-B91.5",
        city: "New York City",
        state: "NY",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        prediction_date: Date.new(2026, 7, 1),
        close_time: 1.day.from_now,
        forecast_high_f: 92,
        adjusted_high_f: 92,
        confidence: 0.70,
        ask: 0.50,
        edge: 0.20,
        status: "open",
        result_status: "pending",
        metadata: live_ready_metadata(lower_confidence: 0.70, spread: 1.0)
      )

      result = WeatherAutopilot.call(organization: organization)
      assert_equal 0, result[:created]
      assert_equal 0, organization.kalshi_weather_wagers.count
    ensure
      if max_positions.nil?
        ENV.delete("WIZWIKI_WEATHER_AUTOPILOT_MAX_POSITIONS_PER_SCAN")
      else
        ENV["WIZWIKI_WEATHER_AUTOPILOT_MAX_POSITIONS_PER_SCAN"] = max_positions
      end
    end

    test "paper tickets do not consume live budget and blind mode cannot open a live ticket" do
      organization = Organization.create!(
        name: "Weather Blind Fill Test",
        slug: "weather-blind-fill-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true, "daily_cap" => 10 } }
      )
      existing_prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL12",
        market_ticker: "KXHIGHCHI-26JUL12-T84",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        confidence: 0.75,
        ask: 0.50,
        edge: 0.25,
        status: "open",
        result_status: "pending",
        metadata: blind_ready_metadata(lower_confidence: 0.75, spread: 1.0)
      )
      next_prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHNY",
        event_ticker: "KXHIGHNY-26JUL12",
        market_ticker: "KXHIGHNY-26JUL12-T84",
        city: "New York City",
        state: "NY",
        action: "paper_yes",
        prediction_date: Time.zone.today,
        close_time: 1.day.from_now,
        confidence: 0.72,
        ask: 0.50,
        edge: 0.22,
        status: "open",
        result_status: "pending",
        metadata: blind_ready_metadata(lower_confidence: 0.72, spread: 1.0)
      )
      organization.kalshi_weather_wagers.create!(
        kalshi_weather_prediction: existing_prediction,
        status: "pending",
        execution_mode: "dry_run",
        side: "yes",
        action: "buy",
        market_ticker: existing_prediction.market_ticker,
        contracts: 10,
        price: 0.50,
        max_cost: 5.0,
        budget_date: Date.current,
        opportunity_tier: "autopilot_strong"
      )

      result = WeatherAutopilot.call(organization: organization)

      assert_equal 0, result[:created]
      assert_nil organization.kalshi_weather_wagers.find_by(kalshi_weather_prediction: next_prediction)
      assert_in_delta 5.0, result[:remaining_today], 0.01
    end

    test "blind live execution remains disabled even when legacy switches are set" do
      organization = Organization.create!(
        name: "Weather Blind Live Gate Test",
        slug: "weather-blind-live-gate-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      autopilot = WeatherAutopilot.new(organization: organization, limit: 1)
      switches = %w[WIZWIKI_WEATHER_LIVE_ORDERS_ENABLED KALSHI_LIVE_ORDERS_ENABLED WIZWIKI_WEATHER_BLIND_LIVE_ENABLED]
      previous = switches.index_with { |key| ENV[key] }

      ENV["WIZWIKI_WEATHER_LIVE_ORDERS_ENABLED"] = "true"
      ENV["KALSHI_LIVE_ORDERS_ENABLED"] = "true"
      ENV["WIZWIKI_WEATHER_BLIND_LIVE_ENABLED"] = "false"
      assert_equal false, autopilot.send(:live_execution_allowed?)

      ENV["WIZWIKI_WEATHER_BLIND_LIVE_ENABLED"] = "true"
      assert_equal false, autopilot.send(:live_execution_allowed?)
    ensure
      previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    test "legacy blind settings are ignored and cannot qualify a candidate" do
      organization = Organization.create!(
        name: "Weather Blind Tail Test",
        slug: "weather-blind-tail-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHMIA",
        event_ticker: "KXHIGHMIA-26JUL13",
        market_ticker: "KXHIGHMIA-26JUL13-T90",
        city: "Miami",
        state: "FL",
        action: "paper_yes",
        prediction_date: Time.zone.today + 1.day,
        close_time: 1.day.from_now,
        confidence: 0.30,
        ask: 0.05,
        edge: 0.25,
        status: "open",
        result_status: "pending",
        metadata: blind_ready_metadata(lower_confidence: 0.20, spread: 1.0)
      )

      autopilot = WeatherAutopilot.new(organization: organization, limit: 1)
      verdict = autopilot.send(:candidate_verdict, prediction)

      assert_equal false, autopilot.send(:blind_edge_mode?)
      assert_equal false, verdict[:ok]
    end

    private

    def live_ready_metadata(lower_confidence:, spread:, gates: [])
      {
        "forecast_coordinate_version" => WeatherBucketProbability::COORDINATE_VERSION,
        "forecast_event_date_aligned" => true,
        "forecast_source_count" => 3,
        "forecast_source_spread_f" => spread,
        "probability_model_version" => WeatherBucketProbability::MODEL_VERSION,
        "probability_training_sample_size" => WeatherBucketProbability::MIN_LIVE_SAMPLE,
        "probability_model_ready" => true,
        "confidence_lower_bound" => lower_confidence,
        "gate_reasons" => gates
      }
    end

    def blind_ready_metadata(lower_confidence:, spread:, gates: [])
      live_ready_metadata(lower_confidence: lower_confidence, spread: spread, gates: gates).merge(
        "probability_model_version" => WeatherBucketProbability::BLIND_MODEL_VERSION,
        "probability_training_sample_size" => 0,
        "blind_edge_mode" => true
      )
    end
  end
end
