# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Kalshi
  class WeatherPaperTraderTest < ActiveSupport::TestCase
    setup do
      @organization = Organization.create!(
        name: "Weather Paper Lanes Test",
        slug: "weather-paper-lanes-#{SecureRandom.hex(4)}"
      )
      @prediction = @organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL20",
        market_ticker: "KXHIGHCHI-26JUL20-T90",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        side: "YES",
        size_label: "paper",
        prediction_date: Date.current + 1.day,
        close_time: 1.day.from_now,
        confidence: 0.70,
        ask: 0.50,
        edge: 0.20,
        status: "open",
        result_status: "pending",
        metadata: {
          "forecast_coordinate_version" => WeatherBucketProbability::COORDINATE_VERSION,
          "forecast_event_date_aligned" => true,
          "forecast_source_count" => 3,
          "forecast_source_spread_f" => 1.0,
          "probability_model_version" => WeatherBucketProbability::MODEL_VERSION,
          "probability_model_ready" => true,
          "gate_reasons" => []
        }
      )
    end

    test "live and both paper strategies can coexist without external orders" do
      @organization.kalshi_weather_wagers.create!(
        kalshi_weather_prediction: @prediction,
        status: "pending",
        execution_mode: "live",
        strategy_key: WeatherAutopilot::LIVE_STRATEGY_KEY,
        strategy_version: WeatherAutopilot::LIVE_STRATEGY_VERSION,
        side: "yes",
        action: "buy",
        market_ticker: @prediction.market_ticker,
        contracts: 1,
        filled_contracts: 1,
        price: 0.50,
        max_cost: 0.50,
        actual_cost: 0.50,
        budget_date: Date.current
      )

      trader = WeatherPaperTrader.new(organization: @organization)
      trader.instance_variable_set(:@harness, deterministic_harness)
      result = trader.call

      assert_equal 3, @organization.kalshi_weather_wagers.count
      assert_equal [WeatherPaperTrader::ACTIVE_STRATEGY, WeatherPaperTrader::CHALLENGER_STRATEGY],
        @organization.kalshi_weather_wagers.paper.order(:strategy_key).pluck(:strategy_key)
      assert result[:strategies].all? { |row| row[:status] == "paper_position_opened" }
      @organization.kalshi_weather_wagers.paper.each do |wager|
        assert_equal false, wager.metadata["external_order_created"]
        assert_operator wager.metadata["total_risk"].to_f, :<=, 5.0
        assert_equal 4.66, wager.metadata["total_risk"].to_f
      end

      trader.call
      assert_equal 3, @organization.kalshi_weather_wagers.count
    end

    test "paper positions settle fee inclusively while live execution stays gated" do
      trader = WeatherPaperTrader.new(organization: @organization)
      trader.instance_variable_set(:@harness, deterministic_harness)
      trader.call
      @prediction.update!(status: "settled", result_status: "won")

      result = WeatherAutopilot.call(organization: @organization)

      assert_equal 2, result[:settled]
      assert_equal false, result[:live_orders_enabled]
      @organization.kalshi_weather_wagers.paper.each do |wager|
        assert_equal "won", wager.status
        assert_equal 4.34, wager.realized_profit.to_f
      end
    end

    private

    def deterministic_harness
      Object.new.tap do |harness|
        harness.define_singleton_method(:evaluate) do |_prediction, strategy:, enforce_live_gate:|
          {
            ok: true,
            strategy: strategy.to_s,
            strategy_version: WeatherCalibrationHarness::STRATEGY_VERSION,
            harness_version: WeatherCalibrationHarness::VERSION,
            reason: enforce_live_gate ? "paper challenger test" : "active shadow test",
            price: 0.50,
            raw_probability: 0.70,
            calibrated_probability: 0.70,
            calibrated_lower_bound: 0.66,
            point_edge: 0.18,
            conservative_edge: 0.14,
            training_events: 30,
            training_scope: "exact_model",
            contracts: 9,
            estimated_fee: 0.16,
            total_risk: 4.66
          }
        end
      end
    end
  end
end
