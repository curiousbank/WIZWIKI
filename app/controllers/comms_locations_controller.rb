require "json"
require "net/http"
require "uri"

class CommsLocationsController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :verify_authenticity_token, only: :create

  def show
    @stage = stage_from_token!
    @company_name = @stage.metadata.to_h["company_name"].presence || @stage.crm_record&.name.to_s.presence || "WIZWIKI Marketing"
    @sender_name = @stage.metadata.dig("sender_profile", "name").presence || @stage.metadata.to_h["sender_name"].presence || "Thumper"
  end

  def create
    stage = stage_from_token!
    latitude = params[:latitude].to_s.strip
    longitude = params[:longitude].to_s.strip
    accuracy = params[:accuracy].to_s.strip.presence

    if latitude.blank? || longitude.blank?
      render json: { ok: false, error: "Missing coordinates." }, status: :unprocessable_entity
      return
    end

    address = reverse_geocode(latitude, longitude)
    metadata = stage.metadata.to_h.deep_dup
    payload = {
      "id" => SecureRandom.uuid,
      "channel" => "location",
      "direction" => "inbound",
      "status" => "consented",
      "latitude" => latitude,
      "longitude" => longitude,
      "accuracy_meters" => accuracy,
      "address" => address,
      "zip" => extract_zip(address),
      "provider" => "browser_geolocation",
      "created_at" => Time.current.iso8601
    }.compact_blank
    thread = Array(metadata["location_thread"]).last(20)
    thread << payload

    sms_thread = Array(metadata["sms_thread"]).last(50)
    sms_thread << {
      "id" => payload["id"],
      "channel" => "location",
      "direction" => "inbound",
      "status" => "consented",
      "body" => location_summary(payload),
      "provider" => "browser_geolocation",
      "created_at" => Time.current.iso8601
    }.compact_blank

    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "location_thread" => thread,
        "sms_thread" => sms_thread,
        "location_capture_last" => payload,
        "location_capture_status" => "consented",
        "location_capture_at" => Time.current.iso8601,
        "comms_command_last_channel" => "location",
        "comms_command_last_status" => "consented",
        "comms_command_last_at" => Time.current.iso8601,
        "comms_embedding_deferred" => true,
        "comms_embedding_deferred_until" => "evening_batch",
        "comms_embedding_deferred_at" => Time.current.iso8601
      )
    )
    continue_autopilot_after_location!(stage.reload, inbound_event_id: payload["id"])

    render json: { ok: true, address: address, zip: payload["zip"] }
  rescue ActiveRecord::RecordNotFound
    render json: { ok: false, error: "Location link not found." }, status: :not_found
  rescue StandardError => error
    Rails.logger.warn("[CommsLocation] capture failed #{error.class}: #{error.message}")
    render json: { ok: false, error: "Could not save location." }, status: :ok
  end

  private

  def stage_from_token!
    token = params[:token].to_s
    raise ActiveRecord::RecordNotFound if token.blank?

    CrmRecordArtifact
      .where(artifact_type: "comm_staging")
      .where("metadata ->> 'location_capture_token' = ?", token)
      .where("updated_at > ?", 180.days.ago)
      .order(updated_at: :desc)
      .first!
  end

  def reverse_geocode(latitude, longitude)
    opencage_reverse_geocode(latitude, longitude).presence || nominatim_reverse_geocode(latitude, longitude)
  end

  def opencage_reverse_geocode(latitude, longitude)
    key = ENV["OPENCAGE_API_KEY"].presence
    return if key.blank?

    uri = URI("https://api.opencagedata.com/geocode/v1/json")
    uri.query = URI.encode_www_form(q: "#{latitude},#{longitude}", key: key, limit: 1, no_annotations: 1, pretty: 0)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 2, read_timeout: 4) do |http|
      http.get(uri.request_uri)
    end
    return unless response.is_a?(Net::HTTPSuccess)

    json = JSON.parse(response.body) rescue {}
    json.dig("results", 0, "formatted")
  rescue StandardError => error
    Rails.logger.warn("[CommsLocation] OpenCage miss #{error.class}: #{error.message}")
    nil
  end

  def nominatim_reverse_geocode(latitude, longitude)
    uri = URI("https://nominatim.openstreetmap.org/reverse")
    uri.query = URI.encode_www_form(lat: latitude, lon: longitude, format: "jsonv2", addressdetails: 1)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "wizwiki.local/1.0 (thumper@wizwiki.local)"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 2, read_timeout: 4) do |http|
      http.request(request)
    end
    return unless response.is_a?(Net::HTTPSuccess)

    json = JSON.parse(response.body) rescue {}
    json["display_name"]
  rescue StandardError => error
    Rails.logger.warn("[CommsLocation] Nominatim miss #{error.class}: #{error.message}")
    nil
  end

  def extract_zip(address)
    address.to_s[/\b\d{5}(?:-\d{4})?\b/]
  end

  def location_summary(payload)
    pieces = []
    pieces << "Location shared with permission."
    pieces << "ZIP #{payload["zip"]}" if payload["zip"].present?
    pieces << payload["address"] if payload["address"].present?
    pieces.join(" ")
  end

  def continue_autopilot_after_location!(stage, inbound_event_id:)
    metadata = stage.metadata.to_h.deep_dup
    return unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"])
    return if autopilot_already_answered?(metadata, inbound_event_id: inbound_event_id)

    route_lead_if_ready!(stage)
    stage.reload
    metadata = stage.metadata.to_h.deep_dup

    to = metadata["sms_listener_to"].to_s.presence || selected_phone(metadata)
    return if to.blank?

    user = stage.user
    profile = user&.respond_to?(:twilio_profile) ? user.twilio_profile.to_h : {}
    completion = autopilot_completion_ready?(metadata) && metadata["sms_autopilot_completion_sent_at"].blank?
    draft = if completion
      {
        "body" => autopilot_completion_body(metadata),
        "provider" => "location_capture",
        "model" => nil,
        "reason" => "All discovery fields are complete after location capture."
      }
    else
      DealReports::CommsDraftWriter.call(
        stage: stage.reload,
        user: user,
        operator_prompt: "Customer shared ZIP/location with permission. Draft the next short SMS as Thumper from WIZWIKI Marketing. Keep going with one missing discovery item only: first name, company name, or campaign lane. Do not ask for industry or business type. If route/name/company/ZIP are now known, keep helping with the best checkout path, a useful comparison, or the design/proof next step without making the conversation sound finished.",
        wait_seconds: ENV.fetch("WIZWIKI_COMMS_LOCATION_AUTOPILOT_WAIT_SECONDS", "25").to_i
      )
    end
    raw_body = draft.to_h["body"].to_s.squish
    body = safe_customer_sms_body(raw_body)
    if raw_body.present? && body.blank?
      Rails.logger.warn("[CommsLocation] blocked unsafe location autopilot SMS stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_body)}")
    end
    return if body.blank?

    body = sms_delivery_body_for_stage(stage, body)
    result = Comms::SmsProvider.deliver!(
      to: to,
      body: body,
      from_number: metadata["sms_listener_from"].presence || profile["from_number"].presence,
      messaging_service_sid: profile["messaging_service_sid"].presence
    )
    thread = Array(metadata["sms_thread"]).last(50)
    thread << {
      "id" => SecureRandom.uuid,
      "channel" => "sms",
      "direction" => "outbound",
      "status" => "sent",
      "to" => to,
      "from" => result.to_h["from"].presence || metadata["sms_listener_from"],
      "body" => body,
      "provider" => result.to_h["provider"].presence || "twilio",
      "provider_message_id" => result.to_h["sid"],
      "provider_status" => result.to_h["status"],
      "autopilot" => true,
      "autopilot_completion" => completion,
      "autopilot_reply_to_sid" => inbound_event_id,
      "draft_provider" => draft.to_h["provider"].presence,
      "draft_model" => draft.to_h["model"].presence,
      "created_at" => Time.current.iso8601
    }.merge(sms_delivery_language_event_payload).compact_blank
    history = Array(metadata["sms_draft_history"]).last(24)
    history << {
      "id" => SecureRandom.uuid,
      "body" => body,
      "provider" => draft.to_h["provider"],
      "model" => draft.to_h["model"],
      "reason" => draft.to_h["reason"].presence || "Auto-drafted after browser ZIP/location capture.",
      "autos_question_id" => draft.to_h["autos_question_id"],
      "created_at" => Time.current.iso8601
    }.compact_blank
    completion_metadata = completion ? {
      "sms_autopilot_completed_at" => Time.current.iso8601,
      "sms_autopilot_completion_sent_at" => Time.current.iso8601,
      "sms_autopilot_enabled" => false,
      "sms_autopilot_disabled_at" => Time.current.iso8601,
      "sms_autopilot_disabled_reason" => "data_capture_complete",
      "comms_command_last_status" => "autopilot_complete"
    } : {}
    stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "sms_draft_history" => history,
        "comms_command_sms_draft_body" => completion ? safe_customer_sms_body(metadata["comms_command_sms_draft_body"]) : body,
        "comms_command_sms_draft" => draft.to_h.merge("created_at" => Time.current.iso8601),
        "comms_bot_state" => draft.to_h["conversation_state"].presence || metadata["comms_bot_state"],
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "autopilot_sent",
        "comms_command_last_at" => Time.current.iso8601,
        "sms_listener_active" => true,
        "sms_listener_until" => 7.days.from_now.iso8601,
        "sms_listener_to" => to,
        "sms_listener_from" => result.to_h["from"].presence || metadata["sms_listener_from"].presence || profile["from_number"].presence,
        "sms_listener_last_outbound_sid" => result.to_h["sid"],
        "sms_listener_last_outbound_at" => Time.current.iso8601,
        "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
        "sms_autopilot_last_sent_at" => Time.current.iso8601,
        "sms_autopilot_last_reply_to_sid" => inbound_event_id,
        "sms_autopilot_last_error" => nil
      ).merge(completion_metadata)
    )
    notify_completion_without_purchase_if_needed!(stage.reload) if completion
  rescue StandardError => error
    metadata = stage&.metadata.to_h.deep_dup
    stage&.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_autopilot_last_error" => error.message,
        "sms_autopilot_last_error_at" => Time.current.iso8601
      )
    )
    Rails.logger.warn("[CommsLocation] autopilot location continuation failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def autopilot_already_answered?(metadata, inbound_event_id:)
    return false if inbound_event_id.to_s.blank?

    Array(metadata["sms_thread"]).any? do |event|
      event.to_h["autopilot_reply_to_sid"].to_s == inbound_event_id.to_s
    end
  end

  def safe_customer_sms_body(value)
    return if value.blank?
    return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

    value.to_s.squish.presence
  end

  def sms_delivery_body_for_stage(stage, value)
    @last_sms_delivery_language_event = nil
    body = value.to_s.squish
    return body if body.blank?
    if defined?(Comms::SmsBodySafety)
      body = Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage&.metadata)
    end
    if defined?(Comms::SmsLanguageSupport)
      result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
      @last_sms_delivery_language_event = result.to_h["event"]
      persist_sms_language_metadata!(stage, result.to_h["metadata"])
      body = result.to_h["body"].presence || body
    end
    body
  end

  def sms_delivery_language_event_payload
    @last_sms_delivery_language_event.to_h.compact_blank
  end

  def persist_sms_language_metadata!(stage, updates)
    return if stage.blank? || updates.to_h.blank?

    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(generated_at: Time.current, metadata: metadata.merge(updates.to_h).compact_blank)
  rescue StandardError => error
    Rails.logger.warn("[CommsLocations] SMS language metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def sms_body_safety_reason(value)
    return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

    "unsafe_sms_body"
  end

  def route_lead_if_ready!(stage)
    routed_to = DealReports::CommsLeadRouter.route!(stage)
    Rails.logger.info("[CommsLocation] comms route claimed stage=#{stage.id} owner=#{routed_to.id}") if routed_to.respond_to?(:id)
  rescue StandardError => error
    Rails.logger.warn("[CommsLocation] comms route claim failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def notify_completion_without_purchase_if_needed!(stage)
    return unless defined?(Comms::SlackNotifier)

    reason = "Thumper completed SMS discovery after location capture and no Shopify/order purchase evidence is attached after 72 hours."
    Comms::SlackNotifier.ensure_completion_without_purchase_pending!(stage: stage, reason: reason)
    return unless Comms::SlackNotifier.completion_without_purchase_due?(stage.reload)

    Comms::SlackNotifier.post_completion_without_purchase!(
      stage: stage,
      owner: Comms::SlackNotifier.safe_owner(stage.user),
      reason: reason,
      force: true
    )
  end

  def autopilot_completion_ready?(metadata)
    route = metadata["processing_code"].presence
    contact = identity_value(metadata["captured_contact_name"].presence || selected_contact(metadata)["name"])
    company = identity_value(metadata["captured_company_name"].presence || metadata["company_name"])
    zip = metadata.dig("location_capture_last", "postal_code").presence ||
      metadata.dig("location_capture_last", "zip").presence ||
      Array(metadata["sms_thread"]).filter_map { |event| event.to_h["body"].to_s[/\b\d{5}(?:-\d{4})?\b/] }.last

    route.present? && contact.present? && company.present? && zip.present?
  end

  def autopilot_completion_body(metadata)
    contact = identity_value(metadata["captured_contact_name"].presence || selected_contact(metadata)["name"])
    label = metadata["processing_label"].presence || metadata["processing_code"].to_s.tr("_", " ").titleize.presence || "your project"
    owner = metadata["comms_routed_to_user_name"].presence || metadata["comms_routed_to_user_email"].presence
    handoff = owner.present? ? "#{owner} will be in touch shortly." : "Someone from WIZWIKI will be in touch shortly."
    ["I have what I need for #{label}.", handoff].join(" ").squish
  end

  def selected_contact(metadata)
    selected_id = metadata["selected_contact_id"].to_s
    options = Array(metadata["contact_options"])
    selected = options.find { |option| option.to_h["id"].to_s == selected_id }
    (selected || options.first || {}).to_h
  end

  def selected_phone(metadata)
    selected_id = metadata["selected_phone_id"].to_s
    options = Array(metadata["phone_options"])
    selected = options.find { |option| option.to_h["id"].to_s == selected_id }
    (selected || options.first || {}).to_h["value"].to_s.presence
  end

  def identity_value(value)
    text = value.to_s.squish
    return if text.blank?
    return if text.downcase.in?(["wizwiki comms", "sample comms", "manual comms", "choose in lab", "contact", "customer"])
    return if text.match?(/\A(?:wizwiki\s*)?comms\b/i) || text.match?(/\Asample\b/i)

    text
  end

  def industry_value(metadata)
    [
      metadata["captured_industry"],
      metadata["industry"],
      metadata["company_industry"],
      metadata["crm_industry"],
      metadata["industry_strategy_label"],
      metadata.dig("industry_strategy", "label"),
      metadata.dig("industry_strategy", "industry")
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
end
