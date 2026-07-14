module Comms
  class StormWatchRefresh
    Result = Data.define(:source_count, :created_count, :updated_count, :skipped_count, :duplicate_contact_count, :missing_contact_count, :archived_count, :error_count, :started_at, :finished_at) do
      def to_h
        {
          source: "storm_watch",
          source_count: source_count,
          created: created_count,
          updated: updated_count,
          skipped: skipped_count,
          duplicate_contact: duplicate_contact_count,
          missing_contact: missing_contact_count,
          archived: archived_count,
          errors: error_count,
          started_at: started_at&.iso8601,
          finished_at: finished_at&.iso8601
        }
      end
    end

    def self.call(organization:, user: nil, limit: nil)
      new(organization: organization, user: user, limit: limit).call
    end

    def initialize(organization:, user:, limit:)
      @organization = organization
      @user = user || organization.users.order(:id).first
      @limit = normalize_limit(limit || ENV["WIZWIKI_COMMS_STORM_REFRESH_LIMIT"])
    end

    def call
      started_at = Time.current
      current_record_ids = []
      source_count = 0
      created = 0
      updated = 0
      skipped = 0
      duplicate_contact = 0
      missing_contact = 0
      errors = 0
      contact_index = Comms::ContactDeduper.key_index(organization: organization)

      source_scope.find_each do |record|
        break if limit.present? && source_count >= limit

        source_count += 1
        current_record_ids << record.id
        attrs = attrs_for(record)
        if attrs[:phone].blank? && attrs[:email].blank?
          skipped += 1
          missing_contact += 1
          next
        end
        existing_stage = active_storm_watch_stage(record)
        if Comms::ContactDeduper.duplicate_in_index?(
          contact_index,
          phone: attrs[:phone],
          email: attrs[:email],
          except_keys: Comms::ContactDeduper.stage_keys(existing_stage)
        )
          skipped += 1
          duplicate_contact += 1
          next
        end
        stage = upsert_stage!(record: record, attrs: attrs)
        Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
        stage.previously_new_record? ? created += 1 : updated += 1
      rescue ActiveRecord::ActiveRecordError, ArgumentError => error
        errors += 1
        skipped += 1
        Rails.logger.warn("[Comms::StormWatchRefresh] skipped record=#{record&.id}: #{error.class}: #{error.message}")
      end

      archived = archive_stale_blocks!(current_record_ids)
      clear_lane_caches!
      finished_at = Time.current
      Result.new(
        source_count: source_count,
        created_count: created,
        updated_count: updated,
        skipped_count: skipped,
        duplicate_contact_count: duplicate_contact,
        missing_contact_count: missing_contact,
        archived_count: archived,
        error_count: errors,
        started_at: started_at,
        finished_at: finished_at
      )
    end

    private

    attr_reader :organization, :user, :limit

    def normalize_limit(value)
      return nil if value.to_s.blank? || value.to_s == "all" || value.to_i <= 0

      value.to_i.clamp(1, 25_000)
    end

    def source_scope
      Weather::LeadMatcher.scope_for(organization)
        .includes(:crm_record_artifacts)
        .order(updated_at: :desc)
    end

    def attrs_for(record)
      props = record.properties.to_h
      hubspot_props = props.fetch("hubspot", {}).to_h.fetch("properties", {}).to_h
      weather = props.fetch("weather_lead", {}).to_h
      contact_name = contact_name_for(record, hubspot_props)
      company_name = company_name_for(record, hubspot_props)
      label = company_name.presence || contact_name.presence || record.name.presence || "Storm Watch COMMS"
      phone = record.phone.presence || first_present_value(hubspot_props, "phone", "mobilephone", "hs_calculated_phone_number", "hs_searchable_calculated_phone_number")
      email = record.email.presence || first_present_value(hubspot_props, "email")
      industry = first_present_value(hubspot_props, "industry", "business_type")
      zip = first_present_value(hubspot_props, "zip", "postal_code", "postalcode")

      {
        label: label,
        phone: normalize_phone(phone),
        email: normalize_email(email),
        contact_name: contact_name,
        company_name: company_name,
        industry: industry,
        zip: zip,
        notes: storm_watch_notes(weather),
        lead_attrs: {
          hubspot_lead_id: record.record_type == "lead" ? hubspot_props["hs_object_id"] : nil,
          hubspot_contact_id: record.record_type == "contact" ? hubspot_props["hs_object_id"] : nil,
          hubspot_company_id: record.record_type == "company" ? hubspot_props["hs_object_id"] : nil,
          hubspot_owner_id: hubspot_props["hubspot_owner_id"],
          hubspot_lead_label: "Storm Watch",
          hubspot_lead_stage: record.stage,
          hubspot_lead_quality: record.priority_source,
          weather_source_record_id: record.id,
          weather_source_record_type: record.record_type,
          weather_events: Array(weather["signals"]).first(5).map { |signal| signal.to_h.slice("event", "severity", "urgency", "certainty", "states", "postal_codes", "expires_at") }
        }.compact_blank,
        raw_row: {
          "crm_record_id" => record.id,
          "crm_record_type" => record.record_type,
          "crm_record_name" => record.name,
          "hubspot_object_id" => hubspot_props["hs_object_id"],
          "weather_lead" => weather
        }
      }
    end

    def upsert_stage!(record:, attrs:)
      stage = active_storm_watch_stage(record)
      stage ||= record.crm_record_artifacts.build(
        organization: organization,
        user: user,
        artifact_type: "comm_staging",
        title: "Storm Watch COMMS: #{attrs[:label]}"
      )
      was_new = stage.new_record?
      stage.update!(
        status: visible_stage_status(stage),
        user: stage.user || user,
        generated_at: Time.current,
        content_type: "application/json",
        metadata: stage.metadata.to_h.merge(stage_metadata(record: record, attrs: attrs))
      )
      stage.define_singleton_method(:previously_new_record?) { was_new }
      stage
    end

    def active_storm_watch_stage(record)
      record.crm_record_artifacts
        .where(organization: organization, artifact_type: "comm_staging")
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "storm_watch_comms")
        .order(updated_at: :desc)
        .first
    end

    def visible_stage_status(stage)
      stage.status.to_s.in?(%w[aircall_ready aircall_sent aircall_failed]) ? stage.status : "staged"
    end

    def stage_metadata(record:, attrs:)
      contact_label = attrs[:contact_name].presence || "Contact"
      company_label = attrs[:company_name].presence || (attrs[:contact_name].present? ? nil : attrs[:label])
      phone_option = attrs[:phone].present? ? { "id" => "storm-phone", "name" => contact_label, "value" => attrs[:phone], "reason" => "Storm Watch source table" } : nil
      email_option = attrs[:email].present? ? { "id" => "storm-email", "name" => contact_label, "value" => attrs[:email], "reason" => "Storm Watch source table" } : nil
      sms_body = opening_sms(attrs[:contact_name], attrs[:company_name])

      {
        "stage_type" => "storm_watch_comms",
        "company_name" => company_label,
        "deal_name" => company_label.presence || contact_label.presence || attrs[:label],
        "comm_kit_direction" => "wizwiki_out",
        "comm_kit_direction_label" => "Storm Watch",
        "contact_options" => [{ "id" => "storm-contact", "name" => contact_label, "company" => company_label, "record_type" => record.record_type, "reason" => "Storm Watch source table" }],
        "phone_options" => [phone_option].compact,
        "recipient_email_options" => [email_option].compact,
        "manual_comms_contact_keys" => Comms::ContactDeduper.keys(phone: attrs[:phone], email: attrs[:email]),
        "manual_comms_contact_phone_digits" => Comms::ContactDeduper.phone_digits(attrs[:phone]),
        "manual_comms_contact_email" => Comms::ContactDeduper.email_address(attrs[:email]),
        "selected_contact_id" => "storm-contact",
        "selected_phone_id" => phone_option.to_h["id"],
        "selected_recipient_email_id" => email_option.to_h["id"],
        "recipient_selection_summary" => "Storm Watch matched #{record.name} from active weather signals near known CRM address data.",
        "sender_name" => user&.display_name,
        "sender_phone" => user&.display_phone_number,
        "sender_profile" => {
          "name" => user&.display_name,
          "phone" => user&.display_phone_number,
          "email" => user&.email_address,
          "twilio" => user&.twilio_profile
        }.compact_blank,
        "sms_options" => [{ "id" => "storm-opener", "tone" => "Storm Watch opener", "body" => sms_body }],
        "selected_sms_id" => "storm-opener",
        "composed_sms_body" => sms_body,
        "aircall_status" => "storm_watch",
        "aircall_ready" => false,
        "captured_contact_name" => attrs[:contact_name],
        "captured_company_name" => attrs[:company_name],
        "captured_email" => attrs[:email],
        "captured_industry" => attrs[:industry],
        "weather_comms_import" => true,
        "weather_storm_watch" => true,
        "weather_storm_watch_loaded_at" => Time.current.iso8601,
        "weather_source_crm_record_id" => record.id,
        "weather_source_crm_record_type" => record.record_type,
        "weather_source_crm_record_name" => record.name,
        "weather_lead" => record.properties.to_h["weather_lead"],
        "csv_call_import" => false,
        "csv_call_import_source" => nil,
        "csv_call_notes" => attrs[:notes],
        "hubspot_lead" => attrs[:lead_attrs],
        "hubspot_lead_id" => attrs.dig(:lead_attrs, :hubspot_lead_id),
        "hubspot_contact_id" => attrs.dig(:lead_attrs, :hubspot_contact_id),
        "hubspot_company_id" => attrs.dig(:lead_attrs, :hubspot_company_id),
        "hubspot_owner_id" => attrs.dig(:lead_attrs, :hubspot_owner_id),
        "comms_bot_state" => {
          "contact_name" => attrs[:contact_name],
          "company_name" => attrs[:company_name],
          "industry" => attrs[:industry]
        }.compact_blank,
        "staged_at" => Time.current.iso8601,
        "staged_by_user_id" => user&.id,
        "staged_by" => user&.display_name,
        "sms_sending_disabled" => false
      }.compact_blank
    end

    def archive_stale_blocks!(current_record_ids)
      scope = organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "storm_watch_comms")
      scope = current_record_ids.present? ? scope.where("crm_record_id IS NULL OR crm_record_id NOT IN (?)", current_record_ids) : scope

      archived = 0
      scope.find_each do |stage|
        stage.update!(
          status: "archived",
          metadata: stage.metadata.to_h.merge(
            "storm_watch_archived_at" => Time.current.iso8601,
            "storm_watch_archive_reason" => "not present in current weather match set"
          )
        )
        archived += 1
      end
      archived
    end

    def contact_name_for(record, hubspot_props)
      if record.record_type == "contact"
        [hubspot_props["firstname"], hubspot_props["lastname"]].compact_blank.join(" ").presence || record.name
      else
        first_present_value(hubspot_props, "contact_name", "firstname")
      end
    end

    def company_name_for(record, hubspot_props)
      return record.name if record.record_type == "company"

      first_present_value(hubspot_props, "company_name", "company", "associated_company_name") ||
        (record.record_type == "deal" ? first_present_value(hubspot_props, "dealname") : nil) ||
        (record.record_type == "lead" ? first_present_value(hubspot_props, "hs_lead_name", "hs_lead_label") : nil)
    end

    def first_present_value(hash, *keys)
      keys.each do |key|
        value = hash[key.to_s].to_s.squish.presence
        return value if value.present?
      end
      nil
    end

    def normalize_phone(value)
      cleaned = value.to_s.gsub(/[^\d+]/, "")
      digits = cleaned.gsub(/\D/, "")
      digits.length >= 7 ? cleaned : nil
    end

    def normalize_email(value)
      value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
    end

    def opening_sms(contact_name, company_name)
      first_name = contact_name.to_s.squish.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      target = first_name.presence || company_name.to_s.squish.presence
      if target.present?
        "Hi #{target}, I'm Thumper from WIZWIKI Marketing. We saw recent weather activity near your market and can help you move quickly with postcards, yard signs, or neighborhood blitz materials. Are you trying to reach homeowners after the storm?"
      else
        "Hi, I'm Thumper from WIZWIKI Marketing. We saw recent weather activity near your market and can help you move quickly with postcards, yard signs, or neighborhood blitz materials. Are you trying to reach homeowners after the storm?"
      end
    end

    def storm_watch_notes(weather)
      signals = Array(weather["signals"]).first(3)
      return "Storm Watch match from current weather signals." if signals.blank?

      signals.map do |signal|
        signal = signal.to_h
        event = signal["event"].presence || "Weather signal"
        severity = [signal["severity"], signal["urgency"], signal["certainty"]].compact_blank.join("/")
        zips = Array(signal["postal_codes"]).first(8).join(", ")
        state = Array(signal["states"]).join(", ")
        [event, severity.presence, state.presence, zips.present? ? "ZIP #{zips}" : nil].compact.join(" // ")
      end.join("\n")
    end

    def clear_lane_caches!
      Rails.cache.delete(["comms_board_status_counts_snapshot", organization.id])
      Rails.cache.delete(["storm_watch_staged_comms_count", organization.id])
      User.pluck(:id).each { |user_id| Rails.cache.delete(["storm_watch_staged_comms_count", organization.id, user_id]) }
    end
  end
end
