require "digest"
require "ostruct"
class TwilioWebhooksController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :verify_authenticity_token

  GENERIC_COMMS_IDENTITY_VALUES = [
    "wizwiki comms",
    "sample comms",
    "manual comms",
    "choose in lab",
    "contact",
    "customer"
  ].freeze
  AUTO_THUMPER_COMMAND_PATTERN = /\A\s*\*?\s*\(?\s*(?:auto|start|restart|reset)\s+thumper\s*\)?\s*\z/i.freeze
  AUTO_THUMPER_RESET_METADATA_KEYS = %w[
    comms_bot_state
    campaign_fit
    current_next_text
    processing_code
    processing_label
    processing_next_step
    processing_summary
    processing_source
    processing_updated_at
    product_interest_code
    product_interest_label
    product_interest
    captured_contact_name
    captured_company_name
    captured_industry
    industry
    company_industry
    crm_industry
    industry_strategy_label
    industry_strategy
    business_context
    captured_email
    captured_phone
    captured_zip
    captured_city
    captured_state
    captured_country
    sms_captured_contact_name
    sms_captured_company_name
    sms_captured_industry
    sms_captured_email
    sms_captured_phone
    sms_captured_zip
    sms_captured_city
    sms_captured_state
    sms_captured_country
    sms_captured_budget
    sms_captured_quantity
    sms_captured_product_interest
    sms_lane_monitor
    sms_lane_monitor_updated_at
    email_opt_in
    contact_preference
    preferred_contact_window
    preferred_contact_days
    preferred_contact_times
    proof_delivery_email
    proof_delivery_method
    proof_delivery_requested_at
    location_capture_last
    manual_comms_zip
    manual_comms_contact_email
    recipient_email_options
    selected_recipient_email_id
    shopify_link
    shopify_link_sent_at
    comms_link_reached_at
    checkout_url
    product_key
    product_label
    route_code
    comms_command_sms_draft_body
    comms_command_sms_draft
    comms_command_sms_prompt
    comms_command_sms_default_objective
    comms_command_sms_sent_draft_at
    comms_command_sms_sent_draft_sha1
    sms_draft_history
    aircall_composed_sms_body
    composed_sms_body
    selected_sms_id
    sms_options
    comms_command_background_question_id
    comms_command_background_status
    comms_command_background_error
    comms_command_background_at
    comms_command_background_running_at
    comms_command_background_failed_at
    comms_command_background_provider
    comms_command_late_worker_question_id
    comms_command_late_worker_applied_at
    sms_reply_generation
    sms_reply_generation_superseded_at
    sms_reply_generation_superseded_reason
    sms_reply_generation_superseded_by_user_id
    sms_reply_generation_superseded_by
    sms_reply_generation_superseded_question_ids
    sms_reply_generation_at
    sms_reply_generation_inbound_id
    sms_reply_generation_inbound_sid
    sms_reply_job_generation
    sms_reply_job_status
    sms_reply_job_queued_at
    sms_reply_job_running_at
    sms_reply_job_completed_at
    sms_reply_job_failed_at
    sms_reply_jobs_recent
    sms_reply_rate_limited_at
    sms_reply_rate_limited_until
    sms_reply_last_stale_generation
    sms_reply_last_stale_at
    sms_reply_last_stale_provider
    sms_guardrail_retry_key
    sms_guardrail_retry_count
    sms_guardrail_retry_reason
    sms_guardrail_retry_instruction
    sms_guardrail_retry_last_question_id
    sms_guardrail_retry_rejected_question_id
    sms_guardrail_retry_at
    sms_inbound_recovery
    sms_inbound_recovery_count
    ask_autopilot_pending_started_at
    ask_autopilot_pending_phase
    sms_autopilot_completed_at
    sms_autopilot_completion_sent_at
    sms_autopilot_slack_human_requested_at
    sms_autopilot_slack_completion_without_purchase_at
    sms_autopilot_slack_handoff_at
    sms_autopilot_slack_handoff_status
    sms_autopilot_slack_handoff_status_at
    sms_autopilot_slack_handoff_error
    sms_autopilot_slack_handoff_queued_at
    sms_autopilot_slack_pending_body
    sms_autopilot_slack_last_reason
    sms_autopilot_am_support_enabled_at
    sms_autopilot_handoff_contact_pending
    sms_autopilot_handoff_contact_started_at
    sms_autopilot_handoff_contact_updated_at
    sms_autopilot_handoff_contact_latest_body
    sms_autopilot_handoff_contact_reason
    sms_autopilot_handoff_contact_preference
    sms_autopilot_handoff_contact_email
    sms_autopilot_handoff_contact_phone
    sms_autopilot_handoff_contact_time
    sms_autopilot_handoff_contact_permission
    sms_autopilot_handoff_contact_ready_at
    sms_autopilot_handoff_contact_posted_at
    comms_support_state
    comms_support_state_at
    comms_support_reason
    comms_support_source
    comms_support_latest_body
    comms_routed_to_user_id
    comms_routed_to_user_name
    comms_routed_to_user_first_name
    comms_routed_to_user_email
    comms_routed_to_hubspot_owner_id
    comms_route_claimed_at
    comms_route_claim_reason
    comms_route_claim_load
    comms_route_claim_order
    comms_route_claim_cursor
    comms_route_claim_history
    comms_route_claim_pool
    comms_route_previous_user_name
    comms_route_previous_user_id
    contact_owner_code
    contact_owner_status
    contact_owner_source
    contact_owner_assigned_at
    hubspot_owner_property
    hubspot_owner_write_pending
    sms_autopilot_last_error
    sms_autopilot_last_error_at
    sms_autopilot_last_status
    sms_autopilot_last_status_at
    sms_autopilot_sent_count
    sms_autopilot_last_sent_at
    sms_autopilot_started_at
    sms_autopilot_started_with_opener
    sms_autopilot_started_with_data_grab
    sms_autopilot_started_with_next_text
    sms_autopilot_last_reply_to_sid
    sms_copilot_requested_at
    sms_copilot_requested_by_user_id
    sms_copilot_requested_by
    sms_copilot_last_question_id
    sms_language_last_detected_code
    sms_language_last_detected_label
    sms_language_last_detected_at
    sms_language_last_inbound_original
    sms_language_last_inbound_english
    sms_language_last_outbound_english
    sms_language_last_outbound_translated
    sms_language_last_outbound_code
    sms_language_last_outbound_label
    sms_language_last_outbound_at
    sms_language_last_error
    sms_language_last_error_at
    sms_language_preferred_code
    sms_language_preferred_label
    sms_language_preferred_at
    sms_language_preference_notice_sent_at
    sms_language_preference_notice_body
    sms_language_preference_notice_sid
    comms_support_state
    comms_support_state_at
    comms_support_reason
    comms_support_source
    comms_support_at
    comms_support_latest_body
    comms_route_claim_reason
  ].freeze
INDUSTRY_COMPANY_KEYWORDS = [
  [/\b(roofing|roofers?|roof|exteriors?|siding|gutters?)\b/i, "Roofing"],
  [/\b(plumbing|plumber)\b/i, "Plumbing"],
  [/\b(hvac|heating|cooling|air conditioning|furnace)\b/i, "HVAC"],
  [/\b(electric|electrical|electrician)\b/i, "Electrical"],
  [/\b(pool\s*(?:service|services|cleaning|care|maintenance)|pools?\b|spa\s*(?:service|services|care))\b/i, "Pool Services"],
  [/\b(lawn|landscap|mowing|turf|irrigation)\b/i, "Lawn & Landscaping"],
  [/\b(cleaning|janitorial|maid|pressure washing|power washing)\b/i, "Cleaning"],
  [/\b(painting|painter)\b/i, "Painting"],
  [/\b(concrete|cement|masonry|paving|asphalt)\b/i, "Concrete & Paving"],
  [/\b(remodel|renovation|construction|contractor|builder|carpentry)\b/i, "Home Improvement"],
  [/\b(pest|termite|exterminat)\b/i, "Pest Control"],
  [/\b(windows?|doors?|garage doors?)\b/i, "Windows & Doors"],
  [/\b(solar|energy)\b/i, "Solar"],
  [/\b(tree|arbor|stump)\b/i, "Tree Service"],
  [/\b(flooring|carpet|tile|hardwood)\b/i, "Flooring"],
  [/\b(restoration|water damage|fire damage|mitigation)\b/i, "Restoration"]
].freeze

  def sms
    payload = params.to_unsafe_h
    receipt = nil
    from = params[:From].to_s
    to = params[:To].to_s
    body = params[:Body].to_s.strip
    sid = params[:MessageSid].to_s.presence || params[:SmsSid].to_s.presence
    status = params[:MessageStatus].to_s.presence || params[:SmsStatus].to_s.presence
    context = twilio_context

    if delivery_status_callback?(sid: sid, status: status, body: body)
      update_delivery_status!(sid: sid, status: status)
      render xml: "<Response></Response>", content_type: "text/xml"
      return
    end

    receipt = record_inbound_sms_receipt!(
      provider: "twilio",
      from: from,
      to: to,
      body: body,
      sid: sid,
      context: context,
      payload: payload
    )
    unless webhook_authorized?
      mark_inbound_sms_receipt_unauthorized!(receipt)
      return head :unauthorized
    end

    auto_thumper_command = auto_thumper_command?(body)
    stage = find_stage_for_sms(from: from, to: to, force_broad: auto_thumper_command)

    if stage.present?
      mark_inbound_sms_receipt_matched!(receipt, stage)
      if append_inbound_sms!(stage, from: from, to: to, body: body, sid: sid, twilio_context: context)
        if auto_thumper_command
          handle_auto_thumper_command!(stage.reload, from: from, to: to, body: body, sid: sid, provider: "twilio")
        elsif do_not_contact_intent?(body) && !consume_first_stop_for_bot_bridge!(stage, body, inbound_sid: sid, provider: "twilio")
          handle_do_not_contact!(stage, from: from, to: to, inbound_sid: sid, provider: "twilio")
        else
          enqueue_inbound_sms_reply!(stage, from: from, to: to, body: body, sid: sid, provider: "twilio")
        end
        defer_stage_memory!(stage)
      end
    else
      mark_inbound_sms_receipt_unmatched!(receipt)
      Rails.logger.info("[TwilioWebhook] no comm stage matched inbound sms from=#{masked_phone(from)} to=#{masked_phone(to)} sid=#{sid}")
    end

    render xml: "<Response></Response>", content_type: "text/xml"
  rescue StandardError => error
    mark_inbound_sms_receipt_failed!(receipt, error, phase: "twilio_sms_webhook") if defined?(receipt) && receipt.present?
    Rails.logger.warn("[TwilioWebhook] sms failed #{error.class}: #{error.message}")
    render xml: "<Response></Response>", content_type: "text/xml", status: :ok
  end

  def heymarket
    payload = params.to_unsafe_h
    receipt = nil
    event_type = payload["type"].to_s
    data = payload["event_data"].to_h
    from = data["phone"].presence || data["phone_number"].presence || data["from"].presence
    to = data["to"].presence || ENV["HEYMARKET_OUTBOUND_INBOX_ID"].presence || ENV["HAYMARKET_OUTBOUND_INBOX_ID"].presence
    body = data["text"].presence || data["body"].presence || data["message"].presence
    sid = data["id"].presence || payload["id"].presence
    context = heymarket_context(payload)

    if heymarket_text_payload?(payload, data)
      receipt = record_inbound_sms_receipt!(
        provider: "haymarket",
        from: from,
        to: to,
        body: body,
        sid: sid,
        context: context,
        payload: payload
      )
    end
    unless heymarket_webhook_authorized?(payload)
      mark_inbound_sms_receipt_unauthorized!(receipt)
      return head :unauthorized
    end
    unless heymarket_inbound_message_event?(payload, data)
      mark_inbound_sms_receipt_ignored!(receipt, reason: "non_inbound_message_event", event_type: event_type)
      Rails.logger.info("[HeymarketWebhook] ignored non-inbound message event type=#{event_type.presence || 'blank'} sid=#{sid}") if receipt.present?
      return head :ok
    end

    auto_thumper_command = auto_thumper_command?(body)
    stage = find_stage_for_sms(from: from, to: to, force_broad: auto_thumper_command)

    if stage.present?
      mark_inbound_sms_receipt_matched!(receipt, stage)
      if append_inbound_sms!(stage, from: from, to: to, body: body, sid: sid, twilio_context: context, provider: "haymarket")
        if auto_thumper_command
          handle_auto_thumper_command!(stage.reload, from: from, to: to, body: body, sid: sid, provider: "haymarket")
        elsif do_not_contact_intent?(body) && !consume_first_stop_for_bot_bridge!(stage, body, inbound_sid: sid, provider: "haymarket")
          handle_do_not_contact!(stage, from: from, to: to, inbound_sid: sid, provider: "haymarket")
        else
          enqueue_inbound_sms_reply!(stage, from: from, to: to, body: body, sid: sid, provider: "haymarket")
        end
        defer_stage_memory!(stage)
      end
    else
      mark_inbound_sms_receipt_unmatched!(receipt)
      Rails.logger.info("[HeymarketWebhook] no comm stage matched inbound sms from=#{masked_phone(from)} sid=#{sid}")
    end

    head :ok
  rescue StandardError => error
    mark_inbound_sms_receipt_failed!(receipt, error, phase: "heymarket_sms_webhook") if defined?(receipt) && receipt.present?
    Rails.logger.warn("[HeymarketWebhook] sms failed #{error.class}: #{error.message}")
    head :ok
  end

  private

  def delivery_status_callback?(sid:, status:, body:)
    sid.present? &&
      status.to_s.in?(%w[queued accepted scheduled sending sent delivered undelivered failed canceled]) &&
      body.blank?
  end

  def update_delivery_status!(sid:, status:)
    base_scope = CrmRecordArtifact
      .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
      .where("crm_record_artifacts.updated_at > ?", 180.days.ago)

    stage = base_scope
      .where("crm_record_artifacts.metadata ->> 'sms_listener_last_outbound_sid' = ?", sid.to_s)
      .order(updated_at: :desc)
      .first
    stage ||= base_scope
      .where("crm_record_artifacts.metadata @> ?", { sms_thread: [{ provider_message_id: sid.to_s }] }.to_json)
      .order(updated_at: :desc)
      .first

    if stage.blank?
      Rails.logger.info("[TwilioWebhook] no comm stage matched delivery status sid=#{sid} status=#{status}")
      return false
    end

    metadata = stage.metadata.to_h.deep_dup
    event_status = normalized_outbound_status(provider_result: { "status" => status })
    error_message = params[:ErrorMessage].to_s.presence
    error_code = params[:ErrorCode].to_s.presence
    thread = Array(metadata["sms_thread"]).map do |event|
      event = event.to_h
      next event unless event["provider_message_id"].to_s == sid.to_s

      event.merge(
        "status" => event_status,
        "provider_status" => status,
        "provider_error_code" => error_code,
        "provider_error_message" => error_message,
        "provider_status_updated_at" => Time.current.iso8601
      ).compact_blank
    end

    latest = thread.reverse.find { |event| event.to_h["provider_message_id"].to_s == sid.to_s }.to_h
    am_support = metadata["comms_support_state"].to_s == "am_support"
    stage.update!(
      status: event_status == "failed" ? "aircall_failed" : stage.status,
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "comms_command_last_channel" => am_support ? metadata["comms_command_last_channel"] : (latest["channel"].presence || metadata["comms_command_last_channel"]),
        "comms_command_last_status" => am_support ? metadata["comms_command_last_status"] : (latest["status"].presence || metadata["comms_command_last_status"]),
        "comms_command_last_at" => Time.current.iso8601,
        "comms_command_last_error" => error_message.presence || metadata["comms_command_last_error"]
      ).compact_blank
    )
    true
  end

  def webhook_authorized?
    secret = ENV["TWILIO_WEBHOOK_SECRET"].presence
    return true if secret.blank?

    supplied = params[:token].to_s
    supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(supplied, secret)
  end

  def heymarket_webhook_authorized?(payload)
    secret =
      ENV["HEYMARKET_WEBHOOK_TOKEN"].presence ||
      ENV["HAYMARKET_WEBHOOK_TOKEN"].presence ||
      ENV["HEYMARKET_WEBHOOK_AUTH"].presence ||
      ENV["HAYMARKET_WEBHOOK_AUTH"].presence ||
      ENV["HEYMARKET_URL_AUTH"].presence ||
      ENV["HAYMARKET_URL_AUTH"].presence
    return !Rails.env.production? if secret.blank?

    supplied =
      payload["token"].presence ||
      payload["auth"].presence ||
      payload["webhook_auth"].presence ||
      request.headers["X-Heymarket-Webhook-Token"].presence ||
      request.headers["X-Heymarket-Webhook-Auth"].presence
    supplied = supplied.to_s
    supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(supplied, secret)
  end

  def heymarket_text_payload?(payload, data)
    payload = payload.to_h
    data = data.to_h
    payload["id"].to_s.present? ||
      data["id"].to_s.present? ||
      data["phone"].to_s.present? ||
      data["phone_number"].to_s.present? ||
      data["from"].to_s.present? ||
      data["text"].to_s.present? ||
      data["body"].to_s.present? ||
      data["message"].to_s.present?
  end

  def heymarket_inbound_message_event?(payload, data)
    payload = payload.to_h
    data = data.to_h
    event_type = payload["type"].to_s
    direction = data["direction"].presence || data["message_direction"].presence
    return false if direction.to_s.match?(/\A(?:out|outbound|sent)\z/i)
    return true if direction.to_s.match?(/\A(?:in|inbound|received)\z/i)
    return true if event_type.in?(%w[message_recieved message_received message.received])

    false
  end

  def find_stage_for_sms(from:, to:, force_broad: false)
    from_tail = phone_tail(from)
    to_tail = phone_tail(to)
    return nil if from_tail.blank?

    base_scope = CrmRecordArtifact
      .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
      .where("crm_record_artifacts.updated_at > ?", 180.days.ago)

    listener_scope = base_scope
      .where("crm_record_artifacts.metadata ->> 'sms_listener_active' = ?", "true")
      .where(
        "crm_record_artifacts.metadata ->> 'sms_listener_until' IS NULL OR crm_record_artifacts.metadata ->> 'sms_listener_until' >= ?",
        Time.current.iso8601
      )

    listener_match = listener_scope
      .where("regexp_replace(coalesce(crm_record_artifacts.metadata ->> 'sms_listener_to', ''), '[^0-9]', '', 'g') LIKE ?", "%#{from_tail}")
      .where("regexp_replace(coalesce(crm_record_artifacts.metadata ->> 'sms_listener_from', ''), '[^0-9]', '', 'g') LIKE ?", "%#{to_tail}") if to_tail.present?
    matched_listener = listener_match&.order(updated_at: :desc)&.first
    return matched_listener if matched_listener.present?
    return nil unless force_broad || sms_broad_lookup_enabled?

    recent_ids = base_scope.order(updated_at: :desc).limit(sms_fallback_lookup_limit).pluck(:id)
    return nil if recent_ids.blank?

    scope = base_scope.where(id: recent_ids)
      .where("regexp_replace(crm_record_artifacts.metadata::text, '[^0-9]', '', 'g') LIKE ?", "%#{from_tail}%")

    if to_tail.present?
      matched_to = scope.where("regexp_replace(crm_record_artifacts.metadata::text, '[^0-9]', '', 'g') LIKE ?", "%#{to_tail}%").order(updated_at: :desc).first
      return matched_to if matched_to.present?
    end

    scope.order(updated_at: :desc).first
  end

  def sms_fallback_lookup_limit
    ENV.fetch("WIZWIKI_COMMS_SMS_FALLBACK_LOOKUP_LIMIT", "250").to_i.clamp(25, 1_000)
  end

  def sms_broad_lookup_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_SMS_BROAD_LOOKUP", "0"))
  end

  def auto_thumper_command?(body)
    body.to_s.squish.match?(AUTO_THUMPER_COMMAND_PATTERN)
  end

  def record_inbound_sms_receipt!(provider:, from:, to:, body:, sid:, context:, payload:, stage: nil)
    raw_payload = nil
    source_uid = nil
    raw_payload = inbound_sms_receipt_payload(
      provider: provider,
      from: from,
      to: to,
      body: body,
      sid: sid,
      context: context,
      payload: payload,
      stage: stage
    )
    unless defined?(IngestionEvent)
      write_inbound_sms_receipt_fallback!(raw_payload, reason: "ingestion_event_unavailable")
      return
    end

    organization = stage&.organization || organization_for_inbound_sms(to: to, provider: provider, payload: payload)
    if organization.blank?
      write_inbound_sms_receipt_fallback!(raw_payload, reason: "no_organization")
      return
    end

    source = "#{provider}_inbound_sms"
    source_uid = sid.to_s.presence || raw_payload["receipt_fingerprint"]
    event = organization.ingestion_events.find_or_initialize_by(source: source, source_uid: source_uid)
    event.crm_record = stage&.crm_record if stage&.crm_record.present?
    event.payload_digest ||= Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(raw_payload))
    event.raw_payload = merge_inbound_sms_receipt_payload(event.raw_payload.to_h, raw_payload, preserve_existing_match: stage.blank? && event.persisted?)
    event.status = "accepted"
    event.save!
    event
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
    Rails.logger.info("[TwilioWebhook] inbound sms receipt duplicate provider=#{provider} sid=#{sid} #{error.class}: #{error.message}")
    find_inbound_sms_receipt(provider: provider, sid: sid, source_uid: source_uid, payload: payload)
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt failed provider=#{provider} sid=#{sid} #{error.class}: #{error.message}")
    write_inbound_sms_receipt_fallback!(
      raw_payload || inbound_sms_receipt_payload(provider: provider, from: from, to: to, body: body, sid: sid, context: context, payload: payload, stage: stage),
      reason: "record_failed",
      error: error
    )
    nil
  end

  def merge_inbound_sms_receipt_payload(existing_payload, raw_payload, preserve_existing_match:)
    existing_payload = existing_payload.to_h
    merged = existing_payload.merge(raw_payload.to_h)
    if preserve_existing_match && existing_payload["match_status"].present? && existing_payload["match_status"] != "pending_match"
      %w[
        match_status
        matched_at
        matched_stage_id
        matched_crm_record_id
        matched_user_id
        unmatched_at
        ignored_at
        ignored_reason
        unauthorized_at
        processing_failed_at
        processing_failed_phase
        processing_failed_error_class
        processing_failed_error
      ].each do |key|
        merged[key] = existing_payload[key] if existing_payload.key?(key)
      end
    end
    merged.compact_blank
  end

  def mark_inbound_sms_receipt_matched!(receipt, stage)
    return if receipt.blank? || stage.blank?

    updates = {
      "match_status" => "matched",
      "matched_at" => Time.current.iso8601,
      "matched_stage_id" => stage.id,
      "matched_crm_record_id" => stage.crm_record_id,
      "matched_user_id" => stage.user_id
    }.compact_blank
    receipt.update!(
      crm_record: stage.crm_record,
      raw_payload: receipt.raw_payload.to_h.merge(updates).compact_blank
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt match update failed receipt=#{receipt&.id} stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def mark_inbound_sms_receipt_unmatched!(receipt)
    return if receipt.blank?

    receipt.update!(
      raw_payload: receipt.raw_payload.to_h.merge(
        "match_status" => "no_stage_match",
        "unmatched_at" => Time.current.iso8601
      ).compact_blank
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt unmatched update failed receipt=#{receipt&.id} #{error.class}: #{error.message}")
  end

  def mark_inbound_sms_receipt_unauthorized!(receipt)
    return if receipt.blank?

    receipt.update!(
      raw_payload: receipt.raw_payload.to_h.merge(
        "match_status" => "unauthorized",
        "unauthorized_at" => Time.current.iso8601
      ).compact_blank
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt unauthorized update failed receipt=#{receipt&.id} #{error.class}: #{error.message}")
  end

  def mark_inbound_sms_receipt_ignored!(receipt, reason:, event_type: nil)
    return if receipt.blank?

    receipt.update!(
      raw_payload: receipt.raw_payload.to_h.merge(
        "match_status" => "ignored",
        "ignored_reason" => reason.to_s,
        "ignored_event_type" => event_type.to_s.presence,
        "ignored_at" => Time.current.iso8601
      ).compact_blank
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt ignored update failed receipt=#{receipt&.id} #{error.class}: #{error.message}")
  end

  def mark_inbound_sms_receipt_failed!(receipt, error, phase:)
    return if receipt.blank?

    receipt.update!(
      raw_payload: receipt.raw_payload.to_h.merge(
        "match_status" => "processing_failed",
        "processing_failed_at" => Time.current.iso8601,
        "processing_failed_phase" => phase.to_s,
        "processing_failed_error_class" => error.class.name,
        "processing_failed_error" => error.message.to_s.truncate(500)
      ).compact_blank
    )
  rescue StandardError => update_error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt failure update failed receipt=#{receipt&.id} #{update_error.class}: #{update_error.message}")
  end

  def inbound_sms_receipt_payload(provider:, from:, to:, body:, sid:, context:, payload:, stage:)
    received_at = Time.current.iso8601
    core = {
      "provider" => provider.to_s,
      "provider_message_id" => sid.to_s.presence,
      "from" => from.to_s,
      "to" => to.to_s,
      "body" => body.to_s,
      "context" => context.to_h,
      "payload" => payload.to_h,
      "match_status" => stage.present? ? "matched" : "pending_match",
      "matched_stage_id" => stage&.id,
      "matched_crm_record_id" => stage&.crm_record_id,
      "matched_user_id" => stage&.user_id,
      "received_at" => received_at
    }.compact_blank
    core.merge(
      "receipt_fingerprint" => Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(core.except("received_at")))
    )
  end

  def organization_for_inbound_sms(to:, provider:, payload:)
    messaging_service_sid = payload.to_h["MessagingServiceSid"].to_s.presence ||
      payload.to_h.dig("event_data", "inbox_id").to_s.presence
    if messaging_service_sid.present?
      user = User.where(twilio_messaging_service_sid: messaging_service_sid).first
      return user.primary_organization if user&.primary_organization.present?
    end

    to_tail = phone_tail(to)
    if to_tail.present?
      user = User
        .joins(:memberships)
        .where(
          "regexp_replace(coalesce(users.twilio_from_number, users.phone_number, ''), '[^0-9]', '', 'g') LIKE ?",
          "%#{to_tail}"
        )
        .order(:id)
        .first
      return user.primary_organization if user&.primary_organization.present?
    end

    Organization.find_by(slug: ENV.fetch("WIZWIKI_COMMS_DEFAULT_ORGANIZATION_SLUG", "wizwiki-autos")) || Organization.order(:created_at).first
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt organization lookup failed provider=#{provider} #{error.class}: #{error.message}")
    nil
  end

  def find_inbound_sms_receipt(provider:, sid:, payload:, source_uid: nil)
    source = "#{provider}_inbound_sms"
    lookup_uid = source_uid.to_s.presence || sid.to_s.presence
    return IngestionEvent.where(source: source, source_uid: lookup_uid).order(updated_at: :desc).first if lookup_uid.present?

    fingerprint = Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload.to_h))
    IngestionEvent.where(source: source, payload_digest: fingerprint).order(updated_at: :desc).first
  end

  def write_inbound_sms_receipt_fallback!(raw_payload, reason:, error: nil)
    payload = raw_payload.to_h.merge(
      "fallback_reason" => reason.to_s,
      "fallback_error_class" => error&.class&.name,
      "fallback_error" => error&.message.to_s.presence&.truncate(500),
      "fallback_recorded_at" => Time.current.iso8601
    ).compact_blank
    path = Rails.root.join("log", "inbound_sms_receipts_fallback.jsonl")
    File.open(path, "a") { |file| file.puts(ActiveSupport::JSON.encode(payload)) }
  rescue StandardError => fallback_error
    Rails.logger.warn("[TwilioWebhook] inbound sms receipt fallback write failed #{fallback_error.class}: #{fallback_error.message}")
  end

def append_inbound_sms!(stage, from:, to:, body:, sid:, twilio_context:, provider: "twilio")
  identity = {}
  location = {}
  processing = {}
  inbound_body = body.to_s.strip
  language_processing_pending = defined?(Comms::SmsLanguageSupport) && Comms::SmsLanguageSupport.enabled_for?(stage: stage)

  stage.with_lock do
    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    return false if sid.present? && thread.any? { |event| event.to_h["provider_message_id"].to_s == sid.to_s }

    event_id = SecureRandom.uuid
    reply_generation = SecureRandom.uuid
    now = Time.current.iso8601
    event = {
      "id" => event_id,
      "channel" => "sms",
      "direction" => "inbound",
      "status" => "received",
      "from" => from,
      "to" => to,
      "body" => inbound_body,
      "provider" => provider,
      "provider_message_id" => sid,
      "reply_generation" => reply_generation,
      "twilio_context" => twilio_context,
      "created_at" => now
    }
    event["language_processing_status"] = "pending" if language_processing_pending
    thread << event.compact_blank
    identity = identity_capture_payload(metadata, inbound_body)
    pending_metadata = metadata.merge(identity).merge("sms_thread" => thread)
    location = location_capture_payload(pending_metadata, inbound_body, twilio_context, provider: provider)
    pending_metadata = pending_metadata.merge(location)
    processing = processing_payload(stage, metadata: pending_metadata, latest_body: inbound_body)
    thread[-1] = thread.last.to_h.merge(
      "processing_code" => processing["processing_code"],
      "processing_label" => processing["processing_label"]
    ).compact_blank
    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(identity).merge(
        "sms_thread" => thread,
        "comms_command_sms_draft_body" => nil,
        "comms_command_sms_draft" => nil,
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "received",
        "comms_command_last_at" => now,
        "comms_command_last_inbound_from" => from,
        "sms_reply_generation" => reply_generation,
        "sms_reply_generation_at" => now,
        "sms_reply_generation_inbound_id" => event_id,
        "sms_reply_generation_inbound_sid" => sid,
        "sms_listener_active" => true,
        "sms_listener_last_inbound_at" => now,
        "sms_listener_last_inbound_sid" => sid
      ).merge(location).merge(processing)
    )
  end

  apply_identity_to_crm_record!(stage, identity)
  route_lead_if_ready!(stage)
  true
end

  def enqueue_inbound_sms_reply!(stage, from:, to:, body:, sid:, provider:)
    now = Time.current
    enqueue_job = false
    wait_seconds = nil

    stage.with_lock do
      stage.reload
      metadata = stage.metadata.to_h.deep_dup
      generation = metadata["sms_reply_generation"].presence || SecureRandom.uuid
      recent_jobs = recent_sms_reply_jobs(metadata, now)
      rate_limited = recent_jobs.length >= sms_reply_jobs_per_minute_limit
      cooldown_until = parse_timestamp(metadata["sms_reply_rate_limited_until"])
      cooldown_active = cooldown_until.present? && cooldown_until > now
      settle_pending = sms_reply_settle_job_pending?(metadata, now)
      enqueue_job = !cooldown_active && !settle_pending
      settle_seconds = sms_reply_settle_delay_seconds
      wait_seconds = [rate_limited ? sms_reply_rate_limit_delay_seconds : nil, settle_seconds.positive? ? settle_seconds : nil].compact.max
      if enqueue_job
        recent_jobs << {
          "generation" => generation,
          "queued_at" => now.iso8601,
          "sid" => sid.to_s.presence,
          "provider" => provider.to_s
        }.compact_blank
      end
      job_status = if settle_pending
        "settle_coalesced"
      elsif enqueue_job
        rate_limited ? "rate_limited_queued" : "queued"
      else
        "rate_limited_coalesced"
      end

      stage.update!(
        generated_at: now,
        metadata: metadata.merge(
          "comms_command_last_status" => "reply_queued",
          "comms_command_last_at" => now.iso8601,
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => now.iso8601,
          "comms_command_background_provider" => provider.to_s,
          "sms_reply_generation" => generation,
          "sms_reply_generation_at" => metadata["sms_reply_generation_at"].presence || now.iso8601,
          "sms_reply_generation_inbound_sid" => sid.to_s.presence || metadata["sms_reply_generation_inbound_sid"],
          "sms_reply_job_generation" => generation,
          "sms_reply_job_status" => job_status,
          "sms_reply_job_queued_at" => enqueue_job ? now.iso8601 : metadata["sms_reply_job_queued_at"],
          "sms_reply_settle_delay_seconds" => wait_seconds,
          "sms_reply_jobs_recent" => recent_jobs,
          "sms_reply_rate_limited_at" => rate_limited ? now.iso8601 : metadata["sms_reply_rate_limited_at"],
          "sms_reply_rate_limited_until" => rate_limited ? (now + wait_seconds.seconds).iso8601 : metadata["sms_reply_rate_limited_until"]
        ).compact_blank
      )
    end
    return true unless enqueue_job

    job = Comms::InboundSmsReplyJob
    job = job.set(wait: wait_seconds.seconds) if wait_seconds.present? && wait_seconds.positive?
    job.perform_later(
      stage_id: stage.id,
      from: from.to_s,
      to: to.to_s,
      body: body.to_s,
      sid: sid.to_s,
      provider: provider.to_s,
      generation: nil
    )
    true
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound reply enqueue failed stage=#{stage&.id} provider=#{provider} #{error.class}: #{error.message}")
  end

  def enqueue_latest_inbound_sms_reply!(stage, provider: "twilio")
    stage.reload
    event = latest_replyable_inbound_event(stage.metadata.to_h)
    return false if event.blank?

    enqueue_inbound_sms_reply!(
      stage,
      from: event["from"].to_s,
      to: event["to"].to_s,
      body: event["body"].to_s,
      sid: event["provider_message_id"].to_s.presence || event["id"].to_s,
      provider: event["provider"].presence || provider
    )
  end

  def latest_replyable_inbound_event(metadata)
    Array(metadata["sms_thread"]).map(&:to_h).reverse.find do |event|
      event["channel"].to_s == "sms" &&
        event["direction"].to_s == "inbound" &&
        event["body"].to_s.squish.present? &&
        !event["status"].to_s.in?(%w[failed canceled])
    end
  end

  def recent_sms_reply_jobs(metadata, now = Time.current)
    cutoff = now - 60.seconds
    Array(metadata["sms_reply_jobs_recent"]).map(&:to_h).filter_map do |job|
      queued_at = parse_timestamp(job["queued_at"])
      next if queued_at.blank? || queued_at < cutoff

      job
    end.last(25)
  end

  def sms_reply_settle_job_pending?(metadata, now = Time.current)
    status = metadata["sms_reply_job_status"].to_s
    return false unless status.in?(%w[queued rate_limited_queued settle_coalesced])

    queued_at = parse_timestamp(metadata["sms_reply_job_queued_at"])
    return false if queued_at.blank?

    recorded_delay = metadata["sms_reply_settle_delay_seconds"].to_i.clamp(0, 120)
    pending_window = [recorded_delay + 60, 90].max.seconds
    queued_at + pending_window > now
  rescue StandardError
    false
  end

  def sms_reply_jobs_per_minute_limit
    ENV.fetch("WIZWIKI_COMMS_SMS_REPLY_JOBS_PER_MINUTE", "12").to_i.clamp(3, 60)
  end

  def sms_reply_rate_limit_delay_seconds
    ENV.fetch("WIZWIKI_COMMS_SMS_REPLY_RATE_LIMIT_DELAY_SECONDS", "12").to_i.clamp(3, 120)
  end

  def sms_reply_settle_delay_seconds
    ENV.fetch("WIZWIKI_COMMS_SMS_REPLY_SETTLE_DELAY_SECONDS", "25").to_i.clamp(0, 120)
  end

  def reply_generation_stale?(stage, generation)
    expected = generation.to_s.presence
    current = stage.reload.metadata.to_h["sms_reply_generation"].to_s
    return false if expected.blank? && current.blank?
    return true if expected.blank? && current.present?

    current.blank? || current != expected
  end

  def mark_reply_generation_stale!(stage, generation, provider: nil)
    return false if stage.blank? || generation.to_s.blank?

    metadata = stage.reload.metadata.to_h.deep_dup
    return false if metadata["sms_reply_generation"].to_s == generation.to_s

    updates = {
      "sms_reply_last_stale_generation" => generation.to_s,
      "sms_reply_last_stale_at" => Time.current.iso8601,
      "sms_reply_last_stale_provider" => provider.to_s.presence
    }.compact_blank
    if metadata["sms_reply_job_generation"].to_s == generation.to_s
      updates.merge!(
        "sms_reply_job_status" => "stale",
        "comms_command_background_status" => "stale_inbound_rescan",
        "comms_command_background_at" => Time.current.iso8601
      )
    end
    stage.update!(generated_at: Time.current, metadata: metadata.merge(updates).compact_blank)
    true
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] stale generation mark failed stage=#{stage&.id} generation=#{generation} #{error.class}: #{error.message}")
    false
  end

  def handle_auto_thumper_command!(stage, from:, to:, body:, sid:, provider:)
    reset_auto_thumper_thread!(stage, from: from, to: to, body: body, sid: sid, provider: provider)
    enqueue_inbound_sms_reply!(stage.reload, from: from, to: to, body: body, sid: sid, provider: provider)
    Rails.logger.info("[TwilioWebhook] AUTO Thumper command reset and queued stage=#{stage.id} provider=#{provider} sid=#{sid}")
    true
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] AUTO Thumper command failed stage=#{stage&.id} provider=#{provider} #{error.class}: #{error.message}")
    false
  end

  def reset_auto_thumper_thread!(stage, from:, to:, body:, sid:, provider:)
    now = Time.current

    stage.with_lock do
      stage.reload
      metadata = stage.metadata.to_h.deep_dup
      reset_count = metadata["sms_conversation_reset_count"].to_i + 1
      reset_metadata = metadata.except(*AUTO_THUMPER_RESET_METADATA_KEYS)
      canceled_question_ids = cancel_inflight_sms_draft_questions!(stage, reason: "auto_thumper_reset", at: now)
      Comms::ConversationMemoryReset.clear_record!(stage.crm_record)

      stage.update!(
        generated_at: now,
        metadata: reset_metadata.merge(
          "comms_bot_state" => {},
          "sms_draft_history" => [],
          "sms_discovery_reset" => true,
          "sms_auto_thumper_command" => body.to_s.squish,
          "sms_auto_thumper_command_at" => now.iso8601,
          "sms_auto_thumper_command_from" => from.to_s,
          "sms_auto_thumper_command_provider" => provider.to_s,
          "sms_auto_thumper_command_sid" => sid.to_s.presence,
          "sms_conversation_reset_at" => now.iso8601,
          "sms_conversation_reset_count" => reset_count,
          "sms_conversation_reset_by" => "AUTO Thumper SMS command",
          "sms_conversation_reset_by_phone" => from.to_s,
          "sms_conversation_reset_previous_thread_count" => Array(metadata["sms_thread"]).length,
          "sms_thread" => [],
          "sms_reply_generation" => SecureRandom.uuid,
          "sms_reply_generation_at" => now.iso8601,
          "sms_reply_generation_superseded_at" => now.iso8601,
          "sms_reply_generation_superseded_reason" => "auto_thumper_reset",
          "sms_reply_generation_superseded_question_ids" => canceled_question_ids.presence,
          "sms_autopilot_enabled" => true,
          "sms_autopilot_updated_at" => now.iso8601,
          "sms_autopilot_updated_by" => "AUTO Thumper SMS command",
          "sms_autopilot_objective" => auto_thumper_autopilot_objective,
          "sms_autopilot_turn_limit" => metadata["sms_autopilot_turn_limit"].presence || ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_TURN_LIMIT", "16").to_i,
          "sms_listener_active" => true,
          "sms_listener_started_at" => now.iso8601,
          "sms_listener_until" => 7.days.from_now.iso8601,
          "sms_listener_from" => to.to_s.presence || metadata["sms_listener_from"],
          "sms_listener_to" => from.to_s.presence || metadata["sms_listener_to"],
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "auto_thumper_reset",
          "comms_command_last_at" => now.iso8601,
          "comms_command_last_error" => nil
        ).compact_blank
      )
    end
  end

  def cancel_inflight_sms_draft_questions!(stage, reason:, at:)
    return [] unless defined?(AutosQuestion)

    canceled = []
    AutosQuestion
      .where(status: %w[queued claimed])
      .where("metadata ->> 'surface' = ?", "comms_sms_draft")
      .where("metadata ->> 'comms_stage_id' = ?", stage.id.to_s)
      .find_each do |question|
        question_metadata = question.metadata.to_h.deep_dup
        worker = question_metadata["local_worker"].to_h
        worker.merge!(
          "status" => "canceled",
          "canceled_at" => at.iso8601,
          "cancel_reason" => reason
        )
        question.update_columns(
          status: "canceled",
          metadata: question_metadata.merge(
            "local_worker" => worker,
            "canceled_at" => at.iso8601,
            "cancel_reason" => reason
          ),
          updated_at: at
        )
        canceled << question.id
      end
    canceled
  end

  def auto_thumper_autopilot_objective
    "AUTO Thumper reset mode: treat old discovery as historical, answer the latest direct question first, and use only reviewed organization facts. If there is no post-reset customer reply, introduce Thumper and ask one open question about what the customer wants help with. Do not request contact details until they are relevant. Keep each SMS concise and human."
  end

  def auto_thumper_opening_result(stage)
    {
      "pending" => false,
      "body" => auto_thumper_opening_body(stage),
      "provider" => "wizwiki/auto_thumper_starter",
      "model" => "goto-starter",
      "draft_source" => "auto_thumper_starter",
      "operator_prompt" => "AUTO Thumper command uses the deterministic quick-start starter.",
      "conversation_state" => {}
    }
  end

  def auto_thumper_opening_body(stage)
    first_name = auto_thumper_contact_first_name(stage)
    greeting = first_name.present? ? "Hi #{first_name}, I'm Thumper with WIZWIKI." : "Hi, I'm Thumper with WIZWIKI."
    variants = [
      "#{greeting} What would you like help confirming?",
      "#{greeting} What are you trying to accomplish?",
      "#{greeting} Ask me your latest question and I'll help make the next step clear.",
      "#{greeting} What would be most useful to work through first?"
    ]
    seed = Digest::SHA1.hexdigest([
      stage.id,
      stage.metadata.to_h["sms_conversation_reset_count"],
      Array(stage.metadata.to_h["sms_thread"]).length,
      Time.current.to_i / 300
    ].join(":")).to_i(16)
    variants[seed % variants.length]
  end

  def auto_thumper_contact_first_name(stage)
    metadata = stage.metadata.to_h
    name = identity_value(selected_contact_name(metadata)) || identity_value(stage.crm_record&.name)
    first = name.to_s.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
    return if first.blank? || first.length < 2

    first
  end

  def large_volume_handoff_result(stage, body)
    count = contextual_large_volume_count(stage, body)
    return if count.blank?

    count_label = number_with_delimiter(count)
    {
      "pending" => false,
      "body" => "Got it, #{count_label} homes is a larger-volume neighborhood push. I can have a WIZWIKI account manager check the best larger-volume options instead of forcing the wrong checkout link. What is the best way to reach you?",
      "provider" => "wizwiki/large_volume_guardrail",
      "model" => "deterministic_handoff",
      "draft_source" => "thumper_guardrail",
      "requires_am_support" => true,
      "am_support_reason" => "starter_pack_over_limit_sms",
      "am_support_source" => "large_volume_context_guardrail",
      "reason" => "Large homes/reach count answered a recent quantity question; routed to AM support without waiting for Thumper.",
      "conversation_state" => { "large_volume_count" => count }
    }
  end

  def contextual_large_volume_count(stage, body)
    text = body.to_s.downcase.squish
    return if text.blank?

    metadata = stage.metadata.to_h
    latest_outbound = latest_outbound_sms_body(metadata)
    count = numeric_count(text)
    if count.present? && count >= large_volume_handoff_threshold
      return count if text.match?(/\b(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/)
      return count if homes_or_quantity_question?(latest_outbound)
    end

    known_count = known_large_volume_count(metadata)
    known_count if known_count.present? && large_volume_followup_question?(latest_outbound)
  end

  def numeric_count(text)
    body = text.to_s.downcase.squish
    if (match = body.match(/\b(\d{1,3}(?:,\d{3})+|\d{3,6})\b/))
      return match[1].delete(",").to_i
    end

    if (match = body.match(/\b(\d+(?:\.\d+)?)\s*k\b/))
      (match[1].to_f * 1000).round
    end
  end

  def large_volume_handoff_threshold
    ENV.fetch("WIZWIKI_COMMS_LARGE_VOLUME_HANDOFF_THRESHOLD", "1000").to_i.clamp(1, 100_000)
  end

  def latest_outbound_sms_body(metadata)
    Array(metadata["sms_thread"]).reverse_each do |event|
      row = event.to_h
      next unless row["channel"].to_s == "sms" && row["direction"].to_s == "outbound"
      next if row["status"].to_s.in?(%w[failed canceled])

      return row["body"].to_s.squish
    end

    ""
  end

  def known_large_volume_count(metadata)
    events = Array(metadata["sms_thread"]).map(&:to_h)
    reset_at = parse_timestamp(metadata["sms_conversation_reset_at"])
    events.each_with_index do |event, index|
      next unless event["channel"].to_s == "sms" && event["direction"].to_s == "inbound"
      event_at = parse_timestamp(event["created_at"])
      next if reset_at.present? && event_at.present? && event_at < reset_at

      count = numeric_count(event["body"])
      next if count.blank? || count < large_volume_handoff_threshold
      return count if event["body"].to_s.match?(/\b(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/i)

      previous_outbound = events[0...index].reverse.find do |candidate|
        candidate_at = parse_timestamp(candidate["created_at"])
        next false if reset_at.present? && candidate_at.present? && candidate_at < reset_at

        candidate["channel"].to_s == "sms" &&
          candidate["direction"].to_s == "outbound" &&
          !candidate["status"].to_s.in?(%w[failed canceled])
      end
      return count if homes_or_quantity_question?(previous_outbound.to_h["body"])
    end

    nil
  end

  def parse_timestamp(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def homes_or_quantity_question?(text)
    text.to_s.match?(/\b(?:how many|about how many|roughly|reach|homes?|households?|doors?|addresses?|mailboxes?|quantity|count)\b/i)
  end

  def large_volume_followup_question?(text)
    text.to_s.match?(/\b(?:what kind of business|business|campaign|promote|helping promote|company)\b/i)
  end

  def number_with_delimiter(number)
    number.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def safe_customer_sms_body(value)
    return if value.blank?
    return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

    value.to_s.strip.presence
  end

  def sms_delivery_body_for_stage(stage, value)
    @last_sms_delivery_language_event = nil
    body = value.to_s.squish
    return body if body.blank?
    if defined?(Comms::SmsBodySafety)
      body = Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage&.metadata)
    end
    if defined?(Comms::SmsPreSendVerifier)
      verification = Comms::SmsPreSendVerifier.call(stage: stage, body: body, source: "twilio_webhook_pre_send")
      persist_sms_language_metadata!(stage, verification.to_h["metadata"])
      raise "Thumper pre-send verifier blocked SMS: #{verification.reason}" unless verification.allowed

      body = verification.body.to_s.squish.presence || body
    end
    return body unless defined?(Comms::SmsLanguageSupport)

    result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
    @last_sms_delivery_language_event = result.to_h["event"]
    persist_sms_language_metadata!(stage, result.to_h["metadata"])
    result.to_h["body"].presence || body
  end

  def sms_delivery_language_event_payload
    @last_sms_delivery_language_event.to_h.compact_blank
  end

  def persist_sms_language_metadata!(stage, updates)
    return if stage.blank? || updates.to_h.blank?

    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(metadata: metadata.merge(updates.to_h).compact_blank)
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] SMS language metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def translated_inbound_body_for_reply(stage, fallback_body, sid)
    event = Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |row|
      row["channel"].to_s == "sms" &&
        row["direction"].to_s == "inbound" &&
        (sid.to_s.blank? || row["provider_message_id"].to_s == sid.to_s || row["id"].to_s == sid.to_s)
    end
    event.to_h["body"].to_s.squish.presence || fallback_body.to_s
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] translated inbound lookup failed stage=#{stage&.id} #{error.class}: #{error.message}")
    fallback_body.to_s
  end

  def ensure_inbound_language_processed!(stage, sid)
    return false unless defined?(Comms::SmsLanguageSupport)
    return false unless Comms::SmsLanguageSupport.enabled_for?(stage: stage)

    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).map(&:to_h)
    index = inbound_sms_event_index(thread, sid)
    event = index.nil? ? nil : thread[index].to_h
    return false if event.blank?
    return true if inbound_language_processed?(event)

    raw_body = event["body"].to_s.squish
    return false if raw_body.blank?

    result = Comms::SmsLanguageSupport.prepare_inbound_body(stage: stage, metadata: metadata, body: raw_body)
    payload = result.to_h
    translated_body = payload["body"].presence || raw_body
    processed_at = Time.current.iso8601
    success = false

    stage.with_lock do
      stage.reload
      metadata = stage.metadata.to_h.deep_dup
      thread = Array(metadata["sms_thread"]).map(&:to_h)
      index = inbound_sms_event_index(thread, sid)
      event = index.nil? ? nil : thread[index].to_h

      if event.blank?
        success = false
      elsif inbound_language_processed?(event)
        success = true
      else
        thread[index] = event.merge(payload["event"].to_h).merge(
          "body" => translated_body,
          "language_processing_status" => "processed",
          "language_processed_at" => processed_at
        ).compact_blank
        language_metadata = payload["metadata"].to_h
        pending_metadata = metadata.merge(language_metadata).merge("sms_thread" => thread)
        processing = processing_payload(stage, metadata: pending_metadata, latest_body: translated_body)
        thread[index] = thread[index].to_h.merge(
          "processing_code" => processing["processing_code"],
          "processing_label" => processing["processing_label"]
        ).compact_blank
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(language_metadata).merge("sms_thread" => thread).merge(processing).compact_blank
        )
        success = true
      end
    end

    success
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] inbound SMS language processing failed stage=#{stage&.id} sid=#{sid} #{error.class}: #{error.message}")
    false
  end

  def inbound_sms_event_index(thread, sid)
    sid_value = sid.to_s
    Array(thread).rindex do |row|
      row = row.to_h
      row["channel"].to_s == "sms" &&
        row["direction"].to_s == "inbound" &&
        (sid_value.blank? || row["provider_message_id"].to_s == sid_value || row["id"].to_s == sid_value)
    end
  end

  def inbound_language_processed?(event)
    event = event.to_h
    event["language_processing_status"].to_s == "processed" || event["language_code"].present?
  end

  def sms_body_safety_reason(value)
    return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

    "unsafe_sms_body"
  end

  def rebuild_next_sms!(stage, from:, to:, body:, sid:, generation: nil)
    stage.reload
    raw_inbound_body = body.to_s
    if reply_generation_stale?(stage, generation)
      mark_reply_generation_stale!(stage, generation, provider: "pre_draft")
      enqueue_latest_inbound_sms_reply!(stage.reload)
      return {
        "pending" => false,
        "provider" => "wizwiki/stale_reply_generation",
        "draft_source" => "stale_reply_generation",
        "reason" => "Newer inbound SMS arrived before this reply job ran; queued latest thread scan."
      }
    end
    ensure_inbound_language_processed!(stage, sid)
    body = translated_inbound_body_for_reply(stage, body, sid)
    auto_thumper_reset = auto_thumper_command?(body)
    support_rag_lane = defined?(Comms::RagProfile) && Comms::RagProfile.support?(stage)
    if !support_rag_lane && !auto_thumper_reset && handoff_inbound_sms_if_needed!(
      stage,
      body,
      source: "inbound_reply_job",
      from: from,
      to: to,
      inbound_sid: sid
    )
      return {
        "pending" => false,
        "provider" => "wizwiki/am_support_handoff",
        "draft_source" => "am_support_handoff",
        "reason" => "Inbound SMS requires AM support; no customer SMS drafted."
      }
    end

    fast_body = (auto_thumper_reset || support_rag_lane) ? nil : fast_inbound_sms_reply(stage, body)
    result = if fast_body.present?
      {
        "body" => fast_body,
        "provider" => "wizwiki/fast_pricing",
        "model" => "deterministic_yard_sign_pricing",
        "draft_source" => "fast_pricing",
        "sms_quality_gate" => "passed",
        "sms_generation_pipeline" => "fast_pricing_guardrail"
      }
    elsif auto_thumper_reset
      auto_thumper_opening_result(stage)
    else
      DealReports::CommsDraftWriter.queue_background(
        stage: stage,
        user: stage.user,
        operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: body, from: from),
        writer_model: WizwikiSettings.normalize_sms_writer_model(stage.metadata.to_h["sms_writer_model"].presence)
      )
    end
    metadata = stage.metadata.to_h.deep_dup
    if ActiveModel::Type::Boolean.new.cast(result["pending"])
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_sms_draft_body" => nil,
          "comms_command_sms_draft" => result.merge("created_at" => Time.current.iso8601),
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "reply_queued",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_background_question_id" => result["autos_question_id"],
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => Time.current.iso8601,
          "comms_command_background_provider" => result["provider"],
          "sms_reply_job_generation" => generation.to_s.presence || metadata["sms_reply_job_generation"],
          "sms_reply_job_status" => "draft_pending"
        ).compact_blank
      )
      return result
    end

    raw_body = result["body"].to_s.strip.presence
    safe_body = safe_customer_sms_body(raw_body)
    if raw_body.present? && safe_body.blank?
      reason = sms_body_safety_reason(raw_body)
      Rails.logger.warn("[TwilioWebhook] blocked unsafe reply draft stage=#{stage&.id} reason=#{reason}")
      blocked_result = result.except("body").merge(
        "error" => [result["error"], "sms_body_safety_rejected: #{reason}"].compact_blank.join(" | "),
        "sms_quality_gate" => "blocked",
        "draft_source" => "safety_rejected"
      )
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_sms_draft_body" => nil,
          "comms_command_sms_draft" => blocked_result.merge("created_at" => Time.current.iso8601),
          "comms_command_last_status" => "reply_blocked",
          "comms_command_last_at" => Time.current.iso8601,
          "sms_autopilot_last_error" => "Blocked unsafe SMS draft: #{reason}",
          "sms_autopilot_last_error_at" => Time.current.iso8601
        ).compact_blank
      )
      return blocked_result
    end
    result = result.merge("body" => safe_body) if safe_body.present?

    processing = safe_body.present? ? processing_payload(stage, metadata: metadata, latest_body: safe_body) : {}
    history = Array(metadata["sms_draft_history"]).last(24)
    if safe_body.present?
      history << {
        "id" => SecureRandom.uuid,
        "body" => safe_body,
        "provider" => result["provider"],
        "model" => result["model"],
        "writer_model" => result["writer_model"],
        "writer_model_label" => result["writer_model_label"],
        "sms_generation_pipeline" => result["sms_generation_pipeline"],
        "sms_quality_gate" => result["sms_quality_gate"],
        "draft_source" => result["draft_source"],
        "requires_am_support" => result["requires_am_support"],
        "am_support_reason" => result["am_support_reason"],
        "reason" => "Auto-drafted after inbound SMS.",
        "operator_prompt" => result["operator_prompt"],
        "error" => result["error"],
        "created_at" => Time.current.iso8601
      }.compact_blank
    end
    if reply_generation_stale?(stage.reload, generation)
      mark_reply_generation_stale!(stage, generation, provider: "post_draft")
      enqueue_latest_inbound_sms_reply!(stage.reload)
      return result.merge(
        "stale_reply_generation" => true,
        "reason" => "Newer inbound SMS arrived while this reply was drafting; queued latest thread scan."
      )
    end
    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "comms_command_sms_draft_body" => safe_body,
        "comms_command_sms_draft" => result.merge("created_at" => Time.current.iso8601),
        "sms_draft_history" => history,
        "comms_bot_state" => result["conversation_state"].presence,
        "comms_command_last_status" => safe_body.present? ? "reply_drafted" : "reply_blank",
        "comms_command_last_at" => Time.current.iso8601,
        "sms_reply_job_generation" => generation.to_s.presence || metadata["sms_reply_job_generation"],
        "sms_reply_job_status" => "drafted",
        "sms_reply_job_completed_at" => Time.current.iso8601
      ).compact_blank.merge(processing)
    )
    if stop_intent?(raw_inbound_body, stage.metadata.to_h, inbound_sid: sid)
      disable_autopilot!(stage, reason: "customer_stop_signal")
    else
      autopilot_sent = maybe_autopilot_reply!(stage, draft: result, inbound_sid: sid, inbound_body: body, from: from, to: to)
      mark_am_support_for_draft!(stage.reload, body, result, source: "inbound_reply_draft") unless autopilot_sent
    end
    result
  end

  def handle_do_not_contact!(stage, from:, to:, inbound_sid:, provider:)
    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    confirmation_body = "Understood. I’ll stop messaging you. Thank you."
    confirmation_result = nil
    confirmation_error = nil

    unless metadata["sms_stop_confirmation_sent_at"].present?
      begin
        profile = stage.user&.respond_to?(:twilio_profile) ? stage.user.twilio_profile.to_h : {}
        confirmation_result = Comms::SmsProvider.deliver!(
          to: from,
          body: confirmation_body,
          from_number: to.presence || profile["from_number"].presence,
          messaging_service_sid: profile["messaging_service_sid"].presence
        )
      rescue StandardError => error
        confirmation_error = error.message
        Rails.logger.warn("[TwilioWebhook] stop confirmation failed stage=#{stage&.id} #{error.class}: #{error.message}")
      end

      thread << {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "outbound",
        "status" => normalized_outbound_status(provider_result: confirmation_result, error: confirmation_error),
        "to" => from.to_s,
        "from" => confirmation_result.to_h["from"].presence || to.to_s,
        "body" => confirmation_body,
        "provider" => confirmation_result.to_h["provider"].presence || provider,
        "provider_message_id" => confirmation_result.to_h["sid"].presence,
        "provider_status" => confirmation_result.to_h["status"].presence,
        "autopilot" => true,
        "do_not_contact_confirmation" => true,
        "autopilot_reply_to_sid" => inbound_sid.to_s.presence,
        "error" => confirmation_error,
        "created_at" => Time.current.iso8601
      }.compact_blank
    end

    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "sms_do_not_contact" => true,
        "sms_do_not_contact_at" => Time.current.iso8601,
        "sms_do_not_contact_reason" => "customer_stop_signal",
        "comms_board_state" => "opt_out",
        "comms_board_state_updated_at" => Time.current.iso8601,
        "comms_board_state_updated_by" => "customer_stop_signal",
        "sms_sending_disabled" => true,
        "sms_autopilot_enabled" => false,
        "sms_autopilot_disabled_at" => Time.current.iso8601,
        "sms_autopilot_disabled_reason" => "customer_stop_signal",
        "sms_listener_active" => false,
        "sms_stop_confirmation_sent_at" => metadata["sms_stop_confirmation_sent_at"].presence || (confirmation_error.blank? ? Time.current.iso8601 : nil),
        "sms_stop_confirmation_error" => confirmation_error,
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "do_not_contact",
        "comms_command_last_at" => Time.current.iso8601
      ).compact_blank
    )
  end

  def maybe_autopilot_reply!(stage, draft:, inbound_sid:, inbound_body:, from:, to:)
    reply_key = nil
    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    return unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"])
    return if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
    return if draft.to_h["body"].to_s.squish.blank?
    return if stop_intent?(inbound_body, metadata, inbound_sid: inbound_sid)
    return if handoff_inbound_sms_if_needed!(stage, inbound_body, source: "autopilot_reply", from: from, to: to, inbound_sid: inbound_sid)
    reply_key = Comms::AutopilotReplyLock.key(inbound_sid: inbound_sid, inbound_body: inbound_body, from: from)
    return if Comms::AutopilotReplyLock.answered?(metadata, key: reply_key)

    limit = metadata["sms_autopilot_turn_limit"].to_i
    limit = 8 if limit <= 0
    count = metadata["sms_autopilot_sent_count"].to_i
    if count >= limit
      disable_autopilot!(stage, reason: "turn_limit_reached")
      return
    end
    reply_key = Comms::AutopilotReplyLock.reserve!(
      stage,
      inbound_sid: inbound_sid,
      inbound_body: inbound_body,
      from: from,
      source: "twilio_webhook"
    )
    return if reply_key.blank?
    stage.reload
    metadata = stage.metadata.to_h.deep_dup

    processing = processing_payload(stage, metadata: metadata, latest_body: inbound_body)
    metadata = metadata.merge(processing).compact_blank
    stage.update!(generated_at: Time.current, metadata: metadata) if processing.present?

    completion = false
    raw_outbound_body = strip_url_trailing_punctuation(draft["body"])
    outbound_body = safe_customer_sms_body(raw_outbound_body)
    if raw_outbound_body.present? && outbound_body.blank?
      reason = sms_body_safety_reason(raw_outbound_body)
      Comms::AutopilotReplyLock.clear!(stage, key: reply_key) if reply_key.present?
      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_last_error" => "Blocked unsafe SMS draft: #{reason}",
          "sms_autopilot_last_error_at" => Time.current.iso8601,
          "comms_command_last_status" => "autopilot_blocked",
          "comms_command_last_at" => Time.current.iso8601
        ).compact_blank
      )
      Rails.logger.warn("[TwilioWebhook] blocked unsafe autopilot reply stage=#{stage&.id} reason=#{reason}")
      return false
    end
    if (quantity_safe_body = corrected_yard_sign_quantity_body(inbound_body, outbound_body)).present?
      outbound_body = quantity_safe_body
      draft = draft.to_h.merge(
        "body" => outbound_body,
        "provider" => "wizwiki/quantity_guardrail",
        "model" => "deterministic_yard_sign_quantity_guardrail",
        "draft_source" => "quantity_guardrail",
        "sms_quality_gate" => "quantity_rewritten"
      )
    end

    outbound_body = sms_delivery_body_for_stage(stage, outbound_body)
    profile = stage.user&.respond_to?(:twilio_profile) ? stage.user.twilio_profile.to_h : {}
    result = Comms::SmsProvider.deliver!(
      to: from,
      body: outbound_body,
      from_number: to.presence || profile["from_number"].presence,
      messaging_service_sid: profile["messaging_service_sid"].presence
    )
    append_autopilot_outbound!(
      stage,
      body: outbound_body,
      to: from,
      from: result.to_h["from"].presence || to,
      provider_result: result,
      inbound_sid: reply_key,
      draft: draft,
      completion: completion
    )
    mark_am_support_for_draft!(stage.reload, inbound_body, draft, source: "autopilot_reply_guardrail")
    true
  rescue StandardError => error
    append_autopilot_failed!(
      stage,
      body: draft.to_h["body"],
      to: from,
      from: to,
      error: error.message,
      inbound_sid: reply_key.presence || inbound_sid
    )
    mark_am_support_for_draft!(stage.reload, inbound_body, draft, source: "autopilot_reply_failed_guardrail")
    disable_autopilot!(stage, reason: "send_failed")
    Rails.logger.warn("[TwilioWebhook] autopilot send failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def append_autopilot_outbound!(stage, body:, to:, from:, provider_result:, inbound_sid:, draft:, completion: false)
    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    return if Comms::AutopilotReplyLock.answered?(metadata, key: inbound_sid)

    outbound_payload = autopilot_event_payload(
      status: normalized_outbound_status(provider_result: provider_result),
      body: body,
      to: to,
      from: from,
      provider_result: provider_result,
      inbound_sid: inbound_sid,
      draft: draft,
      completion: completion
    ).merge(sms_delivery_language_event_payload).compact_blank
    thread << outbound_payload
    count = metadata["sms_autopilot_sent_count"].to_i + 1
    completion_metadata = completion ? {
      "sms_autopilot_completed_at" => Time.current.iso8601,
      "sms_autopilot_completion_sent_at" => Time.current.iso8601,
      "sms_autopilot_enabled" => false,
      "sms_autopilot_disabled_at" => Time.current.iso8601,
      "sms_autopilot_disabled_reason" => "data_capture_complete",
      "shopify_link_sent_at" => Time.current.iso8601,
      "comms_command_last_status" => "autopilot_complete"
    } : {}
    stage.update!(
      status: "aircall_sent",
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "comms_command_sms_draft_body" => nil,
        "comms_command_sms_draft" => nil,
        "comms_command_sms_sent_draft_at" => Time.current.iso8601,
        "comms_command_sms_sent_draft_sha1" => Digest::SHA1.hexdigest(body.to_s.squish),
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "autopilot_sent",
        "comms_command_last_at" => Time.current.iso8601,
        "sms_listener_active" => true,
        "sms_listener_until" => 7.days.from_now.iso8601,
        "sms_listener_from" => from,
        "sms_listener_to" => to,
        "sms_listener_last_outbound_sid" => provider_result.to_h["sid"],
        "sms_listener_last_outbound_at" => Time.current.iso8601,
        "sms_autopilot_sent_count" => count,
        "sms_autopilot_last_sent_at" => Time.current.iso8601,
        "sms_autopilot_last_reply_to_sid" => inbound_sid,
        "sms_autopilot_last_error" => nil,
        "sms_reply_job_status" => "sent",
        "sms_reply_job_completed_at" => Time.current.iso8601
      ).merge(completion_metadata)
    )
    Comms::AutopilotReplyLock.clear!(stage.reload, key: inbound_sid)
    notify_completion_without_purchase_if_needed!(stage.reload) if completion
    run_post_send_supervisor!(stage.reload, outbound_event: outbound_payload, source: "twilio_webhook_autopilot")
    send_language_preference_notice_if_needed!(stage.reload, to: to, from: from)
  end

  def send_language_preference_notice_if_needed!(stage, to:, from:)
    return false unless defined?(Comms::SmsLanguageSupport)
    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    return false unless Comms::SmsLanguageSupport.should_send_preference_notice?(metadata, stage: stage)

    body = Comms::SmsLanguageSupport.preference_notice_body
    profile = stage.user&.respond_to?(:twilio_profile) ? stage.user.twilio_profile.to_h : {}
    result = Comms::SmsProvider.deliver!(
      to: to,
      body: body,
      from_number: from.presence || profile["from_number"].presence,
      messaging_service_sid: profile["messaging_service_sid"].presence
    )
    append_language_preference_notice!(stage, body: body, to: to, from: result.to_h["from"].presence || from, provider_result: result)
    true
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] language preference notice failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def append_language_preference_notice!(stage, body:, to:, from:, provider_result:)
    metadata = stage.reload.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    event = {
      "id" => SecureRandom.uuid,
      "channel" => "sms",
      "direction" => "outbound",
      "status" => normalized_outbound_status(provider_result: provider_result),
      "to" => to.to_s,
      "from" => provider_result.to_h["from"].presence || from.to_s,
      "body" => body,
      "provider" => provider_result.to_h["provider"].presence || "twilio",
      "provider_message_id" => provider_result.to_h["sid"].presence,
      "provider_status" => provider_result.to_h["status"].presence,
      "autopilot" => true,
      "language_preference_notice" => true,
      "created_at" => Time.current.iso8601
    }.compact_blank
    thread << event
    stage.update!(
      status: "aircall_sent",
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "sms_language_preference_notice_sent_at" => Time.current.iso8601,
        "sms_language_preference_notice_body" => body,
        "sms_language_preference_notice_sid" => event["provider_message_id"],
        "sms_listener_active" => true,
        "sms_listener_until" => 7.days.from_now.iso8601,
        "sms_listener_from" => event["from"],
        "sms_listener_to" => to,
        "sms_listener_last_outbound_sid" => event["provider_message_id"],
        "sms_listener_last_outbound_at" => Time.current.iso8601
      ).compact_blank
    )
  end

  def run_post_send_supervisor!(stage, outbound_event:, source:)
    return unless defined?(Comms::PostSendSupervisor)
    return unless outbound_event.to_h["channel"].to_s == "sms"
    return unless outbound_event.to_h["direction"].to_s == "outbound"
    return unless outbound_event.to_h["status"].to_s.in?(%w[queued accepted scheduled sending sent delivered])

    profile = stage.user&.respond_to?(:twilio_profile) ? stage.user.twilio_profile.to_h : {}
    Comms::PostSendSupervisor.call(
      stage: stage,
      outbound_event: outbound_event,
      source: source,
      sender_profile: profile
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] post-send supervisor failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def append_autopilot_failed!(stage, body:, to:, from:, error:, inbound_sid:)
    return if stage.blank?

    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    return if Comms::AutopilotReplyLock.answered?(metadata, key: inbound_sid)

    thread << autopilot_event_payload(
      status: "failed",
      body: body,
      to: to,
      from: from,
      error: error,
      inbound_sid: inbound_sid,
      draft: {}
    )
    stage.update!(
      status: "aircall_failed",
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "autopilot_failed",
        "comms_command_last_error" => error,
        "comms_command_last_at" => Time.current.iso8601,
        "sms_autopilot_last_error" => error
      )
    )
    Comms::AutopilotReplyLock.clear!(stage.reload, key: inbound_sid)
  end

  def autopilot_event_payload(status:, body:, to:, from:, inbound_sid:, draft:, completion: false, provider_result: nil, error: nil)
    event_status = normalized_outbound_status(provider_result: provider_result, error: error.presence || (status.to_s == "failed" ? "failed" : nil))
    {
      "id" => SecureRandom.uuid,
      "channel" => "sms",
      "direction" => "outbound",
      "status" => event_status,
      "to" => to.to_s,
      "from" => provider_result.to_h["from"].presence || from.to_s,
      "body" => body.to_s,
      "provider" => provider_result.to_h["provider"].presence || "twilio",
      "provider_message_id" => provider_result.to_h["sid"].presence,
      "provider_status" => provider_result.to_h["status"].presence,
      "autopilot" => true,
      "autopilot_completion" => completion,
      "autopilot_reply_to_sid" => inbound_sid.to_s.presence,
      "autopilot_reply_key" => inbound_sid.to_s.presence,
      "draft_provider" => draft.to_h["provider"].presence,
      "draft_model" => draft.to_h["model"].presence,
      "draft_source" => draft.to_h["draft_source"].presence,
      "draft_writer_model" => draft.to_h["writer_model"].presence,
      "draft_writer_model_label" => draft.to_h["writer_model_label"].presence,
      "draft_sms_generation_pipeline" => draft.to_h["sms_generation_pipeline"].presence || "single_writer_guardrailed",
      "draft_sms_quality_gate" => draft.to_h["sms_quality_gate"].presence,
      "draft_requires_am_support" => draft.to_h["requires_am_support"].presence,
      "draft_am_support_reason" => draft.to_h["am_support_reason"].presence,
      "draft_time_seconds" => draft.to_h["draft_time_seconds"].presence,
      "draft_time_label" => draft.to_h["draft_time_label"].presence,
      "error" => error.to_s.presence,
      "created_at" => Time.current.iso8601
    }.compact
  end

  def normalized_outbound_status(provider_result: nil, error: nil)
    return "failed" if error.to_s.present?

    status = provider_result.to_h["status"].to_s.squish.downcase
    return "failed" if status.in?(%w[failed undelivered canceled])
    return status if status.in?(%w[queued accepted scheduled sending sent delivered])

    "sent"
  end

  def autopilot_already_answered?(metadata, inbound_sid:)
    Comms::AutopilotReplyLock.answered?(metadata, key: inbound_sid)
  end

  def disable_autopilot!(stage, reason:)
    return if stage.blank?

    metadata = stage.metadata.to_h.deep_dup
    dnc_payload = reason == "customer_stop_signal" ? {
      "sms_do_not_contact" => true,
      "sms_do_not_contact_at" => metadata["sms_do_not_contact_at"].presence || Time.current.iso8601,
      "sms_do_not_contact_reason" => "customer_stop_signal",
      "comms_board_state" => "opt_out",
      "comms_board_state_updated_at" => Time.current.iso8601,
      "comms_board_state_updated_by" => "customer_stop_signal",
      "sms_sending_disabled" => true,
      "comms_command_last_status" => "do_not_contact",
      "comms_command_last_at" => Time.current.iso8601
    } : {}
    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_autopilot_enabled" => false,
        "sms_autopilot_disabled_at" => Time.current.iso8601,
        "sms_autopilot_disabled_reason" => reason,
        "sms_listener_active" => reason == "customer_stop_signal" ? false : metadata["sms_listener_active"]
      ).merge(dnc_payload)
    )
  end

  def handoff_inbound_sms_if_needed!(stage, body, source:, from: nil, to: nil, inbound_sid: nil)
    return false unless defined?(Comms::InboundSmsHandoff)
    stage.reload
    contact_collection_turn =
      Comms::InboundSmsHandoff.contact_collection_response?(stage, body) ||
      Comms::InboundSmsHandoff.accepted_recent_contact_offer?(stage, body)
    handoff_required = Comms::InboundSmsHandoff.required?(body, stage: stage)
    fulfillment_escalation = Comms::InboundSmsHandoff.fulfillment_confirmation_required?(body, stage: stage)
    return false unless handoff_required || contact_collection_turn
    if am_support_autopilot_reply_enabled?(stage) && !handoff_required && !contact_collection_turn && !fulfillment_escalation
      return false
    end

    result = Comms::InboundSmsHandoff.call(stage: stage, body: body, source: source)
    handled = ActiveModel::Type::Boolean.new.cast(result&.handled)
    if ActiveModel::Type::Boolean.new.cast(result&.review_draft_saved)
      sent = send_handoff_review_draft_if_autopilot!(
        stage.reload,
        from: from,
        to: to,
        inbound_sid: inbound_sid,
        inbound_body: body
      )
      return true if sent
    end
    return true if handled

    false
  end

  def send_handoff_review_draft_if_autopilot!(stage, from:, to:, inbound_sid:, inbound_body:)
    return false if stage.blank?
    from = from.to_s.squish
    to = to.to_s.squish
    return false if from.blank? || to.blank?

    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    return false if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
    return false if ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"])

    draft = metadata["comms_command_sms_draft"].to_h
    body = safe_customer_sms_body(draft["body"])
    return false if body.blank?
    handoff_draft = ActiveModel::Type::Boolean.new.cast(draft["requires_am_support"]) ||
      draft["draft_source"].to_s == "am_support_handoff"
    return false unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) || handoff_draft

    reply_key = Comms::AutopilotReplyLock.reserve!(
      stage,
      inbound_sid: inbound_sid,
      inbound_body: inbound_body,
      from: from,
      source: "handoff_contact_collection"
    )
    if reply_key.blank?
      metadata = stage.reload.metadata.to_h
      key = Comms::AutopilotReplyLock.key(inbound_sid: inbound_sid, inbound_body: inbound_body, from: from)
      return true if Comms::AutopilotReplyLock.answered?(metadata, key: key)

      Rails.logger.warn("[TwilioWebhook] AM support contact SMS not sent stage=#{stage&.id} reason=reply_lock_unavailable inbound_sid=#{inbound_sid}")
      return false
    end

    profile = stage.user&.respond_to?(:twilio_profile) ? stage.user.twilio_profile.to_h : {}
    outbound_body = sms_delivery_body_for_stage(stage, body)
    result = Comms::SmsProvider.deliver!(
      to: from,
      body: outbound_body,
      from_number: to.presence || profile["from_number"].presence,
      messaging_service_sid: profile["messaging_service_sid"].presence
    )
    append_autopilot_outbound!(
      stage,
      body: outbound_body,
      to: from,
      from: result.to_h["from"].presence || to,
      provider_result: result,
      inbound_sid: reply_key,
      draft: draft.presence || {
        "provider" => "wizwiki/am_support_handoff",
        "model" => "deterministic_handoff",
        "draft_source" => "am_support_handoff",
        "requires_am_support" => true
      },
      completion: false
    )
    true
  rescue StandardError => error
    Comms::AutopilotReplyLock.clear!(stage, key: reply_key) if defined?(reply_key) && reply_key.present?
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_last_error" => error.message,
        "sms_autopilot_last_error_at" => Time.current.iso8601,
        "comms_command_last_status" => "am_support_contact_send_failed",
        "comms_command_last_at" => Time.current.iso8601
      ).compact_blank
    )
    Rails.logger.warn("[TwilioWebhook] AM support contact SMS failed stage=#{stage&.id} #{error.class}: #{error.message}")
    true
  end

  def am_support_autopilot_reply_enabled?(stage)
    metadata = stage.reload.metadata.to_h
    return false unless metadata["comms_support_state"].to_s == "am_support" ||
      metadata["comms_command_last_status"].to_s.in?(%w[human_requested account_manager_support am_support]) ||
      metadata["sms_autopilot_slack_human_requested_at"].present? ||
      metadata["sms_autopilot_slack_handoff_at"].present?

    ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) &&
      !ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"]) &&
      !ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) &&
      metadata["comms_board_state"].to_s != "opt_out"
  end

  def mark_am_support_for_draft!(stage, body, draft, source:)
    return false unless ActiveModel::Type::Boolean.new.cast(draft.to_h["requires_am_support"])
    return false unless defined?(Comms::InboundSmsHandoff)

    result = Comms::InboundSmsHandoff.call(
      stage: stage.reload,
      body: body.to_s,
      reason: draft.to_h["am_support_reason"].presence || "customer_requested_am_support",
      source: source,
      review_body: source.to_s.include?("autopilot_reply") ? nil : safe_customer_sms_body(draft.to_h["body"])
    )
    ActiveModel::Type::Boolean.new.cast(result&.handled)
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] AM support handoff failed stage=#{stage&.id} source=#{source} #{error.class}: #{error.message}")
    false
  end

  def notify_human_request_if_needed!(stage, body)
    handoff_inbound_sms_if_needed!(stage, body, source: "legacy_human_request_notify")
  end

  def comms_assigned_owner(stage)
    metadata = stage.metadata.to_h
    name = metadata["comms_routed_to_user_name"].to_s.squish.presence
    return if name.blank?

    owner = OpenStruct.new(
      id: metadata["comms_routed_to_user_id"].presence || "manual:#{name.parameterize}",
      display_name: name,
      email_address: metadata["comms_routed_to_user_email"].presence,
      hubspot_owner_id: metadata["comms_routed_to_hubspot_owner_id"].presence,
      source: metadata["contact_owner_source"].presence || "comms_route_metadata"
    )
    return if defined?(Comms::SlackNotifier) && Comms::SlackNotifier.disallowed_owner?(owner)

    owner
  end

  def account_manager_autopilot_handoff_body(stage, inbound_body, metadata)
    owner_name = metadata["comms_routed_to_user_first_name"].to_s.squish.presence ||
      metadata["comms_routed_to_user_name"].to_s.squish.split(/\s+/).first.presence ||
      "a WIZWIKI account manager"
    issue = human_request?(inbound_body) ? "I’ll get a real person on this." : "I want to get you the right answer on that instead of guessing."
    "#{issue} I’m going to have #{owner_name} from WIZWIKI follow up. What is the best time for them to reach you?"
  end

  def mark_am_support_pending!(stage, reason:, latest_body: nil)
    metadata = stage.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "comms_support_state" => "am_support",
        "comms_support_state_at" => metadata["comms_support_state_at"].presence || Time.current.iso8601,
        "comms_support_reason" => reason,
        "sms_autopilot_slack_pending_at" => metadata["sms_autopilot_slack_pending_at"].presence || Time.current.iso8601,
        "sms_autopilot_slack_pending_body" => latest_body.to_s.squish.presence
      ).compact_blank
    )
  end

  def notify_completion_without_purchase_if_needed!(stage)
    return unless defined?(Comms::SlackNotifier)

    reason = "Thumper completed SMS discovery and no Shopify/order purchase evidence is attached after 72 hours."
    Comms::SlackNotifier.ensure_completion_without_purchase_pending!(stage: stage, reason: reason)
    return unless Comms::SlackNotifier.completion_without_purchase_due?(stage.reload)

    owner = if defined?(DealReports::CommsLeadRouter)
      DealReports::CommsLeadRouter.route!(stage, force: true, reason: "completion_without_purchase")
    end
    owner = Comms::SlackNotifier.safe_owner(owner) || Comms::SlackNotifier.safe_owner(stage.reload.user)

    Comms::SlackNotifier.post_completion_without_purchase!(
      stage: stage.reload,
      owner: owner,
      reason: reason,
      force: true
    )
  end

  def human_request?(body)
    Comms::InboundSmsHandoff.human_request?(body)
  end

  def account_manager_answer_needed?(body)
    Comms::InboundSmsHandoff.account_manager_answer_needed?(body)
  end

  def unpriceable_postcard_pricing_question?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?

    text.match?(/\b(how\s+(?:much|mush)|cost|costs|price|pricing|total|rate|rates|charge|charges|quote|quotes|estimate)\b/) &&
      text.match?(/\b(post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/)
  end

  def product_option_mismatch?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?

    text.match?(/\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|where is|missing)\b.*\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b/) ||
      text.match?(/\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b.*\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|missing)\b/) ||
      text.match?(/\b(?:option|quantity|qty|pack|bundle)\s+for\s+\d+\b/) ||
      text.match?(/\b\d+\s+(?:signs?|yard signs?|lawn signs?)\b.*\b(?:option|link|checkout|pack|bundle)\b/) ||
      text.match?(/\b(?:custom|different|specific)\s+(?:quantity|qty|amount|count|number)\b/)
  end

  def priceable_product_question?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?
    return false if text.match?(/\b(custom quote|custom order|invoice|payment|tax|refund|guarantee|deadline|order status)\b/)

    product_signal = text.match?(/\b(yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?|starter\s*pack|pro\s*pack)\b/)
    price_signal = text.match?(/\b(how much|cost|costs|price|pricing|total|rate|quote|shipping|stakes|option|quantity|qty)\b/)
    numeric_signal = text.match?(/\b\d{1,5}\b/)
    product_signal && (price_signal || numeric_signal)
  end

  def fast_inbound_sms_reply(stage, body)
    metadata = stage.metadata.to_h
    return yard_sign_unit_pricing_fast_reply if yard_sign_unit_pricing_fast_question?(metadata, body)

    nil
  end

  def yard_sign_unit_pricing_fast_question?(metadata, body)
    text = body.to_s.downcase.squish
    return false if text.blank?
    return false if text.match?(/\b(?:proof|design|artwork|logo|rush|turnaround|deadline|consultant|person|call|email|postcards?|mail|eddm|blitz|starter\s*pack|pro\s*pack|bundle)\b/)

    sign_context = metadata.to_h["product_interest_code"].to_s == "LAWN_SIGNS" ||
      text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
    unit_question = text.match?(/\b(?:each|apiece|per\s+(?:sign|unit|piece)|one\s+sign|single\s+sign|what(?:'s| is)?\s+one\s+(?:sign\s+)?(?:cost|worth)|how\s+much\s+(?:is|are)\s+(?:each|one|a|single)\s+(?:yard\s+)?sign)\b/)

    sign_context && unit_question
  end

  def yard_sign_unit_pricing_fast_reply
    table = Comms::ProductCatalog.price_table("LAWN_SIGNS")
    entries = table.sort_by { |quantity, _values| quantity }.first(2)
    return if entries.blank?

    options = entries.filter_map do |quantity, values|
      price = values["price"].presence || values.values.find(&:present?)
      "#{quantity} for #{price}" if price.present?
    end
    return if options.blank?

    "The smallest reviewed options are #{options.to_sentence}. Which quantity should I use?"
  end

  def answerable_turnaround_question?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?
    return false if text.match?(/\b(order status|tracking|where is my order|where's my order|specific order|already ordered|invoice|refund|cancel)\b/)

    timing_signal = text.match?(/\b(turnaround|turn around|timeline|how long|how soon|when would|when will|need them by|need it by|asap|rush|expedite|production time|ship|shipping time|delivery time|arrive|get them)\b/)
    product_signal = text.match?(/\b(yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?|print|prints?|business cards?|door hangers?|flyers?|handouts?|starter\s*pack|pro\s*pack)\b/)
    timing_signal && product_signal
  end

  def autopilot_completion_ready?(metadata)
    metadata = metadata.to_h
    route = metadata["product_interest_code"].presence
    contact = identity_value(metadata["captured_contact_name"].presence || selected_contact(metadata)["name"])
    company = identity_value(metadata["captured_company_name"].presence || metadata["company_name"])
    route.present? && contact.present? && company.present? && !same_identity_value?(contact, company) && checkout_link_for(metadata).present?
  end

  def autopilot_completion_body(stage, metadata)
    label = metadata["product_interest_label"].presence || metadata["product_interest_code"].to_s.tr("_", " ").titleize.presence || "your project"
    recommendation = completion_recommendation(metadata, label)
    checkout_link = checkout_link_for(metadata)
    shopify = checkout_link.present? ? "Here is the checkout link for that option: #{checkout_link}" : nil
    [recommendation, shopify].compact.join(" ").squish
  end

  def completion_recommendation(metadata, label)
    route = metadata.to_h["product_interest_code"].to_s
    case route
    when "PRO_PACK"
      "Based on what you shared, I would start with the Pro Pack for the fuller neighborhood push."
    when "STARTER_PACK"
      "Based on what you shared, I would start with the Starter Pack for a tighter first run."
    when "BUSINESS_CARDS"
      "Based on what you shared, Business Cards look like the right order to start with."
    when "DOOR_HANGERS"
      "Based on what you shared, Door Hangers look like the right order to start with."
    when "FLYERS"
      "Based on what you shared, Flyers look like the right order to start with."
    when "LAWN_SIGNS"
      "Based on what you shared, Yard Signs look like the right order to start with."
    when "EDDM"
      "Based on what you shared, I would start with the postcard/EDDM option for mailbox reach."
    when "NEIGHBORHOOD_BLITZ"
      "Based on what you shared, I would start with the neighborhood blitz path for postcards plus local visibility."
    when "CUSTOM_ARTWORK"
      "Based on what you shared, I would start with custom artwork so the campaign is clean before print."
    else
      "Based on what you shared, I would start with #{label}."
    end
  end

  def strip_url_trailing_punctuation(text)
    text.to_s.gsub(%r{https?://\S+}) do |url|
      url.sub(/[.,;:!?)]+\z/, "")
    end
  end

  def corrected_yard_sign_quantity_body(inbound_body, outbound_body)
    quantity = exact_yard_sign_quantity_from_text(inbound_body)
    prices = configured_yard_sign_prices
    return if quantity.blank? || !prices.key?(quantity)
    return unless yard_sign_quantity_reply_conflicts?(quantity, outbound_body)

    price = prices.fetch(quantity)
    base = "#{quantity} yard signs are #{price}."
    checkout_url = Comms::ProductCatalog.checkout_url("LAWN_SIGNS")
    if yard_sign_checkout_request?(inbound_body) && checkout_url.present?
      "#{base} You can use the configured checkout page: #{checkout_url}"
    else
      "#{base} Want the checkout link for the #{quantity}-sign option?"
    end
  end

  def yard_sign_quantity_reply_conflicts?(quantity, outbound_body)
    text = outbound_body.to_s.downcase.squish
    return false if text.blank?

    prices = configured_yard_sign_prices
    other_quantity = prices.keys.any? do |candidate|
      next false if candidate == quantity

      text.match?(/\b#{candidate}\s*(?:-| )?\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|sign\s+option)\b/i)
    end
    return true if other_quantity

    expected_price = prices.fetch(quantity).delete("$,").to_i
    dollar_amounts = text.scan(/\$([\d,]+(?:\.\d{2})?)/).flatten.map { |value| value.delete(",").to_f }
    dollar_amounts.any? { |amount| amount.positive? && amount.round(2) != expected_price.to_f.round(2) }
  end

  def exact_yard_sign_quantity_from_text(text)
    body = text.to_s.downcase.squish
    return if body.blank?

    quantities = []
    body.scan(/\b(\d{1,5})\s*(?:yards?\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i) do |quantity|
      quantities << Array(quantity).first.to_s.delete(",").to_i
    end
    body.scan(/\b(?:yards?\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\s*(?:for|at|around|about|closer to)?\s*(\d{1,5})\b/i) do |quantity|
      quantities << Array(quantity).first.to_s.delete(",").to_i
    end

    quantities = quantities.select(&:positive?).uniq
    return unless quantities.one?

    quantities.first
  end

  def yard_sign_checkout_request?(text)
    text.to_s.match?(/\b(?:link|checkout|order|buy|ready|send|start|proceed|go ahead)\b/i)
  end

  def checkout_link_for(metadata)
    metadata = metadata.to_h
    route = checkout_route_code(metadata)
    candidates = [
      metadata.dig("comms_bot_state", "shopify_link"),
      configured_checkout_link(route),
      metadata["shopify_link"]
    ].filter_map { |link| link.to_s.squish.presence }.uniq

    candidates.find { |link| product_checkout_link?(link, route) } ||
      candidates.find { |link| !generic_checkout_link?(link) }
  end

  def checkout_link_present?(body)
    body.to_s.match?(%r{https?://}i)
  end

  def checkout_route_code(metadata)
    metadata.to_h["product_interest_code"].presence ||
      metadata.to_h.dig("comms_bot_state", "route_code").presence
  end

  def configured_checkout_link(route)
    route = route.to_s.presence
    return if route.blank?

    ENV["WIZWIKI_SHOPIFY_#{route}_URL"].presence ||
      ENV["SHOPIFY_#{route}_URL"].presence ||
      Comms::ProductCatalog.checkout_url(route)
  end

  def default_checkout_links
    Comms::ProductCatalog.shopify_links
  end

  def configured_yard_sign_prices
    Comms::ProductCatalog.price_table("LAWN_SIGNS").transform_values do |values|
      values["price"].presence || values.values.find(&:present?)
    end.compact_blank
  end

  def product_checkout_link?(link, route)
    return false if link.blank? || route.blank? || generic_checkout_link?(link)

    case route.to_s
    when "BUSINESS_CARDS"
      link.match?(%r{/(?:products|collections)/[^?#]*(?:business-cards?|business[_-]?cards?)}i)
    when "DOOR_HANGERS"
      link.match?(%r{/(?:products|collections)/[^?#]*(?:door-hangers?|doorhanger|hangers?)}i)
    when "FLYERS"
      link.match?(%r{/(?:products|collections)/[^?#]*(?:flyers?|flyers-canvasser|handouts?)}i)
    when "EDDM"
      link.match?(%r{/(?:products|collections)/[^?#]*(?:eddm|postcard|postcards|direct-mail|mailer)}i)
    else
      true
    end
  end

  def generic_checkout_link?(link)
    link.to_s.match?(%r{/collections/(?:all|origin)(?:[/?#]|\z)}i) ||
      link.to_s.match?(%r{/collections/?(?:[?#]|\z)}i)
  end

  def identity_value(value)
    return if generic_identity_value?(value)

    value.to_s.squish.presence
  end

  def stop_intent?(body, metadata = nil, inbound_sid: nil)
    text = body.to_s.squish
    return false if email_decline_response?(text, metadata)
    return false if bot_bridge_first_stop_consumed_for?(text, metadata, inbound_sid: inbound_sid)

    do_not_contact_intent?(text)
  end

  def consume_first_stop_for_bot_bridge!(stage, body, inbound_sid:, provider:)
    return false unless exact_stop_command?(body)

    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    return false unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_ignore_first_stop_for_bot_bridge"])
    return false if metadata["sms_autopilot_ignore_first_stop_consumed_at"].present?

    metadata["sms_autopilot_ignore_first_stop_for_bot_bridge"] = false
    metadata["sms_autopilot_ignore_first_stop_consumed_at"] = Time.current.iso8601
    metadata["sms_autopilot_ignore_first_stop_consumed_sid"] = inbound_sid.to_s.presence
    metadata["sms_autopilot_ignore_first_stop_consumed_provider"] = provider.to_s.presence
    metadata["sms_autopilot_ignore_first_stop_body"] = body.to_s.squish
    metadata["comms_command_last_status"] = "bot_bridge_first_stop_ignored"
    metadata["comms_command_last_at"] = Time.current.iso8601
    stage.update!(generated_at: Time.current, metadata: metadata.compact_blank)
    true
  end

  def bot_bridge_first_stop_consumed_for?(body, metadata, inbound_sid:)
    metadata = metadata.to_h
    return false if inbound_sid.blank?
    return false unless metadata["sms_autopilot_ignore_first_stop_consumed_sid"].to_s == inbound_sid.to_s

    exact_stop_command?(body) &&
      metadata["sms_autopilot_ignore_first_stop_body"].to_s.casecmp?(body.to_s.squish)
  end

  def do_not_contact_intent?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?
    return true if exact_stop_command?(text)

    text.match?(/\b(?:unsubscribe|opt\s*-?\s*out|remove me|take me off)\b/i) ||
      text.match?(/\b(?:do not|don't|dont)\s+(?:text|message|contact|sms)\b/i) ||
      text.match?(/\b(?:stop|quit|end|cancel)\s+(?:texting|messaging|messages?|texts?|sms)\b/i)
  end

  def exact_stop_command?(body)
    body.to_s.squish.match?(/\A(?:stop|unsubscribe|quit|end|cancel)\s*[.!]?\z/i)
  end

  def email_decline_response?(body, metadata = nil)
    text = body.to_s.squish.downcase
    return true if text.match?(/\b(no email|don't email|do not email|not by email)\b/)
    return false unless latest_identity_question_kind(metadata) == :email_opt_in

    text.match?(/\b(no|nope|nah|not now|no thanks)\b/i)
  end

  def queue_stage_memory!(stage)
    return defer_stage_memory!(stage) unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_EMBED_IMMEDIATE", "0"))
    return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

    Autos::EmbeddingQueue.enqueue_source!(stage, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] embedding queue failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def defer_stage_memory!(stage)
    stage.reload
    stage.update!(
      metadata: stage.metadata.to_h.merge(
        "comms_embedding_deferred" => true,
        "comms_embedding_deferred_until" => "evening_batch",
        "comms_embedding_deferred_at" => Time.current.iso8601
      )
    )
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] embedding defer mark failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def processing_payload(stage, metadata:, latest_body:)
    DealReports::CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: latest_body)
  end

  def route_lead_if_ready!(stage)
    routed_to = DealReports::CommsLeadRouter.route!(stage)
    Rails.logger.info("[TwilioWebhook] comms route claimed stage=#{stage.id} owner=#{routed_to.id}") if routed_to.respond_to?(:id)
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] comms route claim failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def twilio_context
    {
      "from_city" => params[:FromCity].to_s.presence,
      "from_state" => params[:FromState].to_s.presence,
      "from_zip" => params[:FromZip].to_s.presence,
      "from_country" => params[:FromCountry].to_s.presence,
      "to_city" => params[:ToCity].to_s.presence,
      "to_state" => params[:ToState].to_s.presence,
      "to_zip" => params[:ToZip].to_s.presence,
      "to_country" => params[:ToCountry].to_s.presence,
      "num_media" => params[:NumMedia].to_s.presence,
      "message_status" => params[:MessageStatus].to_s.presence,
      "sms_status" => params[:SmsStatus].to_s.presence,
      "api_version" => params[:ApiVersion].to_s.presence
    }.compact_blank
  end

  def heymarket_context(payload)
    data = payload.to_h["event_data"].to_h
    {
      "event_type" => payload["type"].to_s.presence,
      "event_id" => payload["id"].to_s.presence,
      "message_id" => data["id"].to_s.presence,
      "date" => data["date"].to_s.presence,
      "chat_id" => data["chat_id"].to_s.presence,
      "inbox_id" => data["inbox_id"].to_s.presence
    }.compact_blank
  end

  def location_capture_payload(metadata, body, twilio_context, provider: "twilio")
    text = body.to_s.squish
    context = twilio_context.to_h
    zip = extract_zip(text).presence || extract_zip(context["from_zip"])
    permission_accepted = location_permission_recently_requested?(metadata) && location_permission_accepted?(text)
    return {} if zip.blank? && !permission_accepted

    payload = {
      "id" => SecureRandom.uuid,
      "channel" => "sms",
      "direction" => "inbound",
      "status" => zip.present? ? "captured" : "permission_accepted",
      "zip" => zip,
      "postal_code" => zip,
      "city" => context["from_city"],
      "state" => context["from_state"],
      "country" => context["from_country"],
      "provider" => location_capture_provider(provider),
      "source" => location_capture_source(text, context, zip),
      "created_at" => Time.current.iso8601
    }.compact_blank
    thread = Array(metadata["location_thread"]).last(20)
    thread << payload

    {
      "location_thread" => thread,
      "location_capture_last" => payload,
      "location_capture_status" => zip.present? ? "consented" : "permission_accepted_zip_needed",
      "location_capture_at" => Time.current.iso8601
    }
  end

  def location_capture_provider(provider)
    provider.to_s == "haymarket" ? "haymarket_sms" : "twilio_sms"
  end

  def location_capture_source(text, context, zip)
    return "sms_body_zip" if zip.present? && extract_zip(text).present?
    return "twilio_from_zip" if zip.present? && extract_zip(context["from_zip"]).present?

    "sms_permission_reply"
  end

  def extract_zip(value)
    value.to_s[/\b\d{5}(?:-\d{4})?\b/]
  end

  def location_permission_recently_requested?(metadata)
    Array(metadata.to_h["sms_thread"]).reverse_each.first(8).any? do |event|
      event = event.to_h
      event["direction"].to_s == "outbound" &&
        event["body"].to_s.match?(/\b(check where|check your zip|zip codes? for shipping|share your zip|location|service area|specific area|neighbou?rhood|route area|mailing area)\b/i)
    end
  end

  def location_permission_accepted?(text)
    text.to_s.match?(/\b(yes|yeah|yep|sure|ok|okay|go ahead|please do|send it)\b/i)
  end

def identity_capture_payload(metadata, body)
  @identity_metadata_context = metadata
  updates = {}
  contact_name = extract_contact_name(body)
  company_name = extract_company_name(body)
  known_contact_name = contact_name.presence || metadata["captured_contact_name"].presence || selected_contact_name(metadata)
  company_name = nil if same_identity_value?(company_name, known_contact_name)
  industry = extract_industry(body)
  if industry.blank? && industry_value(metadata).blank?
    industry = infer_industry_from_company_name(
      company_name.presence ||
        metadata["captured_company_name"].presence ||
        metadata["company_name"].presence ||
        metadata["deal_name"].presence
    )
  end
  email = extract_email(body)
  email_opt_in = extract_email_opt_in(body, email: email)
  contact_preference = extract_contact_preference(body)
  preferred_contact_window = extract_preferred_contact_window(body)
  proof_delivery_method = extract_proof_delivery_method(body)
  proof_delivery_email = email if proof_delivery_method.to_s == "email" && email.present?

  if contact_name.present? && generic_identity_value?(selected_contact_name(metadata))

      contact = selected_contact(metadata).merge(
        "id" => selected_contact(metadata)["id"].presence || "sms-captured-contact",
        "name" => contact_name,
        "record_type" => selected_contact(metadata)["record_type"].presence || "sms",
        "reason" => "Captured from inbound SMS"
      )
      updates["captured_contact_name"] = contact_name
      updates["selected_contact_id"] = contact["id"]
      updates["contact_options"] = upsert_option(metadata["contact_options"], contact)
  end

    if company_name.present? && generic_identity_value?(metadata["company_name"])
      updates["captured_company_name"] = company_name
      updates["company_name"] = company_name
      updates["deal_name"] = company_name if generic_identity_value?(metadata["deal_name"])
    end

if industry.present? && industry_value(metadata).blank?
  updates["captured_industry"] = industry
  updates["industry"] = industry
end

if email.present? && email_value(metadata).to_s.downcase != email
  email_option = {
    "id" => "sms-captured-email",
    "email" => email,
    "value" => email,
    "label" => email,
    "record_type" => "sms",
    "reason" => "Captured from inbound SMS"
  }
  updates["captured_email"] = email
  updates["email_opt_in"] = "yes"
  updates["selected_recipient_email_id"] = email_option["id"]
  updates["recipient_email_options"] = upsert_option(metadata["recipient_email_options"], email_option)
elsif email_opt_in.present? && email_opt_in_value(metadata).to_s != email_opt_in.to_s
  updates["email_opt_in"] = email_opt_in
end

if contact_preference.present? && contact_preference_value(metadata).to_s != contact_preference.to_s
  updates["contact_preference"] = contact_preference
end

if proof_delivery_method.present?
  updates["proof_delivery_method"] = proof_delivery_method if metadata["proof_delivery_method"].to_s != proof_delivery_method.to_s
  updates["contact_preference"] ||= proof_delivery_method if %w[email sms phone either].include?(proof_delivery_method.to_s) && contact_preference_value(metadata).blank?
end

if proof_delivery_email.present? && metadata["proof_delivery_email"].to_s.downcase != proof_delivery_email.to_s.downcase
  updates["proof_delivery_email"] = proof_delivery_email
end

if updates["proof_delivery_method"].present? || updates["proof_delivery_email"].present?
  updates["proof_delivery_requested_at"] = Time.current.iso8601
end

if preferred_contact_window.present? && preferred_contact_window_value(metadata).to_s.downcase != preferred_contact_window.to_s.downcase
  updates["preferred_contact_window"] = preferred_contact_window
end

return {} if updates.blank?


    updates.merge(
      "identity_capture_status" => "updated",
      "identity_capture_last_body" => body.to_s.squish,
      "identity_capture_updated_at" => Time.current.iso8601
    )
  end

  def selected_contact(metadata)
    selected_id = metadata["selected_contact_id"].to_s
    options = Array(metadata["contact_options"])
    selected = options.find { |option| option.to_h["id"].to_s == selected_id }
    (selected || options.first || {}).to_h
  end

  def selected_contact_name(metadata)
    selected_contact(metadata)["name"].presence || metadata["captured_contact_name"].presence
  end

  def upsert_option(options, option)
    rows = Array(options).map { |candidate| candidate.to_h }
    index = rows.index { |candidate| candidate["id"].to_s == option["id"].to_s }
    if index
      rows[index] = rows[index].merge(option).compact_blank
    else
      rows.unshift(option.compact_blank)
    end
    rows
  end

  def extract_contact_name(body)
    text = body.to_s.squish
    candidate = text[/\b(?:my name is|i am|i'm|this is)\s+([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,3})\b/i, 1]
    return clean_identity_candidate(candidate) if candidate.present?

    return if latest_identity_question_kind.in?([:company, :industry, :email, :email_opt_in, :contact_preference, :preferred_contact_window])

    candidate = text[/\A([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2})\s+(?:at|with|from)\s+[^.!?;,]{2,80}\z/i, 1] if candidate.blank? && recently_asked_identity?
    candidate = text[/\A([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2})\s*[,\/-]\s*[^,\/-]{2,80}\z/i, 1] if candidate.blank? && recently_asked_identity?
    candidate = text if candidate.blank? && latest_identity_question_kind == :name && plausible_standalone_name?(text)
    candidate = text if candidate.blank? && identity_capture_context_active? && generic_identity_value?(selected_contact_name(@identity_metadata_context)) && plausible_standalone_name?(text)
    candidate = candidate.to_s.sub(/\b(?:and|with|from|at|my company|company|my business|business)\b.*\z/i, "")
    clean_identity_candidate(candidate)
  end

  def extract_company_name(body)
    text = body.to_s.squish
    candidate =
      text[/\b(?:my company is|company is|business is|business name is|we are|we're|i own|i run|from|with|at)\s+([^.!?;,]{2,80})/i, 1]
    candidate = text[/\A[a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2}\s*[,\/-]\s*([^,\/-]{2,80})\z/i, 1] if candidate.blank? && recently_asked_identity?
    candidate = text if candidate.blank? && latest_identity_question_kind == :company && plausible_standalone_company?(text)
    candidate = text if candidate.blank? && latest_identity_question_kind == :industry && company_like_business_context_response?(text)
    candidate = candidate.to_s.sub(/\b(?:and|but|because|so|we|i)\b.*\z/i, "")
    clean_identity_candidate(candidate, allow_company_words: true)
  end

def extract_industry(body)
  text = body.to_s.squish
  candidate =
    text[/\b(?:industry is|industry\:|we are in|we're in|i am in|i'm in|im in|business type is|type of business is)\s+([^.!?;,]{2,80})/i, 1]
  candidate ||= text[/\b(?:we are a|we're a|we are an|we're an|i run a|i run an|i own a|i own an)\s+([^.!?;,]{2,80}?)(?:\s+(?:company|business|shop|firm|agency|contractor|service|services))?\b/i, 1]
  candidate ||= text if latest_identity_question_kind == :industry && plausible_standalone_industry?(text) && !company_like_business_context_response?(text)
  clean_industry_candidate(candidate)
end

def infer_industry_from_company_name(value)
  text = value.to_s.squish
  return if generic_identity_value?(text)

  INDUSTRY_COMPANY_KEYWORDS.each do |pattern, label|
    return label if text.match?(pattern)
  end
  nil
end

def extract_email(body)
  text = body.to_s.squish
  direct = text[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i]
  return direct.downcase if direct.present?

  normalized = text.downcase
    .gsub(/\s*(?:\(|\[)?\s*\bat\b\s*(?:\)|\])?\s*/i, "@")
    .gsub(/\s*(?:\(|\[)?\s*\bdot\b\s*(?:\)|\])?\s*/i, ".")
    .gsub(/\s*@\s*/, "@")
    .gsub(/\s*\.\s*/, ".")
  normalized[/[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}/i].to_s.downcase.presence
end

def extract_email_opt_in(body, email: nil)
  return "yes" if email.present?

  text = body.to_s.squish.downcase
  return "yes" if text.match?(/\b(email me|e-mail me|send me email|send me an email|send it by email|send that by email|send the link by email|yes.*email|email is fine|email works|you can email|please email|by email is fine)\b/)
  return "no" if text.match?(/\b(no email|no emails|don't email|do not email|not by email|skip email|email not needed)\b/)
  return unless latest_identity_question_kind == :email_opt_in
  return "yes" if text.match?(/\b(yes|yeah|yep|sure|ok|okay|please|sounds good)\b/)
  return "no" if text.match?(/\b(no|nope|nah|not now|no thanks)\b/)

  nil
end

def extract_contact_preference(body)
  text = body.to_s.squish.downcase
  return "email" if text.match?(/\b(prefer email|email is best|email works|email only|by email|contact me by email|send it to my email)\b/)
  return "sms" if text.match?(/\b(prefer sms|text is best|sms is best|text works|texts work|text only|sms only|text me|send me a text|shoot me a text|by text|by sms|keep it here|no calls?|don't call|do not call)\b/)
  return "phone" if text.match?(/\b(prefer phone|phone is best|phone works|call works|call me|give me a call|by phone|by call)\b/)
  return "either" if text.match?(/\b(either|any is fine|whatever works|no preference)\b/)
  return unless latest_identity_question_kind == :contact_preference
  return "email" if text.match?(/\bemail\b/)
  return "sms" if text.match?(/\b(sms|text)\b/)
  return "phone" if text.match?(/\b(phone|call)\b/)
  return "either" if text.match?(/\b(either|any|no preference)\b/)

  nil
end

def extract_proof_delivery_method(body)
  text = body.to_s.squish.downcase
  proof_context = text.match?(/\b(proof|proofs|proofing|art|artwork|design|logo|file|layout)\b/)
  return "email" if text.match?(/\b(email|e-mail)\b/) && (proof_context || latest_identity_question_kind.in?([:email, :contact_preference]))
  return "sms" if proof_context && text.match?(/\b(text|sms|here|this thread|message me)\b/)
  return "phone" if proof_context && text.match?(/\b(call|phone)\b/)
  return "either" if proof_context && text.match?(/\b(either|any is fine|whatever works|no preference)\b/)

  nil
end

def extract_preferred_contact_window(body)
  text = body.to_s.squish
  return "anytime" if text.match?(/\b(anytime|whenever|any time|no time preference|any day works|anytime works)\b/i)
  return unless latest_identity_question_kind == :preferred_contact_window ||
    text.match?(/\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekday|weekend|morning|afternoon|evening|night|lunch|today|tomorrow|next week|this week|am|pm|a\.m\.|p\.m\.|after|before|between|around|early|late)\b/i)

  cleaned = text.gsub(/\b(yes|yeah|yep|sure|ok|okay|please|thanks|thank you)\b/i, "").squish
  return if cleaned.blank? || cleaned.match?(/\A(no|nope|nah|none|any)\z/i)

  cleaned[0, 120]
end

def recently_asked_identity?
    latest_identity_question_kind.present?
  end

  def latest_identity_question_kind(metadata = @identity_metadata_context)
    metadata = metadata.to_h
    Array(metadata["sms_thread"]).reverse_each.first(8).each do |event|
      event = event.to_h
      next unless event["direction"].to_s == "outbound"

      body = event["body"].to_s
      return :name if body.match?(/\b(what name|name should|put on this conversation)\b/i)
      return :company if body.match?(/\b(what company|company should|connect this to|company name|business name|what business)\b/i)
return :industry if body.match?(/\b(what industry|type of business|business type|what kind of business|what field)\b/i)
return :email_opt_in if body.match?(/\b(receive updates by email|want email|email too|by email too)\b/i)
return :email if body.match?(/\b(what email|email should|best email|email address|email.*proof|proof.*email|where should.*proof|send.*proof)\b/i)
return :contact_preference if body.match?(/\b(contact method|contact preference|prefer sms|prefer phone|prefer email|sms, phone, or email|text, call, or email|text, phone, or email|proofs?.*(?:text|call|email))\b/i)
return :preferred_contact_window if body.match?(/\b(days or times|what times|best time|best days|when should|when works)\b/i)
return :name if body.match?(/\bname and company\b/i)
    end
    nil
  end

  def recently_asked_company?
    latest_identity_question_kind == :company
  end

  def recently_asked_industry?
    latest_identity_question_kind == :industry
  end

  def identity_capture_context_active?
    metadata = @identity_metadata_context.to_h
    recently_asked_identity? ||
      recently_asked_industry? ||
      metadata["processing_code"].present? ||
      metadata["captured_company_name"].present? ||
      metadata["captured_industry"].present? ||
      !generic_identity_value?(metadata["company_name"])
  end

  def plausible_standalone_name?(text)
    cleaned = text.to_s.squish
    return false unless cleaned.match?(/\A[a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2}\z/i)
    return false if cleaned.match?(/\b(hi|hello|hey|yes|yeah|yep|sure|ok|okay|no|stop|thanks|thank you|great|got it|interested|send|tell me|more|what|kind|eddm|mail|sign|signs|blitz|art|artwork|help|test|morning|afternoon|evening|email|phone|sms|text)\b/i)

    true
  end

  def clean_identity_candidate(value, allow_company_words: false)
    text = value.to_s.squish
      .sub(/\A(?:called|named)\s+/i, "")
      .gsub(/\b(?:thanks|thank you|please|yes|yeah|sure|ok|okay)\b/i, "")
      .squish
    return if text.blank?
    return if text.length < 2 || text.length > 80
    return if text.match?(/\b(eddm|postcards?|mail|mailer|signs?|artwork|blitz|zip|shipping|oil|car|help|offer|services?)\b/i) && !allow_company_words

    text.split.map { |part| part.match?(/\A[A-Z0-9&.'-]+\z/) ? part : part.capitalize }.join(" ")
  end

  def plausible_standalone_industry?(text)
    cleaned = text.to_s.squish
    return false unless cleaned.match?(/\A[a-z0-9&.' -]{3,60}\z/i)
  return false if cleaned.match?(/\b(hi|hello|hey|yes|yeah|yep|sure|ok|okay|no|stop|thanks|thank you|great|got it|interested|send|tell me|more|what|kind|help|test)\b/i)
  return false if cleaned.match?(/\b(poolside|right now|rn|at home|outside|driving|watching|walking|eating|working)\b/i)
  true
end

def plausible_standalone_company?(text)
    cleaned = text.to_s.squish
    return false unless cleaned.match?(/\A[a-z0-9&.' -]{2,80}\z/i)
    return false if cleaned.match?(/\b(hi|hello|hey|yes|yeah|yep|sure|ok|okay|no|stop|thanks|thank you|great|got it|interested|send|tell me|more|what|kind|eddm|mail|sign|signs|blitz|art|artwork|help|test|zip)\b/i)

    true
  end

  def company_like_business_context_response?(text)
    cleaned = text.to_s.squish
    return false unless cleaned.match?(/\A[a-z0-9&.' -]{2,80}\z/i)
    return true if company_legal_suffix?(cleaned)
    return false unless plausible_standalone_company?(cleaned)

    cleaned.split(/\s+/).length >= 2 && cleaned.match?(/\b(roofing|roofers?|plumbing|hvac|heating|cooling|electrical|landscap|construction|contractor|painting|flooring|restoration|pest|solar|concrete|masonry|remodel)\b/i)
  end

  def company_legal_suffix?(text)
    text.to_s.match?(/\b(?:l\.?\s*l\.?\s*c\.?|llc|inc(?:orporated)?|corp(?:oration)?|co\.?|company|llp|pllc|group|partners|enterprises)\b/i)
  end

  def clean_industry_candidate(value)
    text = value.to_s.squish
      .sub(/\A(?:a|an|the)\s+/i, "")
      .sub(/\b(?:company|business|shop|firm|agency|contractor|service|services)\b\z/i, "")
      .gsub(/\b(?:thanks|thank you|please|yes|yeah|sure|ok|okay)\b/i, "")
      .squish
    return if text.blank?
    return if text.length < 3 || text.length > 80
    return if company_legal_suffix?(text)
  return if text.match?(/\b(zip|shipping|oil|car|help|offer|services?|company name|my name)\b/i)
  return if text.match?(/\b(poolside|right now|rn|at home|outside|driving|watching|walking|eating|working)\b/i)

text.split
.map { |part| part.match?(/\A[A-Z0-9&.'-]+\z/) ? part : part.capitalize }.join(" ")
  end


def email_value(metadata)
  metadata["captured_email"].presence ||
    metadata["recipient_email"].presence ||
    metadata.dig("aircall_selected_recipient_email", "email").presence ||
    metadata.dig("aircall_selected_recipient_email", "value").presence ||
    option_by_id(metadata, "recipient_email_options", "selected_recipient_email_id")["email"].presence ||
    option_by_id(metadata, "recipient_email_options", "selected_recipient_email_id")["value"].presence
end

def email_opt_in_value(metadata)
  value = metadata["email_opt_in"].to_s.downcase
  return "yes" if value.in?(%w[yes true 1 y])
  return "no" if value.in?(%w[no false 0 n])
  return "yes" if email_value(metadata).present?

  nil
end

def contact_preference_value(metadata)
  metadata["contact_preference"].to_s.squish.presence
end

def preferred_contact_window_value(metadata)
  metadata["preferred_contact_window"].to_s.squish.presence ||
    metadata["preferred_contact_days"].to_s.squish.presence ||
    metadata["preferred_contact_times"].to_s.squish.presence
end

def contact_preference_requires_window?(metadata)
  contact_preference_value(metadata).to_s.match?(/\b(sms|text|phone|call)\b/i)
end

def optional_discovery_complete?(metadata)
  email_ready = email_value(metadata).present? || email_opt_in_value(metadata) == "no"
  preference_ready = contact_preference_value(metadata).present?
  window_ready = !contact_preference_requires_window?(metadata) || preferred_contact_window_value(metadata).present?
  email_ready && preference_ready && window_ready
end

def option_by_id(metadata, options_key, selected_key)
  selected_id = metadata[selected_key].to_s
  options = Array(metadata[options_key])
  match = options.find { |option| option.to_h["id"].to_s == selected_id }
  (match || options.first || {}).to_h
end

  def generic_identity_value?(value)
    text = value.to_s.squish.downcase
    text.blank? || GENERIC_COMMS_IDENTITY_VALUES.include?(text) || text.match?(/\A(?:wizwiki\s*)?comms\b/) || text.match?(/\Asample\b/)
  end

  def same_identity_value?(left, right)
    left_text = left.to_s.squish.downcase
    right_text = right.to_s.squish.downcase
    left_text.present? && left_text == right_text
  end

  def industry_value(metadata)
[
  metadata["captured_industry"],
  metadata["industry"],
  metadata["company_industry"],
  metadata["crm_industry"],
  metadata["industry_strategy_label"],
  metadata.dig("industry_strategy", "label"),
  metadata.dig("industry_strategy", "industry"),
  infer_industry_from_company_name(metadata["captured_company_name"].presence || metadata["company_name"].presence || metadata["deal_name"].presence)
].each do |candidate|
      value = normalize_industry(candidate)
      return value if value.present?
    end
    nil
  end

  def normalize_industry(value)
    text = value.to_s.tr("_", " ").squish
    return if text.blank?
    return if text.match?(/\A(auto|unknown|not provided|not set|n\/a|na|none|general|fallback)\z/i)
    return if text.match?(/\A(general )?local services?\z/i)

    text
  end

  def apply_identity_to_crm_record!(stage, identity)
    return if identity.blank? || stage.crm_record.blank?

    record = stage.crm_record
    properties = record.properties.to_h.merge(
      "sms_captured_contact_name" => identity["captured_contact_name"].presence || record.properties.to_h["sms_captured_contact_name"],
      "sms_captured_company_name" => identity["captured_company_name"].presence || record.properties.to_h["sms_captured_company_name"],
"sms_captured_industry" => identity["captured_industry"].presence || record.properties.to_h["sms_captured_industry"],
"sms_captured_email" => identity["captured_email"].presence || record.properties.to_h["sms_captured_email"],
"sms_email_opt_in" => identity["email_opt_in"].presence || record.properties.to_h["sms_email_opt_in"],
"sms_contact_preference" => identity["contact_preference"].presence || record.properties.to_h["sms_contact_preference"],
"sms_preferred_contact_window" => identity["preferred_contact_window"].presence || record.properties.to_h["sms_preferred_contact_window"],
"sms_identity_capture_updated_at" => identity["identity_capture_updated_at"].presence || Time.current.iso8601
    ).compact_blank
    record.assign_attributes(properties: properties)
    if identity["captured_company_name"].present? && (record.source.to_s == "manual_comms" || generic_identity_value?(record.name))
      record.name = identity["captured_company_name"]
    elsif identity["captured_contact_name"].present? && generic_identity_value?(record.name)
      record.name = identity["captured_contact_name"]
    end
    record.save! if record.changed?
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] identity capture failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def apply_location_to_crm_record!(stage, location)
    payload = location.to_h["location_capture_last"].to_h
    return if payload.blank? || stage.crm_record.blank?

    record = stage.crm_record
    properties = record.properties.to_h.merge(
      "sms_captured_zip" => payload["postal_code"].presence || payload["zip"].presence || record.properties.to_h["sms_captured_zip"],
      "sms_captured_city" => payload["city"].presence || record.properties.to_h["sms_captured_city"],
      "sms_captured_state" => payload["state"].presence || record.properties.to_h["sms_captured_state"],
      "sms_captured_country" => payload["country"].presence || record.properties.to_h["sms_captured_country"],
      "sms_location_capture_status" => location.to_h["location_capture_status"],
      "sms_location_capture_source" => payload["source"],
      "sms_location_capture_updated_at" => location.to_h["location_capture_at"].presence || Time.current.iso8601
    ).compact_blank
    record.assign_attributes(properties: properties)
    record.save! if record.changed?
  rescue StandardError => error
    Rails.logger.warn("[TwilioWebhook] location capture failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def ensure_location_token!(stage)
    metadata = stage.metadata.to_h
    token = metadata["location_capture_token"].to_s.presence
    base_url = ENV["WIZWIKI_PUBLIC_URL"].presence || ENV["APP_HOST"].presence || "https://wizwiki.local"
    if token.present?
      stage.update!(metadata: metadata.merge("location_capture_url" => "#{base_url.to_s.chomp('/')}/comms/location/#{token}")) if metadata["location_capture_url"].blank?
      return token
    end

    token = SecureRandom.urlsafe_base64(24)
    stage.update!(
      metadata: metadata.merge(
        "location_capture_token" => token,
        "location_capture_url" => "#{base_url.to_s.chomp('/')}/comms/location/#{token}"
      )
    )
    token
  end

  def phone_tail(value)
    digits = value.to_s.gsub(/\D/, "")
    digits.length >= 7 ? digits.last(10) : nil
  end

  def masked_phone(value)
    tail = phone_tail(value)
    tail.present? ? "***#{tail.last(4)}" : "blank"
  end
end
