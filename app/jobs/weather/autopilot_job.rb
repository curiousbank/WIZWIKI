module Weather
  class AutopilotJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, limit: nil)
      organizations = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      organizations.find_each do |organization|
        paper_result = Kalshi::WeatherPaperTrader.call(organization: organization)
        live_result = Kalshi::WeatherAutopilot.call(
          organization: organization,
          limit: limit.presence || ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_LIMIT", Kalshi::WeatherAutopilot::DEFAULT_LIMIT).to_i
        )
        Rails.logger.info("[Weather::AutopilotJob] organization=#{organization.id} paper=#{paper_result.inspect} live=#{live_result.inspect}")
      rescue StandardError => error
        Rails.logger.warn("[Weather::AutopilotJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
