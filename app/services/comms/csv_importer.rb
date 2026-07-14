# frozen_string_literal: true

require "csv"
require "digest"
require "ostruct"

module Comms
  class CsvImporter
    PROGRESS_EVERY_ROWS = 10

    class << self
      def call(organization:, user:, path:, job_id:, import_id:, title: nil, status_key: nil, claim_by_current_user: false)
        new(
          organization: organization,
          user: user,
          path: path,
          job_id: job_id,
          import_id: import_id,
          title: title,
          status_key: status_key,
          claim_by_current_user: claim_by_current_user
        ).call
      end
    end

    def initialize(organization:, user:, path:, job_id:, import_id:, title: nil, status_key: nil, claim_by_current_user: false)
      @organization = organization
      @user = user
      @path = path
      @job_id = job_id
      @import_id = import_id
      @import_title = normalize_csv_import_title(title)
      @import_status_key = status_key.presence
      @claim_by_current_user = ActiveModel::Type::Boolean.new.cast(claim_by_current_user)
      @result = base_result
    end

    def call
      rows = parsed_rows
      result[:rows] = rows.length
      write_status!("running", processed: 0)

      contact_index = Comms::ContactDeduper.key_index(organization: organization)
      rows.each_with_index do |row, index|
        break if canceled_by_purge?

        import_row!(row, index, contact_index)
        write_progress!(index + 1) if ((index + 1) % PROGRESS_EVERY_ROWS).zero?
      end

      final_state = canceled_by_purge? ? "canceled" : "success"
      write_status!(final_state, processed: result[:processed], finished_at: Time.current.iso8601, cancel_reason: final_state == "canceled" ? "purged" : nil)
      result.merge(state: final_state)
    rescue StandardError => error
      write_status!("failed", error: "#{error.class}: #{error.message}", finished_at: Time.current.iso8601)
      raise
    ensure
      File.delete(path) if path.present? && File.exist?(path)
    end

    private

    attr_reader :organization, :user, :path, :job_id, :import_id, :import_title, :import_status_key, :claim_by_current_user, :result

    def base_result
      {
        rows: 0,
        processed: 0,
        created: 0,
        updated: 0,
        skipped: 0,
        duplicate_contact: 0,
        missing_contact: 0,
        errors: 0,
        import_id: import_id,
        title: import_title,
        status_key: import_status_key,
        claim_by_current_user: claim_by_current_user
      }
    end

    def parsed_rows
      content = File.binread(path).to_s
      content = content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      rows = CSV.parse(content, headers: true, skip_blanks: true)
      raise ArgumentError, "CSV must include a header row." if rows.headers.blank?

      rows
    end

    def import_row!(row, index, contact_index)
      attrs = csv_call_attrs(row)
      if attrs[:phone].blank? && attrs[:email].blank?
        result[:skipped] += 1
        result[:missing_contact] += 1
        result[:processed] += 1
        return
      end
      if Comms::ContactDeduper.duplicate_in_index?(contact_index, phone: attrs[:phone], email: attrs[:email])
        result[:skipped] += 1
        result[:duplicate_contact] += 1
        result[:processed] += 1
        return
      end

      label = attrs[:company_name].presence || attrs[:contact_name].presence || attrs[:email].presence || attrs[:phone].presence || "WIZWIKI COMMS"
      record = manual_crm_record!(
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        import_title: import_title,
        import_status_key: import_status_key,
        claim_by_current_user: claim_by_current_user,
        row_number: index + 2,
        raw_row: row.to_h
      )
      stage = manual_stage!(
        record: record,
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        import_title: import_title,
        import_status_key: import_status_key,
        claim_by_current_user: claim_by_current_user,
        row_number: index + 2,
        raw_row: row.to_h
      )
      Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
      stage.respond_to?(:csv_import_created?) && stage.csv_import_created? ? result[:created] += 1 : result[:updated] += 1
      result[:processed] += 1
    rescue StandardError => error
      result[:skipped] += 1
      result[:errors] += 1
      result[:processed] += 1
      Rails.logger.warn("[Comms::CsvImporter] CSV row skipped organization=#{organization.id} row=#{index + 2}: #{error.class}: #{error.message}")
    end

    def write_progress!(processed)
      write_status!("running", processed: processed)
    end

    def write_status!(state, attrs = {})
      Comms::CsvImportStatus.update!(
        organization,
        job_id,
        {
          state: state,
          rows: result[:rows],
          processed: result[:processed],
          created: result[:created],
          updated: result[:updated],
          skipped: result[:skipped],
          duplicate_contact: result[:duplicate_contact],
          missing_contact: result[:missing_contact],
          errors: result[:errors],
          import_id: import_id,
          title: import_title,
          status_key: import_status_key,
          claim_by_current_user: claim_by_current_user,
          claimed_by_user_id: claim_by_current_user ? user.id : nil,
          claimed_by: claim_by_current_user ? user.display_name : nil
        }.merge(attrs).compact_blank
      )
    end

    def canceled_by_purge?
      import_status_key.present? && Comms::CsvImportStatus.purged?(organization, import_status_key)
    end

    def csv_call_attrs(row)
      associated_contact = parse_associated_contact(csv_value(row, "associated_contact_primary", "associated_contact", "associated_contact_ids_primary"))
      contact_name = csv_value(row, "contact_name", "contact", "name", "full_name", "customer_name", "person", "first_name").presence || associated_contact[:name]
      company_name = csv_value(row, "company_name", "company", "account", "business", "business_name", "organization", "lead_name")
      company_name = distinct_comms_company_name(contact_name, company_name)
      phone = extract_phone(csv_value(row, "phone", "phone_number", "mobile", "mobile_phone", "cell", "cell_phone", "number", "contact_phone").to_s)
      email = extract_email(csv_value(row, "email", "email_address", "contact_email").to_s).presence || associated_contact[:email]
      zip = csv_value(row, "zip", "zipcode", "zip_code", "postal", "postal_code", "service_zip", "service_area")
      {
        contact_name: contact_name,
        company_name: company_name,
        phone: phone,
        email: email,
        zip: zip.to_s[/\b\d{5}(?:-\d{4})?\b/].presence || zip,
        industry: csv_value(row, "industry", "business_type", "vertical", "trade", "category"),
        notes: csv_value(row, "notes", "note", "note_for_rep", "summary", "call_notes", "call_summary", "description", "message"),
        source: csv_value(row, "source", "lead_source", "campaign", "channel").presence || "csv_call_import",
        hubspot_lead_id: csv_value(row, "record_id", "lead_id", "hs_object_id"),
        hubspot_contact_id: csv_value(row, "associated_contact_ids_primary", "associated_contact_id").presence || associated_contact[:contact_id],
        hubspot_lead_owner: csv_value(row, "lead_owner", "contact_owner", "owner"),
        hubspot_owner_id: csv_value(row, "hubspot_owner_id", "contact_owner_id", "lead_owner_id", "owner_id"),
        hubspot_lead_label: csv_value(row, "lead_label"),
        hubspot_lead_stage: csv_value(row, "lead_stage"),
        hubspot_lead_quality: csv_value(row, "lead_quality")
      }.compact_blank
    end

    def parse_associated_contact(value)
      text = value.to_s.squish
      return {} if text.blank?

      email = extract_email(text)
      name = text.sub(/\([^)]*@[^)]*\)/, "").squish.presence
      contact_id = text[/\b\d{6,}\b/]
      {
        name: name,
        email: email,
        contact_id: contact_id
      }.compact_blank
    end

    def csv_value(row, *names)
      normalized = row.headers.compact.index_by { |header| normalize_csv_header(header) }
      names.each do |name|
        header = normalized[normalize_csv_header(name)]
        value = row[header].to_s.squish if header.present?
        return value if value.present?
      end
      nil
    end

    def normalize_csv_header(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def manual_crm_record!(label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, claim_by_current_user: false, row_number: nil, raw_row: nil)
      company_name = distinct_comms_company_name(contact_name, company_name)
      source_uid = manual_comms_source_uid(phone: phone, email: email)
      record = find_manual_comms_record(phone: phone, email: email) ||
        organization.crm_records.find_or_initialize_by(source: "manual_comms", source_uid: source_uid)
      base_properties = clean_manual_comms_properties(record.properties.to_h, source: source)
      record.assign_attributes(
        record_type: "contact",
        status: "open",
        name: label,
        phone: phone.presence || record.phone,
        email: email.presence || record.email,
        owner: ActiveModel::Type::Boolean.new.cast(claim_by_current_user) ? user : record.owner,
        stage: "manual_comms",
        properties: base_properties.merge(
          "manual_comms" => true,
          "manual_comms_created_by_user_id" => user.id,
          "manual_comms_contact_value" => [phone, email].compact.join(" / "),
          "manual_comms_contact_keys" => manual_comms_contact_keys(phone: phone, email: email),
          "manual_comms_contact_phone_digits" => normalized_phone_digits(phone),
          "manual_comms_contact_email" => normalized_email(email),
          "manual_comms_contact_name" => contact_name,
          "manual_comms_company_name" => company_name,
          "industry" => industry,
          "sms_captured_industry" => industry,
          "manual_comms_zip" => zip,
          "manual_comms_notes" => notes,
          "manual_comms_source" => source,
          "manual_comms_hubspot_lead" => lead_attrs.to_h.compact_blank,
          "contact_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
          "contact_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
          "hubspot_lead_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
          "hubspot_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
          "manual_comms_import_id" => import_id,
          "manual_comms_import_title" => import_title,
          "manual_comms_import_status_key" => import_status_key,
          "manual_comms_claimed_by_importer" => ActiveModel::Type::Boolean.new.cast(claim_by_current_user),
          "manual_comms_import_row" => row_number,
          "manual_comms_raw_row" => raw_row
        ).compact_blank
      )
      record.save!
      record
    end

    def clean_manual_comms_properties(properties, source:)
      return properties if source.present?

      properties.except(
        "manual_comms_source",
        "manual_comms_import_id",
        "manual_comms_import_title",
        "manual_comms_import_status_key",
        "manual_comms_import_row",
        "manual_comms_raw_row",
        "owner_queue_source_uid",
        "owner_queue_refreshed_at"
      )
    end

    def manual_stage!(record:, label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, claim_by_current_user: false, row_number: nil, raw_row: nil)
      metadata = manual_stage_metadata(label: label, phone: phone, email: email, contact_name: contact_name, company_name: company_name, industry: industry, zip: zip, notes: notes, source: source, lead_attrs: lead_attrs, import_id: import_id, import_title: import_title, import_status_key: import_status_key, claim_by_current_user: claim_by_current_user, row_number: row_number, raw_row: raw_row)
      stage = if source.present?
        record.crm_record_artifacts.where(
          organization: organization,
          artifact_type: "comm_staging"
        )
          .where.not(status: "archived")
          .where("metadata ->> 'stage_type' = ?", "manual_comms")
          .order(updated_at: :desc)
          .first
      end
      stage ||= record.crm_record_artifacts.build(
        organization: organization,
        user: user,
        artifact_type: "comm_staging",
        title: "WIZWIKI COMMS: #{label}"
      )
      if (duplicate_stage = duplicate_active_comms_stage(phone: phone, email: email, except_stage: stage))
        raise Comms::ContactDeduper::DuplicateContactError, "duplicate phone/email already staged in COMMS block ##{duplicate_stage.id}"
      end
      was_new = stage.new_record?
      base_metadata = clean_manual_comms_stage_metadata(stage.metadata.to_h, source: source)
      stage.update!(
        status: "staged",
        user: user,
        generated_at: Time.current,
        content_type: "application/json",
        metadata: was_new ? metadata : base_metadata.merge(metadata)
      )
      stage.define_singleton_method(:csv_import_created?) { was_new }
      stage
    end

    def clean_manual_comms_stage_metadata(metadata, source:)
      return metadata if source.present?

      metadata.except(
        "csv_call_import",
        "csv_call_import_source",
        "csv_call_import_id",
        "csv_call_import_title",
        "csv_call_import_status_key",
        "csv_call_import_row",
        "csv_call_raw_row",
        "owner_queue_source_uid",
        "owner_queue_source_record_id",
        "owner_queue_refreshed_at",
        "owner_queue_archived_at",
        "owner_queue_archive_reason"
      )
    end

    def manual_stage_metadata(label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, claim_by_current_user: false, row_number: nil, raw_row: nil)
      contact_label = contact_name.presence || "Contact"
      company_name = distinct_comms_company_name(contact_name, company_name)
      company_label = company_name.presence || (contact_name.present? ? nil : label)
      display_label = company_label.presence || contact_label.presence || label
      phone_option = phone.present? ? { "id" => "manual-phone", "name" => contact_label, "value" => phone, "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" } : nil
      email_option = email.present? ? { "id" => "manual-email", "name" => contact_label, "value" => email, "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" } : nil
      sms_body = comms_opening_sms_body(contact_name)
      metadata = {
        "stage_type" => "manual_comms",
        "company_name" => company_label,
        "deal_name" => display_label,
        "comm_kit_direction" => "wizwiki_out",
        "comm_kit_direction_label" => "WIZWIKI COMMS",
        "contact_options" => [{ "id" => "manual-contact", "name" => contact_label, "company" => company_label, "record_type" => "manual", "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" }],
        "phone_options" => [phone_option].compact,
        "recipient_email_options" => [email_option].compact,
        "manual_comms_contact_keys" => manual_comms_contact_keys(phone: phone, email: email),
        "manual_comms_contact_phone_digits" => normalized_phone_digits(phone),
        "manual_comms_contact_email" => normalized_email(email),
        "selected_contact_id" => "manual-contact",
        "selected_phone_id" => phone_option.to_h["id"],
        "selected_recipient_email_id" => email_option.to_h["id"],
        "recipient_selection_summary" => source.present? ? "CSV call import staged by #{user.display_name}." : "Manual WIZWIKI COMMS created by #{user.display_name}.",
        "sender_name" => user.display_name,
        "sender_phone" => user.display_phone_number,
        "sender_profile" => {
          "name" => user.display_name,
          "phone" => user.display_phone_number,
          "email" => user.email_address,
          "twilio" => user.twilio_profile
        }.compact_blank,
        "sms_options" => [{ "id" => "manual-opener", "tone" => "Thumper opener", "body" => sms_body }],
        "selected_sms_id" => "manual-opener",
        "composed_sms_body" => sms_body,
        "aircall_status" => "manual_comms",
        "aircall_ready" => false,
        "captured_contact_name" => contact_name,
        "captured_company_name" => company_name,
        "captured_industry" => industry,
        "captured_email" => email,
        "industry" => industry,
        "csv_call_import" => source.present?,
        "csv_call_import_source" => source,
        "csv_call_import_id" => import_id,
        "csv_call_import_title" => import_title,
        "csv_call_import_status_key" => import_status_key,
        "csv_call_import_claimed_by_me" => ActiveModel::Type::Boolean.new.cast(claim_by_current_user),
        "csv_call_import_row" => row_number,
        "csv_call_notes" => notes,
        "hubspot_lead" => lead_attrs.to_h.compact_blank,
        "hubspot_lead_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
        "hubspot_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
        "contact_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
        "contact_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
        "hubspot_lead_id" => lead_attrs.to_h[:hubspot_lead_id].presence,
        "hubspot_contact_id" => lead_attrs.to_h[:hubspot_contact_id].presence,
        "hubspot_lead_quality" => lead_attrs.to_h[:hubspot_lead_quality].presence,
        "csv_call_raw_row" => raw_row,
        "comms_bot_state" => {
          "contact_name" => contact_name,
          "company_name" => company_name
        }.compact_blank,
        "staged_at" => Time.current.iso8601,
        "staged_by_user_id" => user.id,
        "staged_by" => user.display_name,
        "sms_sending_disabled" => false
      }.merge(claimed_stage_metadata(claim_by_current_user)).compact_blank
      metadata.merge(DealReports::CommsProcessingCode.call(stage: OpenStruct.new(crm_record: nil, title: label), metadata: metadata, latest_body: sms_body))
    end

    def claimed_stage_metadata(claim_by_current_user)
      return {} unless ActiveModel::Type::Boolean.new.cast(claim_by_current_user)

      now = Time.current.iso8601
      {
        "claimed_by_user_id" => user.id.to_s,
        "claimed_by_user_name" => user.display_name,
        "claimed_at" => now,
        "claimed_last_confirmed_at" => now,
        "claimed_source" => "csv_import_claim_by_me"
      }
    end

    def extract_phone(value)
      return if value.match?(/@/)

      cleaned = value.gsub(/[^\d+]/, "")
      digits = cleaned.gsub(/\D/, "")
      digits.length >= 7 ? cleaned : nil
    end

    def extract_email(value)
      value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
    end

    def normalized_email(value)
      extract_email(value.to_s).to_s.downcase.presence
    end

    def normalized_phone_digits(value)
      digits = value.to_s.gsub(/\D/, "")
      return if digits.blank?

      digits.length >= 10 ? digits.last(10) : digits
    end

    def manual_comms_contact_keys(phone:, email:)
      [
        (digits = normalized_phone_digits(phone)).present? ? "phone:#{digits}" : nil,
        (address = normalized_email(email)).present? ? "email:#{address}" : nil
      ].compact
    end

    def duplicate_active_comms_stage(phone:, email:, except_stage: nil, except_record: nil)
      Comms::ContactDeduper.duplicate_stage(
        organization: organization,
        phone: phone,
        email: email,
        except_stage: except_stage,
        except_record: except_record
      )
    end

    def manual_comms_source_uid(phone:, email:)
      key = manual_comms_contact_keys(phone: phone, email: email).first.presence ||
        [phone, email].compact.join("|").presence ||
        SecureRandom.uuid
      "manual-comms-#{Digest::SHA256.hexdigest(key).first(24)}"
    end

    def find_manual_comms_record(phone:, email:)
      email_value = normalized_email(email)
      phone_digits = normalized_phone_digits(phone)
      return if email_value.blank? && phone_digits.blank?

      conditions = []
      binds = {}
      if email_value.present?
        conditions << "LOWER(COALESCE(email, '')) = :email"
        conditions << "properties ->> 'manual_comms_contact_email' = :email"
        conditions << "jsonb_exists(properties -> 'manual_comms_contact_keys', :email_key)"
        binds[:email] = email_value
        binds[:email_key] = "email:#{email_value}"
      end
      if phone_digits.present?
        conditions << "RIGHT(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10) = :phone_digits"
        conditions << "properties ->> 'manual_comms_contact_phone_digits' = :phone_digits"
        conditions << "jsonb_exists(properties -> 'manual_comms_contact_keys', :phone_key)"
        binds[:phone_digits] = phone_digits
        binds[:phone_key] = "phone:#{phone_digits}"
      end

      organization.crm_records
        .where(source: "manual_comms")
        .where(conditions.map { |condition| "(#{condition})" }.join(" OR "), binds)
        .order(updated_at: :desc)
        .first
    end

    def comms_opening_sms_body(contact_name)
      first_name = comms_first_name(contact_name)
      return DealReports::CommsDraftWriter::OPENING_OFFER if first_name.blank?

      Thumper::VoiceGuide.starter_sms(first_name)
    end

    def comms_first_name(value)
      text = value.to_s.squish
      return if generic_comms_identity?(text)
      return if text.match?(/@/)

      first_name = text.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      return if first_name.blank? || first_name.length < 2

      first_name
    end

    def generic_comms_identity?(value)
      text = value.to_s.squish.downcase
      text.blank? ||
        %w[wizwiki\ comms sample\ comms manual\ comms choose\ in\ lab contact customer].include?(text) ||
        text.match?(/\A(?:wizwiki\s*)?comms\b/) ||
        text.match?(/\Asample\b/)
    end

    def distinct_comms_company_name(contact_name, company_name)
      company = company_name.to_s.squish.presence
      return if company.blank? || generic_comms_identity?(company)

      contact_key = comms_identity_key(contact_name)
      company_key = comms_identity_key(company)
      return if contact_key.present? && company_key.present? && contact_key == company_key

      company
    end

    def comms_identity_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "").presence
    end

    def normalize_csv_import_title(value)
      value.to_s.squish.gsub(/[^a-zA-Z0-9 #&_.:-]/, "").squish[0, 80].presence
    end
  end
end
