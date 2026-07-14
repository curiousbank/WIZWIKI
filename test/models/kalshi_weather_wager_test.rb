# frozen_string_literal: true

require "test_helper"
require "securerandom"

class KalshiWeatherWagerTest < ActiveSupport::TestCase
  test "a prediction supports independent live and paper strategy lanes" do
    organization = Organization.create!(
      name: "Weather Wager Lanes Test",
      slug: "weather-wager-lanes-#{SecureRandom.hex(4)}"
    )
    prediction = organization.kalshi_weather_predictions.create!(
      series_ticker: "KXHIGHAUS",
      event_ticker: "KXHIGHAUS-26JUL20",
      market_ticker: "KXHIGHAUS-26JUL20-T100",
      city: "Austin",
      state: "TX",
      action: "paper_yes",
      prediction_date: Date.new(2026, 7, 20),
      status: "open",
      result_status: "pending"
    )

    lanes = [
      ["live", "live_active"],
      ["dry_run", "paper_active"],
      ["dry_run", "paper_challenger"]
    ].map do |execution_mode, strategy_key|
      organization.kalshi_weather_wagers.create!(
        kalshi_weather_prediction: prediction,
        status: "pending",
        execution_mode: execution_mode,
        strategy_key: strategy_key,
        market_ticker: prediction.market_ticker,
        contracts: 1,
        filled_contracts: 1,
        max_cost: 0.50,
        budget_date: Date.current
      )
    end

    assert_equal 3, prediction.reload.kalshi_weather_wagers.count
    assert_equal "live", lanes.first.execution_label
    assert_equal ["paper", "paper"], lanes.drop(1).map(&:execution_label)
  end

  test "display status falls back to realized profit when settlement status lags" do
    organization = Organization.create!(
      name: "Weather Wager Display Test",
      slug: "weather-wager-display-test-#{SecureRandom.hex(4)}"
    )
    prediction = organization.kalshi_weather_predictions.create!(
      series_ticker: "KXHIGHAUS",
      event_ticker: "KXHIGHAUS-26JUL06",
      market_ticker: "KXHIGHAUS-26JUL06-B96.5",
      city: "Austin",
      state: "TX",
      action: "paper_yes",
      side: "YES",
      size_label: "1 paper contract",
      prediction_date: Date.new(2026, 7, 6),
      forecast_high_f: 97,
      adjusted_high_f: 97,
      market_floor_strike: 96,
      market_cap_strike: 97,
      confidence: 0.7,
      ask: 0.1,
      edge: 0.2,
      status: "settled",
      result_status: "won"
    )
    wager = organization.kalshi_weather_wagers.create!(
      kalshi_weather_prediction: prediction,
      status: "filled",
      execution_mode: "live",
      side: "yes",
      action: "buy",
      market_ticker: prediction.market_ticker,
      contracts: 10,
      filled_contracts: 10,
      price: 0.1,
      max_cost: 1.0,
      actual_cost: 1.0,
      realized_profit: 8.9,
      budget_date: prediction.prediction_date
    )

    assert_equal "won", wager.display_result_status
    assert_equal "+", wager.result_symbol
  end
end
