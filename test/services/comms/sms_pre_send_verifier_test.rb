# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class SmsPreSendVerifierTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(
        name: "Pre Send #{suffix}",
        slug: "pre-send-#{suffix}"
      )
      @user = users(:one)
      @crm_record = CrmRecord.create!(
        organization: @organization,
        name: "Pre Send Roofing",
        record_type: "deal",
        fingerprint: "pre-send-#{suffix}"
      )
    end

    test "blocks price claims when no reviewed catalog is configured" do
      stage = comm_stage([
        inbound("How much for 50 yard signs?", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "For 100 signs, the price is $399. Want the checkout link?",
        source: "test"
      )

      refute result.allowed
      assert_equal "unconfigured_catalog_claim", result.reason
      assert_includes result.issue_codes, "unconfigured_catalog_claim"
      assert_nil result.body
    end

    test "blocks unreviewed product checkout links" do
      stage = comm_stage([
        inbound("Send me the door hanger checkout link.", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Here is the checkout link: https://shop.example.invalid/products/24x18-yard-signs-sample_owner",
        source: "test"
      )

      refute result.allowed
      assert_equal "unconfigured_catalog_claim", result.reason
      assert_includes result.issue_codes, "unconfigured_catalog_claim"
      assert_nil result.body
    end

    test "does not trust a thread link that is absent from the reviewed catalog" do
      stage = comm_stage(
        [
          inbound("Can i get the business card link", 5.minutes.ago),
          outbound("Yes. Business cards have a standalone option. Here is the Business Cards checkout link: https://shop.example.invalid/products/business-cards", 4.minutes.ago),
          inbound("What about door hangers?", 3.minutes.ago),
          outbound("Yes. Door hangers have a standalone 4.25x11 option. Want me to send the door-hanger checkout link?", 2.minutes.ago),
          inbound("Yes please", 1.minute.ago)
        ],
        metadata: {
          "product_interest_code" => "BUSINESS_CARDS",
          "comms_bot_state" => {
            "route_code" => "BUSINESS_CARDS",
            "shopify_link" => "https://shop.example.invalid/products/business-cards"
          }
        }
      )

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Door Hangers have a standalone checkout. Here is the checkout link: https://shop.example.invalid/products/door-hangers",
        source: "test"
      )

      refute result.allowed
      assert_equal "unconfigured_catalog_claim", result.reason
      assert_includes result.issue_codes, "unconfigured_catalog_claim"
      assert_nil result.body
    end

    test "blocks an unreviewed link for an ambiguous request" do
      stage = comm_stage([
        inbound("I need flyers, maybe business cards, maybe door hangers, but I have no idea on sizes or quantities.", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Here is the yard-sign checkout link: https://shop.example.invalid/products/24x18-yard-signs-sample_owner",
        source: "test"
      )

      refute result.allowed
      assert_equal "unconfigured_catalog_claim", result.reason
      assert_includes result.issue_codes, "unconfigured_catalog_claim"
      assert_nil result.body
    end

    test "blocks non customer facing worker replies" do
      stage = comm_stage([
        inbound("Do you have pricing for postcards?", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Here's the next SMS body for Sample Contact: For 1,000 postcards, it is $790.",
        source: "test"
      )

      refute result.allowed
      assert_equal "internal_voice_leak", result.reason
      assert_includes result.issue_codes, "internal_voice_leak"
      assert_nil result.body
    end

    test "rewrites premature handoff confirmation until contact details are posted" do
      stage = comm_stage([
        inbound("Yes, have someone reach out.", 1.minute.ago)
      ], metadata: {
        "sms_autopilot_handoff_contact_permission" => true
      })

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Perfect. Kristina F. will be contacting you by email. I let them know your contact preferences.",
        source: "test"
      )

      assert result.allowed
      assert result.corrected
      assert_includes result.issue_codes, "handoff_contact_details_missing"
      assert_includes result.body, "best way"
      assert_includes result.body, "email, call, or text"
      refute_includes result.body, "will be contacting"
    end

    test "polishes canned model framing before send" do
      stage = comm_stage([
        inbound("Can someone confirm the next step?", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Absolutely! An operator can confirm the next step — I can route it for review.",
        source: "test"
      )

      assert result.allowed
      assert result.corrected
      assert_includes result.issue_codes, "consultant_voice_canned_opener"
      assert_includes result.issue_codes, "consultant_voice_em_dash"
      refute_includes result.body, "Absolutely"
      refute_match(/[—–]/, result.body)
    end

    test "blocks corporate model language before send" do
      stage = comm_stage([
        inbound("What would work for my roofing company?", 1.minute.ago)
      ])

      result = SmsPreSendVerifier.call(
        stage: stage,
        body: "Our robust solutions can seamlessly elevate your local visibility.",
        source: "test"
      )

      refute result.allowed
      assert_equal "consultant_voice_corporate_language", result.reason
      assert_nil result.body
    end

    private

    def comm_stage(thread, metadata: {})
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @crm_record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "SMS pre-send verifier test",
        metadata: {
          "stage_type" => "manual_comms",
          "sms_autopilot_enabled" => true,
          "sms_thread" => thread
        }.merge(metadata)
      )
    end

    def inbound(body, at)
      {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "inbound",
        "status" => "received",
        "from" => "+15555550100",
        "to" => "+15555550999",
        "body" => body,
        "provider" => "twilio",
        "provider_message_id" => "SM#{SecureRandom.hex(6).upcase}",
        "created_at" => at.iso8601
      }
    end

    def outbound(body, at)
      {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "delivered",
        "from" => "+15555550999",
        "to" => "+15555550100",
        "body" => body,
        "provider" => "twilio",
        "provider_message_id" => "SM#{SecureRandom.hex(6).upcase}",
        "created_at" => at.iso8601
      }
    end
  end
end
