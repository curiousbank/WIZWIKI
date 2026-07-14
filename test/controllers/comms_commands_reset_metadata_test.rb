require "test_helper"
require "ostruct"

class CommsCommandsResetMetadataTest < ActiveSupport::TestCase
  test "conversation reset strips AI discovery while preserving delivery settings" do
    controller = CommsCommandsController.new
    metadata = {
      "selected_phone_id" => "phone-1",
      "selected_recipient_email_id" => "email-1",
      "recipient_email_options" => [{ "id" => "email-1", "email" => "old@example.com" }],
      "manual_comms_contact_email" => "old@example.com",
      "sms_listener_active" => true,
      "sms_listener_to" => "+13135551212",
      "sms_writer_model" => "qwen3:30b",
      "sms_writer_model_label" => "Qwen",
      "contact_options" => [{ "id" => "contact-1", "name" => "Sample Contact", "company" => "Example Plumbing" }],
      "selected_contact_id" => "contact-1",
      "comms_bot_state" => {
        "contact_name" => "Sample Contact",
        "company_name" => "Example Plumbing",
        "route_code" => "LAWN_SIGNS",
        "product_interest" => "yard signs"
      },
      "product_interest_code" => "LAWN_SIGNS",
      "product_interest_label" => "Yard Signs",
      "sms_captured_product_interest" => "yard signs",
      "sms_captured_quantity" => "50",
      "sms_lane_monitor" => { "route_code" => "LAWN_SIGNS", "latest_body" => "signs" },
      "sms_guardrail_retry_instruction" => "old route-specific instruction",
      "sms_guardrail_retry_count" => 4,
      "ask_autopilot_pending_phase" => "drafting_message",
      "comms_command_sms_draft" => { "body" => "old yard sign draft" },
      "comms_command_sms_draft_body" => "old yard sign draft",
      "sms_inbound_recovery" => { "inbound_sid" => "SM123" },
      "sms_reply_job_status" => "draft_pending"
    }

    preserved = controller.send(:sms_conversation_reset_preserved_metadata, metadata)
    identity = controller.send(:sms_conversation_reset_identity, metadata, preserved)

    assert_equal "phone-1", preserved["selected_phone_id"]
    assert_equal true, preserved["sms_listener_active"]
    assert_equal "+13135551212", preserved["sms_listener_to"]
    assert_equal "qwen3:30b", preserved["sms_writer_model"]
    assert_equal({ "contact_name" => "Sample Contact", "company_name" => "Example Plumbing" }, identity)
    refute preserved.key?("selected_recipient_email_id")
    refute preserved.key?("recipient_email_options")
    refute preserved.key?("manual_comms_contact_email")

    refute preserved.key?("comms_bot_state")
    refute preserved.key?("product_interest_code")
    refute preserved.key?("product_interest_label")
    refute preserved.key?("sms_captured_product_interest")
    refute preserved.key?("sms_captured_quantity")
    refute preserved.key?("sms_lane_monitor")
    refute preserved.key?("sms_guardrail_retry_instruction")
    refute preserved.key?("sms_guardrail_retry_count")
    refute preserved.key?("ask_autopilot_pending_phase")
    refute preserved.key?("comms_command_sms_draft")
    refute preserved.key?("comms_command_sms_draft_body")
    refute preserved.key?("sms_inbound_recovery")
    refute preserved.key?("sms_reply_job_status")
  end

  test "auto thumper reset strips lane monitor metadata too" do
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "sms_lane_monitor"
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "sms_guardrail_retry_instruction"
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "ask_autopilot_pending_phase"
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "recipient_email_options"
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "selected_recipient_email_id"
    assert_includes TwilioWebhooksController::AUTO_THUMPER_RESET_METADATA_KEYS, "manual_comms_contact_email"
  end

  test "stale sms send guard blocks browser body after newer inbound cleared draft" do
    controller = CommsCommandsController.new
    inbound_at = Time.zone.parse("2026-07-09 16:32:55")
    stage = OpenStruct.new(
      metadata: {
        "comms_command_sms_draft_body" => nil,
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "outbound",
            "body" => "Old staged answer",
            "created_at" => (inbound_at - 5.minutes).iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "body" => "Actually I want postcards",
            "created_at" => inbound_at.iso8601
          }
        ]
      }
    )

    reason = controller.send(:stale_sms_draft_send_reason, stage, "Old staged answer")

    assert_match(/newer inbound text cleared/i, reason)
  end

  test "stale sms send guard allows fresh draft after latest inbound" do
    controller = CommsCommandsController.new
    inbound_at = Time.zone.parse("2026-07-09 16:32:55")
    draft_at = inbound_at + 30.seconds
    body = "For postcards, the standard EDDM route starts at $399."
    stage = OpenStruct.new(
      metadata: {
        "comms_command_sms_draft_body" => body,
        "comms_command_sms_draft" => { "created_at" => draft_at.iso8601 },
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "inbound",
            "body" => "Do you have any specials?",
            "created_at" => inbound_at.iso8601
          }
        ]
      }
    )

    assert_nil controller.send(:stale_sms_draft_send_reason, stage, body)
    assert_nil controller.send(:stale_sms_draft_send_reason, stage, "Edited: #{body}")
  end

  test "sms draft fingerprint guard blocks old tab after staged draft changes" do
    controller = CommsCommandsController.new
    old_body = "Old yard sign draft"
    new_body = "Fresh postcard draft"
    stage = OpenStruct.new(
      metadata: {
        "comms_command_sms_draft_body" => new_body,
        "sms_reply_generation" => "generation-new"
      }
    )

    reason = controller.send(
      :sms_draft_fingerprint_mismatch_reason,
      stage,
      Digest::SHA1.hexdigest(old_body),
      "generation-new"
    )

    assert_match(/reviewed draft changed/i, reason)
    assert_nil controller.send(
      :sms_draft_fingerprint_mismatch_reason,
      stage,
      Digest::SHA1.hexdigest(new_body),
      "generation-new"
    )
  end

  test "sms draft fingerprint guard blocks old generation" do
    controller = CommsCommandsController.new
    body = "Fresh postcard draft"
    stage = OpenStruct.new(
      metadata: {
        "comms_command_sms_draft_body" => body,
        "sms_reply_generation" => "generation-new"
      }
    )

    reason = controller.send(
      :sms_draft_fingerprint_mismatch_reason,
      stage,
      Digest::SHA1.hexdigest(body),
      "generation-old"
    )

    assert_match(/newer inbound generation/i, reason)
  end
end
