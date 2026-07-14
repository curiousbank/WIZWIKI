# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Kalshi
  class WeatherOutcomeAnalysisTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Weather Qwen #{suffix}", slug: "weather-qwen-#{suffix}")
    end

    test "builds compact official station evidence with fee-aware metrics" do
      prediction = create_prediction
      analyst = WeatherOutcomeAnalysis.new(organization: @organization, limit: 80)
      rows = analyst.send(:scored_predictions)
      digest = analyst.send(:batch_digest, rows)
      context = analyst.send(:analysis_context, rows, digest: digest)
      payload = JSON.parse(context)

      assert_equal [prediction.id], rows.map(&:id)
      assert_operator context.length, :<, 20_000
      assert_equal WeatherAnalysisKnowledge::VERSION, payload.dig("canonical_knowledge", "knowledge_version")
      assert_match(/strictly greater/, payload.dig("canonical_knowledge", "settlement_rules", "greater_than"))
      assert_equal 1, payload.dig("overall_metrics", "paper_yes", "entries")
      assert_operator payload.dig("overall_metrics", "paper_yes", "net_profit"), :>, 0
      assert_equal "KMDW", payload.dig("recent_cases", 0, "station")
      assert_equal [], payload["prior_validated_analyses"]
      refute_includes context, "live_divergence_watch"
    end

    test "digest is stable when unrelated timestamps change" do
      prediction = create_prediction
      analyst = WeatherOutcomeAnalysis.new(organization: @organization, limit: 80)
      before = analyst.send(:batch_digest, analyst.send(:scored_predictions))

      prediction.touch
      after = analyst.send(:batch_digest, analyst.send(:scored_predictions))

      assert_equal before, after
    end

    test "ignores legacy city-center predictions" do
      prediction = create_prediction
      prediction.update!(metadata: prediction.metadata.to_h.merge("forecast_coordinate_version" => "city_center_v0"))

      rows = WeatherOutcomeAnalysis.new(organization: @organization, limit: 80).send(:scored_predictions)

      assert_empty rows
    end

    private

    def create_prediction
      @organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL12",
        market_ticker: "KXHIGHCHI-26JUL12-T84",
        city: "Chicago",
        state: "IL",
        market_title: "Chicago high above 84",
        market_range: "84F+",
        action: "paper_yes",
        side: "YES",
        size_label: "1 paper contract",
        forecast_high_f: 86,
        adjusted_high_f: 86,
        observed_high_f: 87,
        market_floor_strike: 84,
        confidence: 0.70,
        ask: 0.50,
        edge: 0.20,
        prediction_date: Date.new(2026, 7, 12),
        close_time: Time.zone.parse("2026-07-13 00:00:00"),
        status: "settled",
        result_status: "won",
        metadata: {
          "official_market_reconciled_at" => Time.current.iso8601,
          "official_market_result" => "yes",
          "forecast_coordinate_version" => WeatherBucketProbability::COORDINATE_VERSION,
          "probability_model_version" => WeatherBucketProbability::MODEL_VERSION,
          "forecast_event_date_aligned" => true,
          "probability_model_ready" => false,
          "forecast_station_id" => "KMDW",
          "confidence_lower_bound" => 0.62,
          "forecast_source_spread_f" => 1.5,
          "forecast_sources" => [
            { "key" => "weather_gov", "high_f" => 86 },
            { "key" => "open_meteo", "high_f" => 87 }
          ]
        }
      )
    end
  end
end
