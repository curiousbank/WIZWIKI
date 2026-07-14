# frozen_string_literal: true

require "test_helper"
require "securerandom"

class KalshiWeatherPredictionTest < ActiveSupport::TestCase
  test "one-sided weather strikes are strict" do
    above = KalshiWeatherPrediction.new(observed_high_f: 80, market_floor_strike: 80)
    below = KalshiWeatherPrediction.new(observed_high_f: 80, market_cap_strike: 80)

    assert_equal false, above.observed_inside_market?
    assert_equal false, below.observed_inside_market?

    above.observed_high_f = 81
    below.observed_high_f = 79
    assert_equal true, above.observed_inside_market?
    assert_equal true, below.observed_inside_market?
  end

  test "one-sided miss distance counts equality as one whole degree outside" do
    above = KalshiWeatherPrediction.new(observed_high_f: 80, market_floor_strike: 80)
    below = KalshiWeatherPrediction.new(observed_high_f: 80, market_cap_strike: 80)

    assert_equal 1.0, above.market_distance_f
    assert_equal 1.0, below.market_distance_f
    assert_equal "above 80F", above.market_band_label
    assert_equal "under 80F", below.market_band_label
  end

  test "official market outcome overrides a derived weather-band result" do
    organization = Organization.create!(name: "Weather Settlement Test", slug: "weather-settlement-#{SecureRandom.hex(4)}")
    prediction = organization.kalshi_weather_predictions.create!(
      series_ticker: "KXHIGHNY",
      event_ticker: "KXHIGHNY-26JUL12",
      market_ticker: "KXHIGHNY-26JUL12-T81",
      city: "New York City",
      state: "NY",
      action: "watch",
      side: "YES",
      size_label: "0 contracts",
      prediction_date: Date.new(2026, 7, 12),
      market_cap_strike: 81,
      status: "open",
      result_status: "pending"
    )

    prediction.score_from_observed!(observed_high: 80, official_outcome: "no", source: "kalshi_market_detail")

    assert_equal "lost", prediction.result_status
    assert_equal "no", prediction.metadata["official_market_result"]
    assert prediction.metadata["official_market_reconciled_at"].present?
  end
end
