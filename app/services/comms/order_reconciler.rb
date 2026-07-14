module Comms
  class OrderReconciler
    PAID_STATUSES = %w[paid].freeze

    def self.call(organization:)
      new(organization: organization).call
    end

    def initialize(organization:)
      @organization = organization
    end

    def call
      result = { scanned: 0, archived: 0, unmatched: 0 }

      manual_comms_scope.find_each do |stage|
        result[:scanned] += 1
        order = matching_order(stage)
        if order.present?
          archive_stage!(stage, order)
          result[:archived] += 1
        else
          result[:unmatched] += 1
        end
      rescue StandardError => error
        Rails.logger.warn("[Comms::OrderReconciler] stage=#{stage&.id} skipped #{error.class}: #{error.message}")
      end

      result
    end

    private

    attr_reader :organization

    def manual_comms_scope
      organization.crm_record_artifacts
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
    end

    def matching_order(stage)
      record = stage.crm_record
      order_scope = organization.quick_cart_orders.where(status: PAID_STATUSES)
      return order_scope.where(crm_record_id: record.id).order(updated_at: :desc).first if record&.id.present? && order_scope.where(crm_record_id: record.id).exists?

      email = stage_email(stage).presence || record&.email.to_s.downcase.presence
      if email.present?
        match = order_scope.where("LOWER(email) = ?", email.downcase).order(updated_at: :desc).first
        return match if match.present?
      end

      digits = phone_digits(stage_phone(stage).presence || record&.phone)
      return if digits.blank?

      order_scope
        .where("RIGHT(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10) = ?", digits)
        .order(updated_at: :desc)
        .first
    end

    def archive_stage!(stage, order)
      metadata = stage.metadata.to_h.merge(
        "comms_removed_reason" => "matched_paid_order",
        "comms_removed_at" => Time.current.iso8601,
        "matched_quick_cart_order_id" => order.id,
        "matched_quick_cart_order_package" => order.package,
        "matched_quick_cart_order_status" => order.status,
        "matched_quick_cart_order_updated_at" => order.updated_at&.iso8601
      )

      stage.update!(
        status: "archived",
        generated_at: Time.current,
        metadata: metadata
      )
    end

    def stage_email(stage)
      metadata = stage.metadata.to_h
      option = selected_option(metadata, "recipient_email_options", "selected_recipient_email_id")
      option["value"].to_s.downcase.presence ||
        metadata["captured_email"].to_s.downcase.presence ||
        metadata.dig("comms_bot_state", "email").to_s.downcase.presence
    end

    def stage_phone(stage)
      metadata = stage.metadata.to_h
      option = selected_option(metadata, "phone_options", "selected_phone_id")
      option["value"].presence
    end

    def selected_option(metadata, collection_key, selected_key)
      selected_id = metadata[selected_key].to_s
      Array(metadata[collection_key]).map(&:to_h).find { |option| option["id"].to_s == selected_id } ||
        Array(metadata[collection_key]).map(&:to_h).first ||
        {}
    end

    def phone_digits(value)
      digits = value.to_s.gsub(/\D/, "")
      digits.length >= 10 ? digits.last(10) : digits.presence
    end
  end
end
