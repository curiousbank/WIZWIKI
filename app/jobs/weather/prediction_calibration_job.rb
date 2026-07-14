module Weather
  class PredictionCalibrationJob < ApplicationJob
    queue_as :default

    CACHE_VERSION = "v1".freeze

    def self.result_cache_key(organization_id)
      ["weather_prediction_calibration_result", CACHE_VERSION, organization_id]
    end

    def perform(organization_id: nil, limit: nil)
      organizations = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      organizations.find_each do |organization|
        settlement = if kalshi_configured?
          Kalshi::WeatherPredictionSettler.call(
            organization: organization,
            limit: ENV.fetch("WIZWIKI_WEATHER_SETTLEMENT_LIMIT", 64).to_i
          )
        else
          { checked: 0, settled: 0, waiting: 0, errors: ["Kalshi credentials not configured"], ran_at: Time.current }
        end
        backfill = Kalshi::WeatherActualHighBackfill.call(
          organization: organization,
          limit: limit.presence || ENV.fetch("WIZWIKI_WEATHER_ACTUAL_BACKFILL_LIMIT", 16).to_i
        )
        refreshed = refresh_existing_score_metadata(organization)
        analysis = Kalshi::WeatherOutcomeAnalysis.enqueue!(
          organization: organization,
          limit: ENV.fetch("WIZWIKI_WEATHER_OUTCOME_ANALYSIS_LIMIT", 18).to_i
        )

        Rails.cache.write(
          self.class.result_cache_key(organization.id),
          {
            settlement: settlement,
            backfill: backfill,
            refreshed: refreshed,
            analysis: analysis,
            ran_at: Time.current
          },
          expires_in: 2.hours
        )

        Rails.logger.info("[Weather::PredictionCalibrationJob] organization=#{organization.id} backfill=#{backfill.inspect} settlement=#{settlement.inspect} refreshed=#{refreshed} analysis=#{analysis.inspect}")
      rescue StandardError => error
        Rails.logger.warn("[Weather::PredictionCalibrationJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end

    private

    def kalshi_configured?
      %w[KALSHI_API_KEY_ID KALSHI_ACCESS_KEY KALSHI_API_KEY].any? { |key| ENV[key].present? } &&
        %w[KALSHI_PRIVATE_KEY_PATH KALSHI_PRIVATE_KEY].any? { |key| ENV[key].present? }
    end

    def refresh_existing_score_metadata(organization)
      return 0 unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

      count = 0
      organization.kalshi_weather_predictions
        .where.not(result_status: "pending")
        .where("NOT (metadata ? 'miss_cause')")
        .order(updated_at: :desc)
        .limit(80)
        .find_each do |prediction|
          count += 1 if prediction.refresh_score_metadata!
        end
      count
    end
  end
end
