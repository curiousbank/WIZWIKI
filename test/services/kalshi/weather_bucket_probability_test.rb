# frozen_string_literal: true

require "test_helper"

module Kalshi
  class WeatherBucketProbabilityTest < ActiveSupport::TestCase
    test "a narrow bucket near the point forecast is not treated as sixty percent likely" do
      result = probability(floor: 79, cap: 80, forecast: 80, residuals: [])

      assert_operator result[:confidence], :>, 0.10
      assert_operator result[:confidence], :<, 0.30
      assert_operator result[:confidence_lower_bound], :<=, result[:confidence]
      assert_equal false, result[:model_ready]
    end

    test "strict one-sided tails and the exact degree bucket partition probability" do
      below = probability(floor: nil, cap: 80, forecast: 80, residuals: [])
      exact = probability(floor: 80, cap: 80, forecast: 80, residuals: [])
      above = probability(floor: 80, cap: nil, forecast: 80, residuals: [])

      assert_in_delta 1.0, below[:confidence] + exact[:confidence] + above[:confidence], 0.001
      assert_in_delta below[:confidence], above[:confidence], 0.001
    end

    test "live readiness requires thirty independent station residuals" do
      building = probability(floor: 79, cap: 80, forecast: 80, residuals: Array.new(29, 0))
      ready = probability(floor: 79, cap: 80, forecast: 80, residuals: Array.new(30, 0))

      assert_equal false, building[:model_ready]
      assert_equal true, ready[:model_ready]
      assert_equal 30, ready[:training_sample_size]
    end

    test "blind edge mode ignores supplied history and is immediately source-ready" do
      clean = probability(floor: 79, cap: 80, forecast: 80, residuals: [], use_history: false)
      biased = probability(floor: 79, cap: 80, forecast: 80, residuals: Array.new(100, 8), use_history: false)

      assert_equal clean[:confidence], biased[:confidence]
      assert_equal WeatherBucketProbability::BLIND_MODEL_VERSION, biased[:model_version]
      assert_equal 0, biased[:training_sample_size]
      assert_equal true, biased[:model_ready]
      assert_equal false, biased[:history_enabled]
      assert_equal true, biased[:blind_edge_mode]
    end

    private

    def probability(floor:, cap:, forecast:, residuals:, use_history: true)
      WeatherBucketProbability.call(
        organization: nil,
        series_ticker: "KXHIGHCHI",
        target_date: Date.new(2026, 7, 12),
        forecast_high_f: forecast,
        market_floor_strike: floor,
        market_cap_strike: cap,
        source_spread_f: 0,
        residuals: residuals,
        use_history: use_history
      )
    end
  end
end
