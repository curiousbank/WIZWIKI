require "digest"

module Weather
  class LeadMatcher
    WEATHER_RELEVANT_RECORD_TYPES = %w[company contact deal ticket lead].freeze
    MATCH_SIGNAL_TYPES = %w[alert historical_alert].freeze
    BAD_WEATHER_SEVERITIES = %w[extreme severe moderate].freeze
    BAD_WEATHER_EVENT_KEYWORDS = [
      "warning", "watch", "advisory", "tornado", "thunderstorm", "flood",
      "flash flood", "hail", "wind", "hurricane", "tropical", "storm",
      "winter", "snow", "ice", "freeze", "wildfire", "fire weather", "heat"
    ].freeze
    CONSTRUCTION_TRADE_KEYWORDS = [
      "roof", "roofer", "roofing", "roof repair", "tarp",
      "gutter", "gutters", "siding", "soffit", "fascia", "exterior",
      "contractor", "construction", "builder", "builders", "general contractor",
      "restoration", "restore", "remediation", "mitigation", "disaster",
      "storm", "damage", "water damage", "fire damage", "flood", "mold",
      "remodel", "renovation", "repair", "home repair", "handyman",
      "plumbing", "plumber", "drain", "sewer", "septic", "waterproofing",
      "hvac", "heating", "cooling", "air conditioning", "furnace",
      "electrical", "electric", "electrician", "generator",
      "tree", "tree service", "tree removal", "arborist", "stump",
      "landscaping", "landscape", "lawn", "lawn care", "irrigation", "sprinkler",
      "fence", "fencing", "deck", "patio", "hardscape",
      "windows", "window", "doors", "door", "garage", "garage door",
      "painting", "drywall", "plaster", "flooring", "carpet", "tile",
      "pressure washing", "power washing", "cleaning", "cleanup", "janitorial",
      "concrete", "masonry", "foundation", "basement", "crawl space",
      "asphalt", "paving", "excavation", "grading", "solar", "pool"
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
    US_STATE_CODE_TO_NAME = US_STATE_NAME_TO_CODE.invert.freeze

    class << self
      def scope_for(organization)
        flagged = flagged_scope_for(organization)
        return flagged if flagged.exists?

        matching_scope_for(organization)
      end

      def flagged_scope_for(organization)
        organization.crm_records.where.not(status: "archived").where("crm_records.properties ? :key", key: "weather_lead")
      end

      def matching_scope_for(organization, signals: nil)
        base = organization.crm_records.where(record_type: WEATHER_RELEVANT_RECORD_TYPES).where.not(status: "archived")
        return base.none unless WeatherLeadSignal.storage_ready?
        return base.none unless ActiveRecord::Base.connection.table_exists?(:crm_address_records)

        signals = signals.present? ? Array(signals) : signals_for_matching(organization).to_a
        zips = signals.flat_map { |signal| Array(signal.affected_postal_codes) }.compact_blank.uniq
        states = signals.flat_map { |signal| Array(signal.affected_states) }.compact_blank.uniq
        return base.none if zips.blank? && states.blank?

        address_scope = matched_address_scope(organization, zips, states)
        if zips.present?
          address_records = address_scope.present? ? base.where(id: address_scope.select(:crm_record_id).distinct) : base.none
          return trade_scope(raw_zip_fallback_enabled? ? address_records.or(raw_zip_scope(base, zips)) : address_records)
        end

        return base.none unless ActiveModel::Type::Boolean.new.cast(ENV["WIZWIKI_WEATHER_ALLOW_STATE_FALLBACK"])
        return base.none unless address_scope.present? && address_scope.exists?

        trade_scope(base.where(id: address_scope.select(:crm_record_id).distinct))
      end

      def signal_summary_for(organization)
        return { actionable: 0, alerts: 0, history: 0, forecasts: 0, predictions: 0, states: [], postal_codes: [], latest: nil, zip_crosswalk_rows: Weather::ZipResolver.crosswalk_count } unless WeatherLeadSignal.storage_ready?

        scope = organization.weather_lead_signals.actionable
        signals = scope.recent_first.limit(12)
        {
          actionable: scope.count,
          alerts: scope.alerts.count,
          history: scope.historical_alerts.count,
          forecasts: scope.forecasts.count,
          predictions: scope.where(
            "LOWER(COALESCE(weather_lead_signals.urgency, '')) IN (:urgencies) OR LOWER(COALESCE(weather_lead_signals.certainty, '')) IN (:certainties)",
            urgencies: %w[future expected immediate],
            certainties: %w[possible likely observed]
          ).count,
          states: signals.flat_map { |signal| Array(signal.affected_states) }.compact_blank.uniq.sort,
          postal_codes: signals.flat_map { |signal| Array(signal.affected_postal_codes) }.compact_blank.uniq.sort.first(12),
          zip_crosswalk_rows: Weather::ZipResolver.crosswalk_count,
          zip_resolution: signals.map { |signal| signal.metadata.to_h["zip_resolution"] }.compact_blank.tally,
          latest: signals.first
        }
      end

      def flag_matches!(organization)
        signals = signals_for_matching(organization).to_a
        if signals.blank?
          clear_stale_flags!(organization, [])
          return 0
        end

        summary = {
          "lead_source" => "weather",
          "flagged_at" => Time.current.iso8601,
          "lookback_days" => match_window_days,
          "signals_count" => signals.length,
          "signals" => signals.map do |signal|
            {
              "id" => signal.id,
              "type" => signal.signal_type,
              "event" => signal.event,
              "severity" => signal.severity,
              "urgency" => signal.urgency,
              "certainty" => signal.certainty,
              "states" => signal.affected_states,
              "postal_codes" => signal.affected_postal_codes,
              "expires_at" => signal.expires_at&.iso8601
            }.compact
          end
        }
        digest = Digest::SHA256.hexdigest(summary.except("flagged_at").to_json)
        changed = 0

        match_ids = matching_scope_for(organization, signals: signals).pluck(:id)
        clear_stale_flags!(organization, match_ids)
        return 0 if match_ids.blank?

        organization.crm_records.where(id: match_ids).find_each do |record|
          properties = record.properties.to_h
          weather = properties.fetch("weather_lead", {}).to_h
          next if weather["digest"] == digest

          properties["weather_lead"] = summary.merge("digest" => digest)
          hubspot = properties.fetch("hubspot", {}).to_h
          hubspot["lead_sources"] = (Array(hubspot["lead_sources"]) | ["weather"]).compact_blank
          properties["hubspot"] = hubspot
          record.update!(properties: properties)
          changed += 1
        end

        changed
      end

      private

      def signals_for_matching(organization)
        since = match_window_days.days.ago
        scope = organization.weather_lead_signals
          .where(signal_type: MATCH_SIGNAL_TYPES)
          .where(
            "COALESCE(weather_lead_signals.started_at, weather_lead_signals.expires_at, weather_lead_signals.updated_at, weather_lead_signals.created_at) >= ?",
            since
          )

        severity_filter = BAD_WEATHER_SEVERITIES.map(&:downcase)
        event_clauses = []
        event_binds = {}
        BAD_WEATHER_EVENT_KEYWORDS.each_with_index do |keyword, index|
          key = "weather_event#{index}".to_sym
          event_binds[key] = "%#{ActiveRecord::Base.sanitize_sql_like(keyword)}%"
          event_clauses << "LOWER(COALESCE(weather_lead_signals.event, '')) LIKE :#{key}"
          event_clauses << "LOWER(COALESCE(weather_lead_signals.headline, '')) LIKE :#{key}"
        end

        scope
          .where(
            "LOWER(COALESCE(weather_lead_signals.severity, '')) IN (:severities) OR #{event_clauses.join(" OR ")}",
            event_binds.merge(severities: severity_filter)
          )
          .recent_first
          .limit(match_signal_limit)
      end

      def match_window_days
        value = ENV.fetch("WIZWIKI_WEATHER_MATCH_WINDOW_DAYS", "7").to_i
        value.positive? ? value : 7
      end

      def match_signal_limit
        value = ENV.fetch("WIZWIKI_WEATHER_MATCH_SIGNAL_LIMIT", "750").to_i
        value.positive? ? value : 750
      end

      def raw_zip_fallback_enabled?
        ActiveModel::Type::Boolean.new.cast(ENV["WIZWIKI_WEATHER_RAW_ZIP_FALLBACK"])
      end

      def matched_address_scope(organization, zips, states)
        return nil unless ActiveRecord::Base.connection.table_exists?(:crm_address_records)

        scope = organization.crm_address_records.where.not(crm_record_id: nil)
        if zips.present?
          scope.where(postal_code: zips)
        else
          normalized_states = state_match_terms(states)
          return scope.none if normalized_states.blank?

          scope.where("UPPER(crm_address_records.state) IN (:states)", states: normalized_states)
        end
      end

      def state_match_terms(states)
        Array(states).flat_map do |state|
          normalized = state.to_s.strip.upcase
          code = US_STATE_NAME_TO_CODE[normalized] || normalized[/\A[A-Z]{2}\z/]
          next [] unless code.present? && US_STATE_CODE_TO_NAME.key?(code)

          [code, US_STATE_CODE_TO_NAME[code]]
        end.compact.uniq
      end

      def trade_scope(scope)
        clauses = []
        binds = {}
        CONSTRUCTION_TRADE_KEYWORDS.each_with_index do |keyword, index|
          key = "q#{index}".to_sym
          binds[key] = "%#{ActiveRecord::Base.sanitize_sql_like(keyword)}%"
          clauses << "crm_records.name ILIKE :#{key}"
          clauses << "crm_records.domain ILIKE :#{key}"
          clauses << "crm_records.stage ILIKE :#{key}"
          clauses << "crm_records.properties::text ILIKE :#{key}"
        end

        scope.where(clauses.join(" OR "), binds)
      end

      def raw_zip_scope(scope, zips)
        clauses = []
        binds = {}
        zips.first(50).each_with_index do |zip, index|
          key = "zip#{index}".to_sym
          binds[key] = "%#{ActiveRecord::Base.sanitize_sql_like(zip.to_s)}%"
          clauses << "crm_records.properties::text ILIKE :#{key}"
        end
        return scope.none if clauses.blank?

        scope.where(clauses.join(" OR "), binds)
      end

      def clear_stale_flags!(organization, keep_ids)
        scope = flagged_scope_for(organization)
        scope = scope.where.not(id: keep_ids) if keep_ids.present?
        scope.find_each do |record|
          properties = record.properties.to_h
          properties.delete("weather_lead")
          hubspot = properties.fetch("hubspot", {}).to_h
          hubspot["lead_sources"] = Array(hubspot["lead_sources"]) - ["weather"]
          properties["hubspot"] = hubspot
          record.update!(properties: properties)
        end
      end
    end
  end
end
