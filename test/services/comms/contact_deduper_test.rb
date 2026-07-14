# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class ContactDeduperTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Contact deduper #{suffix}", slug: "contact-deduper-#{suffix}")
      @record = CrmRecord.create!(
        organization: @organization,
        name: "Indexed contact",
        record_type: "contact",
        source: "manual_comms",
        source_uid: "manual-comms-#{suffix}"
      )
      @stage = CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @record,
        artifact_type: "comm_staging",
        status: "staged",
        title: "Indexed COMMS contact",
        metadata: {
          "stage_type" => "manual_comms",
          "manual_comms_contact_phone_digits" => "4125550101",
          "manual_comms_contact_email" => "indexed@example.com",
          "manual_comms_contact_keys" => ["phone:4125550101", "email:indexed@example.com"]
        }
      )
    end

    test "finds normalized phone and email fields" do
      assert_equal @stage, ContactDeduper.duplicate_stage(organization: @organization, phone: "(412) 555-0101", email: nil)
      assert_equal @stage, ContactDeduper.duplicate_stage(organization: @organization, phone: nil, email: "INDEXED@example.com")
    end

    test "a missing contact performs one artifact lookup without a legacy scan" do
      selects = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        selects += 1 if payload[:sql].to_s.include?(%Q("crm_record_artifacts")) && payload[:sql].to_s.lstrip.start_with?("SELECT")
      end

      assert_nil ContactDeduper.duplicate_stage(organization: @organization, phone: "4125550199", email: nil)
      assert_equal 1, selects
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
