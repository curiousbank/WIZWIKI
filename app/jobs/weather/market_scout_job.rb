module Weather
  class MarketScoutJob < ApplicationJob
    queue_as :default

    CACHE_VERSION = "v1".freeze

    def self.result_cache_key(organization_id)
      ["weather_market_scout_result", CACHE_VERSION, organization_id]
    end

    def perform(organization_id: nil)
      organizations = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      organizations.find_each do |organization|
        scout = Kalshi::WeatherMarketScout.call(
          organization: organization,
          signals: recent_signals_for(organization)
        )
        Rails.cache.write(self.class.result_cache_key(organization.id), scout, expires_in: 45.minutes)
        Rails.logger.info(
          "[Weather::MarketScoutJob] organization=#{organization.id} cities=#{Array(scout[:study_series]).length} " \
          "stored=#{scout.dig(:prediction_storage)} errors=#{Array(scout[:errors]).length}"
        )
      rescue StandardError => error
        Rails.logger.warn("[Weather::MarketScoutJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end

    private

    def recent_signals_for(organization)
      return [] unless WeatherLeadSignal.storage_ready?

      organization.weather_lead_signals
        .where("COALESCE(started_at, expires_at, updated_at, created_at) >= ?", 7.days.ago)
        .recent_first
        .limit(500)
        .to_a
    rescue StandardError => error
      Rails.logger.warn("[Weather::MarketScoutJob] signal load skipped organization=#{organization.id}: #{error.class}: #{error.message}")
      []
    end
  end
end
