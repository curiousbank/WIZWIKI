require "json"
require "net/http"
require "uri"

module Kalshi
  class WeatherActualHighBackfill
    DEFAULT_LIMIT = 16
    STATION_LIMIT = 6
    OBSERVATION_CACHE_TTL = 8.hours
    CLIMATE_PRODUCT_CACHE_TTL = 8.hours
    POINT_CACHE_TTL = 7.days
    FINAL_ACTUAL_BUFFER = 90.minutes

    CITY_TIME_ZONES = {
      "KXHIGHNY" => "Eastern Time (US & Canada)",
      "KXHIGHLAX" => "Pacific Time (US & Canada)",
      "KXHIGHCHI" => "Central Time (US & Canada)",
      "KXHIGHMIA" => "Eastern Time (US & Canada)",
      "KXHIGHAUS" => "Central Time (US & Canada)",
      "KXHIGHDEN" => "Mountain Time (US & Canada)",
      "KXHIGHPHIL" => "Eastern Time (US & Canada)",
      "KXHIGHTBOS" => "Eastern Time (US & Canada)"
    }.freeze
    CLIMATE_PRODUCT_LOCATIONS = {
      "KXHIGHNY" => "NYC",
      "KXHIGHLAX" => "LAX",
      "KXHIGHCHI" => "MDW",
      "KXHIGHMIA" => "MIA",
      "KXHIGHAUS" => "AUS",
      "KXHIGHDEN" => "DEN",
      "KXHIGHPHIL" => "PHL",
      "KXHIGHTBOS" => "BOS"
    }.freeze

    class << self
      def call(organization:, limit: DEFAULT_LIMIT)
        new(organization: organization, limit: limit).call
      end
    end

    def initialize(organization:, limit:)
      @organization = organization
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
      @checked = 0
      @backfilled = 0
      @waiting = 0
      @errors = []
      @sources = Hash.new(0)
    end

    def call
      return status("prediction storage not ready") unless storage_ready?

      candidates.each do |prediction|
        @checked += 1
        backfill_prediction(prediction)
      rescue StandardError => error
        @errors << "#{prediction.market_ticker}: #{error.class}: #{error.message}"
        mark_backfill_error(prediction, error)
      end

      status
    end

    private

    attr_reader :organization, :limit

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        organization.respond_to?(:kalshi_weather_predictions)
    end

    def status(reason = nil)
      {
        checked: @checked,
        backfilled: @backfilled,
        waiting: @waiting,
        sources: @sources.sort.to_h,
        errors: (reason.present? ? [reason] : @errors.first(5)),
        ran_at: Time.current
      }
    end

    def candidates
      organization.kalshi_weather_predictions
        .where(observed_high_f: nil)
        .where("prediction_date <= ?", Time.current.to_date)
        .where("close_time IS NULL OR close_time <= ?", 90.minutes.ago)
        .order(Arel.sql("COALESCE(close_time, created_at) ASC"))
        .limit(limit)
    end

    def backfill_prediction(prediction)
      definition = city_definition_for(prediction)
      return mark_waiting(prediction, "city definition missing") if definition.blank?

      range = day_range_for(definition, prediction)
      return mark_waiting(prediction, "local observation day still open") unless final_actual_ready?(range)

      actual = actual_high_for(definition, prediction, range: range)
      return mark_waiting(prediction, "observations unavailable") if actual.blank?

      if prediction.result_status == "pending"
        prediction.score_from_observed!(
          observed_high: actual.fetch(:high_f),
          settlement_value: "#{actual.fetch(:high_f)}F",
          source: actual.fetch(:source),
          payload: actual.stringify_keys
        )
      else
        prediction.observed_high_f = actual.fetch(:high_f)
        prediction.metadata = prediction.metadata.to_h.merge(
          "actual_high_source" => actual.fetch(:source),
          "actual_high_backfilled_at" => Time.current.iso8601,
          "actual_high_payload" => actual.stringify_keys
        )
        prediction.refresh_score_metadata!
      end
      @backfilled += 1
      @sources[actual.fetch(:source)] += 1
    end

    def city_definition_for(prediction)
      Kalshi::WeatherMarketScout::WEATHER_STUDY_SERIES.find do |definition|
        definition.fetch(:ticker).to_s.casecmp?(prediction.series_ticker.to_s)
      end || Kalshi::WeatherMarketScout::WEATHER_STUDY_SERIES.find do |definition|
        definition.fetch(:city).to_s.casecmp?(prediction.city.to_s)
      end
    end

    def actual_high_for(definition, prediction, range: nil)
      climate_product_actual_high(definition, prediction)
    end

    def climate_product_actual_high(definition, prediction)
      date = event_date_for(prediction) || prediction.prediction_date
      location = CLIMATE_PRODUCT_LOCATIONS[definition.fetch(:ticker).to_s]
      return nil if date.blank? || location.blank?

      product = climate_product_for(location, date)
      return nil if product.blank?

      high = extract_climate_maximum(product.fetch(:text), date)
      return nil if high.blank?

      {
        high_f: high.fetch(:high_f),
        observed_at: high[:observed_at],
        station_id: location,
        station_name: product[:station_name].presence || location,
        source: product.fetch(:source),
        product_id: product.fetch(:product_id),
        product_code: product.fetch(:product_code),
        issuance_time: product.fetch(:issuance_time),
        climate_date: date.iso8601
      }
    end

    def climate_product_for(location, date)
      cache_key = ["weather_actual_climate_product", location, date.iso8601]
      Rails.cache.fetch(cache_key, expires_in: CLIMATE_PRODUCT_CACHE_TTL) do
        matched_product = nil
        %w[CLI CF6].each do |product_code|
          matched_product = climate_product_by_code(location, date, product_code)
          break if matched_product.present?
        end
        matched_product
      end
    end

    def climate_product_by_code(location, date, product_code)
      list_uri = URI("https://api.weather.gov/products/types/#{product_code}/locations/#{URI.encode_www_form_component(location)}")
      list = request_json(list_uri)
      Array(list["@graph"]).first(12).each do |row|
        product_id = row["id"].presence || row["@id"].to_s.split("/").last
        next if product_id.blank?

        product = request_json(URI("https://api.weather.gov/products/#{URI.encode_www_form_component(product_id)}"))
        text = product["productText"].to_s
        next unless climate_product_matches_date?(text, date, product_code)

        return {
          text: text,
          product_id: product_id,
          product_code: product_code,
          issuance_time: product["issuanceTime"].presence || row["issuanceTime"],
          station_name: climate_station_name(text),
          source: "weather.gov_#{product_code.downcase}_climate_product"
        }
      end
      nil
    end

    def climate_product_matches_date?(text, date, product_code)
      case product_code
      when "CLI"
        text.match?(/CLIMATE SUMMARY FOR #{Regexp.escape(date.strftime("%B").upcase)}\s+#{date.day}\s+#{date.year}/)
      when "CF6"
        text.match?(/MONTH:\s+#{Regexp.escape(date.strftime("%B").upcase)}/) &&
          text.match?(/YEAR:\s+#{date.year}/) &&
          cf6_daily_max(text, date).present?
      else
        false
      end
    end

    def extract_climate_maximum(text, date)
      if (match = text.match(/^\s*MAXIMUM\s+(-?\d{1,3})(?:\s+([0-9:]+\s+[AP]M))?/i))
        return {
          high_f: match[1].to_i,
          observed_at: match[2].presence
        }
      end

      cf6_high = cf6_daily_max(text, date)
      return { high_f: cf6_high } if cf6_high.present?

      nil
    end

    def cf6_daily_max(text, date)
      table_armed = false
      in_data_table = false
      text.each_line do |line|
        if line.match?(/\bDY\s+MAX\s+MIN\s+AVG\b/)
          table_armed = true
          next
        end

        if table_armed && line.match?(/\A=+\s*\z/)
          in_data_table = true
          next
        end

        next unless in_data_table
        break if line.match?(/\A=+\s*\z/)

        match = line.match(/\A\s*#{date.day}\s+(-?\d{1,3})\s+/)
        next if match.blank?

        high = match[1].to_i
        return high if high.between?(-80, 140)
      end
      nil
    end

    def climate_station_name(text)
      match = text.match(/^\s*STATION:\s+(.+?)\s*$/i)
      match&.[](1)&.squish
    end

    def observation_stations_for(definition)
      Rails.cache.fetch(["weather_actual_stations", definition.fetch(:ticker)], expires_in: POINT_CACHE_TTL) do
        points_uri = URI("https://api.weather.gov/points/#{definition.fetch(:latitude)},#{definition.fetch(:longitude)}")
        points = request_json(points_uri)
        stations_url = points.dig("properties", "observationStations").presence
        raise "observationStations URL missing" if stations_url.blank?

        station_payload = request_json(URI(stations_url))
        Array(station_payload["features"]).filter_map do |feature|
          props = feature["properties"].to_h
          station_id = props["stationIdentifier"].presence || props["@id"].to_s.split("/").last
          next if station_id.blank?

          {
            station_id: station_id,
            station_name: props["name"].presence || station_id,
            station_url: props["@id"],
            distance_m: station_distance_m(feature)
          }
        end.sort_by { |station| station[:distance_m].to_f }
      end
    end

    def day_range_for(definition, prediction)
      zone = ActiveSupport::TimeZone[CITY_TIME_ZONES.fetch(definition.fetch(:ticker), "Central Time (US & Canada)")] || Time.zone
      date = event_date_for(prediction) || prediction.prediction_date || prediction.close_time&.in_time_zone(zone)&.to_date || Date.current
      start_time = zone.local(date.year, date.month, date.day, 0, 0, 0)
      end_time = start_time.end_of_day
      start_time..end_time
    end

    def event_date_for(prediction)
      return nil unless defined?(KalshiWeatherPrediction)

      KalshiWeatherPrediction.event_date_from_ticker(prediction.event_ticker.presence || prediction.market_ticker)
    end

    def final_actual_ready?(range)
      Time.current >= range.end + FINAL_ACTUAL_BUFFER
    end

    def station_actual_high(station, range)
      cache_key = [
        "weather_actual_high",
        station.fetch(:station_id),
        range.begin.iso8601,
        range.end.iso8601
      ]
      Rails.cache.fetch(cache_key, expires_in: OBSERVATION_CACHE_TTL) do
        uri = URI("https://api.weather.gov/stations/#{URI.encode_www_form_component(station.fetch(:station_id))}/observations")
        uri.query = URI.encode_www_form(start: range.begin.utc.iso8601, end: range.end.utc.iso8601)
        payload = request_json(uri)
        readings = Array(payload["features"]).filter_map do |feature|
          props = feature["properties"].to_h
          temp_c = props.dig("temperature", "value")
          next if temp_c.blank?

          temp_f = celsius_to_f(temp_c.to_f)
          next unless temp_f.between?(-80, 140)

          {
            high_f: temp_f.round,
            observed_at: props["timestamp"],
            raw_c: temp_c.to_f
          }
        end
        if readings.blank?
          nil
        else
          high = readings.max_by { |row| row.fetch(:high_f) }
          {
            high_f: high.fetch(:high_f),
            observed_at: high.fetch(:observed_at),
            station_id: station.fetch(:station_id),
            station_name: station.fetch(:station_name),
            station_distance_m: station[:distance_m],
            source: "weather.gov_station_observation",
            features_checked: Array(payload["features"]).length,
            range_start: range.begin.iso8601,
            range_end: range.end.iso8601
          }
        end
      end
    end

    def station_distance_m(feature)
      props = feature["properties"].to_h
      value = props.dig("distance", "value")
      return value.to_f if value.present?

      0.0
    end

    def celsius_to_f(value)
      (value * 9.0 / 5.0) + 32.0
    end

    def request_json(uri)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/geo+json, application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (actual high backfill)"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 18) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def mark_waiting(prediction, reason)
      @waiting += 1
      prediction.update_columns(
        metadata: prediction.metadata.to_h.merge(
          "actual_high_backfill_status" => "waiting",
          "actual_high_backfill_reason" => reason,
          "actual_high_backfill_checked_at" => Time.current.iso8601
        ),
        updated_at: Time.current
      )
    end

    def mark_backfill_error(prediction, error)
      prediction.update_columns(
        metadata: prediction.metadata.to_h.merge(
          "actual_high_backfill_status" => "error",
          "actual_high_backfill_error" => "#{error.class}: #{error.message}".truncate(300),
          "actual_high_backfill_checked_at" => Time.current.iso8601
        ),
        updated_at: Time.current
      )
    rescue StandardError
      nil
    end
  end
end
