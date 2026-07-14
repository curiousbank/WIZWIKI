# frozen_string_literal: true

module Comms
  class ConversationMemoryReset
    CRM_PROPERTY_KEYS = %w[
      sms_captured_contact_name
      sms_captured_company_name
      sms_captured_industry
      sms_captured_email
      sms_email_opt_in
      sms_contact_preference
      sms_preferred_contact_window
      sms_captured_zip
      sms_captured_city
      sms_captured_state
      sms_captured_country
      sms_location_capture_status
      sms_location_capture_source
      sms_location_capture_updated_at
      sms_identity_capture_updated_at
    ].freeze

    def self.clear_record!(record)
      return if record.blank?

      properties = record.properties.to_h
      reset_properties = properties.except(*CRM_PROPERTY_KEYS)
      record.update!(properties: reset_properties) if reset_properties != properties
    end
  end
end
