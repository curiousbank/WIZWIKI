# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class AutopilotLearningTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Autopilot Learning #{suffix}", slug: "autopilot-learning-#{suffix}")
      @user = users(:one)
      @crm_record = CrmRecord.create!(
        organization: @organization,
        name: "Learning Roofing",
        record_type: "deal",
        fingerprint: "learning-#{suffix}"
      )
      @service = AutopilotLearning.new(organization: @organization, dry_run: true)
    end

    test "does not promote simulator transcripts as customer voice" do
      stage = comm_stage(clean_thread, "ask_autopilot_test" => true)
      memory = @service.send(:memory_for, stage)

      assert memory[:simulation]
      refute @service.send(:promotable?, memory)
    end

    test "quarantines a clean engaged production thread for human review" do
      stage = comm_stage(clean_thread)
      memory = @service.send(:memory_for, stage)

      assert_empty memory[:quality_issues]
      assert @service.send(:promotable?, memory)

      metadata = @service.send(:training_metadata, stage, memory)
      assert_equal "pending_review", metadata["learning_status"]
      assert_equal "quarantined_memory", metadata["retrieval_role"]
      assert_equal false, metadata["composition_eligible"]
      assert_equal true, metadata["human_review_required"]
      assert_operator metadata["candidate_score"], :>=, 70
      assert_includes metadata["candidate_evidence"], "automated quality and consultant-voice gates passed"
    end

    test "rejects fallback wording and stale link metadata from promotion" do
      events = clean_thread
      events[1]["draft_source"] = "fallback"
      stage = comm_stage(events, "shopify_link_sent_at" => 1.hour.ago.iso8601)
      memory = @service.send(:memory_for, stage)

      refute memory[:link_sent]
      refute @service.send(:promotable?, memory)
    end

    test "ignores operational notices and evaluates multilingual drafts in English" do
      events = clean_thread + [
        outbound("¿Quieres que te envíe el enlace?", 30.seconds.ago).merge(
          "english_body" => "Would you like me to send the link?"
        ),
        outbound("Reply with your preferred language.", 20.seconds.ago).merge(
          "language_preference_notice" => true
        ),
        outbound("Understood. I'll stop messaging you.", 10.seconds.ago).merge(
          "do_not_contact_confirmation" => true
        ),
        outbound("Provider failure", 5.seconds.ago).merge("status" => "failed")
      ]

      filtered = @service.send(:sms_events, "sms_thread" => events)

      assert_includes filtered.map { |event| event["body"] }, "Would you like me to send the link?"
      refute_includes filtered.map { |event| event["body"] }, "Reply with your preferred language."
      refute_includes filtered.map { |event| event["body"] }, "Understood. I'll stop messaging you."
      refute_includes filtered.map { |event| event["body"] }, "Provider failure"
    end

    private

    def clean_thread
      [
        inbound("How much are 50 yard signs?", 4.minutes.ago),
        outbound("50 yard signs are $249, including design, stakes, and shipping. That quantity is a practical jobsite run. Want the checkout link? Reply STOP to opt out.", 3.minutes.ago),
        inbound("Can I approve the proof first?", 2.minutes.ago),
        outbound("After checkout, the intake form collects your logo and notes. You review the proof before production starts. Want me to send the 50-sign link?", 1.minute.ago)
      ]
    end

    def comm_stage(thread, extra_metadata = {})
      CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: @crm_record,
        user: @user,
        artifact_type: "comm_staging",
        status: "aircall_sent",
        title: "Autopilot learning test",
        metadata: {
          "stage_type" => "manual_comms",
          "sms_thread" => thread
        }.merge(extra_metadata)
      )
    end

    def inbound(body, at)
      sms_event("inbound", "received", body, at)
    end

    def outbound(body, at)
      sms_event("outbound", "delivered", body, at).merge(
        "draft_source" => "thumper",
        "sms_quality_gate" => "passed"
      )
    end

    def sms_event(direction, status, body, at)
      {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => direction,
        "status" => status,
        "body" => body,
        "provider" => "twilio",
        "created_at" => at.iso8601
      }
    end
  end
end
