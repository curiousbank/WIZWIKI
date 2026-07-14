require "json"
require "net/http"
require "uri"
require "digest"

module Weather
  class LeadSignalSync
    Error = Class.new(StandardError)

    ACTIONABLE_EVENT_REGEX = /
      tornado|severe\ thunderstorm|hail|high\ wind|damaging\ wind|hurricane|tropical\ storm|
      flash\ flood|flood|wildfire|fire\ weather|winter\ storm|ice\ storm|blizzard|
      dust\ storm|landslide|earthquake|tsunami
    /ix.freeze

    WARNING_EVENT_REGEX = /
      tornado\ warning|severe\ thunderstorm\ warning|flash\ flood\ warning|flood\ warning|
      extreme\ wind\ warning|high\ wind\ warning|hurricane\ warning|tropical\ storm\ warning|
      storm\ surge\ warning|dust\ storm\ warning|blizzard\ warning|ice\ storm\ warning|
      winter\ storm\ warning|fire\ warning
    /ix.freeze

    CONSTRUCTION_OPPORTUNITY_EVENTS = /
      tornado|severe\ thunderstorm|hail|wind|hurricane|tropical|flood|wildfire|winter|ice|blizzard
    /ix.freeze

    DEFAULT_ALERT_STATES = %w[
      MI OH IN IL PA NY NJ DE MD VA NC SC GA FL TN KY AL MS MO IA KS OK TX LA
    ].freeze
    WEATHER_GOV_AREA_CODES = %w[
      AL AK AZ AR CA CO CT DE DC FL GA GU HI ID IL IN IA KS KY LA ME MD MA MI
      MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA PR RI SC SD TN TX UT VT
      VA VI WA WV WI WY AS MP
    ].freeze
    US_STATE_NAME_TO_CODE = {
      "ALABAMA" => "AL", "ALASKA" => "AK", "ARIZONA" => "AZ", "ARKANSAS" => "AR",
      "CALIFORNIA" => "CA", "COLORADO" => "CO", "CONNECTICUT" => "CT", "DELAWARE" => "DE",
      "DISTRICT OF COLUMBIA" => "DC", "FLORIDA" => "FL", "GEORGIA" => "GA", "HAWAII" => "HI",
      "IDAHO" => "ID", "ILLINOIS" => "IL", "INDIANA" => "IN", "IOWA" => "IA",
      "KANSAS" => "KS", "KENTUCKY" => "KY", "LOUISIANA" => "LA", "MAINE" => "ME",
      "MARYLAND" => "MD", "MASSACHUSETTS" => "MA", "MICHIGAN" => "MI", "MINNESOTA" => "MN",
      "MISSISSIPPI" => "MS", "MISSOURI" => "MO", "MONTANA" => "MT", "NEBRASKA" => "NE",
      "NEVADA" => "NV", "NEW HAMPSHIRE" => "NH", "NEW JERSEY" => "NJ", "NEW MEXICO" => "NM",
      "NEW YORK" => "NY", "NORTH CAROLINA" => "NC", "NORTH DAKOTA" => "ND", "OHIO" => "OH",
      "OKLAHOMA" => "OK", "OREGON" => "OR", "PENNSYLVANIA" => "PA", "RHODE ISLAND" => "RI",
      "SOUTH CAROLINA" => "SC", "SOUTH DAKOTA" => "SD", "TENNESSEE" => "TN", "TEXAS" => "TX",
      "UTAH" => "UT", "VERMONT" => "VT", "VIRGINIA" => "VA", "WASHINGTON" => "WA",
      "WEST VIRGINIA" => "WV", "WISCONSIN" => "WI", "WYOMING" => "WY"
    }.freeze

    Result = Struct.new(:states_scanned, :alerts_seen, :historical_alerts_seen, :forecasts_seen, :signals_created, :signals_updated, :signals_expired, :error_count, :actionable_count, :matched_lead_count, :flagged_lead_count, keyword_init: true)

    class << self
      def call(organization:, states: nil)
        raise Error, "weather lead signal storage is not ready" unless WeatherLeadSignal.storage_ready?

        sync_started_at = Time.current
        state_codes = rotate_states(normalize_weather_gov_states(states.presence || states_from_crm(organization).presence || default_alert_states))
        state_codes = state_codes.first(state_limit)
        return empty_result if state_codes.blank?

        ensure_zip_crosswalk_for_states(state_codes)

        seen_source_uids = []
        alerts_seen = 0
        historical_alerts_seen = 0
        forecasts_seen = 0
        created = 0
        updated = 0
        errors = 0
        forecast_zones = []

        national_alerts = safe_fetch("national active warnings", "US") { fetch_national_active_alerts }
        errors += 1 if national_alerts.nil?
        national_alerts ||= []
        alerts_seen += national_alerts.length
        national_alerts.each do |feature|
          next unless storm_warning_alert?(feature)

          attrs = attributes_from_feature(feature, fallback_state_from_feature(feature), historical: false, source_mode: "national_warning")
          forecast_zones |= Array(attrs.dig(:metadata, "forecast_zones"))
          seen_source_uids << attrs.fetch(:source_uid)
          saved = upsert_signal!(organization, attrs)
          created += 1 if saved == :created
          updated += 1 if saved == :updated
        end

        state_codes.each do |state|
          alerts = safe_fetch("active alerts", state) { fetch_alerts_for_state(state) }
          errors += 1 if alerts.nil?
          alerts ||= []
          alerts_seen += alerts.length
          alerts.each do |feature|
            next unless storm_warning_alert?(feature)

            attrs = attributes_from_feature(feature, state, historical: false, source_mode: "state_warning")
            forecast_zones |= Array(attrs.dig(:metadata, "forecast_zones"))
            seen_source_uids << attrs.fetch(:source_uid)
            saved = upsert_signal!(organization, attrs)
            created += 1 if saved == :created
            updated += 1 if saved == :updated
          end

          historical_alerts = safe_fetch("recent alerts", state) { fetch_recent_alerts_for_state(state) }
          errors += 1 if historical_alerts.nil?
          historical_alerts ||= []
          historical_alerts_seen += historical_alerts.length
          historical_alerts.each do |feature|
            next unless storm_warning_alert?(feature)

            attrs = attributes_from_feature(feature, state, historical: true, source_mode: "state_warning_history")
            forecast_zones |= Array(attrs.dig(:metadata, "forecast_zones"))
            seen_source_uids << attrs.fetch(:source_uid)
            saved = upsert_signal!(organization, attrs)
            created += 1 if saved == :created
            updated += 1 if saved == :updated
          end
        end

        forecast_zones.first(forecast_zone_limit).each do |zone_id|
          attrs = safe_fetch("forecast zone", zone_id) { forecast_signal_for_zone(zone_id) }
          errors += 1 if attrs.nil?
          next unless attrs.present?

          forecasts_seen += 1
          seen_source_uids << attrs.fetch(:source_uid)
          saved = upsert_signal!(organization, attrs)
          created += 1 if saved == :created
          updated += 1 if saved == :updated
        end

        expired = expire_missing_signals(organization, seen_source_uids, sync_started_at)
        flagged = Weather::LeadMatcher.flag_matches!(organization)
        Result.new(
          states_scanned: state_codes.length,
          alerts_seen: alerts_seen,
          historical_alerts_seen: historical_alerts_seen,
          forecasts_seen: forecasts_seen,
          signals_created: created,
          signals_updated: updated,
          signals_expired: expired,
          error_count: errors,
          actionable_count: organization.weather_lead_signals.actionable.count,
          matched_lead_count: Weather::LeadMatcher.scope_for(organization).count,
          flagged_lead_count: flagged
        )
      end

      private

      def empty_result
        Result.new(
          states_scanned: 0,
          alerts_seen: 0,
          historical_alerts_seen: 0,
          forecasts_seen: 0,
          signals_created: 0,
          signals_updated: 0,
          signals_expired: 0,
          error_count: 0,
          actionable_count: 0,
          matched_lead_count: 0,
          flagged_lead_count: 0
        )
      end

      def states_from_crm(organization)
        return [] unless ActiveRecord::Base.connection.table_exists?(:crm_address_records)

        organization.crm_address_records.where.not(state: [nil, ""]).distinct.pluck(:state)
      end

      def normalize_states(values)
        values = ENV.fetch("WIZWIKI_WEATHER_ALERT_STATES", "").split(",") if values.blank?
        Array(values).map do |state|
          normalized = state.to_s.strip.upcase
          US_STATE_NAME_TO_CODE[normalized] || normalized[/\A[A-Z]{2}\z/]
        end.compact.uniq
      end

      def normalize_weather_gov_states(values)
        normalize_states(values).select { |state| WEATHER_GOV_AREA_CODES.include?(state) }
      end

      def default_alert_states
        configured = ENV.fetch("WIZWIKI_WEATHER_ALERT_STATES", "").split(",")
        configured.present? ? configured : DEFAULT_ALERT_STATES
      end

      def rotate_states(states)
        return states if states.length < 2

        offset = Time.current.hour % states.length
        states.rotate(offset)
      end

      def state_limit
        configured = ENV["WIZWIKI_WEATHER_STATE_LIMIT"].to_s.strip
        return WEATHER_GOV_AREA_CODES.length if configured.blank?

        limit = configured.to_i
        limit.positive? ? limit : WEATHER_GOV_AREA_CODES.length
      end

      def safe_fetch(label, scope)
        yield
      rescue Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
        Rails.logger.warn("[Weather::LeadSignalSync] #{label} #{scope} skipped: #{error.class}: #{error.message}")
        nil
      end

      def fetch_alerts_for_state(state)
        uri = URI("https://api.weather.gov/alerts/active?area=#{URI.encode_www_form_component(state)}")
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/geo+json, application/json"
        request["User-Agent"] = ENV.fetch("WIZWIKI_WEATHER_USER_AGENT", "WIZWIKI AUTOS Weather Leads (Thumper von AUTOS)")

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
          http.request(request)
        end
        raise Error, "Weather.gov #{state} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).fetch("features", [])
      rescue JSON::ParserError => error
        raise Error, "Weather.gov #{state} returned invalid JSON: #{error.message}"
      end

      def fetch_national_active_alerts
        uri = URI("https://api.weather.gov/alerts/active")
        uri.query = URI.encode_www_form(status: "actual")
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/geo+json, application/json"
        request["User-Agent"] = ENV.fetch("WIZWIKI_WEATHER_USER_AGENT", "WIZWIKI AUTOS Weather Leads (Thumper von AUTOS)")

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 12) do |http|
          http.request(request)
        end
        raise Error, "Weather.gov national active warnings returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).fetch("features", [])
      rescue JSON::ParserError => error
        raise Error, "Weather.gov national active warnings returned invalid JSON: #{error.message}"
      end

      def fetch_recent_alerts_for_state(state)
        days = history_days
        return [] unless days.positive?

        finish = Time.current
        start = finish - days.days
        uri = URI("https://api.weather.gov/alerts")
        uri.query = URI.encode_www_form(
          area: state,
          start: start.utc.iso8601,
          end: finish.utc.iso8601,
          status: "actual"
        )
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/geo+json, application/json"
        request["User-Agent"] = ENV.fetch("WIZWIKI_WEATHER_USER_AGENT", "WIZWIKI AUTOS Weather Leads (Thumper von AUTOS)")

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 12) do |http|
          http.request(request)
        end
        raise Error, "Weather.gov recent alerts #{state} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).fetch("features", []).first(history_alert_limit)
      rescue JSON::ParserError => error
        raise Error, "Weather.gov recent alerts #{state} returned invalid JSON: #{error.message}"
      end

      def fetch_forecast_for_zone(zone_id)
        uri = URI("https://api.weather.gov/zones/forecast/#{URI.encode_www_form_component(zone_id)}/forecast")
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/geo+json, application/json"
        request["User-Agent"] = ENV.fetch("WIZWIKI_WEATHER_USER_AGENT", "WIZWIKI AUTOS Weather Leads (Thumper von AUTOS)")

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) do |http|
          http.request(request)
        end
        return nil if response.code.to_i == 404
        raise Error, "Weather.gov forecast #{zone_id} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError => error
        raise Error, "Weather.gov forecast #{zone_id} returned invalid JSON: #{error.message}"
      end

      def actionable_alert?(feature)
        props = feature.to_h.fetch("properties", {}).to_h
        text = [
          props["event"],
          props["headline"],
          props["description"],
          props["instruction"]
        ].compact.join(" ")
        return false unless text.match?(ACTIONABLE_EVENT_REGEX)

        severity = props["severity"].to_s.downcase
        urgency = props["urgency"].to_s.downcase
        certainty = props["certainty"].to_s.downcase
        return true if text.match?(CONSTRUCTION_OPPORTUNITY_EVENTS)
        return true if severity.in?(%w[extreme severe]) || urgency.in?(%w[immediate expected]) || certainty == "observed"

        false
      end

      def storm_warning_alert?(feature)
        props = feature.to_h.fetch("properties", {}).to_h
        text = [
          props["event"],
          props["headline"],
          props["description"],
          props["instruction"]
        ].compact.join(" ")
        text.match?(WARNING_EVENT_REGEX)
      end

      def attributes_from_feature(feature, fallback_state, historical:, source_mode: nil)
        props = feature.to_h.fetch("properties", {}).to_h
        source_uid = props["id"].presence || feature["id"].presence || Digest::SHA256.hexdigest(feature.to_json)
        source_uid = "history:#{source_uid}" if historical
        area_desc = props["areaDesc"].to_s
        text = [area_desc, props["headline"], props["description"], props["instruction"]].compact.join(" ")
        states = normalize_states([fallback_state] + Array(props.dig("geocode", "UGC")).map { |code| code.to_s[0, 2] })
        expires_at = parse_time(props["expires"] || props["ends"])
        explicit_zips = explicit_postal_codes(props)
        county_zones = county_zone_ids(props)
        county_fips = county_fips_codes(props)
        postal_codes = Weather::ZipResolver.resolve(county_fips: county_fips, states: states, explicit_postal_codes: explicit_zips)
        zip_resolution = zip_resolution_mode(explicit_zips: explicit_zips, resolved_zips: postal_codes, county_fips: county_fips)

        {
          source: "weather.gov",
          source_uid: source_uid,
          signal_type: historical ? "historical_alert" : "alert",
          event: props["event"].presence || "Weather Alert",
          headline: props["headline"].presence,
          description: props["description"].presence,
          severity: props["severity"].presence,
          urgency: props["urgency"].presence,
          certainty: props["certainty"].presence,
          status: historical ? "recent" : "active",
          area_desc: area_desc.presence,
          affected_states: states,
          affected_postal_codes: postal_codes,
          started_at: parse_time(props["effective"] || props["sent"]),
          expires_at: historical ? historical_signal_expires_at(expires_at) : expires_at,
          raw_payload: feature.to_h,
          metadata: {
            "sender_name" => props["senderName"],
            "response" => props["response"],
            "category" => props["category"],
            "message_type" => props["messageType"],
            "forecast_zones" => forecast_zone_ids(props),
            "affected_zones" => affected_zone_ids(props),
            "county_zones" => county_zones,
            "same_codes" => same_codes(props),
            "county_fips" => county_fips,
            "source_mode" => source_mode,
            "zip_resolution" => zip_resolution,
            "zip_count" => postal_codes.length,
            "zip_crosswalk_rows" => Weather::ZipResolver.crosswalk_count,
            "historical_lookback_days" => historical ? history_days : nil,
            "construction_opportunity" => text.match?(CONSTRUCTION_OPPORTUNITY_EVENTS),
            "synced_at" => Time.current.iso8601
          }.compact
        }
      end

      def forecast_signal_for_zone(zone_id)
        payload = fetch_forecast_for_zone(zone_id)
        return nil unless payload.present?

        props = payload.fetch("properties", {}).to_h
        periods = Array(props["periods"]).first(8)
        text = periods.map { |period| [period["name"], period["shortForecast"], period["detailedForecast"]].compact.join(": ") }.join("\n")
        return nil unless text.match?(ACTIONABLE_EVENT_REGEX)

        state = zone_id.to_s[0, 2]
        digest = Digest::SHA256.hexdigest(text)[0, 16]
        generated_at = parse_time(props["generatedAt"]) || Time.current
        {
          source: "weather.gov",
          source_uid: "forecast:#{zone_id}:#{generated_at.utc.strftime("%Y%m%d%H")}:#{digest}",
          signal_type: "forecast",
          event: "Weather Forecast",
          headline: periods.first&.fetch("shortForecast", nil).presence || "Forecast signal for #{zone_id}",
          description: text,
          severity: "moderate",
          urgency: "future",
          certainty: "possible",
          status: "active",
          area_desc: zone_id,
          affected_states: normalize_states([state]),
          affected_postal_codes: [],
          started_at: generated_at,
          expires_at: generated_at + 7.days,
          raw_payload: payload,
          metadata: {
            "forecast_zone" => zone_id,
            "generated_at" => generated_at.iso8601,
            "construction_opportunity" => text.match?(CONSTRUCTION_OPPORTUNITY_EVENTS),
            "prediction_signal" => true,
            "synced_at" => Time.current.iso8601
          }.compact
        }
      end

      def upsert_signal!(organization, attrs)
        signal = organization.weather_lead_signals.find_or_initialize_by(source: attrs.fetch(:source), source_uid: attrs.fetch(:source_uid))
        signal.assign_attributes(attrs.except(:source, :source_uid))
        if signal.new_record?
          signal.save!
          :created
        elsif signal.changed?
          signal.save!
          :updated
        end
      end

      def forecast_zone_ids(props)
        Array(props.dig("geocode", "UGC"))
          .map { |code| code.to_s.strip.upcase }
          .select { |code| code.match?(/\A[A-Z]{2}Z\d{3}\z/) }
          .uniq
      end

      def affected_zone_ids(props)
        Array(props["affectedZones"]).map { |url| url.to_s.split("/").last }.compact_blank.uniq
      end

      def county_zone_ids(props)
        (Array(props.dig("geocode", "UGC")) + affected_zone_ids(props))
          .map { |code| code.to_s.strip.upcase }
          .select { |code| code.match?(Weather::ZipResolver::COUNTY_ZONE_REGEX) }
          .uniq
      end

      def same_codes(props)
        Array(props.dig("geocode", "SAME")).map { |code| code.to_s.strip }.compact_blank.uniq
      end

      def explicit_postal_codes(props)
        [
          props["affectedPostalCodes"],
          props["postalCodes"],
          props.dig("geocode", "ZIP")
        ].flatten.compact.map { |zip| zip.to_s[/\A\d{5}\z/] }.compact.uniq
      end

      def county_fips_codes(props)
        from_same = same_codes(props).select { |code| code.match?(/\A\d{6}\z/) }.map { |code| code[1, 5] }
        (from_same + Weather::ZipResolver.county_fips_from_zone_codes(county_zone_ids(props))).uniq
      end

      def zip_resolution_mode(explicit_zips:, resolved_zips:, county_fips:)
        return "explicit_alert_property" if explicit_zips.present? && (resolved_zips - explicit_zips).blank?
        return "explicit_alert_property+county_fips_crosswalk" if explicit_zips.present? && resolved_zips.present?
        return "county_fips_crosswalk" if resolved_zips.present?
        return "crosswalk_missing" if county_fips.present?

        "not_available_from_weather_gov_alert"
      end

      def ensure_zip_crosswalk_for_states(states)
        Weather::ZipCrosswalkImporter.import_missing_states!(states) if defined?(Weather::ZipCrosswalkImporter) && WeatherZipCrosswalk.storage_ready?
      rescue StandardError => error
        Rails.logger.warn("[Weather::LeadSignalSync] ZIP crosswalk preflight skipped: #{error.class}: #{error.message}")
      end

      def fallback_state_from_feature(feature)
        props = feature.to_h.fetch("properties", {}).to_h
        normalize_states(Array(props.dig("geocode", "UGC")).map { |code| code.to_s[0, 2] }).first
      end

      def forecast_zone_limit
        limit = ENV.fetch("WIZWIKI_WEATHER_FORECAST_ZONE_LIMIT", "0").to_i
        limit.positive? ? limit : 0
      end

      def history_days
        days = ENV.fetch("WIZWIKI_WEATHER_HISTORY_DAYS", "30").to_i
        [[days, 0].max, 30].min
      end

      def history_alert_limit
        limit = ENV.fetch("WIZWIKI_WEATHER_HISTORY_ALERT_LIMIT", "25").to_i
        limit.positive? ? limit : 25
      end

      def historical_signal_expires_at(original_expires_at)
        cutoff = Time.current + ENV.fetch("WIZWIKI_WEATHER_RECENT_SIGNAL_TTL_DAYS", "14").to_i.days
        [original_expires_at, cutoff].compact.max
      end

      def parse_time(value)
        Time.zone.parse(value.to_s) if value.present?
      rescue ArgumentError
        nil
      end

      def expire_missing_signals(organization, seen_source_uids, sync_started_at)
        scope = organization.weather_lead_signals.where(source: "weather.gov", status: "active")
          .where("weather_lead_signals.updated_at < ?", sync_started_at)
        scope = scope.where.not(source_uid: seen_source_uids) if seen_source_uids.present?
        scope.update_all(status: "expired", updated_at: Time.current)
      end
    end
  end
end
