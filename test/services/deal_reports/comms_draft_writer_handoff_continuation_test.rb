# frozen_string_literal: true

require "test_helper"
require "securerandom"

module DealReports
  class CommsDraftWriterHandoffContinuationTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Handoff continuation #{suffix}", slug: "handoff-continuation-#{suffix}")
      @user = users(:one)
      @record = CrmRecord.create!(
        organization: @organization,
        name: "Sign buyer",
        record_type: "deal",
        fingerprint: "handoff-continuation-#{suffix}"
      )
    end

    test "pending rush handoff does not promote an unreviewed checkout" do
      stage = comm_stage(
        [
          sms("outbound", "What is the best way for a marketing consultant to reach you?", 2.minutes.ago),
          sms("inbound", "I need to see the checkout link for signs", 1.minute.ago)
        ],
        "sms_autopilot_handoff_contact_pending" => true,
        "sms_autopilot_handoff_contact_permission" => true,
        "sms_autopilot_handoff_contact_reason" => "rush_or_deadline_confirmation_sms"
      )
      writer = CommsDraftWriter.new(stage: stage, user: @user, writer_model: "nvidia:nemotron")

      refute writer.send(:handoff_contact_fast_path_turn?)
      refute writer.send(:am_support_required_for_latest_inbound?)

      draft = writer.send(:deterministic_fast_path_draft)
      assert_nil draft
    end

    test "sent handoff confirmation does not replace later product answers" do
      posted_at = 3.minutes.ago
      stage = comm_stage(
        [
          sms("outbound", "Perfect. Dane is assigned to follow up by email. You can keep texting me here.", 2.minutes.ago),
          sms("inbound", "What sign options do you have?", 1.minute.ago)
        ],
        "sms_autopilot_handoff_contact_pending" => false,
        "sms_autopilot_handoff_contact_permission" => true,
        "sms_autopilot_handoff_contact_preference" => "email",
        "sms_autopilot_handoff_contact_email" => "owner@example.com",
        "sms_autopilot_handoff_contact_posted_at" => posted_at.iso8601,
        "sms_autopilot_slack_handoff_at" => posted_at.iso8601
      )
      writer = CommsDraftWriter.new(stage: stage, user: @user, writer_model: "nvidia:nemotron")

      refute writer.send(:handoff_contact_confirmation_due?)
      refute writer.send(:handoff_contact_fast_path_turn?)
    end

    private

    def comm_stage(thread, metadata = {})
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "Rush continuation",
        metadata: {
          "sms_autopilot_enabled" => true,
          "sms_listener_active" => true,
          "product_interest_code" => "LAWN_SIGNS",
          "product_interest_label" => "Lawn Signs",
          "shopify_link" => "https://shop.example.invalid/products/24x18-yard-signs-sample_owner",
          "sms_thread" => thread
        }.merge(metadata)
      )
    end

    def sms(direction, body, at)
      {
        "channel" => "sms",
        "direction" => direction,
        "status" => direction == "inbound" ? "received" : "delivered",
        "body" => body,
        "created_at" => at.iso8601,
        "provider_message_id" => "SM#{SecureRandom.hex(8)}"
      }
    end
  end
end
