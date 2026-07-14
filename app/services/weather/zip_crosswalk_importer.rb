require "csv"
require "json"
require "net/http"
require "uri"

module Weather
  class ZipCrosswalkImporter
    Error = Class.new(StandardError)
    HUD_API_URL = "https://www.huduser.gov/hudapi/public/usps".freeze
    HUD_COUNTY_TO_ZIP_TYPE = "7".freeze

    Result = Struct.new(:source, :source_version, :states, :rows_seen, :rows_imported, :rows_skipped, :error_count, keyword_init: true)

    class << self
      def call(path: nil, token: nil, states: nil, source: nil, source_version: nil)
        if path.present?
          import_csv(path: path, source: source, source_version: source_version)
        else
          import_hud_api(token: token.presence || ENV["WIZWIKI_HUD_USPS_API_TOKEN"], states: states, source_version: source_version)
        end
      end

      def import_missing_states!(states)
        return empty_result(source: "hud_usps_api") unless WeatherZipCrosswalk.storage_ready?

        state_values = normalize_states(states)
        return empty_result(source: "hud_usps_api") if state_values.blank?

        missing_states = state_values.reject { |state| WeatherZipCrosswalk.where(state: state).exists? }
        return empty_result(source: "hud_usps_api", states: state_values) if missing_states.blank?
        return empty_result(source: "hud_usps_api", states: missing_states) if ENV["WIZWIKI_HUD_USPS_API_TOKEN"].blank?

        import_hud_api(token: ENV["WIZWIKI_HUD_USPS_API_TOKEN"], states: missing_states)
      rescue StandardError => error
        Rails.logger.warn("[Weather::ZipCrosswalkImporter] missing state import skipped: #{error.class}: #{error.message}")
        empty_result(source: "hud_usps_api", states: Array(states), error_count: 1)
      end

      def import_csv(path:, source: nil, source_version: nil)
        raise Error, "weather ZIP crosswalk table is not ready" unless WeatherZipCrosswalk.storage_ready?
        raise Error, "crosswalk path is required" if path.blank?
        raise Error, "crosswalk file not found: #{path}" unless File.file?(path)

        inferred_source = source.presence || infer_csv_source(path)
        result = empty_result(source: inferred_source, source_version: source_version.presence || default_csv_version(inferred_source))
        batch = []
        CSV.foreach(path, headers: true, encoding: "bom|utf-8", col_sep: csv_col_sep(path)) do |row|
          result.rows_seen += 1
          attrs = attributes_from_row(row.to_h, source: result.source, source_version: result.source_version)
          if attrs.blank?
            result.rows_skipped += 1
            next
          end

          result.states |= [attrs[:state]].compact
          batch << attrs
          if batch.length >= 1_000
            result.rows_imported += upsert_batch(batch)
            batch.clear
          end
        end
        result.rows_imported += upsert_batch(batch) if batch.present?
        result
      end

      def import_hud_api(token:, states:, source_version: nil)
        raise Error, "weather ZIP crosswalk table is not ready" unless WeatherZipCrosswalk.storage_ready?
        raise Error, "WIZWIKI_HUD_USPS_API_TOKEN is required for HUD API import" if token.blank?

        state_values = normalize_states(states.presence || ENV.fetch("WIZWIKI_WEATHER_CROSSWALK_STATES", "").split(","))
        state_values = Weather::LeadSignalSync::DEFAULT_ALERT_STATES if state_values.blank? && defined?(Weather::LeadSignalSync::DEFAULT_ALERT_STATES)
        state_values = normalize_states(state_values)
        raise Error, "at least one state is required for HUD API import" if state_values.blank?

        result = empty_result(source: "hud_usps_api", source_version: source_version.presence || "latest", states: state_values)
        state_values.each do |state|
          payload = fetch_hud_state(token: token, state: state)
          data = payload.fetch("data", {}).to_h
          version = source_version.presence || hud_source_version(data)
          rows = Array(data["results"])
          result.rows_seen += rows.length
          result.source_version = version if result.source_version == "latest"

          batch = rows.filter_map do |row|
            attrs = attributes_from_row(row.to_h, source: result.source, source_version: version, fallback_state: state)
            result.rows_skipped += 1 if attrs.blank?
            attrs
          end
          result.rows_imported += upsert_batch(batch) if batch.present?
        rescue StandardError => error
          result.error_count += 1
          Rails.logger.warn("[Weather::ZipCrosswalkImporter] HUD #{state} import skipped: #{error.class}: #{error.message}")
        end
        result
      end

      private

      def empty_result(source:, source_version: "unknown", states: [], error_count: 0)
        Result.new(
          source: source,
          source_version: source_version,
          states: normalize_states(states),
          rows_seen: 0,
          rows_imported: 0,
          rows_skipped: 0,
          error_count: error_count
        )
      end

      def fetch_hud_state(token:, state:)
        uri = URI(HUD_API_URL)
        uri.query = URI.encode_www_form(type: HUD_COUNTY_TO_ZIP_TYPE, query: state)
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        request["Authorization"] = "Bearer #{token}"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.request(request)
        end
        raise Error, "HUD USPS API #{state} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError => error
        raise Error, "HUD USPS API #{state} returned invalid JSON: #{error.message}"
      end

      def attributes_from_row(row, source:, source_version:, fallback_state: nil)
        values = normalized_row(row)
        postal_code = first_present(values, "zip", "postal_code", "zipcode", "usps_zip", "geoid_zcta5_20", "zcta5")&.to_s&.[](/\A\d{5}\z/)
        county_fips = first_present(values, "county", "county_fips", "county_geoid", "geoid_county_20")
        county_fips = first_present(values, "geoid") if county_fips.blank? && postal_code.present? && first_present(values, "geoid").to_s.match?(/\A\d{5}\z/)
        county_fips = county_fips.to_s[/\d{5}/]
        return nil if postal_code.blank? || county_fips.blank?

        {
          postal_code: postal_code,
          county_fips: county_fips,
          state: first_present(values, "usps_zip_pref_state", "state").presence || fallback_state.presence || state_from_fips(county_fips),
          preferred_city: first_present(values, "usps_zip_pref_city", "city", "preferred_city"),
          res_ratio: decimal_value(first_present(values, "res_ratio", "residential_ratio")),
          bus_ratio: decimal_value(first_present(values, "bus_ratio", "business_ratio")),
          oth_ratio: decimal_value(first_present(values, "oth_ratio", "other_ratio")),
          total_ratio: decimal_value(first_present(values, "tot_ratio", "total_ratio")) || census_area_ratio(values),
          source: source,
          source_version: source_version,
          metadata: { "raw_headers" => values.keys.first(20) },
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      def upsert_batch(rows)
        return 0 if rows.blank?

        rows = rows.uniq { |row| [row[:source], row[:source_version], row[:postal_code], row[:county_fips]] }
        WeatherZipCrosswalk.upsert_all(
          rows,
          unique_by: "idx_weather_zip_crosswalks_unique_source_version",
          update_only: [:state, :preferred_city, :res_ratio, :bus_ratio, :oth_ratio, :total_ratio, :metadata]
        )
        rows.length
      end

      def normalized_row(row)
        row.to_h.transform_keys { |key| key.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "") }
      end

      def csv_col_sep(path)
        header = File.open(path, "r:bom|utf-8", &:readline).to_s
        header.include?("|") ? "|" : ","
      rescue EOFError
        ","
      end

      def infer_csv_source(path)
        header = File.open(path, "r:bom|utf-8", &:readline).to_s.downcase
        return "census_zcta_county" if header.include?("geoid_zcta5") && header.include?("geoid_county")

        "hud_usps_csv"
      rescue EOFError
        "hud_usps_csv"
      end

      def default_csv_version(source)
        source.to_s == "census_zcta_county" ? "2020" : "csv"
      end

      def first_present(values, *keys)
        keys.each do |key|
          value = values[key]
          return value.to_s.strip if value.present?
        end
        nil
      end

      def decimal_value(value)
        return nil if value.blank?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      def census_area_ratio(values)
        part = decimal_value(first_present(values, "arealand_part"))
        county = decimal_value(first_present(values, "arealand_county_20", "arealand_county"))
        return nil if part.blank? || county.blank? || county.zero?

        part / county
      end

      def hud_source_version(data)
        year = data["year"].presence || data["data_year"].presence
        quarter = data["quarter"].presence
        [year, quarter && "Q#{quarter}"].compact.join.presence || "latest"
      end

      def state_from_fips(county_fips)
        state_fips = county_fips.to_s[0, 2]
        Weather::ZipResolver::STATE_FIPS.invert[state_fips]
      end

      def normalize_states(values)
        Array(values).map { |state| state.to_s.strip.upcase[/\A[A-Z]{2}\z/] }.compact.uniq
      end
    end
  end
end
