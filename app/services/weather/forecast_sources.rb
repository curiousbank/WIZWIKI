require "json"
require "net/http"
require "time"
require "uri"

module Weather
  class ForecastSources
    CACHE_TTL = 20.minutes
    REQUEST_OPEN_TIMEOUT = 4
    REQUEST_READ_TIMEOUT = 10
    USER_AGENT = ENV.fetch("WIZWIKI_WEATHER_USER_AGENT", "WIZWIKI AUTOS Weather Brain (Thumper von AUTOS)")
    VISUAL_CROSSING_KEYS = %w[
      VISUAL_CROSSING_API_KEY
      VISUALCROSSING_API_KEY
      VISUAL_CROSSING_KEY
      WEATHER_VISUAL_CROSSING_API_KEY
    ].freeze

    POLLING_GUIDANCE = {
      forecast_sources: "20-30 minutes while markets are open; faster polling rarely helps because the source forecasts do not all refresh every minute.",
      kalshi_markets: "5 minutes for active page cache, 30 minutes for scheduled paper snapshots, and WebSocket/orderbook work only after paper edge is proven.",
      actual_highs: "hourly after market close; only the official Kalshi result and NWS Daily Climate Report are valid training labels.",
      execution_policy: "paper only until station-aligned, officially settled, out-of-sample results show a repeatable fee-adjusted edge."
    }.freeze

    class << self
      def call(definition, target_date: nil)
        new(definition, target_date: target_date).call
      end

      def polling_guidance
        POLLING_GUIDANCE
      end
    end

    def initialize(definition, target_date: nil)
      @definition = definition.to_h.symbolize_keys
      @target_date = normalize_date(target_date)
      @errors = []
    end

    def call
      Rails.cache.fetch([
        "weather_forecast_sources_v7",
        definition.fetch(:ticker),
        definition[:station_id],
        definition.fetch(:latitude),
        definition.fetch(:longitude),
        definition[:time_zone],
        target_date&.iso8601
      ], expires_in: CACHE_TTL) do
        build_consensus
      end
    rescue StandardError => error
      {
        high_f: nil,
        period: "source consensus unavailable",
        short_forecast: "Forecast sources failed",
        detailed_forecast: error.message.to_s.truncate(180),
        source: "Multi-source forecast consensus",
        source_count: 0,
        source_spread_f: nil,
        agreement_label: "offline",
        sources: [],
        unavailable_sources: [],
        errors: ["#{error.class}: #{error.message}"],
        polling_guidance: POLLING_GUIDANCE,
        fetched_at: Time.current
      }
    end

    private

    attr_reader :definition, :target_date, :errors

    def build_consensus
      sources = [
        weather_gov_source,
        open_meteo_source,
        met_norway_source,
        visual_crossing_source
      ].compact
      available = sources.select { |source| source[:high_f].present? && source_date_aligned?(source) }
      misaligned = sources.select { |source| source[:high_f].present? && !source_date_aligned?(source) }
      values = available.map { |source| source[:high_f].to_f }
      spread = values.present? ? (values.max - values.min).round(1) : nil
      high = consensus_high(values)
      leader = available.min_by { |source| (source[:high_f].to_f - high.to_f).abs } || available.first

      {
        high_f: high,
        period: leader&.dig(:period).presence || "today",
        short_forecast: consensus_short_forecast(available, spread),
        detailed_forecast: consensus_detail(available, sources, spread),
        source: "Multi-source forecast consensus",
        source_count: available.length,
        source_total: sources.length,
        source_spread_f: spread,
        agreement_label: agreement_label(available.length, spread),
        sources: available,
        unavailable_sources: sources.reject { |source| available.include?(source) }.map do |source|
          next source unless misaligned.include?(source)

          source.except(:high_f).merge(
            status: "unavailable",
            reason: "source date #{source[:forecast_date] || 'missing'} does not match target #{forecast_date.iso8601}"
          )
        end,
        target_date: forecast_date,
        event_date_aligned: available.present? && available.all? { |source| source_date_aligned?(source) },
        errors: errors,
        polling_guidance: POLLING_GUIDANCE,
        fetched_at: Time.current
      }
    end

    def weather_gov_source
      points_uri = URI("https://api.weather.gov/points/#{definition.fetch(:latitude)},#{definition.fetch(:longitude)}")
      points = request_json(points_uri)
      forecast_url = points.dig("properties", "forecast")
      raise "Weather.gov forecast URL missing" if forecast_url.blank?

      forecast = request_json(URI(forecast_url))
      periods = Array(forecast.dig("properties", "periods"))
      period = forecast_period_for(periods)
      period ||= periods.find { |item| item["isDaytime"] && item["temperature"].present? } if target_date.blank?
      raise "Weather.gov forecast period missing" if period.blank?

      source_row(
        key: "weather_gov",
        label: "Weather.gov",
        high_f: period["temperature"],
        period: period["name"],
        summary: period["shortForecast"],
        detail: period["detailedForecast"].to_s.truncate(180),
        url: forecast_url,
        forecast_date: period_date(period)
      )
    rescue StandardError => error
      errors << "Weather.gov #{definition.fetch(:city)}: #{error.class}: #{error.message}"
      unavailable_source("weather_gov", "Weather.gov", error)
    end

    def open_meteo_source
      uri = URI("https://api.open-meteo.com/v1/forecast")
      uri.query = URI.encode_www_form(
        latitude: definition.fetch(:latitude),
        longitude: definition.fetch(:longitude),
        daily: "temperature_2m_max,precipitation_sum,weather_code",
        temperature_unit: "fahrenheit",
        timezone: "auto",
        forecast_days: 2
      )
      payload = request_json(uri)
      daily = payload.fetch("daily", {})
      dates = Array(daily["time"])
      index = daily_index_for(dates)
      raise "Open-Meteo target date #{forecast_date.iso8601} missing" if index.blank?
      high = Array(daily["temperature_2m_max"])[index]
      date = dates[index]
      raise "Open-Meteo daily high missing" if high.blank?

      source_row(
        key: "open_meteo",
        label: "Open-Meteo",
        high_f: high,
        period: date.presence || "today",
        summary: "Daily max from Open-Meteo model blend",
        detail: "Precip #{Array(daily['precipitation_sum'])[index] || 'n/a'} // weather code #{Array(daily['weather_code'])[index] || 'n/a'}",
        url: "https://open-meteo.com/en/docs",
        forecast_date: normalize_date(date)
      )
    rescue StandardError => error
      errors << "Open-Meteo #{definition.fetch(:city)}: #{error.class}: #{error.message}"
      unavailable_source("open_meteo", "Open-Meteo", error)
    end

    def visual_crossing_source
      key = visual_crossing_key
      return unavailable_source("visual_crossing", "Visual Crossing", "API key missing") if key.blank?

      location = "#{definition.fetch(:latitude)},#{definition.fetch(:longitude)}"
      date_path = target_date&.iso8601 || "today"
      uri = URI("https://weather.visualcrossing.com/VisualCrossingWebServices/rest/services/timeline/#{location}/#{date_path}")
      uri.query = URI.encode_www_form(
        unitGroup: "us",
        include: "days",
        elements: "datetime,tempmax,conditions,description,source",
        key: key,
        contentType: "json"
      )
      payload = request_json(uri)
      day = Array(payload["days"]).first || {}
      high = day["tempmax"]
      raise "Visual Crossing tempmax missing" if high.blank?

      source_row(
        key: "visual_crossing",
        label: "Visual Crossing",
        high_f: high,
        period: day["datetime"].presence || "today",
        summary: day["conditions"].presence || "Timeline daily max",
        detail: day["description"].to_s.truncate(180).presence || "Visual Crossing timeline forecast",
        url: "https://www.visualcrossing.com/weather-api",
        forecast_date: normalize_date(day["datetime"])
      )
    rescue StandardError => error
      errors << "Visual Crossing #{definition.fetch(:city)}: #{error.class}: #{error.message}"
      unavailable_source("visual_crossing", "Visual Crossing", error)
    end

    def met_norway_source
      uri = URI("https://api.met.no/weatherapi/locationforecast/2.0/compact")
      uri.query = URI.encode_www_form(
        lat: definition.fetch(:latitude),
        lon: definition.fetch(:longitude)
      )
      payload = request_json(uri)
      rows = Array(payload.dig("properties", "timeseries"))
      day_rows = rows.select do |row|
        source_time(row["time"])&.to_date == forecast_date
      rescue ArgumentError, TypeError
        false
      end
      day_rows = rows.first(24) if day_rows.blank? && target_date.blank?
      raise "MET Norway target date #{forecast_date.iso8601} missing" if day_rows.blank?
      temperatures_c = day_rows.filter_map { |row| row.dig("data", "instant", "details", "air_temperature") }
      raise "MET Norway air temperature missing" if temperatures_c.blank?

      high_f = temperatures_c.map { |value| celsius_to_fahrenheit(value) }.max
      summary = day_rows.filter_map do |row|
        row.dig("data", "next_6_hours", "summary", "symbol_code") ||
          row.dig("data", "next_1_hours", "summary", "symbol_code")
      end.first

      source_row(
        key: "met_norway",
        label: "MET Norway",
        high_f: high_f,
        period: forecast_date.iso8601,
        summary: summary.to_s.tr("_", " ").presence || "Locationforecast daily max",
        detail: "Global locationforecast compact model, max from today's hourly air_temperature values.",
        url: "https://api.met.no/weatherapi/locationforecast/2.0/documentation",
        forecast_date: forecast_date
      )
    rescue StandardError => error
      errors << "MET Norway #{definition.fetch(:city)}: #{error.class}: #{error.message}"
      unavailable_source("met_norway", "MET Norway", error)
    end

    def request_json(uri, redirects_remaining: 3)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = USER_AGENT
      response = http_get(uri, request)
      if response.is_a?(Net::HTTPRedirection)
        raise "HTTP redirect limit reached" unless redirects_remaining.positive?

        location = response["location"].to_s
        raise "HTTP redirect missing location" if location.blank?

        redirected_uri = URI.join(uri.to_s, location)
        raise "insecure HTTP redirect blocked" unless redirected_uri.scheme == "https"

        return request_json(redirected_uri, redirects_remaining: redirects_remaining - 1)
      end
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def http_get(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: REQUEST_OPEN_TIMEOUT, read_timeout: REQUEST_READ_TIMEOUT) do |http|
        http.request(request)
      end
    end

    def forecast_period_for(periods)
      return nil if target_date.blank?

      periods.find { |item| item["isDaytime"] && item["temperature"].present? && period_date(item) == target_date }
    end

    def period_date(period)
      source_time(period["startTime"])&.to_date
    rescue ArgumentError, TypeError
      nil
    end

    def daily_index_for(dates)
      return 0 if target_date.blank?

      dates.index(target_date.iso8601)
    end

    def forecast_date
      target_date || Time.current.in_time_zone(forecast_zone).to_date
    end

    def source_time(value)
      Time.iso8601(value.to_s).in_time_zone(forecast_zone)
    end

    def forecast_zone
      @forecast_zone ||= ActiveSupport::TimeZone[definition[:time_zone]] || Time.zone
    end

    def normalize_date(value)
      return value if value.is_a?(Date)
      return value.to_date if value.respond_to?(:to_date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def source_row(key:, label:, high_f:, period:, summary:, detail:, url:, forecast_date:)
      {
        key: key,
        label: label,
        high_f: high_f.to_f.round(1),
        period: period.to_s,
        summary: summary.to_s.squish.presence || "Daily high forecast",
        detail: detail.to_s.squish.presence || "No source detail supplied.",
        url: url,
        forecast_date: normalize_date(forecast_date)&.iso8601,
        fetched_at: Time.current
      }
    end

    def source_date_aligned?(source)
      normalize_date(source[:forecast_date]) == forecast_date
    end

    def unavailable_source(key, label, error)
      {
        key: key,
        label: label,
        status: "unavailable",
        reason: error.is_a?(StandardError) ? "#{error.class}: #{error.message}" : error.to_s,
        fetched_at: Time.current
      }
    end

    def visual_crossing_key
      VISUAL_CROSSING_KEYS.filter_map { |env_key| ENV[env_key].presence }.first
    end

    def consensus_high(values)
      values = Array(values).compact.map(&:to_f).sort
      return nil if values.blank?

      middle = values.length / 2
      median = values.length.odd? ? values[middle] : ((values[middle - 1] + values[middle]) / 2.0)
      median.round
    end

    def agreement_label(count, spread)
      return "offline" if count.to_i.zero?
      return "single source" if count.to_i == 1
      return "tight agreement" if spread.to_f <= 2.0
      return "watch spread" if spread.to_f <= 4.0

      "source conflict"
    end

    def consensus_short_forecast(available, spread)
      parts = available.map { |source| "#{source[:label]} #{format_temperature(source[:high_f])}" }
      parts << "spread #{format_temperature(spread)}" if spread.present?
      parts.join(" // ").presence || "Forecast sources pending"
    end

    def consensus_detail(available, sources, spread)
      if available.present?
        "#{agreement_label(available.length, spread)} across #{available.length}/#{sources.length} sources. #{available.map { |source| "#{source[:label]}: #{source[:detail]}" }.join(' | ')}".truncate(360)
      else
        "No forecast source returned a daily high. #{sources.map { |source| "#{source[:label]}: #{source[:reason]}" }.join(' | ')}".truncate(360)
      end
    end

    def format_temperature(value)
      return "n/a" if value.blank?

      number = value.to_f
      "#{number == number.round ? number.round : number.round(1)}F"
    end

    def celsius_to_fahrenheit(value)
      ((value.to_f * 9.0 / 5.0) + 32.0).round(1)
    end
  end
end
