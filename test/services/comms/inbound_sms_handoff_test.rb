# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class InboundSmsHandoffTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(
        name: "Handoff #{suffix}",
        slug: "handoff-#{suffix}"
      )
      @user = users(:one)
      @crm_record = CrmRecord.create!(
        organization: @organization,
        name: "Handoff Roofing",
        record_type: "deal",
        email: "owner@example.com",
        phone: "+15555550100",
        fingerprint: "handoff-#{suffix}"
      )
    end

    test "collects contact preference before posting handoff" do
      stage = comm_stage([
        outbound("Would it be helpful for me to get you connected with one of our marketing consultants?", 2.minutes.ago),
        inbound("Yes please", 1.minute.ago)
      ], crm_record: CrmRecord.create!(
        organization: @organization,
        name: "No Known Contact",
        record_type: "deal",
        fingerprint: "handoff-empty-#{SecureRandom.hex(4)}"
      ))

      result = InboundSmsHandoff.call(
        stage: stage,
        body: "Yes please",
        reason: "customer_accepted_marketing_consultant_sms",
        source: "test"
      )

      refute result.handled
      refute result.slack_posted
      assert result.review_draft_saved

      metadata = stage.reload.metadata
      assert_equal true, metadata["sms_autopilot_handoff_contact_pending"]
      assert_equal "collecting_contact", metadata["sms_autopilot_handoff_state"]
      assert_equal "am_support_contact_pending", metadata["comms_command_last_status"]
      assert_includes metadata["comms_command_sms_draft_body"], "best way"
      assert_includes metadata["comms_command_sms_draft_body"], "email, call, or text"
    end

    test "uses known email and posts handoff only when contact details are ready" do
      stage = comm_stage([
        outbound("Would it be helpful for me to get you connected with one of our marketing consultants?", 2.minutes.ago),
        inbound("Yes, email works.", 1.minute.ago)
      ])
      slack_calls = []

      with_slack_handoff_stub(slack_calls, true) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Yes, email works.",
          reason: "customer_accepted_marketing_consultant_sms",
          source: "test"
        )

        assert result.slack_posted
        assert result.review_draft_saved
      end

      assert_equal 1, slack_calls.length
      metadata = stage.reload.metadata
      assert_equal "posted", metadata["sms_autopilot_handoff_state"]
      assert_equal "posted", metadata["sms_autopilot_slack_handoff_status"]
      assert_equal "owner@example.com", metadata["sms_autopilot_handoff_contact_email"]
      assert_equal "email", metadata["sms_autopilot_handoff_contact_preference"]
      assert metadata["sms_autopilot_handoff_contact_posted_at"].present?
      assert_includes metadata["comms_command_sms_draft_body"], "by email"
    end

    test "reset conversation does not reuse the CRM email" do
      reset_at = 5.minutes.ago
      stage = comm_stage(
        [
          outbound("Would it be helpful for me to get you connected with one of our marketing consultants?", 2.minutes.ago),
          inbound("Yes, email works.", 1.minute.ago)
        ],
        metadata: {
          "sms_discovery_reset" => true,
          "sms_conversation_reset_at" => reset_at.iso8601
        }
      )
      slack_calls = []

      with_slack_handoff_stub(slack_calls, true) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Yes, email works.",
          reason: "customer_accepted_marketing_consultant_sms",
          source: "test"
        )

        refute result.slack_posted
        assert result.review_draft_saved
      end

      assert_empty slack_calls
      metadata = stage.reload.metadata
      assert_nil metadata["sms_autopilot_handoff_contact_email"]
      assert_includes metadata["comms_command_sms_draft_body"], "What email"
    end

    test "generic contact request with known contact info still asks preference before posting" do
      stage = comm_stage([
        inbound("Can you have someone contact me", 1.minute.ago)
      ])
      slack_calls = []

      with_slack_handoff_stub(slack_calls, true) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Can you have someone contact me",
          reason: "human_requested_sms",
          source: "test"
        )

        refute result.handled
        refute result.slack_posted
        assert result.review_draft_saved
      end

      assert_empty slack_calls
      metadata = stage.reload.metadata
      assert_equal true, metadata["sms_autopilot_handoff_contact_pending"]
      assert_nil metadata["sms_autopilot_handoff_contact_posted_at"]
      assert_equal "collecting_contact", metadata["sms_autopilot_handoff_state"]
      assert_equal "am_support_contact_pending", metadata["comms_command_last_status"]
      assert_equal "owner@example.com", metadata["sms_autopilot_handoff_contact_email"]
      assert_equal "(555) 555-0100", metadata["sms_autopilot_handoff_contact_phone"]
      assert_nil metadata["sms_autopilot_handoff_contact_preference"]
      assert_includes metadata["comms_command_sms_draft_body"], "best way"
      assert_includes metadata["comms_command_sms_draft_body"], "email, call, or text"
      assert_includes metadata["comms_command_sms_draft_body"], "email or number we already have"
    end

    test "call this number during contact collection asks for time before posting" do
      stage = comm_stage(
        [
          inbound("Can you have someone contact me", 3.minutes.ago),
          outbound("Perfect. What is the best way for them to reach you: email, call, or text?", 2.minutes.ago),
          inbound("Call this number", 1.minute.ago)
        ],
        metadata: {
          "sms_autopilot_handoff_contact_pending" => true,
          "sms_autopilot_handoff_state" => "collecting_contact",
          "sms_autopilot_handoff_contact_permission" => true,
          "sms_autopilot_handoff_contact_email" => "owner@example.com",
          "sms_autopilot_handoff_contact_phone" => "(555) 555-0100"
        }
      )
      slack_calls = []

      with_slack_handoff_stub(slack_calls, true) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Call this number",
          reason: "am_support_contact_collection_sms",
          source: "test"
        )

        refute result.handled
        refute result.slack_posted
        assert result.review_draft_saved
      end

      assert_empty slack_calls
      metadata = stage.reload.metadata
      assert_equal true, metadata["sms_autopilot_handoff_contact_pending"]
      assert_nil metadata["sms_autopilot_handoff_contact_posted_at"]
      assert_equal "call", metadata["sms_autopilot_handoff_contact_preference"]
      assert_equal "(555) 555-0100", metadata["sms_autopilot_handoff_contact_phone"]
      assert_nil metadata["sms_autopilot_handoff_contact_time"]
      assert_includes metadata["comms_command_sms_draft_body"], "good time to call or text"
    end

    test "pending contact collection remains active even if prior run set posted marker" do
      stage = comm_stage(
        [
          inbound("Can you have someone contact me", 3.minutes.ago),
          outbound("Perfect. What is the best way for them to reach you: email, call, or text?", 2.minutes.ago),
          inbound("Call this number", 1.minute.ago)
        ],
        metadata: {
          "sms_autopilot_handoff_contact_pending" => true,
          "sms_autopilot_handoff_state" => "collecting_contact",
          "sms_autopilot_handoff_contact_posted_at" => 1.minute.ago.iso8601,
          "sms_autopilot_handoff_contact_permission" => true,
          "sms_autopilot_handoff_contact_email" => "owner@example.com",
          "sms_autopilot_handoff_contact_phone" => "(555) 555-0100"
        }
      )
      slack_calls = []

      assert InboundSmsHandoff.contact_collection_active?(stage)

      with_slack_handoff_stub(slack_calls, true) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Call this number",
          reason: "am_support_contact_collection_sms",
          source: "test"
        )

        refute result.handled
        refute result.slack_posted
        assert result.review_draft_saved
      end

      assert_empty slack_calls
      metadata = stage.reload.metadata
      assert_equal true, metadata["sms_autopilot_handoff_contact_pending"]
      assert_equal "call", metadata["sms_autopilot_handoff_contact_preference"]
      assert_nil metadata["sms_autopilot_handoff_contact_time"]
      assert_includes metadata["comms_command_sms_draft_body"], "good time to call or text"
    end

    test "pending rush handoff lets product and checkout questions continue" do
      stage = comm_stage(
        [
          inbound("Can I get the order rushed?", 3.minutes.ago),
          outbound("What is the best way for a marketing consultant to reach you?", 2.minutes.ago),
          inbound("I need to see the checkout link for signs", 1.minute.ago)
        ],
        metadata: {
          "sms_autopilot_handoff_contact_pending" => true,
          "sms_autopilot_handoff_contact_permission" => true,
          "sms_autopilot_handoff_contact_reason" => "rush_or_deadline_confirmation_sms"
        }
      )

      assert InboundSmsHandoff.contact_collection_active?(stage)
      refute InboundSmsHandoff.contact_collection_response?(stage, "I need to see the checkout link for signs")
      refute InboundSmsHandoff.contact_collection_response?(stage, "Can you tell me more about sign options?")
      assert InboundSmsHandoff.contact_collection_response?(stage, "Email")
      assert InboundSmsHandoff.contact_collection_response?(stage, "owner@example.com")
      assert InboundSmsHandoff.contact_collection_response?(stage, "Give me a call tomorrow afternoon")
      assert InboundSmsHandoff.contact_collection_response?(stage, "Text me Tuesday between 2 and 4 PM CST")
      assert InboundSmsHandoff.contact_collection_response?(stage, "Tuesday between 2 and 4 PM CST")
      assert InboundSmsHandoff.contact_collection_response?(stage, "Ring me next Wednesday at 10am")
      assert InboundSmsHandoff.contact_collection_response?(stage, "SMS is best during business hours")

      result = InboundSmsHandoff.call(
        stage: stage,
        body: "I need to see the checkout link for signs",
        source: "test"
      )

      refute result.handled
      refute result.review_draft_saved
    end

    test "consultant request followed by call me after 4 completes the handoff" do
      travel_to Time.find_zone("Central Time (US & Canada)").local(2026, 7, 13, 10, 36) do
        stage = comm_stage([
          inbound("Can I get a consultant to contact me?", 3.minutes.ago),
          outbound("What is the best way for them to reach you: email, call, or text?", 2.minutes.ago),
          inbound("Call me after 4", 1.minute.ago)
        ])
        slack_calls = []

        assert InboundSmsHandoff.required?("Can I get a consultant to contact me?", stage: stage)

        first_result = InboundSmsHandoff.call(
          stage: stage,
          body: "Can I get a consultant to contact me?",
          source: "test"
        )
        refute first_result.handled
        assert first_result.review_draft_saved
        assert_equal true, stage.reload.metadata["sms_autopilot_handoff_contact_permission"]

        legacy_metadata = stage.metadata.to_h.deep_dup.except("sms_autopilot_handoff_contact_permission")
        stage.update!(metadata: legacy_metadata)
        assert InboundSmsHandoff.contact_collection_response?(stage, "Call me after 4")

        with_slack_handoff_stub(slack_calls, true) do
          second_result = InboundSmsHandoff.call(
            stage: stage,
            body: "Call me after 4",
            source: "inbound_reply_job"
          )

          assert second_result.slack_posted
          assert second_result.review_draft_saved
        end

        assert_equal 1, slack_calls.length
        metadata = stage.reload.metadata
        assert_equal false, metadata["sms_autopilot_handoff_contact_pending"]
        assert_equal "call", metadata["sms_autopilot_handoff_contact_preference"]
        assert_equal "after 4", metadata["sms_autopilot_handoff_contact_time"].downcase
        assert_includes metadata["comms_command_sms_draft_body"], "by phone"
        assert_includes metadata["comms_command_sms_draft_body"], "around after 4"
      end
    end

    test "this number after four on Wednesdays infers a phone callback and completes handoff" do
      travel_to Time.find_zone("Central Time (US & Canada)").local(2026, 7, 13, 10, 36) do
        body = "This number after 4 on Wednesdays"
        stage = comm_stage(
          [
            outbound("What is the best way for a marketing consultant to reach you: email, text/SMS, or phone call?", 2.minutes.ago),
            inbound(body, 1.minute.ago)
          ],
          metadata: {
            "sms_autopilot_handoff_contact_pending" => true,
            "sms_autopilot_handoff_contact_permission" => true,
            "sms_autopilot_handoff_contact_phone" => "(555) 555-0100",
            "sms_autopilot_handoff_contact_reason" => "rush_or_deadline_confirmation_sms"
          }
        )
        slack_calls = []

        assert InboundSmsHandoff.contact_collection_response?(stage, body)
        with_slack_handoff_stub(slack_calls, true) do
          result = InboundSmsHandoff.call(stage: stage, body: body, source: "inbound_reply_job")

          assert result.slack_posted
          assert result.review_draft_saved
        end

        metadata = stage.reload.metadata
        assert_equal "call", metadata["sms_autopilot_handoff_contact_preference"]
        assert_equal "2026-07-15", metadata["sms_autopilot_handoff_contact_day"]
        assert_equal "2026-07-15T16:00:00-05:00", metadata["sms_autopilot_handoff_contact_not_before_at"]
        assert_equal false, metadata["sms_autopilot_handoff_contact_pending"]
        assert_equal 1, slack_calls.length
        assert_includes metadata["comms_command_sms_draft_body"], "Wednesday, July 15 after 4 PM Central"
      end
    end

    test "does not mark handoff posted when Slack declines the post" do
      stage = comm_stage([
        outbound("Would it be helpful for me to get you connected with one of our marketing consultants?", 2.minutes.ago),
        inbound("Yes, email works.", 1.minute.ago)
      ])

      with_slack_handoff_stub([], false) do
        result = InboundSmsHandoff.call(
          stage: stage,
          body: "Yes, email works.",
          reason: "customer_accepted_marketing_consultant_sms",
          source: "test"
        )

        refute result.slack_posted
      end

      metadata = stage.reload.metadata
      assert_equal "slack_failed", metadata["sms_autopilot_handoff_state"]
      assert_equal "failed", metadata["sms_autopilot_slack_handoff_status"]
      assert_nil metadata["sms_autopilot_handoff_contact_posted_at"]
    end

    test "existing support state without an owner still routes the ready handoff" do
      stage = comm_stage(
        [inbound("Call me after 4", 1.minute.ago)],
        metadata: {
          "comms_support_state" => "am_support",
          "comms_support_reason" => "human_requested_sms",
          "sms_autopilot_handoff_contact_pending" => true,
          "sms_autopilot_handoff_contact_permission" => true,
          "sms_autopilot_handoff_contact_phone" => "(555) 555-0100"
        }
      )
      owner = Struct.new(:id, :display_name, :email_address, keyword_init: true).new(
        id: "virtual:kristina-f",
        display_name: "Kristina F.",
        email_address: nil
      )
      route_calls = []
      slack_calls = []

      with_lead_router_stub(route_calls, owner) do
        with_slack_handoff_stub(slack_calls, true) do
          result = InboundSmsHandoff.call(stage: stage, body: "Call me after 4", source: "inbound_reply_job")

          assert result.slack_posted
          assert_equal owner, result.owner
        end
      end

      assert_equal 1, route_calls.length
      assert_equal 1, slack_calls.length
      assert_equal owner, slack_calls.first[:owner]
      assert_includes stage.reload.metadata["comms_command_sms_draft_body"], "I assigned Kristina F., who will follow up"
    end

    test "owner routing timeout still posts the handoff and saves confirmation" do
      stage = comm_stage(
        [inbound("Call me after 4", 1.minute.ago)],
        metadata: {
          "sms_autopilot_handoff_contact_pending" => true,
          "sms_autopilot_handoff_contact_permission" => true,
          "sms_autopilot_handoff_contact_phone" => "(555) 555-0100",
          "sms_autopilot_handoff_contact_reason" => "human_requested_sms"
        }
      )
      previous_timeout = ENV["WIZWIKI_COMMS_HANDOFF_ROUTE_TIMEOUT_SECONDS"]
      ENV["WIZWIKI_COMMS_HANDOFF_ROUTE_TIMEOUT_SECONDS"] = "1"
      slack_calls = []

      with_lead_router_stub([], -> { sleep 2 }) do
        with_slack_handoff_stub(slack_calls, true) do
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = InboundSmsHandoff.call(stage: stage, body: "Call me after 4", source: "inbound_reply_job")
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

          assert result.slack_posted
          assert result.review_draft_saved
          assert_operator elapsed, :<, 1.8
        end
      end

      assert_equal 1, slack_calls.length
      assert_equal "posted", stage.reload.metadata["sms_autopilot_slack_handoff_status"]
    ensure
      if previous_timeout.nil?
        ENV.delete("WIZWIKI_COMMS_HANDOFF_ROUTE_TIMEOUT_SECONDS")
      else
        ENV["WIZWIKI_COMMS_HANDOFF_ROUTE_TIMEOUT_SECONDS"] = previous_timeout
      end
    end

    test "rush request collects email preference before posting to Slack" do
      stage = comm_stage([
        inbound("I need the order rushed", 3.minutes.ago),
        outbound("What deadline do you need the signs by?", 2.minutes.ago),
        inbound("Tomorrow", 1.minute.ago)
      ])
      slack_calls = []

      with_slack_handoff_stub(slack_calls, true) do
        first_result = InboundSmsHandoff.call(
          stage: stage,
          body: "Tomorrow",
          source: "inbound_reply_job"
        )

        refute first_result.handled
        refute first_result.slack_posted
        assert first_result.review_draft_saved
        assert_equal "rush_or_deadline_confirmation_sms", first_result.reason
        assert_empty slack_calls

        pending = stage.reload.metadata
        assert_equal true, pending["sms_autopilot_handoff_contact_pending"]
        assert_equal true, pending["sms_autopilot_handoff_contact_permission"]
        assert_equal "waiting_for_contact_details", pending["sms_autopilot_slack_handoff_status"]
        assert_includes pending["comms_command_sms_draft_body"], "can't promise"
        assert_includes pending["comms_command_sms_draft_body"], "email, text/SMS, or phone call"

        second_result = InboundSmsHandoff.call(
          stage: stage,
          body: "Email",
          source: "inbound_reply_job"
        )

        refute second_result.handled
        assert second_result.slack_posted
        assert second_result.review_draft_saved
        confirmation = stage.reload.metadata["comms_command_sms_draft_body"]
        assert_includes confirmation, second_result.owner.display_name
        assert_includes confirmation, "by email at owner@example.com"
        assert_includes confirmation, "confirm rush availability"
        assert_includes confirmation, "keep texting me here"
      end

      assert_equal 1, slack_calls.length
      assert_includes slack_calls.first[:latest_body], "I need the order rushed"
      assert_includes slack_calls.first[:latest_body], "Tomorrow"

      metadata = stage.reload.metadata
      assert_equal "am_support", metadata["comms_support_state"]
      assert_equal "posted", metadata["sms_autopilot_slack_handoff_status"]
      assert_equal false, metadata["sms_autopilot_handoff_contact_pending"]
      assert_equal "email", metadata["sms_autopilot_handoff_contact_preference"]
      assert_equal "owner@example.com", metadata["sms_autopilot_handoff_contact_email"]
      assert_includes metadata["comms_command_sms_draft_body"], "by email"
      assert_equal true, metadata["sms_autopilot_handoff_conversation_continues"]
      assert_equal true, metadata["sms_autopilot_enabled"]
      assert_equal true, metadata["sms_listener_active"]
    end

    test "rush request waits for SMS timing before posting to Slack" do
      travel_to Time.find_zone("Central Time (US & Canada)").local(2026, 7, 13, 10, 36) do
        stage = comm_stage([
          inbound("I need the order rushed", 2.minutes.ago),
          inbound("Tomorrow", 1.minute.ago)
        ])
        slack_calls = []

        with_slack_handoff_stub(slack_calls, true) do
          InboundSmsHandoff.call(
            stage: stage,
            body: "Tomorrow",
            source: "inbound_reply_job"
          )
          sms_result = InboundSmsHandoff.call(
            stage: stage,
            body: "SMS",
            source: "inbound_reply_job"
          )

          refute sms_result.slack_posted
          assert_empty slack_calls
          waiting = stage.reload.metadata
          assert_equal "text", waiting["sms_autopilot_handoff_contact_preference"]
          assert_includes waiting["comms_command_sms_draft_body"], "good time to text"

          final_result = InboundSmsHandoff.call(
            stage: stage,
            body: "Anytime",
            source: "inbound_reply_job"
          )

          assert final_result.slack_posted
          confirmation = stage.reload.metadata["comms_command_sms_draft_body"]
          assert_includes confirmation, final_result.owner.display_name
          assert_includes confirmation, "by text at (555) 555-0100"
          assert_includes confirmation, "when convenient"
          assert_includes confirmation, "keep texting me here"
        end

        assert_equal 1, slack_calls.length
        metadata = stage.reload.metadata
        assert_equal "text", metadata["sms_autopilot_handoff_contact_preference"]
        assert_equal "anytime", metadata["sms_autopilot_handoff_contact_time"].downcase
        assert_equal "posted", metadata["sms_autopilot_slack_handoff_status"]
        assert_equal true, metadata["sms_autopilot_handoff_conversation_continues"]
      end
    end

    test "direct rush request requires immediate fulfillment escalation" do
      stage = comm_stage([inbound("Can you rush these signs?", 1.minute.ago)])

      assert InboundSmsHandoff.required?("Can you rush these signs?", stage: stage)
      assert_equal(
        "rush_or_deadline_confirmation_sms",
        InboundSmsHandoff.reason_for("Can you rush these signs?", stage: stage)
      )
    end

    test "bare deadline reply uses the preceding deadline question" do
      stage = comm_stage([
        outbound("What deadline do you need the signs by?", 2.minutes.ago),
        inbound("Tomorrow", 1.minute.ago)
      ])

      assert InboundSmsHandoff.required?("Tomorrow", stage: stage)
      assert_equal "rush_or_deadline_confirmation_sms", InboundSmsHandoff.reason_for("Tomorrow", stage: stage)
    end

    test "casual tomorrow statement without fulfillment context stays in bot scope" do
      stage = comm_stage([
        outbound("Would you like the pricing link?", 2.minutes.ago),
        inbound("I'll decide tomorrow", 1.minute.ago)
      ])

      refute InboundSmsHandoff.required?("I'll decide tomorrow", stage: stage)
    end

    private

    def comm_stage(thread, metadata: {}, crm_record: @crm_record)
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: crm_record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "SMS handoff state test",
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
        "status" => "sent",
        "from" => "+15555550999",
        "to" => "+15555550100",
        "body" => body,
        "provider" => "twilio",
        "provider_message_id" => "SM#{SecureRandom.hex(6).upcase}",
        "created_at" => at.iso8601
      }
    end

    def with_slack_handoff_stub(calls, response)
      original = SlackNotifier.method(:post_human_requested!)
      SlackNotifier.define_singleton_method(:post_human_requested!) do |**kwargs|
        calls << kwargs
        response
      end

      yield
    ensure
      SlackNotifier.define_singleton_method(:post_human_requested!, original)
    end

    def with_lead_router_stub(calls, owner)
      original = DealReports::CommsLeadRouter.method(:route!)
      DealReports::CommsLeadRouter.define_singleton_method(:route!) do |stage, **options|
        calls << { stage: stage, options: options }
        owner.respond_to?(:call) ? owner.call : owner
      end

      yield
    ensure
      DealReports::CommsLeadRouter.define_singleton_method(:route!, original)
    end
  end
end
