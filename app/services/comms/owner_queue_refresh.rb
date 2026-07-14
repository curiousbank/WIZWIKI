require "set"

module Comms
  class OwnerQueueRefresh
    SOURCE_NAME = "hubspot_owner_lead".freeze
    CONTACT_PROPERTIES = %w[
      firstname lastname email phone mobilephone hs_calculated_phone_number hs_calculated_mobile_number
      company jobtitle industry zip city state hs_object_id hubspot_owner_id
    ].freeze

    Result = Data.define(:source_count, :created_count, :updated_count, :skipped_count, :duplicate_contact_count, :missing_contact_count, :archived_count, :error_count, :started_at, :finished_at) do
      def to_h
        {
          source: SOURCE_NAME,
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

    def self.call(organization:, user: nil, owner_id: nil, limit: nil)
      new(organization: organization, user: user, owner_id: owner_id, limit: limit).call
    end

    def initialize(organization:, user:, owner_id:, limit:)
      @organization = organization
      @user = user
      @owner_id = owner_id.to_s.presence || ENV["WIZWIKI_COMMS_SOURCE_OWNER_ID"].presence || ENV["HUBSPOT_COMMS_OWNER_ID"].presence
      raise ArgumentError, "owner_id or WIZWIKI_COMMS_SOURCE_OWNER_ID is required" if @owner_id.blank?

      @limit = normalize_limit(limit || ENV["WIZWIKI_COMMS_OWNER_QUEUE_REFRESH_LIMIT"])
      @client = Hubspot::Client.new
    end

    def call
      started_at = Time.current
      current_source_uids = Set.new
      source_count = 0
      created = 0
      updated = 0
      skipped = 0
      duplicate_contact = 0
      missing_contact = 0
      errors = 0
      contact_index = Comms::ContactDeduper.key_index(organization: organization)

      source_scope.find_each do |source_record|
        break if limit.present? && source_count >= limit

        source_count += 1
        attrs = attrs_for_source_record(source_record)
        source_uid = wob_source_uid(source_record)
        current_source_uids << source_uid

        if attrs[:phone].blank? && attrs[:email].blank?
          skipped += 1
          missing_contact += 1
          next
        end
        existing_stage = existing_stage_for_source_uid(source_uid)
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

        record = upsert_comms_record!(source_record: source_record, attrs: attrs, source_uid: source_uid)
        stage = upsert_comms_stage!(record: record, source_record: source_record, attrs: attrs, source_uid: source_uid)
        Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
        stage.previously_new_record? ? created += 1 : updated += 1
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError, URI::InvalidURIError => error
        errors += 1
        skipped += 1
        Rails.logger.warn("[Comms::OwnerQueueRefresh] skipped source_record=#{source_record&.id}: #{error.class}: #{error.message}")
      end

      archived = archive_stale_blocks!(current_source_uids)
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

    attr_reader :organization, :user, :owner_id, :limit, :client

    def normalize_limit(value)
      return nil if value.to_s.blank? || value.to_s == "all" || value.to_i <= 0

      value.to_i.clamp(1, 10_000)
    end

    def source_scope
      organization.crm_records
        .where(record_type: "contact")
        .where.not(source: "manual_comms")
        .where.not(status: "archived")
        .where(
          <<~SQL.squish,
            crm_records.properties #>> '{hubspot,properties,hubspot_owner_id}' = :owner_id
            OR crm_records.properties #>> '{hubspot_owner_id}' = :owner_id
            OR crm_records.properties #>> '{contact_owner_id}' = :owner_id
          SQL
          owner_id: owner_id
        )
        .where(facebook_contact_source_sql)
        .order(updated_at: :desc)
    end

    def facebook_contact_source_sql
      <<~SQL.squish
        crm_records.properties #>> '{hubspot,lead_source}' = 'facebook'
        OR (crm_records.properties #> '{hubspot,lead_sources}') @> '["facebook"]'::jsonb
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_click_id}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebookid}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_ad_clicked}', '') = 'true'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_inquiry}', '') = 'true'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_messenger_conversion}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_1}', '') ILIKE '%facebook%'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_2}', '') ILIKE '%facebook%'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_1}', '') ILIKE '%facebook%'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_2}', '') ILIKE '%facebook%'
      SQL
    end

    def attrs_for_source_record(source_record)
      hubspot = hubspot_payload(source_record)
      contact_payload = associated_contact_payload(source_record)
      contact_properties = contact_payload.fetch("properties", {}).to_h
      hubspot_properties = hubspot.fetch("properties", {}).to_h
      contact_name = full_name(contact_properties).presence ||
        contact_properties["email"].presence ||
        source_record.properties.to_h["manual_comms_contact_name"].presence ||
        source_record.name
      company_name = distinct_company_name(
        contact_name,
        contact_properties["company"].presence ||
          hubspot_properties["dealname"].presence ||
          hubspot_properties["hs_lead_name"].presence ||
          source_record.name
      )
      phone = normalize_phone([
        source_record.phone,
        contact_properties["phone"],
        contact_properties["mobilephone"],
        contact_properties["hs_calculated_phone_number"],
        contact_properties["hs_calculated_mobile_number"]
      ].compact_blank.first.to_s)
      email = normalize_email(source_record.email.presence || contact_properties["email"].to_s)

      {
        contact_name: contact_name,
        company_name: company_name,
        phone: phone,
        email: email,
        industry: contact_properties["industry"].presence,
        zip: contact_properties["zip"].presence,
        notes: wob_notes(source_record, contact_properties, hubspot_properties),
        hubspot_source_record_id: source_record.id,
        hubspot_source_record_type: source_record.record_type,
        hubspot_object_id: hubspot_object_id(source_record),
        hubspot_contact_id: contact_payload["id"].presence || contact_properties["hs_object_id"].presence,
        hubspot_owner_id: owner_id,
        hubspot_lead_owner: "Sample Owner",
        hubspot_lead_label: hubspot_properties["hs_lead_label"].presence,
        hubspot_lead_stage: hubspot_properties["hs_pipeline_stage"].presence || source_record.stage,
        hubspot_lead_quality: hubspot_properties["hs_lead_quality"].presence,
        raw_row: {
          "source_record_id" => source_record.id,
          "source_record_type" => source_record.record_type,
          "source_record_name" => source_record.name,
          "source_record_source_uid" => source_record.source_uid,
          "hubspot" => hubspot,
          "contact" => contact_payload
        }.compact_blank
      }.compact_blank
    end

    def upsert_comms_record!(source_record:, attrs:, source_uid:)
      label = attrs[:company_name].presence || attrs[:contact_name].presence || attrs[:email].presence || attrs[:phone].presence || source_record.name
      record = organization.crm_records.find_or_initialize_by(source: "manual_comms", source_uid: source_uid)
      record.assign_attributes(
        owner: record.owner || source_record.owner || user,
        record_type: "contact",
        status: "open",
        name: label,
        phone: attrs[:phone].presence || record.phone,
        email: attrs[:email].presence || record.email,
        stage: "manual_comms",
        properties: record.properties.to_h.merge(
          "manual_comms" => true,
          "manual_comms_source" => SOURCE_NAME,
          "manual_comms_contact_value" => [attrs[:phone], attrs[:email]].compact_blank.join(" / "),
          "manual_comms_contact_keys" => manual_comms_contact_keys(phone: attrs[:phone], email: attrs[:email]),
          "manual_comms_contact_phone_digits" => normalized_phone_digits(attrs[:phone]),
          "manual_comms_contact_email" => normalize_email(attrs[:email]),
          "manual_comms_contact_name" => attrs[:contact_name],
          "manual_comms_company_name" => attrs[:company_name],
          "manual_comms_zip" => attrs[:zip],
          "manual_comms_notes" => attrs[:notes],
          "manual_comms_hubspot_lead" => attrs.slice(:hubspot_source_record_id, :hubspot_source_record_type, :hubspot_object_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
          "hubspot_owner_id" => owner_id,
          "contact_owner_id" => owner_id,
          "hubspot_lead_owner" => attrs[:hubspot_lead_owner],
          "manual_comms_import_id" => refresh_id,
          "manual_comms_raw_row" => attrs[:raw_row],
          "owner_queue_source_uid" => source_uid,
          "owner_queue_refreshed_at" => Time.current.iso8601
        ).compact_blank
      )
      record.save!
      record
    end

    def upsert_comms_stage!(record:, source_record:, attrs:, source_uid:)
      label = attrs[:company_name].presence || attrs[:contact_name].presence || attrs[:email].presence || attrs[:phone].presence || source_record.name
      stage = record.crm_record_artifacts
        .where(organization: organization, artifact_type: "comm_staging")
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
        .order(updated_at: :desc)
        .first
      stage ||= record.crm_record_artifacts.build(
        organization: organization,
        user: user,
        artifact_type: "comm_staging",
        title: "WIZWIKI COMMS: #{label}"
      )
      was_new = stage.new_record?
      metadata = stage.metadata.to_h.merge(stage_metadata(record: record, source_record: source_record, attrs: attrs, source_uid: source_uid, label: label))
      stage.update!(
        status: visible_stage_status(stage),
        user: stage.user || user,
        generated_at: Time.current,
        content_type: "application/json",
        metadata: metadata
      )
      stage.define_singleton_method(:previously_new_record?) { was_new }
      stage
    end

    def existing_stage_for_source_uid(source_uid)
      organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
        .where("metadata ->> 'owner_queue_source_uid' = ?", source_uid)
        .order(updated_at: :desc)
        .first
    end

    def visible_stage_status(stage)
      stage.status.to_s.in?(%w[aircall_ready aircall_sent aircall_failed]) ? stage.status : "staged"
    end

    def stage_metadata(record:, source_record:, attrs:, source_uid:, label:)
      contact_label = attrs[:contact_name].presence || "Contact"
      company_label = attrs[:company_name].presence || (attrs[:contact_name].present? ? nil : label)
      sms_body = opening_sms(attrs[:contact_name])
      phone_option = attrs[:phone].present? ? { "id" => "wob-phone", "name" => contact_label, "value" => attrs[:phone], "reason" => "Owner Queue source table" } : nil
      email_option = attrs[:email].present? ? { "id" => "wob-email", "name" => contact_label, "value" => attrs[:email], "reason" => "Owner Queue source table" } : nil

      {
        "stage_type" => "manual_comms",
        "company_name" => company_label,
        "deal_name" => company_label.presence || contact_label.presence || label,
        "comm_kit_direction" => "wizwiki_out",
        "comm_kit_direction_label" => "WIZWIKI COMMS",
        "contact_options" => [{ "id" => "wob-contact", "name" => contact_label, "company" => company_label, "record_type" => source_record.record_type, "reason" => "Owner Queue source table" }],
        "phone_options" => [phone_option].compact,
        "recipient_email_options" => [email_option].compact,
        "manual_comms_contact_keys" => manual_comms_contact_keys(phone: attrs[:phone], email: attrs[:email]),
        "manual_comms_contact_phone_digits" => normalized_phone_digits(attrs[:phone]),
        "manual_comms_contact_email" => normalize_email(attrs[:email]),
        "selected_contact_id" => "wob-contact",
        "selected_phone_id" => phone_option.to_h["id"],
        "selected_recipient_email_id" => email_option.to_h["id"],
        "recipient_selection_summary" => "Owner Queue local source table refreshed from Sample Owner-owned HubSpot #{source_record.record_type}.",
        "sender_name" => user&.display_name,
        "sender_phone" => user&.display_phone_number,
        "sender_profile" => {
          "name" => user&.display_name,
          "phone" => user&.display_phone_number,
          "email" => user&.email_address,
          "twilio" => user&.twilio_profile
        }.compact_blank,
        "sms_options" => [{ "id" => "wob-opener", "tone" => "Thumper opener", "body" => sms_body }],
        "email_options" => [{ "id" => "wob-email-draft", "subject" => "A practical next step from WIZWIKI", "body" => Thumper::VoiceGuide.starter_email(contact_label, attrs[:company_name]) }],
        "selected_sms_id" => "wob-opener",
        "selected_email_id" => "wob-email-draft",
        "composed_sms_body" => sms_body,
        "composed_email_subject" => "A practical next step from WIZWIKI",
        "composed_email_body" => Thumper::VoiceGuide.starter_email(contact_label, attrs[:company_name]),
        "aircall_status" => "manual_comms",
        "aircall_ready" => false,
        "captured_contact_name" => attrs[:contact_name],
        "captured_company_name" => attrs[:company_name],
        "captured_email" => attrs[:email],
        "csv_call_import" => true,
        "csv_call_import_source" => SOURCE_NAME,
        "csv_call_import_id" => refresh_id,
        "csv_call_notes" => attrs[:notes],
        "hubspot_lead" => attrs.slice(:hubspot_source_record_id, :hubspot_source_record_type, :hubspot_object_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality).compact_blank,
        "hubspot_lead_id" => attrs[:hubspot_object_id],
        "hubspot_contact_id" => attrs[:hubspot_contact_id],
        "hubspot_owner_id" => owner_id,
        "contact_owner_id" => owner_id,
        "contact_owner" => attrs[:hubspot_lead_owner],
        "owner_queue_source_uid" => source_uid,
        "owner_queue_source_record_id" => source_record.id,
        "owner_queue_refreshed_at" => Time.current.iso8601,
        "comms_bot_state" => {
          "contact_name" => attrs[:contact_name],
          "company_name" => attrs[:company_name]
        }.compact_blank,
        "staged_at" => stage_staged_at(record),
        "staged_by_user_id" => user&.id,
        "staged_by" => user&.display_name,
        "sms_sending_disabled" => false
      }.compact_blank
    end

    def archive_stale_blocks!(current_source_uids)
      return 0 if current_source_uids.blank?

      archived = 0
      stale_scope = organization.crm_record_artifacts
        .joins(:crm_record)
        .where(artifact_type: "comm_staging")
        .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
        .where("crm_record_artifacts.metadata ->> 'csv_call_import_source' = ?", SOURCE_NAME)
        .where(
          "crm_record_artifacts.metadata ->> 'owner_queue_source_uid' IS NULL OR crm_record_artifacts.metadata ->> 'owner_queue_source_uid' NOT IN (?)",
          current_source_uids.to_a
        )

      stale_scope.find_each do |stage|
        stage.update!(
          status: "archived",
          metadata: stage.metadata.to_h.merge(
            "owner_queue_archived_at" => Time.current.iso8601,
            "owner_queue_archive_reason" => "not present in current local Owner Queue source table"
          )
        )
        archived += 1
      end
      archived
    end

    def associated_contact_payload(source_record)
      object_id = hubspot_object_id(source_record)
      return {} if object_id.blank?

      return local_contact_payload(source_record, object_id) if source_record.record_type.to_s == "contact"

      contact_id = associated_contact_ids(source_record.record_type, object_id).first
      return {} if contact_id.blank?

      client.get("/crm/v3/objects/contacts/#{contact_id}", properties: CONTACT_PROPERTIES.join(","))
    rescue Hubspot::Error => error
      Rails.logger.warn("[Comms::OwnerQueueRefresh] contact hydration failed source_record=#{source_record.id}: #{error.message}")
      source_record.record_type.to_s == "contact" ? local_contact_payload(source_record, object_id) : {}
    end

    def local_contact_payload(source_record, object_id)
      properties = hubspot_payload(source_record).fetch("properties", {}).to_h
      {
        "id" => object_id,
        "properties" => properties
      }
    end

    def associated_contact_ids(record_type, object_id)
      object_type = hubspot_object_type(record_type)
      response = client.get("/crm/v4/objects/#{object_type}/#{object_id}/associations/contacts")
      Array(response["results"])
        .sort_by { |row| Array(row["associationTypes"]).any? { |type| type.to_h["label"].to_s.casecmp("Primary").zero? } ? 0 : 1 }
        .filter_map { |row| row.to_h["toObjectId"].presence&.to_s }
        .uniq
    rescue Hubspot::Error
      response = client.get("/crm/v3/objects/#{object_type}/#{object_id}/associations/contacts")
      Array(response["results"]).filter_map { |row| row.to_h["id"].presence&.to_s }.uniq
    end

    def hubspot_object_type(record_type)
      case record_type.to_s
      when "deal" then "deals"
      when "ticket" then "tickets"
      when "company" then "companies"
      when "contact" then "contacts"
      when "lead" then "leads"
      else "deals"
      end
    end

    def hubspot_object_id(source_record)
      hubspot_payload(source_record).fetch("properties", {}).to_h["hs_object_id"].presence ||
        source_record.source_uid.presence ||
        source_record.properties.to_h["hs_object_id"].presence
    end

    def hubspot_payload(source_record)
      source_record.properties.to_h.fetch("hubspot", {}).to_h
    end

    def wob_source_uid(source_record)
      object_id = hubspot_object_id(source_record).presence || source_record.id
      "wob-#{source_record.record_type}-#{object_id}"
    end

    def full_name(properties)
      [properties["firstname"], properties["lastname"]].compact_blank.join(" ").presence
    end

    def distinct_company_name(contact_name, company_name)
      company = company_name.to_s.squish.presence
      return if company.blank?

      contact_key = identity_key(contact_name)
      company_key = identity_key(company)
      return if contact_key.present? && company_key.present? && contact_key == company_key

      company
    end

    def identity_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "").presence
    end

    def normalize_phone(value)
      cleaned = value.to_s.gsub(/[^\d+]/, "")
      digits = cleaned.gsub(/\D/, "")
      digits.length >= 7 ? cleaned : nil
    end

    def normalize_email(value)
      value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
    end

    def normalized_phone_digits(value)
      digits = value.to_s.gsub(/\D/, "")
      return if digits.blank?

      digits.length >= 10 ? digits.last(10) : digits
    end

    def manual_comms_contact_keys(phone:, email:)
      [
        (digits = normalized_phone_digits(phone)).present? ? "phone:#{digits}" : nil,
        (address = normalize_email(email)).present? ? "email:#{address}" : nil
      ].compact
    end

    def opening_sms(contact_name)
      first_name = contact_name.to_s.squish.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      Thumper::VoiceGuide.starter_sms(first_name.presence)
    end

    def wob_notes(source_record, contact_properties, hubspot_properties)
      [
        "Owner Queue source row owned by Sample Owner.",
        "HubSpot #{source_record.record_type}: #{source_record.name}.",
        source_record.stage.present? ? "Stage: #{source_record.stage}." : nil,
        hubspot_properties["hs_lead_label"].present? ? "Label: #{hubspot_properties["hs_lead_label"]}." : nil,
        contact_properties["jobtitle"].present? ? "Contact title: #{contact_properties["jobtitle"]}." : nil
      ].compact.join(" ")
    end

    def stage_staged_at(record)
      record.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
        .order(updated_at: :desc)
        .first&.metadata.to_h["staged_at"].presence || Time.current.iso8601
    end

    def refresh_id
      @refresh_id ||= "wall-of-sample_owner-#{owner_id}-#{Time.current.to_i}"
    end

    def clear_lane_caches!
      keys = %w[owner_queue all claimed_by_me]
      keys.each do |key|
        Rails.cache.delete(["deal_queue_lead_source_count", organization.id, key])
        User.pluck(:id).each { |user_id| Rails.cache.delete(["deal_queue_lead_source_count", organization.id, user_id, key]) }
      end
    end
  end
end
