# frozen_string_literal: true

require "test_helper"
require "securerandom"

class TwilioWebhooksSmsBurstTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    suffix = SecureRandom.hex(4)
    organization = Organization.create!(name: "SMS burst #{suffix}", slug: "sms-burst-#{suffix}")
    crm_record = CrmRecord.create!(
      organization: organization,
      name: "SMS Burst Lead",
      record_type: "deal",
      fingerprint: "sms-burst-#{suffix}"
    )
    @stage = CrmRecordArtifact.create!(
      organization: organization,
      crm_record: crm_record,
      user: users(:one),
      artifact_type: "comm_staging",
      status: "aircall_sent",
      title: "SMS burst test",
      metadata: {
        "stage_type" => "manual_comms",
        "sms_reply_generation" => "generation-1",
        "sms_thread" => []
      }
    )
    @controller = TwilioWebhooksController.new
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
  end

  test "rapid inbound messages share one delayed reply job" do
    enqueue_reply(body: "Yard signs please", sid: "SM1")
    update_generation("generation-2", sid: "SM2")
    enqueue_reply(body: "Actually do you have any specials?", sid: "SM2")
    update_generation("generation-3", sid: "SM3")
    enqueue_reply(body: "I need the order rushed", sid: "SM3")

    jobs = enqueued_jobs.select { |job| job[:job] == Comms::InboundSmsReplyJob }
    assert_equal 1, jobs.length

    metadata = @stage.reload.metadata.to_h
    assert_equal "settle_coalesced", metadata["sms_reply_job_status"]
    assert_equal "generation-3", metadata["sms_reply_job_generation"]
    assert_equal 1, Array(metadata["sms_reply_jobs_recent"]).length
    assert_nil jobs.first[:args].first["generation"]
  end

  private

  def enqueue_reply(body:, sid:)
    @controller.send(
      :enqueue_inbound_sms_reply!,
      @stage.reload,
      from: "+13125550100",
      to: "+13125550200",
      body: body,
      sid: sid,
      provider: "twilio"
    )
  end

  def update_generation(generation, sid:)
    metadata = @stage.reload.metadata.to_h.deep_dup
    @stage.update!(
      metadata: metadata.merge(
        "sms_reply_generation" => generation,
        "sms_reply_generation_inbound_sid" => sid
      )
    )
  end
end
