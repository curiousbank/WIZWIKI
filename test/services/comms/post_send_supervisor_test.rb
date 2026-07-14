require "test_helper"
require "securerandom"

module Comms
  class PostSendSupervisorTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(
        name: "Post Send #{suffix}",
        slug: "post-send-#{suffix}"
      )
      @user = users(:one)
      @crm_record = CrmRecord.create!(
        organization: @organization,
        name: "Test Roofing",
        record_type: "deal",
        fingerprint: "post-send-#{suffix}"
      )
    end

    test "does not invent a correction when no reviewed catalog is configured" do
      outbound = {
        "id" => "out-1",
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "sent",
        "to" => "+15555550100",
        "from" => "+15555550999",
        "body" => "For 100 signs, the price is $399. Here is the checkout link: https://shop.example.invalid/products/24x18-yard-signs-sample_owner",
        "provider_message_id" => "SMOUT1",
        "created_at" => Time.current.iso8601
      }
      stage = comm_stage([
        inbound("How much for 50 yard signs?", 2.minutes.ago),
        outbound
      ])

      with_sms_delivery_stub(->(**) { raise "should not send" }) do
        result = PostSendSupervisor.call(stage: stage, outbound_event: outbound, source: "test")

        assert_equal "skipped", result.fetch("supervisor_status")
        assert_equal "no_high_confidence_issue", result.fetch("reason")
      end

      bodies = Array(stage.reload.metadata["sms_thread"]).map { |event| event.to_h["body"].to_s }
      assert_equal outbound["body"], bodies.last
      refute Array(stage.metadata["sms_thread"]).last.to_h["post_send_supervisor"]
    end

    test "does not correct after hard stop" do
      outbound = {
        "id" => "out-stop",
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "sent",
        "to" => "+15555550100",
        "from" => "+15555550999",
        "body" => "For 100 signs, the price is $399.",
        "created_at" => 2.minutes.ago.iso8601
      }
      stage = comm_stage([
        inbound("How much for 50 yard signs?", 4.minutes.ago),
        outbound,
        inbound("STOP", 1.minute.ago)
      ])

      with_sms_delivery_stub(->(**) { raise "should not send" }) do
        result = PostSendSupervisor.call(stage: stage, outbound_event: outbound, source: "test")

        assert_equal "blocked", result.fetch("supervisor_status")
        assert_equal "hard_stop_seen", result.fetch("reason")
      end
    end

    test "does not request contact preference again after a completed handoff" do
      outbound = {
        "id" => "out-handoff",
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "sent",
        "to" => "+15555550100",
        "from" => "+15555550999",
        "body" => "Perfect. Peyton will be contacting you by email. I let them know your contact preferences.",
        "created_at" => Time.current.iso8601
      }
      stage = comm_stage(
        [
          inbound("Can you show me the sign checkout link", 1.minute.ago),
          outbound
        ],
        "sms_autopilot_handoff_contact_preference" => "email",
        "sms_autopilot_handoff_contact_email" => "owner@example.com",
        "sms_autopilot_handoff_contact_posted_at" => 2.minutes.ago.iso8601,
        "sms_autopilot_slack_handoff_at" => 2.minutes.ago.iso8601
      )

      with_sms_delivery_stub(->(**) { raise "should not send" }) do
        result = PostSendSupervisor.call(stage: stage, outbound_event: outbound, source: "test")

        assert_equal "skipped", result.fetch("supervisor_status")
        assert_equal "no_high_confidence_issue", result.fetch("reason")
        refute_includes Array(result["issue_codes"]), "handoff_details_missing"
      end
    end

    private

    def comm_stage(thread, metadata = {})
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @crm_record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "SMS post-send supervisor test",
        metadata: {
          "sms_thread" => thread,
          "sms_autopilot_enabled" => true
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
        "created_at" => at.iso8601
      }
    end

    def with_sms_delivery_stub(response)
      original = Comms::SmsProvider.method(:deliver!)
      replacement = response.respond_to?(:call) ? response : ->(**) { response }

      Comms::SmsProvider.define_singleton_method(:deliver!) do |**kwargs|
        replacement.call(**kwargs)
      end

      yield
    ensure
      Comms::SmsProvider.define_singleton_method(:deliver!, original)
    end
  end
end
