# frozen_string_literal: true

module Kalshi
  class WeatherAnalysisKnowledge
    VERSION = "kalshi_weather_rules_v1".freeze

    class << self
      def payload
        {
          knowledge_version: VERSION,
          authoritative_sources: {
            settlement: "Final NWS Daily Climate Report for the exact Kalshi series station",
            contract: "The series contract terms and market strike fields returned by Kalshi",
            weather_help_url: "https://help.kalshi.com/en/articles/13823837-weather-markets"
          },
          settlement_rules: {
            time_basis: "NWS local standard-time reporting day, not an assumed midnight-to-midnight civil day",
            greater_than: "strictly greater than the strike; equality is NO",
            less_than: "strictly less than the strike; equality is NO",
            between: "inclusive of both listed endpoints",
            reported_value: "Compare against the final reported climate value. Continuous forecast probabilities use half-degree continuity boundaries for whole-degree outcomes."
          },
          objective: {
            primary: "Maximize positive out-of-sample expected value after transaction fees while preserving capital",
            abstention: "No trade is a valid and preferred decision when evidence is weak",
            validation: "Judge calibration, Brier score, source error, fee-adjusted ROI, and sample independence; never optimize raw win rate alone",
            prohibited: "Never force daily spend, invent certainty, modify settlement facts, or place/size an order"
          },
          qwen_role: {
            allowed: "Find source, city, regime, calibration, and data-quality patterns; explain evidence; propose the next measurement; conservatively veto",
            forbidden: "Override deterministic rules, promote its own hypothesis to production, or authorize live trading"
          },
          live_validation: {
            minimum_independent_station_events: minimum_live_sample,
            coordinate_version: coordinate_version,
            probability_model_version: probability_model_version,
            manual_promotion_required: true
          },
          stations: station_payload
        }
      end

      private

      def minimum_live_sample
        defined?(Kalshi::WeatherBucketProbability) ? Kalshi::WeatherBucketProbability::MIN_LIVE_SAMPLE : 30
      end

      def coordinate_version
        defined?(Kalshi::WeatherBucketProbability) ? Kalshi::WeatherBucketProbability::COORDINATE_VERSION : "settlement_station_v1"
      end

      def probability_model_version
        defined?(Kalshi::WeatherBucketProbability) ? Kalshi::WeatherBucketProbability::MODEL_VERSION : "station_residual_normal_v1"
      end

      def station_payload
        return [] unless defined?(Kalshi::WeatherMarketScout::WEATHER_STUDY_SERIES)

        Kalshi::WeatherMarketScout::WEATHER_STUDY_SERIES.map do |definition|
          definition.slice(:ticker, :city, :state, :station_id, :climate_location, :time_zone)
        end
      end
    end
  end
end
