require "json"
require "net/http"
require "uri"
require "cgi"
require "stringio"
require "zip"

module DealReports
  class CommsStager
    DuplicateContactError = Class.new(StandardError)

    READY_REPORT_STATUSES = %w[report_ready canva_kit_ready ready archived].freeze
    SENDER_PLACEHOLDER_PATTERN = /\[(?:your name|sender name|name)\]/i.freeze
    SENDER_PHONE_PLACEHOLDER_PATTERN = /\[(?:your phone|sender phone|phone number|callback number)\]/i.freeze

    def self.stage!(source_report:, user:, force: false)
      new(source_report: source_report, user: user, force: force).stage!
    end

    def self.stage_all!(organization:, user:, owner_id: nil)
      staged = 0
      skipped = 0
      eligible_reports(organization, owner_id: owner_id).find_each do |source_report|
        stage!(source_report: source_report, user: user)
        staged += 1
      rescue StandardError => error
        Rails.logger.warn("COMMS stage skipped report=#{source_report.id}: #{error.class}: #{error.message}")
        skipped += 1
      end
      { staged: staged, skipped: skipped }
    end

    def self.stage_claimed_records!(organization:, user:, owner_id:)
      staged = 0
      skipped = 0
      missing_contact = 0
      duplicate_contact = 0
      return { staged: staged, skipped: skipped, duplicate_contact: duplicate_contact, missing_contact: missing_contact } if owner_id.blank?

      organization.crm_records.where(owner_id: owner_id).where.not(status: "archived").find_each do |record|
        stage_claimed_record!(record: record, user: user)
        staged += 1
      rescue ArgumentError => error
        skipped += 1
        missing_contact += 1 if error.message.include?("phone or email")
      rescue DuplicateContactError
        skipped += 1
        duplicate_contact += 1
      rescue StandardError => error
        Rails.logger.warn("Claimed COMMS stage skipped record=#{record&.id}: #{error.class}: #{error.message}")
        skipped += 1
      end

      { staged: staged, skipped: skipped, duplicate_contact: duplicate_contact, missing_contact: missing_contact }
    end

    def self.stage_claimed_record!(record:, user:)
      properties = record.properties.to_h
      phone = claimed_phone(record, properties)
      email = claimed_email(record, properties)
      raise ArgumentError, "claimed record has no usable phone or email" if phone.blank? && email.blank?

      contact_name = claimed_contact_name(record, properties)
      company_name = distinct_company_name(contact_name, claimed_company_name(record, properties))
      label = company_name.presence || contact_name.presence || record.name.presence || "Claimed lead ##{record.id}"
      stage = record.crm_record_artifacts.where(
        organization: record.organization,
        artifact_type: "comm_staging"
      )
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
        .order(updated_at: :desc)
        .first
      duplicate_stage = Comms::ContactDeduper.duplicate_stage(
        organization: record.organization,
        phone: phone,
        email: email,
        except_stage: stage
      )
      raise DuplicateContactError, "duplicate phone/email already staged in COMMS block ##{duplicate_stage.id}" if duplicate_stage

      metadata = claimed_stage_metadata(
        record: record,
        user: user,
        label: label,
        phone: phone,
        email: email,
        contact_name: contact_name,
        company_name: company_name,
        properties: properties
      )
      stage ||= record.crm_record_artifacts.build(
        organization: record.organization,
        user: user,
        artifact_type: "comm_staging",
        title: "WIZWIKI COMMS: #{label}"
      )

      stage.update!(
        status: stage.status.presence || "staged",
        user: stage.user || user,
        generated_at: Time.current,
        content_type: "application/json",
        metadata: stage.metadata.to_h.merge(metadata)
      )
      stage
    end

    def self.eligible_reports(organization, owner_id: nil)
      scope = organization.crm_record_artifacts
        .where(artifact_type: "market_report", status: READY_REPORT_STATUSES)
        .where("metadata ->> 'report_audience' = ?", "copy_maker")
        .where("metadata ->> 'copy_maker_comm_kit_enabled' = ?", "true")
      scope = scope.joins(:crm_record).where(crm_records: { owner_id: owner_id }) if owner_id.present?
      scope.order(created_at: :desc)
    end

    def self.update_selection!(stage:, sms_id:, email_id:, contact_id: nil, phone_id: nil, recipient_email_id: nil, address_id: nil, sender_name_override: nil, sms_body_override: nil, email_subject_override: nil, email_body_override: nil, user:)
      metadata = stage.metadata.to_h
      sender_name = normalize_sender_name(sender_name_override.presence || metadata.dig("sender_profile", "name").presence || metadata["sender_name"], user)
      sender_phone = normalize_sender_phone(metadata.dig("sender_profile", "phone").presence || metadata["sender_phone"].presence || user&.display_phone_number)
      sms_id = valid_id_or_current(metadata.fetch("sms_options", []), sms_id, metadata["selected_sms_id"])
      email_id = valid_id_or_current(metadata.fetch("email_options", []), email_id, metadata["selected_email_id"])
      contact_id = valid_id_or_current(metadata.fetch("contact_options", []), contact_id, metadata["selected_contact_id"])
      phone_id = valid_id_or_current(metadata.fetch("phone_options", []), phone_id, metadata["selected_phone_id"])
      recipient_email_id = valid_id_or_current(metadata.fetch("recipient_email_options", []), recipient_email_id, metadata["selected_recipient_email_id"])
      address_id = valid_id_or_current(metadata.fetch("address_options", []), address_id, metadata["selected_address_id"])
      sms = option_by_id(metadata.fetch("sms_options", []), sms_id).to_h
      email = option_by_id(metadata.fetch("email_options", []), email_id).to_h
      composed_sms_body = apply_sender_profile(normalize_composed_body(sms_body_override).presence || metadata["composed_sms_body"].presence || sms["body"], sender_name, sender_phone)
      composed_email_subject = apply_sender_profile(normalize_composed_subject(email_subject_override).presence || metadata["composed_email_subject"].presence || email["subject"], sender_name, sender_phone)
      composed_email_body = apply_sender_profile(normalize_composed_body(email_body_override).presence || metadata["composed_email_body"].presence || email["body"], sender_name, sender_phone)
      edited = composed_sms_body.to_s != apply_sender_profile(sms["body"], sender_name, sender_phone).to_s ||
        composed_email_subject.to_s != apply_sender_profile(email["subject"], sender_name, sender_phone).to_s ||
        composed_email_body.to_s != apply_sender_profile(email["body"], sender_name, sender_phone).to_s

      stage.update!(
        metadata: metadata.merge(
          "sender_name" => sender_name,
          "sender_phone" => sender_phone,
          "sender_profile" => {
            "name" => sender_name,
            "phone" => sender_phone,
            "email" => metadata.dig("sender_profile", "email").presence || user&.email_address
          }.compact_blank,
          "selected_sms_id" => sms_id,
          "selected_email_id" => email_id,
          "selected_contact_id" => contact_id,
          "selected_phone_id" => phone_id,
          "selected_recipient_email_id" => recipient_email_id,
          "selected_address_id" => address_id,
          "composed_sms_body" => composed_sms_body,
          "composed_email_subject" => composed_email_subject,
          "composed_email_body" => composed_email_body,
          "composition_edited" => edited,
          "selection_updated_at" => Time.current.iso8601,
          "selection_updated_by_user_id" => user&.id,
          "selection_updated_by" => user&.display_name
        )
      )
      stage
    end

    def self.mark_aircall_ready!(stage:, sms_id:, email_id:, contact_id: nil, phone_id: nil, recipient_email_id: nil, address_id: nil, sender_name_override: nil, sms_body_override: nil, email_subject_override: nil, email_body_override: nil, user:)
      update_selection!(
        stage: stage,
        sms_id: sms_id,
        email_id: email_id,
        contact_id: contact_id,
        phone_id: phone_id,
        recipient_email_id: recipient_email_id,
        address_id: address_id,
        sender_name_override: sender_name_override,
        sms_body_override: sms_body_override,
        email_subject_override: email_subject_override,
        email_body_override: email_body_override,
        user: user
      )
      metadata = stage.reload.metadata.to_h
      aircall_profile = metadata.dig("sender_profile", "aircall").to_h.presence || user&.aircall_profile.to_h
      sms = option_by_id(metadata.fetch("sms_options", []), metadata["selected_sms_id"]).to_h
      email = option_by_id(metadata.fetch("email_options", []), metadata["selected_email_id"]).to_h
      contact = option_by_id(metadata.fetch("contact_options", []), metadata["selected_contact_id"])
      phone = option_by_id(metadata.fetch("phone_options", []), metadata["selected_phone_id"])
      recipient_email = option_by_id(metadata.fetch("recipient_email_options", []), metadata["selected_recipient_email_id"])
      address = option_by_id(metadata.fetch("address_options", []), metadata["selected_address_id"])
      sms = sms.merge(
        "body" => metadata["composed_sms_body"].presence || sms["body"],
        "source_option_id" => metadata["selected_sms_id"],
        "edited" => ActiveModel::Type::Boolean.new.cast(metadata["composition_edited"])
      )
      email = email.merge(
        "subject" => metadata["composed_email_subject"].presence || email["subject"],
        "body" => metadata["composed_email_body"].presence || email["body"],
        "source_option_id" => metadata["selected_email_id"],
        "edited" => ActiveModel::Type::Boolean.new.cast(metadata["composition_edited"])
      )
      stage.update!(
        status: "aircall_ready",
        generated_at: Time.current,
        metadata: metadata.merge(
          "aircall_status" => "ready_for_aircall",
          "aircall_ready" => false,
          "aircall_note" => "Saved work is staged for WIZWIKI COMMS review. No SMS or email has been sent.",
          "aircall_ready_at" => Time.current.iso8601,
          "aircall_requested_by_user_id" => user&.id,
          "aircall_requested_by" => user&.display_name,
          "aircall_sender_name" => metadata["sender_name"],
          "aircall_sender_phone" => metadata["sender_phone"],
          "aircall_sender_profile" => metadata["sender_profile"],
          "aircall_user_id" => aircall_profile["user_id"].presence,
          "aircall_number_id" => aircall_profile["number_id"].presence,
          "aircall_external_key" => aircall_profile["external_key"].presence,
          "aircall_selected_contact" => contact,
          "aircall_selected_phone" => phone,
          "aircall_selected_recipient_email" => recipient_email,
          "aircall_selected_address" => address,
          "aircall_selected_sms" => sms,
          "aircall_selected_email" => email,
          "aircall_composed_sms_body" => sms["body"],
          "aircall_composed_email_subject" => email["subject"],
          "aircall_composed_email_body" => email["body"]
        )
      )
      stage
    end

    def self.valid_id_or_current(options, requested_id, current_id)
      requested = requested_id.to_s.presence
      return requested if option_by_id(options, requested)

      current = current_id.to_s.presence
      return current if option_by_id(options, current)

      option_by_id(options, nil)&.fetch("id", nil)
    end

    def self.option_by_id(options, id)
      normalized = id.to_s
      Array(options).find { |option| option.to_h["id"].to_s == normalized } || Array(options).first
    end

    def self.normalize_composed_subject(value)
      value.to_s.squish.first(160)
    end

    def self.normalize_composed_body(value)
      value.to_s.gsub(/\r\n?/, "\n").strip.gsub(/[ \t]+$/, "").first(3_000)
    end

    def self.normalize_sender_name(value, user = nil)
      (value.to_s.squish.presence || user&.display_name.to_s.squish.presence || "WIZWIKI Marketing").first(80)
    end

    def self.normalize_sender_phone(value)
      value.to_s.squish.gsub(/[^\d+().\-\sx]/i, "").presence&.first(32)
    end

    def self.apply_sender_name(value, sender_name)
      value.to_s.gsub(SENDER_PLACEHOLDER_PATTERN, normalize_sender_name(sender_name))
    end

    def self.apply_sender_profile(value, sender_name, sender_phone)
      apply_sender_name(value, sender_name)
        .gsub(SENDER_PHONE_PLACEHOLDER_PATTERN, normalize_sender_phone(sender_phone).presence || "reply here")
    end

    def self.claimed_stage_metadata(record:, user:, label:, phone:, email:, contact_name:, company_name:, properties:)
      contact_label = contact_name.presence || "Contact"
      company_label = company_name.presence || (contact_name.present? ? nil : label)
      display_label = company_label.presence || contact_label.presence || label
      phone_option = phone.present? ? { "id" => "claimed-phone", "name" => contact_label, "value" => phone, "reason" => "Claimed CRM card" } : nil
      email_option = email.present? ? { "id" => "claimed-email", "name" => contact_label, "value" => email, "reason" => "Claimed CRM card" } : nil
      sms_body = claimed_opening_sms(contact_name)
      sender_name = normalize_sender_name(user&.display_name, user)
      sender_phone = normalize_sender_phone(user&.display_phone_number)

      {
        "stage_type" => "manual_comms",
        "claimed_call_source" => true,
        "claimed_by_user_id" => record.owner_id,
        "claimed_loaded_at" => Time.current.iso8601,
        "company_name" => company_label,
        "deal_name" => display_label,
        "comm_kit_direction" => "wizwiki_out",
        "comm_kit_direction_label" => "WIZWIKI COMMS",
        "contact_options" => [{ "id" => "claimed-contact", "name" => contact_label, "company" => company_label, "record_type" => record.record_type, "reason" => "Claimed CRM card" }],
        "phone_options" => [phone_option].compact,
        "recipient_email_options" => [email_option].compact,
        "manual_comms_contact_keys" => Comms::ContactDeduper.keys(phone: phone, email: email),
        "manual_comms_contact_phone_digits" => Comms::ContactDeduper.phone_digits(phone),
        "manual_comms_contact_email" => Comms::ContactDeduper.email_address(email),
        "selected_contact_id" => "claimed-contact",
        "selected_phone_id" => phone_option.to_h["id"],
        "selected_recipient_email_id" => email_option.to_h["id"],
        "recipient_selection_summary" => "Claimed CRM card staged by #{sender_name}.",
        "sender_name" => sender_name,
        "sender_phone" => sender_phone,
        "sender_profile" => {
          "name" => sender_name,
          "phone" => sender_phone,
          "email" => user&.email_address,
          "twilio" => user&.twilio_profile
        }.compact_blank,
        "sms_options" => [{ "id" => "claimed-opener", "tone" => "Thumper opener", "body" => sms_body }],
        "email_options" => [{ "id" => "claimed-email-draft", "subject" => "A practical next step from WIZWIKI", "body" => Thumper::VoiceGuide.starter_email(contact_label, company_name) }],
        "selected_sms_id" => "claimed-opener",
        "selected_email_id" => "claimed-email-draft",
        "composed_sms_body" => sms_body,
        "composed_email_subject" => "A practical next step from WIZWIKI",
        "composed_email_body" => Thumper::VoiceGuide.starter_email(contact_label, company_name),
        "aircall_status" => "manual_comms",
        "aircall_ready" => false,
        "captured_contact_name" => contact_name,
        "captured_company_name" => company_name,
        "captured_email" => email,
        "claimed_crm_record_id" => record.id,
        "claimed_crm_source" => record.source,
        "claimed_crm_source_uid" => record.source_uid,
        "hubspot_lead" => hubspot_claimed_payload(properties),
        "hubspot_lead_id" => hubspot_property(properties, "hs_object_id"),
        "hubspot_contact_id" => hubspot_property(properties, "associated_contact_id"),
        "hubspot_owner_id" => hubspot_property(properties, "hubspot_owner_id"),
        "contact_owner_id" => hubspot_property(properties, "hubspot_owner_id"),
        "contact_owner" => hubspot_property(properties, "hubspot_lead_owner").presence || hubspot_property(properties, "contact_owner"),
        "comms_bot_state" => {
          "contact_name" => contact_name,
          "company_name" => company_name
        }.compact_blank,
        "staged_at" => Time.current.iso8601,
        "staged_by_user_id" => user&.id,
        "staged_by" => sender_name,
        "sms_sending_disabled" => false
      }.compact_blank
    end

    def self.claimed_opening_sms(contact_name)
      first_name = contact_name.to_s.squish.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      Thumper::VoiceGuide.starter_sms(first_name.presence)
    end

    def self.claimed_phone(record, properties)
      normalize_phone_value(
        record.phone.presence ||
          hubspot_property(properties, "phone").presence ||
          hubspot_property(properties, "mobilephone").presence ||
          hubspot_property(properties, "hs_calculated_phone_number").presence ||
          labeled_property(properties, "Phone").presence ||
          labeled_property(properties, "Mobile Phone Number")
      )
    end

    def self.claimed_email(record, properties)
      normalize_email_value(
        record.email.presence ||
          hubspot_property(properties, "email").presence ||
          labeled_property(properties, "Email")
      )
    end

    def self.claimed_contact_name(record, properties)
      [
        hubspot_property(properties, "firstname").presence && hubspot_property(properties, "lastname").presence ? "#{hubspot_property(properties, "firstname")} #{hubspot_property(properties, "lastname")}" : nil,
        hubspot_property(properties, "name"),
        labeled_property(properties, "Contact"),
        properties["manual_comms_contact_name"],
        record.record_type.to_s == "contact" ? record.name : nil
      ].compact_blank.first.to_s.squish.presence
    end

    def self.claimed_company_name(record, properties)
      [
        hubspot_property(properties, "company").presence,
        hubspot_property(properties, "company_name").presence,
        hubspot_property(properties, "hs_lead_name").presence,
        labeled_property(properties, "Company").presence,
        properties["manual_comms_company_name"].presence,
        record.record_type.to_s == "company" ? record.name : nil,
        record.name
      ].compact_blank.first.to_s.squish.presence
    end

    def self.distinct_company_name(contact_name, company_name)
      company = company_name.to_s.squish.presence
      return if company.blank?

      contact_key = identity_key(contact_name)
      company_key = identity_key(company)
      return if contact_key.present? && company_key.present? && contact_key == company_key

      company
    end

    def self.identity_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "").presence
    end

    def self.hubspot_claimed_payload(properties)
      {
        "id" => hubspot_property(properties, "hs_object_id"),
        "name" => hubspot_property(properties, "hs_lead_name").presence || hubspot_property(properties, "name"),
        "owner_id" => hubspot_property(properties, "hubspot_owner_id"),
        "source" => hubspot_property(properties, "hs_analytics_source").presence || properties["manual_comms_source"]
      }.compact_blank
    end

    def self.hubspot_property(properties, key)
      properties.to_h[key].presence ||
        properties.to_h.fetch("hubspot", {}).to_h.fetch("properties", {}).to_h[key].presence ||
        properties.to_h.fetch("hubspot", {}).to_h.fetch("labeled_properties", {}).to_h[key].presence
    end

    def self.labeled_property(properties, label)
      properties.to_h.fetch("hubspot", {}).to_h.fetch("labeled_properties", {}).to_h[label].presence
    end

    def self.normalize_phone_value(value)
      cleaned = value.to_s.gsub(/[^\d+]/, "")
      digits = cleaned.gsub(/\D/, "")
      digits.length >= 7 ? cleaned : nil
    end

    def self.normalize_email_value(value)
      value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
    end

    def initialize(source_report:, user:, force: false)
      @source_report = source_report
      @user = user
      @force = force
    end

    def stage!
      raise ArgumentError, "source report is not a COMM KIT Copy Maker artifact" unless comm_kit_report?

      existing = existing_stage
      return existing if existing.present? && !@force && existing.status.in?(%w[aircall_ready aircall_sent])

      options = extract_options
      selected = select_favorites(options)
      selected_sms = selected_option(options.fetch(:sms), selected.fetch(:sms_id))
      selected_email = selected_option(options.fetch(:emails), selected.fetch(:email_id))
      contacts = contact_intelligence
      sender_profile = source_sender_profile
      sender_name = self.class.normalize_sender_name(sender_profile["name"], @user)
      sender_phone = self.class.normalize_sender_phone(sender_profile["phone"].presence || @user&.display_phone_number)
      aircall_profile = sender_profile["aircall"].to_h.presence || @user&.aircall_profile.to_h
      stage = existing || @source_report.crm_record.crm_record_artifacts.build(
        organization: @source_report.organization,
        user: @user,
        artifact_type: "comm_staging",
        title: "COMMS staging: #{deal_name}"
      )

      metadata = stage.metadata.to_h.merge(
        "stage_type" => "aircall_comms",
        "source_report_id" => @source_report.id,
        "source_report_title" => @source_report.title,
        "source_report_status" => @source_report.status,
        "source_report_storage_key" => @source_report.storage_key,
        "source_report_url" => @source_report.file_url,
        "source_report_generated_at" => @source_report.generated_at&.iso8601,
        "deal_id" => @source_report.crm_record_id,
        "deal_name" => deal_name,
        "company_name" => company_name,
        "comm_kit_direction" => comm_kit_direction,
        "comm_kit_direction_label" => comm_kit_direction_label,
        "comm_kit_structured" => @structured_comm_kit.present?,
        "comm_kit_source" => @structured_comm_kit.to_h["source"].presence || (@structured_comm_kit.present? ? "manifest_comm_kit" : "docx_text_fallback"),
        "comm_kit_source_model" => @structured_comm_kit.to_h["source_model"],
        "contact_intelligence" => contacts,
        "contact_context" => contact_context,
        "contact_options" => contacts.fetch("ranked_contacts", []),
        "phone_options" => contacts.fetch("phone_options", []),
        "recipient_email_options" => contacts.fetch("email_options", []),
        "address_options" => contacts.fetch("address_options", []),
        "selected_contact_id" => contacts["selected_contact_id"],
        "selected_phone_id" => contacts["selected_phone_id"],
        "selected_recipient_email_id" => contacts["selected_email_id"],
        "selected_address_id" => contacts["selected_address_id"],
        "recipient_selection_summary" => contacts["selected_summary"],
        "sender_name" => sender_name,
        "sender_phone" => sender_phone,
        "sender_profile" => sender_profile.merge(
          "name" => sender_name,
          "phone" => sender_phone,
          "email" => sender_profile["email"].presence || @user&.email_address,
          "aircall" => aircall_profile.presence
        ).compact_blank,
        "sms_options" => options.fetch(:sms),
        "email_options" => options.fetch(:emails),
        "selected_sms_id" => selected.fetch(:sms_id),
        "selected_email_id" => selected.fetch(:email_id),
        "composed_sms_body" => self.class.apply_sender_profile(selected_sms["body"], sender_name, sender_phone),
        "composed_email_subject" => self.class.apply_sender_profile(selected_email["subject"], sender_name, sender_phone),
        "composed_email_body" => self.class.apply_sender_profile(selected_email["body"], sender_name, sender_phone),
        "composition_edited" => false,
        "selection_reason" => selected.fetch(:reason),
        "selector_provider" => selected.fetch(:provider),
        "selector_model" => selected.fetch(:model),
        "selector_error" => selected[:error],
        "aircall_status" => "staged",
        "aircall_ready" => false,
        "aircall_user_id" => aircall_profile["user_id"].presence,
        "aircall_number_id" => aircall_profile["number_id"].presence,
        "aircall_external_key" => aircall_profile["external_key"].presence,
        "aircall_note" => "Review selections, then SAVE WORK to stage this call for WIZWIKI COMMS.",
        "staged_at" => Time.current.iso8601,
        "staged_by_user_id" => @user&.id,
        "staged_by" => @user&.display_name
      )

      stage.assign_attributes(
        status: "staged",
        content_type: "application/json",
        metadata: metadata
      )
      stage.save!
      stage
    end

    private

    def comm_kit_report?
      metadata = @source_report.metadata.to_h
      @source_report.artifact_type == "market_report" &&
        metadata["report_audience"].to_s == "copy_maker" &&
        ActiveModel::Type::Boolean.new.cast(metadata["copy_maker_comm_kit_enabled"])
    end

    def existing_stage
      @source_report.organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where("metadata ->> 'source_report_id' = ?", @source_report.id.to_s)
        .order(created_at: :desc)
        .first
    end

    def deal_name
      @source_report.crm_record&.name.to_s.presence || @source_report.title
    end

    def company_name
      metadata = @source_report.metadata.to_h
      metadata["company_name"].presence || deal_name.to_s.sub(/\ANew Signup\s*-\s*/i, "").presence || deal_name
    end

    def source_sender_profile
      metadata = @source_report.metadata.to_h
      metadata["copy_maker_sender_profile"].to_h.presence || {
        "name" => metadata["queued_by"].presence || @user&.display_name,
        "phone" => metadata["queued_by_phone"].presence || @user&.display_phone_number,
        "email" => @user&.email_address,
        "aircall" => @user&.aircall_profile
      }.compact_blank
    end

    def comm_kit_direction
      value = @source_report.metadata.to_h["copy_maker_comm_kit_direction"].presence || manifest_comm_kit["direction"]
      value = value.to_s
      value == "client_out" ? "client_out" : "wizwiki_out"
    end

    def comm_kit_direction_label
      @source_report.metadata.to_h["copy_maker_comm_kit_direction_label"].presence ||
        manifest_comm_kit["direction_label"].presence ||
        (comm_kit_direction == "client_out" ? "CLIENT OUT" : "WIZWIKI OUT")
    end

    def contact_context
      hubspot = @source_report.crm_record&.properties.to_h.fetch("hubspot", {}).to_h
      labeled = hubspot.fetch("labeled_properties", {}).to_h
      {
        "email" => @source_report.crm_record&.email.presence || labeled["Email"].presence,
        "phone" => @source_report.crm_record&.phone.presence || labeled["Phone"].presence || labeled["Mobile Phone Number"].presence,
        "contact" => labeled["Contact"].presence || labeled["Associated Contact"].presence
      }.compact
    end

    def contact_intelligence
      kit = manifest_comm_kit
      manifest_contacts = kit.fetch("contact_intelligence", {}).to_h
      return normalized_contact_intelligence(manifest_contacts) if manifest_contacts.present?

      DealReports::ContactIntelligence.for_record(@source_report.crm_record, direction: comm_kit_direction)
    end

    def normalized_contact_intelligence(payload)
      payload.merge(
        "ranked_contacts" => Array(payload["ranked_contacts"]),
        "phone_options" => Array(payload["phone_options"]),
        "email_options" => Array(payload["email_options"]),
        "address_options" => Array(payload["address_options"])
      )
    end

    def extract_options
      if (structured = structured_comm_kit_options)
        return structured
      end

      text = source_text
      sms_section = extract_section(text, /COMM\s+KIT\s*\/\/\s*Text Messages|Text Messages|SMS/i, /COMM\s+KIT\s*\/\/\s*Sales Emails|Sales Emails|Usage Notes/i)
      email_section = extract_section(text, /COMM\s+KIT\s*\/\/\s*Sales Emails|Sales Emails|Email Templates/i, /Usage Notes|Source-Aware Copy Direction/i)

      {
        sms: extract_sms_options(sms_section.presence || text),
        emails: extract_email_options(email_section.presence || text)
      }
    end

    def structured_comm_kit_options
      kit = manifest_comm_kit
      return nil unless ActiveModel::Type::Boolean.new.cast(kit["enabled"])

      sms = Array(kit["sms_options"]).map(&:to_h).select { |option| option["id"].present? && option["body"].present? }
      emails = Array(kit["email_options"]).map(&:to_h).select { |option| option["id"].present? && option["subject"].present? && option["body"].present? }
      return nil if sms.size < 3 || emails.size < 2

      @structured_comm_kit = kit
      { sms: sms, emails: emails }
    end

    def manifest_comm_kit
      metadata = @source_report.metadata.to_h
      metadata.fetch("manifest", {}).to_h.fetch("comm_kit", {}).to_h.presence ||
        metadata.fetch("worker_payload", {}).to_h.fetch("manifest", {}).to_h.fetch("comm_kit", {}).to_h.presence ||
        metadata.fetch("comm_kit", {}).to_h
    end

    def source_text
      metadata = @source_report.metadata.to_h
      manifest = metadata.fetch("manifest", {}).to_h
      worker_payload = metadata.fetch("worker_payload", {}).to_h
      [
        manifest["visible_markdown"],
        manifest["report_text"],
        manifest["summary"],
        worker_payload.fetch("manifest", {}).to_h["visible_markdown"],
        worker_payload.fetch("manifest", {}).to_h["report_text"],
        worker_payload["summary"],
        worker_payload["report_text"],
        docx_text,
        metadata["copy_maker_prompt"]
      ].compact.map(&:to_s).find(&:present?) || ""
    end

    def selected_option(options, id)
      self.class.option_by_id(options, id).to_h
    end

    def docx_text
      @docx_text ||= begin
        return "" if @source_report.storage_key.blank?

        bytes = DealReports::Publisher.download_bytes!(@source_report).to_s.b
        return "" if bytes.blank?

        parts = []
        Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
          %w[word/document.xml word/header1.xml word/footer1.xml].each do |entry_name|
            entry = zip.find_entry(entry_name)
            parts << open_xml_text(entry.get_input_stream.read.to_s.b) if entry
          end
        end
        parts.reject(&:blank?).join("\n\n")
      rescue StandardError => error
        Rails.logger.info("COMMS DOCX text fallback unavailable report=#{@source_report.id}: #{error.class}: #{error.message}")
        ""
      end
    end

    def open_xml_text(xml)
      clean_xml = xml.to_s.b.dup
        .force_encoding("UTF-8")
        .encode("UTF-8", invalid: :replace, undef: :replace, replace: " ")

      extracted = CGI.unescapeHTML(
        clean_xml
          .gsub(%r{</w:p>}, "\n")
          .gsub(%r{</w:tr>}, "\n")
          .gsub(%r{</w:tc>}, " | ")
          .gsub(/<[^>]+>/, " ")
      ).encode("UTF-8", invalid: :replace, undef: :replace, replace: " ")

      extracted.lines.map(&:squish).reject(&:blank?).join("\n")
    end

    def extract_section(text, start_pattern, end_pattern)
      match = text.match(start_pattern)
      return "" unless match

      rest = text[match.begin(0)..]
      ending = rest[match[0].length..].to_s.match(end_pattern)
      ending ? rest[0...(match[0].length + ending.begin(0))] : rest
    end

    def extract_sms_options(text)
      lines = cleaned_lines(text)
      candidates = []
      lines.each do |line|
        if (match = line.match(/\A(?:sms|text)(?:\s*(\d+|warm|helpful|urgent|low|medium|high))?\s*[:\-–]\s*(.+)\z/i))
          candidates << build_sms_option(match[1], match[2])
        elsif line.match?(/\A\d+\.\s+/) && !line.match?(/\Asubject\b/i)
          candidates << build_sms_option(nil, line.sub(/\A\d+\.\s+/, ""))
        end
      end

      if candidates.blank?
        split_paragraphs(text).first(3).each { |paragraph| candidates << build_sms_option(nil, paragraph) }
      end

      normalize_sms_options(candidates)
    end

    def extract_email_options(text)
      chunks = text.split(/(?=Subject\s*:)/i).select { |chunk| chunk.match?(/Subject\s*:/i) }
      emails = chunks.map.with_index(1) do |chunk, index|
        subject = chunk[/Subject\s*:\s*(.+)/i, 1].to_s.strip
        body = chunk.sub(/.*?Subject\s*:\s*.+?\n/im, "").sub(/\ABody\s*:\s*/i, "").strip
        build_email_option(index, subject, body)
      end

      if emails.blank?
        email_chunks = text.split(/(?=\bEmail\s*(?:\d+|one|two|intro|follow[- ]?up)?\s*[:\-–])/i).select { |chunk| chunk.match?(/\bEmail\b/i) }
        emails = email_chunks.map.with_index(1) do |chunk, index|
          cleaned = clean_copy_line(chunk)
          subject = cleaned[/Subject\s*:\s*(.+?)(?:\s+Body\s*:|\z)/i, 1].to_s.strip
          body = cleaned.sub(/\AEmail\s*[^:]*[:\-–]\s*/i, "").sub(/Subject\s*:\s*.+?(Body\s*:)?/i, "").strip
          build_email_option(index, subject, body)
        end
      end

      normalize_email_options(emails)
    end

    def cleaned_lines(text)
      text.to_s.lines.map { |line| clean_copy_line(line) }.select(&:present?)
    end

    def split_paragraphs(text)
      text.to_s.split(/\n{2,}/).map { |paragraph| clean_copy_line(paragraph) }.select { |paragraph| paragraph.length.between?(20, 360) }
    end

    def clean_copy_line(line)
      line.to_s.gsub(/\r/, "\n")
        .gsub(/\A[#>*\-\s]+/, "")
        .gsub(/\*\*/, "")
        .squish
    end

    def build_sms_option(label, body)
      body = clean_copy_line(body)
      tone = case "#{label} #{body}".downcase
      when /warm|friendly|check/ then "warm check-in"
      when /urgent|soon|today|limited|before/ then "clear next-step prompt"
      else "helpful reminder"
      end
      {
        "id" => "",
        "label" => label.to_s.presence,
        "tone" => tone,
        "urgency" => tone.include?("urgent") || tone.include?("next-step") ? "high without pressure" : (tone.include?("warm") ? "low" : "medium"),
        "body" => body.first(480)
      }
    end

    def build_email_option(index, subject, body)
      body = clean_copy_line(body)
      {
        "id" => index == 1 ? "email_intro" : "email_follow_up",
        "label" => index == 1 ? "Friendly intro" : "Friendly follow-up",
        "subject" => subject.presence || (index == 1 ? "A practical next step for #{company_name}" : "Following up on your campaign plan"),
        "body" => body.presence || "Hi, I wanted to follow up with a practical next step for your campaign. If this still feels useful, we can review the best audience, offer, and timing together."
      }
    end

    def normalize_sms_options(candidates)
      base = candidates.reject { |candidate| candidate["body"].blank? }.first(3)
      labels = [
        ["sms_warm", "Warm check-in", "warm check-in", "low"],
        ["sms_helpful", "Helpful reminder", "helpful reminder", "medium"],
        ["sms_urgent", "Clear next-step", "clear next-step prompt", "high without pressure"]
      ]
      labels.map.with_index do |(id, label, tone, urgency), index|
        candidate = base[index] || fallback_sms_option(id)
        candidate.merge(
          "id" => id,
          "label" => label,
          "tone" => candidate["tone"].presence || tone,
          "urgency" => candidate["urgency"].presence || urgency
        )
      end
    end

    def fallback_sms_option(id)
      body = if comm_kit_direction == "client_out"
        case id
        when "sms_warm"
          "Hi, this is #{company_name}. We are checking in with neighbors who may need help soon. Reply here and we can point you to the best next step."
        when "sms_urgent"
          "Hi, this is #{company_name}. If this project is still on your list, now is a good time to schedule before the next busy window. Want us to send options?"
        else
          "Hi, this is #{company_name}. We put together a simple next step for local customers and wanted to make it easy to respond. Would a quick follow-up help?"
        end
      else
        action_step = wizwiki_sender_action_step
        case id
        when "sms_warm"
          "Hi, this is WIZWIKI Marketing. We put together a local direct-mail idea for #{company_name} and wanted to see if you are open to reviewing it this week. #{action_step}"
        when "sms_urgent"
          "Hi, this is WIZWIKI. If #{company_name} is still evaluating the next step, we can help review the options. #{action_step}"
        else
          "Hi, this is WIZWIKI Marketing. We can help #{company_name} turn local visibility into a simple postcard campaign. #{action_step}"
        end
      end

      build_sms_option(id, body)
    end

    def wizwiki_sender_action_step
      phone = self.class.normalize_sender_phone(source_sender_profile["phone"])
      phone.present? ? "Text #{phone} and we can send the short plan." : "Reply here and we can send the short plan."
    end

    def normalize_email_options(candidates)
      base = candidates.reject { |candidate| candidate["body"].blank? }.first(2)
      [0, 1].map do |index|
        base[index] || build_email_option(index + 1, nil, nil)
      end
    end

    def select_favorites(options)
      structured = select_from_structured_manifest(options)
      return structured if structured

      selector = select_with_ollama(options)
      return selector if selector

      {
        provider: "ruby/fallback",
        model: "heuristic",
        sms_id: best_sms_option(options.fetch(:sms))&.fetch("id", nil),
        email_id: best_email_option(options.fetch(:emails))&.fetch("id", nil),
        reason: fallback_selection_reason
      }
    end

    def select_from_structured_manifest(options)
      kit = @structured_comm_kit.to_h
      return nil if kit.blank?

      sms_id = kit["selected_sms_id"].to_s
      email_id = kit["selected_email_id"].to_s
      return nil unless self.class.option_by_id(options.fetch(:sms), sms_id) && self.class.option_by_id(options.fetch(:emails), email_id)

      selector = kit.fetch("selector", {}).to_h
      {
        provider: selector["provider"].presence || "alice/manifest",
        model: selector["model"].presence || @source_report.metadata.to_h.dig("manifest", "model").presence || "local",
        sms_id: sms_id,
        email_id: email_id,
        reason: selector["reason"].presence || "Alice selected this COMM KIT pair during local generation.",
        error: selector["error"].presence
      }
    end

    def select_with_ollama(options)
      return nil unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_SELECTOR_LLM_ENABLED", "1"))

      base = URI.parse(ENV["WIZWIKI_COMMS_SELECTOR_URL"].presence || ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434")
      uri = URI.join(base.to_s.chomp("/") + "/", "api/generate")
      model = ENV["WIZWIKI_COMMS_SELECTOR_MODEL"].presence || @source_report.metadata.to_h["report_local_model"].presence || "qwen3:8b"
      payload = {
        model: model,
        stream: false,
        format: "json",
        options: { temperature: 0.1 },
        prompt: selector_prompt(options)
      }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 12) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        http.request(request)
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      parsed = JSON.parse(body["response"].to_s)
      sms_id = parsed["sms_id"].to_s
      email_id = parsed["email_id"].to_s
      return nil unless self.class.option_by_id(options.fetch(:sms), sms_id) && self.class.option_by_id(options.fetch(:emails), email_id)

      {
        provider: "ollama/local",
        model: body["model"].presence || model,
        sms_id: sms_id,
        email_id: email_id,
        reason: parsed["reason"].to_s.squish.presence || "Local model selected the most balanced COMM KIT pair."
      }
    rescue StandardError => error
      Rails.logger.info("COMMS selector fallback report=#{@source_report.id}: #{error.class}: #{error.message}")
      nil
    end

    def selector_prompt(options)
      <<~PROMPT
        Pick the best SMS and email for a WIZWIKI Marketing WIZWIKI COMMS sales follow-up.
        Choose one sms_id and one email_id from the JSON options.
        Favor useful, friendly, specific, low-risk copy. Avoid fake urgency, unsupported claims, or anything that feels spammy.
        Return JSON only with keys: sms_id, email_id, reason.

        Company: #{company_name}
        Contact context: #{JSON.generate(contact_context)}
        Recipient intelligence: #{JSON.generate(contact_intelligence.slice("selected_summary", "ranked_contacts", "phone_options", "email_options", "address_options"))}
        SMS options: #{JSON.generate(options.fetch(:sms))}
        Email options: #{JSON.generate(options.fetch(:emails))}
      PROMPT
    end

    def best_sms_option(options)
      Array(options).max_by { |option| copy_score(option.to_h["body"].to_s, sms: true) } || Array(options).first
    end

    def best_email_option(options)
      Array(options).max_by do |option|
        option = option.to_h
        copy_score([option["subject"], option["body"]].compact.join(" "), sms: false)
      end || Array(options).first
    end

    def copy_score(text, sms:)
      normalized = text.to_s.downcase
      score = 0
      score += 12 if normalized.include?(company_name.to_s.downcase)
      score += 10 if normalized.match?(/direct mail|postcard|mail|neighborhood|campaign/)
      score += 8 if normalized.match?(/july|250th|america|summer|season/)
      score += 7 if normalized.match?(/next step|review|quick|call|plan|setup/)
      score += 6 if normalized.match?(/previous|recent|again|follow up|following up|last/)
      score += 4 if normalized.match?(/owner|business|team/)
      score -= 18 if normalized.match?(/guarantee|limited time only|act now|discount|percent|%/)
      score -= 12 if normalized.match?(/hubspot|ticket|artifact|payload|ai|model/)
      score -= 8 if normalized.length < (sms ? 60 : 160)
      score -= 5 if normalized.length > (sms ? 360 : 1_800)
      score
    end

    def fallback_selection_reason
      summary = contact_intelligence["selected_summary"].presence || "ranked CRM association data"
      "Heuristic selected the most specific, low-risk copy and the top CRM-ranked recipient. #{summary}"
    end
  end
end
