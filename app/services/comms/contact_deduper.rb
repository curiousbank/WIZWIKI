require "set"

module Comms
  class ContactDeduper
    DuplicateContactError = Class.new(StandardError)
    STAGE_TYPES = %w[manual_comms storm_watch_comms].freeze

    class << self
      def keys(phone:, email:)
        [
          (digits = phone_digits(phone)).present? ? "phone:#{digits}" : nil,
          (address = email_address(email)).present? ? "email:#{address}" : nil
        ].compact
      end

      def add_keys(index, phone:, email:)
        keys(phone: phone, email: email).each { |key| index.add(key) }
        index
      end

      def duplicate_in_index?(index, phone:, email:, except_keys: nil)
        ignored = Set.new(Array(except_keys))
        keys(phone: phone, email: email).any? { |key| index.include?(key) && !ignored.include?(key) }
      end

      def key_index(organization:, stage_types: STAGE_TYPES)
        active_stage_scope(organization: organization, stage_types: stage_types).each_with_object(Set.new) do |stage, index|
          stage_keys(stage).each { |key| index.add(key) }
        end
      end

      def duplicate_stage(organization:, phone:, email:, except_stage: nil, except_record: nil, stage_types: STAGE_TYPES)
        candidate_keys = keys(phone: phone, email: email)
        return if candidate_keys.blank?

        scope = active_stage_scope(organization: organization, stage_types: stage_types)
        scope = scope.where.not(id: except_stage.id) if except_stage&.id.present?
        scope = scope.where.not(crm_record_id: except_record.id) if except_record&.id.present?

        fast_sql, fast_binds = duplicate_stage_fast_conditions(scope, phone: phone, email: email)
        if fast_sql.present?
          fast_match = scope.where(fast_sql, fast_binds).take
          return fast_match if fast_match
        end

        return unless legacy_scan_enabled?

        legacy_scope = scope.where(no_contact_keys_sql(scope))
        legacy_sql, legacy_binds = duplicate_stage_legacy_conditions(legacy_scope, phone: phone, email: email)
        return if legacy_sql.blank?

        legacy_scope.where(legacy_sql, legacy_binds).take
      end

      def stage_keys(stage_or_metadata)
        metadata = stage_or_metadata.respond_to?(:metadata) ? stage_or_metadata.metadata.to_h : stage_or_metadata.to_h
        found = Set.new

        Array(metadata["manual_comms_contact_keys"]).each { |key| add_known_key(found, key) }
        add_phone_key(found, metadata["manual_comms_contact_phone_digits"])
        add_phone_key(found, metadata["captured_phone"])
        add_phone_key(found, metadata["selected_phone"])
        add_email_key(found, metadata["manual_comms_contact_email"])
        add_email_key(found, metadata["captured_email"])
        add_email_key(found, metadata["selected_recipient_email"])

        Array(metadata["phone_options"]).each do |option|
          option = option.respond_to?(:to_h) ? option.to_h : { "value" => option }
          add_phone_key(found, option["value"].presence || option["phone"].presence || option["number"])
        end

        Array(metadata["recipient_email_options"]).each do |option|
          option = option.respond_to?(:to_h) ? option.to_h : { "value" => option }
          add_email_key(found, option["value"].presence || option["email"].presence || option["address"])
        end

        found
      end

      def phone_digits(value)
        digits = value.to_s.gsub(/\D/, "")
        return if digits.blank?

        digits.length >= 10 ? digits.last(10) : digits
      end

      def email_address(value)
        value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
      end

      private

      def active_stage_scope(organization:, stage_types:)
        organization.crm_record_artifacts
          .where(artifact_type: "comm_staging")
          .where.not(status: "archived")
          .where("metadata ->> 'stage_type' IN (?)", Array(stage_types))
      end

      def duplicate_stage_fast_conditions(scope, phone:, email:)
        metadata = metadata_column(scope)
        conditions = []
        binds = {}

        if (digits = phone_digits(phone)).present?
          conditions << <<~SQL.squish
            #{metadata} ->> 'manual_comms_contact_phone_digits' = :phone_digits
              AND NULLIF(#{metadata} ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
          SQL
          binds[:phone_digits] = digits
        end

        if (address = email_address(email)).present?
          conditions << <<~SQL.squish
            #{metadata} ->> 'manual_comms_contact_email' = :email_address
              AND NULLIF(#{metadata} ->> 'manual_comms_contact_email', '') IS NOT NULL
          SQL
          binds[:email_address] = address
        end

        [conditions.join(" OR "), binds]
      end

      def legacy_scan_enabled?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_LEGACY_CONTACT_SCAN_ENABLED", "0"))
      end

      def duplicate_stage_legacy_conditions(scope, phone:, email:)
        metadata = metadata_column(scope)
        conditions = []
        binds = {}

        if (digits = phone_digits(phone)).present?
          binds[:phone_digits] = digits
          phone_columns = %w[
            manual_comms_contact_phone_digits
            captured_phone
            selected_phone
          ]
          phone_columns.each do |column|
            conditions << "RIGHT(regexp_replace(COALESCE(#{metadata} ->> '#{column}', ''), '[^0-9]', '', 'g'), 10) = :phone_digits"
          end
          conditions << <<~SQL.squish
            EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                CASE
                  WHEN jsonb_typeof(#{metadata} -> 'phone_options') = 'array'
                  THEN #{metadata} -> 'phone_options'
                  ELSE '[]'::jsonb
                END
              ) AS phone_option(value)
              WHERE RIGHT(
                regexp_replace(
                  COALESCE(
                    phone_option.value ->> 'value',
                    phone_option.value ->> 'phone',
                    phone_option.value ->> 'number',
                    CASE
                      WHEN jsonb_typeof(phone_option.value) = 'string'
                      THEN TRIM(BOTH '"' FROM phone_option.value::text)
                      ELSE NULL
                    END,
                    ''
                  ),
                  '[^0-9]',
                  '',
                  'g'
                ),
                10
              ) = :phone_digits
            )
          SQL
        end

        if (address = email_address(email)).present?
          binds[:email_address] = address
          email_columns = %w[
            manual_comms_contact_email
            captured_email
            selected_recipient_email
          ]
          email_columns.each do |column|
            conditions << "LOWER(COALESCE(#{metadata} ->> '#{column}', '')) = :email_address"
          end
          conditions << <<~SQL.squish
            EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                CASE
                  WHEN jsonb_typeof(#{metadata} -> 'recipient_email_options') = 'array'
                  THEN #{metadata} -> 'recipient_email_options'
                  ELSE '[]'::jsonb
                END
              ) AS email_option(value)
              WHERE LOWER(
                COALESCE(
                  email_option.value ->> 'value',
                  email_option.value ->> 'email',
                  email_option.value ->> 'address',
                  CASE
                    WHEN jsonb_typeof(email_option.value) = 'string'
                    THEN TRIM(BOTH '"' FROM email_option.value::text)
                    ELSE NULL
                  END,
                  ''
                )
              ) = :email_address
            )
          SQL
        end

        [conditions.join(" OR "), binds]
      end

      def no_contact_keys_sql(scope)
        metadata = metadata_column(scope)
        <<~SQL.squish
          CASE
            WHEN jsonb_typeof(#{metadata} -> 'manual_comms_contact_keys') = 'array'
            THEN jsonb_array_length(#{metadata} -> 'manual_comms_contact_keys')
            ELSE 0
          END = 0
        SQL
      end

      def metadata_column(scope)
        table = scope.klass.quoted_table_name
        "#{table}.#{scope.klass.connection.quote_column_name("metadata")}"
      end

      def add_known_key(found, value)
        key = value.to_s.downcase.strip
        found.add(key) if key.match?(/\A(?:phone|email):.+\z/)
      end

      def add_phone_key(found, value)
        digits = phone_digits(value)
        found.add("phone:#{digits}") if digits.present?
      end

      def add_email_key(found, value)
        address = email_address(value)
        found.add("email:#{address}") if address.present?
      end
    end
  end
end
