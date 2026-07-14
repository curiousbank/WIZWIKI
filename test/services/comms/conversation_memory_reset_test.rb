# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class ConversationMemoryResetTest < ActiveSupport::TestCase
    test "clears SMS-captured CRM discovery while preserving unrelated properties" do
      suffix = SecureRandom.hex(4)
      organization = Organization.create!(name: "Reset #{suffix}", slug: "reset-#{suffix}")
      record = CrmRecord.create!(
        organization: organization,
        name: "Reset lead",
        record_type: "deal",
        fingerprint: "reset-#{suffix}",
        properties: {
          "sms_captured_email" => "old@example.com",
          "sms_captured_company_name" => "Old Company",
          "sms_contact_preference" => "email",
          "manual_comms_contact_phone_digits" => "3135550100"
        }
      )

      ConversationMemoryReset.clear_record!(record)

      properties = record.reload.properties
      refute properties.key?("sms_captured_email")
      refute properties.key?("sms_captured_company_name")
      refute properties.key?("sms_contact_preference")
      assert_equal "3135550100", properties["manual_comms_contact_phone_digits"]
    end
  end
end
