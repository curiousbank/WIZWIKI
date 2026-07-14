module Weather
  class ZipResolver
    STATE_FIPS = {
      "AL" => "01", "AK" => "02", "AZ" => "04", "AR" => "05", "CA" => "06", "CO" => "08",
      "CT" => "09", "DE" => "10", "DC" => "11", "FL" => "12", "GA" => "13", "HI" => "15",
      "ID" => "16", "IL" => "17", "IN" => "18", "IA" => "19", "KS" => "20", "KY" => "21",
      "LA" => "22", "ME" => "23", "MD" => "24", "MA" => "25", "MI" => "26", "MN" => "27",
      "MS" => "28", "MO" => "29", "MT" => "30", "NE" => "31", "NV" => "32", "NH" => "33",
      "NJ" => "34", "NM" => "35", "NY" => "36", "NC" => "37", "ND" => "38", "OH" => "39",
      "OK" => "40", "OR" => "41", "PA" => "42", "RI" => "44", "SC" => "45", "SD" => "46",
      "TN" => "47", "TX" => "48", "UT" => "49", "VT" => "50", "VA" => "51", "WA" => "53",
      "WV" => "54", "WI" => "55", "WY" => "56", "PR" => "72", "VI" => "78"
    }.freeze

    COUNTY_ZONE_REGEX = /\A([A-Z]{2})C(\d{3})\z/.freeze

    class << self
      def resolve(county_fips:, states: [], explicit_postal_codes: [])
        explicit = normalize_postal_codes(explicit_postal_codes)
        crosswalk = resolve_county_fips(county_fips, states: states)

        (explicit + crosswalk).uniq.sort
      end

      def resolve_county_fips(county_fips, states: [])
        return [] unless WeatherZipCrosswalk.storage_ready?

        counties = Array(county_fips).map { |code| code.to_s[/\d{5}/] }.compact_blank.uniq
        return [] if counties.blank?

        scope = WeatherZipCrosswalk.for_counties(counties).meaningful(minimum_ratio)
        state_values = Array(states).map { |state| state.to_s.strip.upcase[/\A[A-Z]{2}\z/] }.compact_blank.uniq
        scope = scope.for_states(state_values) if state_values.present?
        scope.distinct.order(:postal_code).limit(zip_limit).pluck(:postal_code)
      end

      def county_fips_from_zone_codes(zone_codes)
        Array(zone_codes).filter_map do |zone_code|
          match = zone_code.to_s.strip.upcase.match(COUNTY_ZONE_REGEX)
          next unless match

          state_fips = STATE_FIPS[match[1]]
          next unless state_fips

          "#{state_fips}#{match[2]}"
        end.uniq
      end

      def crosswalk_count
        WeatherZipCrosswalk.storage_ready? ? WeatherZipCrosswalk.count : 0
      end

      private

      def normalize_postal_codes(values)
        Array(values).map { |zip| zip.to_s[/\A\d{5}\z/] }.compact_blank.uniq
      end

      def minimum_ratio
        value = ENV.fetch("WIZWIKI_WEATHER_ZIP_MIN_RATIO", "0.001").to_f
        value.positive? ? value : 0.001
      end

      def zip_limit
        value = ENV.fetch("WIZWIKI_WEATHER_ZIP_RESOLVE_LIMIT", "250").to_i
        value.positive? ? value : 250
      end
    end
  end
end
