require "test_helper"
require "securerandom"

module Comms
  class InboundSmsRecoverySweepTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(
        name: "No Ghost #{suffix}",
        slug: "no-ghost-#{suffix}"
      )
      @user = users(:one)
      @crm_record = CrmRecord.create!(
        organization: @organization,
        name: "No Ghost Roofing",
        record_type: "deal",
        fingerprint: "no-ghost-#{suffix}"
      )
    end

    test "requeues stale pending draft so inbound SMS is not ghosted" do
      inbound = inbound_event("How much are 50 yard signs?", 14.minutes.ago, sid: "SMSTALE1")
      stage = comm_stage(
        thread: [inbound],
        metadata: {
          "comms_command_sms_draft" => {
            "pending" => true,
            "draft_source" => "pending",
            "created_at" => 12.minutes.ago.iso8601
          },
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => 12.minutes.ago.iso8601,
          "sms_reply_job_status" => "draft_pending"
        }
      )

      calls = []
      with_reply_job_stub(calls) do
        result = InboundSmsRecoverySweep.call(organization: @organization, limit: 10)

        assert_equal 1, result.fetch(:recovered)
      end

      assert_equal 1, calls.length
      metadata = stage.reload.metadata
      watchdog = metadata.fetch("sms_no_ghost_watchdog")
      assert_equal "requeued", watchdog.fetch("status")
      assert_equal "stale_draft_after_inbound", watchdog.fetch("reason")
      assert_equal "queued", metadata.fetch("sms_reply_job_status")
      assert_equal "reply_recovery_queued", metadata.fetch("comms_command_last_status")
      assert_equal 1, metadata.dig("sms_inbound_recovery_attempts_by_key", watchdog.fetch("reply_key"))
    end

    test "does not requeue a fresh active draft job" do
      stage = comm_stage(
        thread: [inbound_event("How much are 50 yard signs?", 3.minutes.ago, sid: "SMFRESH1")],
        metadata: {
          "comms_command_sms_draft" => {
            "pending" => true,
            "draft_source" => "pending",
            "created_at" => 2.minutes.ago.iso8601
          },
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => 2.minutes.ago.iso8601,
          "sms_reply_job_status" => "draft_pending"
        }
      )

      calls = []
      with_reply_job_stub(calls) do
        result = InboundSmsRecoverySweep.call(organization: @organization, limit: 10)

        assert_equal 0, result.fetch(:recovered)
        assert_equal 1, result.fetch(:skipped)
      end

      assert_empty calls
      assert_nil stage.reload.metadata["sms_no_ghost_watchdog"]
    end

    test "marks needs attention after repeated recovery attempts for same inbound" do
      inbound = inbound_event("How much are 50 yard signs?", 18.minutes.ago, sid: "SMLOOP1")
      reply_key = AutopilotReplyLock.key(
        inbound_sid: inbound.fetch("provider_message_id"),
        inbound_body: inbound.fetch("body"),
        from: inbound.fetch("from")
      )
      history = InboundSmsRecoverySweep::MAX_RECOVERIES_PER_INBOUND.times.map do
        {
          "status" => "requeued",
          "reply_key" => reply_key,
          "checked_at" => 5.minutes.ago.iso8601
        }
      end
      stage = comm_stage(
        thread: [inbound],
        metadata: {
          "comms_command_sms_draft" => {
            "pending" => true,
            "draft_source" => "pending",
            "created_at" => 16.minutes.ago.iso8601
          },
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => 16.minutes.ago.iso8601,
          "sms_reply_job_status" => "draft_pending",
          "sms_no_ghost_watchdog_history" => history
        }
      )

      calls = []
      with_reply_job_stub(calls) do
        result = InboundSmsRecoverySweep.call(organization: @organization, limit: 10)

        assert_equal 0, result.fetch(:recovered)
        assert_equal 1, result.fetch(:skipped)
      end

      assert_empty calls
      metadata = stage.reload.metadata
      assert_equal "needs_attention", metadata.dig("sms_no_ghost_watchdog", "status")
      assert_equal "max_recoveries_reached", metadata.dig("sms_no_ghost_watchdog", "reason")
      assert_equal "needs_attention", metadata.fetch("sms_reply_job_status")
      assert_equal "reply_needs_attention", metadata.fetch("comms_command_last_status")
    end

    test "persisted recovery attempts cannot be pushed out by rolling watchdog history" do
      inbound = inbound_event("How much are 50 yard signs?", 18.minutes.ago, sid: "SMPERSIST1")
      reply_key = AutopilotReplyLock.key(
        inbound_sid: inbound.fetch("provider_message_id"),
        inbound_body: inbound.fetch("body"),
        from: inbound.fetch("from")
      )
      stage = comm_stage(
        thread: [inbound],
        metadata: {
          "comms_command_sms_draft" => {
            "pending" => true,
            "draft_source" => "pending",
            "created_at" => 16.minutes.ago.iso8601
          },
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => 16.minutes.ago.iso8601,
          "sms_reply_job_status" => "draft_pending",
          "sms_inbound_recovery_attempts_by_key" => { reply_key => InboundSmsRecoverySweep::MAX_RECOVERIES_PER_INBOUND },
          "sms_no_ghost_watchdog_history" => 10.times.map { { "status" => "needs_attention", "reply_key" => reply_key } }
        }
      )

      calls = []
      with_reply_job_stub(calls) do
        InboundSmsRecoverySweep.call(organization: @organization, limit: 10)
      end

      assert_empty calls
      assert_equal "needs_attention", stage.reload.metadata["sms_reply_job_status"]
    end

    test "terminal quality rejection stops immediately instead of entering recovery loop" do
      inbound = inbound_event("500", 4.minutes.ago, sid: "SMQUALITY1")
      stage = comm_stage(
        thread: [inbound],
        metadata: {
          "comms_command_sms_draft" => {
            "draft_source" => "quality_rejected",
            "reason" => "SMS quality gate rejected the worker draft: asks_for_known_fit_field",
            "created_at" => 1.minute.ago.iso8601
          },
          "comms_command_background_status" => "rejected_quality_gate",
          "sms_reply_job_status" => "failed",
          "sms_reply_job_failed_at" => 1.minute.ago.iso8601,
          "sms_guardrail_retry_reason" => "asks_for_known_fit_field"
        }
      )

      calls = []
      with_reply_job_stub(calls) do
        InboundSmsRecoverySweep.call(organization: @organization, limit: 10)
      end

      assert_empty calls
      metadata = stage.reload.metadata
      assert_equal "needs_attention", metadata["sms_reply_job_status"]
      assert_equal "terminal_quality_gate:asks_for_known_fit_field", metadata.dig("sms_no_ghost_watchdog", "reason")
      assert_nil metadata["sms_auto_follow_up_enabled"]
      assert_nil metadata["sms_optional_follow_ups_enabled"]

      history_size = Array(metadata["sms_no_ghost_watchdog_history"]).size
      with_reply_job_stub(calls) do
        InboundSmsRecoverySweep.call(organization: @organization, limit: 10)
      end
      assert_equal history_size, Array(stage.reload.metadata["sms_no_ghost_watchdog_history"]).size
    end

    private

    def comm_stage(thread:, metadata: {})
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @crm_record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "No ghost watchdog test",
        metadata: base_metadata(thread).merge(metadata)
      )
    end

    def base_metadata(thread)
      latest_inbound = thread.reverse.find { |event| event["direction"] == "inbound" }
      {
        "stage_type" => "manual_comms",
        "sms_autopilot_enabled" => true,
        "sms_listener_last_inbound_at" => latest_inbound.fetch("created_at"),
        "sms_thread" => thread
      }
    end

    def inbound_event(body, at, sid:)
      {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "inbound",
        "status" => "received",
        "from" => "+15555550100",
        "to" => "+15555550999",
        "body" => body,
        "provider" => "twilio",
        "provider_message_id" => sid,
        "created_at" => at.iso8601
      }
    end

    def with_reply_job_stub(calls)
      original = InboundSmsReplyJob.method(:perform_later)
      InboundSmsReplyJob.define_singleton_method(:perform_later) do |**kwargs|
        calls << kwargs
      end
      yield
    ensure
      InboundSmsReplyJob.define_singleton_method(:perform_later, original)
    end
  end
end
