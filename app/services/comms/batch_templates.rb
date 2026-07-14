module Comms
  module BatchTemplates
    TYPES = %w[sms email].freeze
    MAX_TEMPLATES_PER_TYPE = 40
    MAX_TITLE_LENGTH = 90
    MAX_SMS_BODY_LENGTH = 1_200
    MAX_EMAIL_BODY_LENGTH = 8_000
    MAX_EMAIL_SUBJECT_LENGTH = 160
    TOKEN_OPTIONS = [
      ["First name", "{{first_name}}"],
      ["Contact", "{{contact_name}}"],
      ["Company", "{{company}}"],
      ["Phone", "{{phone}}"],
      ["Email", "{{email}}"]
    ].freeze

    module_function

    def defaults
      {
        "selected_sms_template_id" => nil,
        "selected_email_template_id" => nil,
        "templates" => {
          "sms" => [],
          "email" => []
        }
      }
    end

    def settings_for(organization)
      normalize(organization.settings.to_h.fetch("comms_batch_templates", {}).to_h)
    end

    def normalize(raw)
      raw = raw.to_h
      template_sets = defaults["templates"].deep_dup
      TYPES.each do |type|
        template_sets[type] = Array(raw.dig("templates", type)).filter_map do |template|
          normalize_template(template.to_h, type: type)
        end.first(MAX_TEMPLATES_PER_TYPE)
      end

      settings = defaults.deep_merge(
        "selected_sms_template_id" => raw["selected_sms_template_id"].to_s.presence,
        "selected_email_template_id" => raw["selected_email_template_id"].to_s.presence,
        "templates" => template_sets
      )
      TYPES.each do |type|
        selected_key = selected_key_for(type)
        selected_id = settings[selected_key].to_s
        settings[selected_key] = nil unless template_sets[type].any? { |template| template["id"].to_s == selected_id }
      end
      settings
    end

    def sanitize(raw, existing:, user:)
      raw = raw.to_h
      existing = normalize(existing)
      now = Time.current.iso8601
      settings = defaults

      TYPES.each do |type|
        existing_by_id = Array(existing.dig("templates", type)).index_by { |template| template["id"].to_s }
        submitted_rows = raw.dig("templates", type).to_h.values
        settings["templates"][type] = submitted_rows.filter_map do |row|
          row = row.to_h
          next if truthy?(row["delete"])

          existing_template = existing_by_id[row["id"].to_s].to_h
          normalize_template(
            existing_template.merge(row).merge(
              "id" => existing_template["id"].presence || row["id"].presence || SecureRandom.uuid,
              "created_at" => existing_template["created_at"].presence || now,
              "created_by_user_id" => existing_template["created_by_user_id"].presence || user&.id,
              "created_by" => existing_template["created_by"].presence || user&.display_name,
              "updated_at" => now,
              "updated_by_user_id" => user&.id,
              "updated_by" => user&.display_name
            ),
            type: type
          )
        end.first(MAX_TEMPLATES_PER_TYPE)
      end

      new_template = normalize_new_template(raw["new"].to_h, user: user, now: now)
      if new_template.present?
        type = new_template["type"]
        settings["templates"][type] << new_template.except("type")
        settings["templates"][type] = settings["templates"][type].last(MAX_TEMPLATES_PER_TYPE)
      end

      TYPES.each do |type|
        selected_key = selected_key_for(type)
        requested_id = raw[selected_key].to_s.presence
        requested_id = new_template["id"] if new_template.present? && new_template["type"] == type && truthy?(raw.dig("new", "activate"))
        settings[selected_key] = if requested_id.present? && settings["templates"][type].any? { |template| template["id"].to_s == requested_id }
          requested_id
        end
      end

      normalize(settings)
    end

    def active_template(settings, type)
      type = normalize_type(type)
      return {} if type.blank?

      settings = normalize(settings)
      selected_id = settings[selected_key_for(type)].to_s
      return {} if selected_id.blank?

      Array(settings.dig("templates", type)).find { |template| template["id"].to_s == selected_id }.to_h
    end

    def source_payload(settings)
      settings = normalize(settings)
      payload = {}
      sms_template = active_template(settings, "sms")
      email_template = active_template(settings, "email")
      payload["static_sms_template"] = source_template(sms_template, type: "sms") if sms_template.present?
      payload["static_email_template"] = source_template(email_template, type: "email") if email_template.present?
      payload
    end

    def render_body(template, stage)
      template = template.to_h
      body = template["body"].to_s
      rendered = replace_tokens(body, stage)
      template["type"].to_s == "email" ? clean_email_text(rendered, limit: MAX_EMAIL_BODY_LENGTH) : clean_sms_text(rendered, limit: MAX_SMS_BODY_LENGTH)
    end

    def render_subject(template, stage)
      clean_email_text(replace_tokens(template.to_h["subject"].to_s, stage), limit: MAX_EMAIL_SUBJECT_LENGTH).squish
    end

    def token_options
      TOKEN_OPTIONS
    end

    def selected_key_for(type)
      "selected_#{normalize_type(type)}_template_id"
    end

    def normalize_type(value)
      type = value.to_s.downcase
      TYPES.include?(type) ? type : nil
    end

    def source_template(template, type:)
      template = template.to_h
      {
        "id" => template["id"].to_s,
        "type" => type,
        "title" => template["title"].to_s,
        "subject" => template["subject"].to_s.presence,
        "body" => template["body"].to_s
      }.compact_blank
    end

    def normalize_new_template(raw, user:, now:)
      raw = raw.to_h
      type = normalize_type(raw["type"])
      return if type.blank?

      normalize_template(
        raw.merge(
          "id" => SecureRandom.uuid,
          "created_at" => now,
          "created_by_user_id" => user&.id,
          "created_by" => user&.display_name,
          "updated_at" => now,
          "updated_by_user_id" => user&.id,
          "updated_by" => user&.display_name
        ),
        type: type
      )&.merge("type" => type)
    end

    def normalize_template(raw, type:)
      type = normalize_type(type)
      return if type.blank?

      body = clean_text(raw["body"], limit: type == "sms" ? MAX_SMS_BODY_LENGTH : MAX_EMAIL_BODY_LENGTH)
      return if body.blank?

      title = raw["title"].to_s.squish.truncate(MAX_TITLE_LENGTH, omission: "").presence || "#{type.upcase} template"
      {
        "id" => raw["id"].to_s.presence || SecureRandom.uuid,
        "title" => title,
        "subject" => type == "email" ? clean_email_text(raw["subject"], limit: MAX_EMAIL_SUBJECT_LENGTH).squish : nil,
        "body" => body,
        "created_at" => raw["created_at"].to_s.presence,
        "created_by_user_id" => raw["created_by_user_id"].to_s.presence,
        "created_by" => raw["created_by"].to_s.presence,
        "updated_at" => raw["updated_at"].to_s.presence,
        "updated_by_user_id" => raw["updated_by_user_id"].to_s.presence,
        "updated_by" => raw["updated_by"].to_s.presence
      }.compact_blank
    end

    def replace_tokens(text, stage)
      values = token_values(stage)
      text.to_s.gsub(/\{\{\s*([a-z_]+)\s*\}\}/i) do
        key = Regexp.last_match(1).to_s.downcase
        values.fetch(key, "")
      end
    end

    def token_values(stage)
      metadata = stage&.metadata.to_h
      contact = selected_option(metadata, "contact_options", "selected_contact_id")
      phone = selected_option(metadata, "phone_options", "selected_phone_id")
      email = selected_option(metadata, "email_options", "selected_email_id")
      contact_name = contact["name"].to_s.squish.presence ||
        metadata["captured_contact_name"].to_s.squish.presence ||
        metadata["contact_name"].to_s.squish.presence
      company = metadata["company_name"].to_s.squish.presence || stage&.crm_record&.name.to_s.squish.presence || stage&.title.to_s.squish.presence
      first_name = first_name_from(contact_name) || first_name_from(company)
      {
        "first_name" => first_name.presence || "there",
        "contact_name" => contact_name.presence || first_name.presence || "",
        "company" => company.presence || "",
        "company_name" => company.presence || "",
        "phone" => phone["value"].to_s.squish,
        "email" => email["value"].to_s.squish
      }
    end

    def selected_option(metadata, options_key, selected_key)
      selected_id = metadata.to_h[selected_key].to_s
      options = Array(metadata.to_h[options_key])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first).to_h
    end

    def first_name_from(value)
      text = value.to_s.squish
      return if text.blank? || text.match?(/@/)
      return if generic_identity?(text)

      first = text.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      first if first.length >= 2
    end

    def generic_identity?(value)
      text = value.to_s.squish.downcase
      text.blank? ||
        text.match?(/\A(?:wizwiki\s*)?comms\b/) ||
        text.match?(/\Asample\b/) ||
        %w[contact customer test unknown].include?(text)
    end

    def clean_text(value, limit:)
      value.to_s.gsub(/\r\n?/, "\n").gsub(/[ \t]+\n/, "\n").gsub(/\n{4,}/, "\n\n\n").strip.first(limit)
    end

    def clean_sms_text(value, limit:)
      clean_text(value, limit: limit).gsub(/[ \t]{2,}/, " ").gsub(/\n{3,}/, "\n\n").strip
    end

    def clean_email_text(value, limit:)
      clean_text(value, limit: limit)
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
