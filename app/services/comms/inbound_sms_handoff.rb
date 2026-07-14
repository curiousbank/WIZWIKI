require "timeout"

module Comms
  class InboundSmsHandoff
    Result = Struct.new(:handled, :reason, :owner, :slack_posted, :review_draft_saved, keyword_init: true)

    def self.call(stage:, body:, reason: nil, source: nil, review_body: nil)
      new(stage: stage, body: body, reason: reason, source: source, review_body: review_body).call
    end

    def self.required?(body, stage: nil)
      reason_for(body, stage: stage).present?
    end

    def self.contact_collection_active?(stage)
      metadata = stage&.reload&.metadata.to_h
      ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_handoff_contact_pending"])
    rescue StandardError
      false
    end

    def self.contact_collection_response?(stage, body)
      return false unless contact_collection_active?(stage)

      text = body.to_s.squish
      return false if text.blank?
      return true if text.match?(/\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i)
      return true if text.gsub(/\D/, "").length >= 7
      return true if affirmative_contact_reply?(text)
      return true if Comms::ContactWindowParser.extract(text).present?
      return true if text.match?(/\A(?:please\s+)?(?:email|e-mail|text|sms|call|phone)(?:\s+(?:me|works|is best|please|this number|same number|that number))?(?:\s+(?:today|tomorrow|anytime|any time|this (?:morning|afternoon|evening)|(?:after|before|at)\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?))?[\s.!]*\z/i)
      return true if text.match?(/\A(?:by|via)\s+(?:email|e-mail|text|sms|phone|call)[\s.!]*\z/i)
      return true if text.match?(/\A(?:use\s+)?(?:this|same|that)\s+(?:number|email)(?:\s+is fine)?[\s.!]*\z/i)
      return true if text.match?(/\A(?:reach|contact)\s+me\s+(?:by|via)\s+(?:email|e-mail|text|sms|phone|call)[\s.!]*\z/i)

      text.match?(/\A(?:today|tomorrow|anytime|any time|(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?:\s+(?:morning|afternoon|evening))?|(?:morning|afternoon|evening)|(?:after|before)\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?|\d{1,2}(?::\d{2})?\s*(?:am|pm))[\s.!]*\z/i)
    rescue StandardError
      false
    end

    def self.accepted_recent_contact_offer?(stage, body)
      return false unless affirmative_contact_reply?(body)

      metadata = stage&.reload&.metadata.to_h
      return false if metadata.blank?
      return false if metadata["sms_autopilot_handoff_contact_posted_at"].present?

      Array(metadata["sms_thread"]).map(&:to_h).reverse.first(12).any? do |event|
        event["direction"].to_s == "outbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped]) &&
          consultant_handoff_offer?(event["body"])
      end
    rescue StandardError
      false
    end

    def self.reason_for(body, stage: nil)
      return "rush_or_deadline_confirmation_sms" if fulfillment_confirmation_required?(body, stage: stage)
      return "human_requested_sms" if human_request?(body)
      return "checkout_support_needed_sms" if checkout_handoff_needed?(body)
      return "account_manager_answer_needed_sms" if account_manager_answer_needed?(body)

      nil
    end

    def self.fulfillment_confirmation_required?(body, stage: nil)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return true if explicit_rush_request?(text)
      return true if explicit_hard_deadline?(text)
      return false if stage.blank? || !bare_deadline_reply?(text)

      events = Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).last(12)
      latest_outbound = events.reverse.find do |event|
        event["direction"].to_s == "outbound" && event["body"].to_s.squish.present?
      end.to_h["body"].to_s.downcase.squish
      recent_inbound = events.select { |event| event["direction"].to_s == "inbound" }
        .filter_map { |event| event["body"].to_s.downcase.squish.presence }
        .last(6)

      deadline_prompt = latest_outbound.match?(/\b(?:deadline|what day|which day|when do you need|need (?:them|it|the order).{0,40}by|delivery date|arrive by|ready by)\b/)
      rush_context = recent_inbound.any? { |message| explicit_rush_request?(message) }
      deadline_prompt || rush_context
    rescue StandardError
      false
    end

    def self.explicit_rush_request?(body)
      body.to_s.match?(/\b(?:rush(?:ed)?|expedit(?:e|ed)|asap|same[- ]day|next[- ]day|overnight)\b/i)
    end

    def self.explicit_hard_deadline?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      date_signal = "(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next\\s+(?:day|week|monday|tuesday|wednesday|thursday|friday)|\\d{1,2}[/-]\\d{1,2}(?:[/-]\\d{2,4})?)"
      text.match?(/\b(?:need|must|have|get|arrive|deliver|delivery|ready|by)\b.{0,80}\b#{date_signal}\b/i)
    end

    def self.bare_deadline_reply?(body)
      text = body.to_s.downcase.squish
      return false if text.blank? || text.length > 80 || text.include?("?")

      text.match?(%r{\A(?:by\s+)?(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next\s+(?:day|week|monday|tuesday|wednesday|thursday|friday)|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)(?:\s+(?:morning|afternoon|evening|night|by\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?))?[.!]*\z}i)
    end

    def self.human_request?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\b(?:human|person|rep|representative|sales\s*(?:person|rep)?|account\s*manager|marketing\s+consultant|consultant|manager|someone|team|owner)\b/) &&
        text.match?(/\b(?:talk|speak|call|connect|contact|reach|help|get|want|need|can|please)\b/)
    end

    def self.account_manager_answer_needed?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false if human_request?(text)
      return true if checkout_handoff_needed?(text)
      return true if frustrated_or_support_pressure?(text) && explicit_support_handoff_request?(text)

      false
    end

    def self.checkout_handoff_needed?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      checkout_context = text.match?(/\b(?:checkout|check out|cart|payment|pay|paid|order|link|url|website|site|shopify)\b/)
      blocked = text.match?(/\b(?:can'?t|cannot|couldn'?t|won'?t|will not|error|failed|fails|failure|not working|doesn'?t work|isn'?t working|stuck|broken|declined|decline|missing|issue|problem|trouble|won'?t load|will not load)\b/)
      checkout_context && blocked
    end

    def self.explicit_support_handoff_request?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      human_request?(text) || text.match?(/\b(?:support person|human support|account manager|assistant|sales rep|representative|someone call|call me|email me|text me)\b/)
    end

    def self.affirmative_contact_reply?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false if text.include?("?")

      text.match?(/\A(?:yes|yesd|yep|yeah|sure|ok|okay|please|absolutely|that works|sounds good|do that|go ahead|please do)[\s.!]*\z/) ||
        text.match?(/\b(?:yes|yesd|yep|yeah|sure|ok|okay|please|absolutely|that works|sounds good|go ahead|please do|let'?s do|lets do|do this|this number|same number|use this number|use that number|text only)\b/)
    end

    def self.consultant_handoff_offer?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false unless text.match?(/\b(?:marketing consultant|consultant|wizwiki teammate|teammate|person|someone)\b/)
      return false unless text.match?(/\b(?:want me|would it be helpful|can i|should i|check this|reach out|go over|connect|best way for (?:them|someone|a consultant|our consultant) to reach|what(?:'s| is) the best way)\b/)
      return false if text.match?(/\b(?:will be contacting|i let them know|getting that to|got this to)\b/)

      true
    end

    def self.frustrated_or_support_pressure?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\b(?:frustrated|upset|angry|annoyed|not helping|isn'?t helping|this isn'?t helping|you(?:'re| are)? not answering|not answering my question|still confused|still don'?t understand|still do not understand|still lost|need support|want support|support person)\b/)
    end

    def self.discount_or_negotiation_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\b(discount|discounts|price break|bulk discount|better price|best price|deal|special price|special rate|coupon|promo|promotion|negotiate|match (?:a|the)?\s*price)\b/)
    end

    def self.unpriceable_postcard_pricing_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\b(how\s+(?:much|mush)|cost|costs|price|pricing|total|rate|rates|charge|charges|quote|quotes|estimate)\b/) &&
        text.match?(/\b(post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/)
    end

    def self.product_option_mismatch?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return true if outside_deal_quantity_pressure?(text)

      text.match?(/\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|where is|missing)\b.*\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b/) ||
        text.match?(/\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b.*\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|missing)\b/) ||
        text.match?(/\b(?:option|quantity|qty|pack|bundle)\s+for\s+\d+\b/) ||
        text.match?(/\b\d+\s+(?:signs?|yard signs?|lawn signs?)\b.*\b(?:option|link|checkout|pack|bundle)\b/) ||
        text.match?(/\b(?:custom|different|specific)\s+(?:quantity|qty|amount|count|number)\b/)
    end

    def self.priceable_product_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false if outside_deal_quantity_pressure?(text)
      return false if text.match?(/\b(custom quote|custom order|discount|special price|price break|bulk discount|invoice|payment|tax|refund|guarantee|deadline|order status)\b/)

      product_signal = text.match?(/\b(yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?|starter\s*pack|pro\s*pack)\b/)
      price_signal = text.match?(/\b(how much|cost|costs|price|pricing|total|rate|quote|shipping|stakes|option|quantity|qty)\b/)
      numeric_signal = text.match?(/\b\d{1,5}\b/)
      product_signal && (price_signal || numeric_signal)
    end

    def self.outside_deal_quantity_pressure?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return true if text.match?(/\b(?:custom|specific|exact|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk)\b.*\b(?:quantity|qty|count|number|amount|price|pricing|quote|deal|package|pack|bundle)\b/)
      return true if text.match?(/\b(?:quantity|qty|count|number|amount|price|pricing|quote|deal|package|pack|bundle)\b.*\b(?:custom|specific|exact|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk)\b/)
      return true if text.match?(/\b(?:can|could|do|does|will|would|need|want|order|get|quote|price|cost|how much)\b.*\b\d{2,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i)
      return true if text.match?(/\b\d{2,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b.*\b(?:quote|price|cost|option|checkout|order|deal|special|bulk|custom|exact|available|listed)\b/i)
      return true if text.match?(/\b\d{2,6}\s*(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b.*\b(?:quote|exact|custom|special|bulk|discount|deal|pricing)\b/i)

      false
    end

    def self.answerable_turnaround_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false if text.match?(/\b(order status|tracking|where is my order|where's my order|specific order|already ordered|invoice|refund|cancel)\b/)

      timing_signal = text.match?(/\b(turnaround|turn around|timeline|how long|how soon|when would|when will|need them by|need it by|asap|rush|expedite|production time|ship|shipping time|delivery time|arrive|get them)\b/)
      product_signal = text.match?(/\b(yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?|print|prints?|business cards?|door hangers?|flyers?|handouts?|starter\s*pack|pro\s*pack)\b/)
      timing_signal && product_signal
    end

    def initialize(stage:, body:, reason:, source:, review_body: nil)
      @stage = stage
      @body = body.to_s.squish
      @reason = reason.to_s.squish.presence ||
        self.class.reason_for(@body, stage: @stage) ||
        (self.class.accepted_recent_contact_offer?(@stage, @body) ? "customer_accepted_marketing_consultant_sms" : nil) ||
        (self.class.contact_collection_response?(@stage, @body) ? existing_contact_collection_reason : nil)
      @source = source.to_s.squish.presence || "inbound_sms"
      @review_body = safe_customer_sms_body(review_body)
    end

    def call
      return Result.new(handled: false) if @stage.blank?
      return Result.new(handled: false) if @reason.blank?

      if immediate_fulfillment_escalation?
        contact_payload = record_contact_collection!
        unless handoff_contact_ready?(contact_payload)
          save_review_draft!(nil, body: fulfillment_contact_collection_reply(contact_payload))
          return Result.new(handled: false, reason: @reason, owner: nil, slack_posted: false, review_draft_saved: true)
        end

        return immediate_fulfillment_handoff!(contact_payload)
      end

      contact_payload = record_contact_collection!
      unless handoff_contact_ready?(contact_payload)
        save_review_draft!(nil, body: contact_collection_reply(contact_payload))
        return Result.new(handled: false, reason: @reason || "am_support_contact_collection", owner: nil, slack_posted: false, review_draft_saved: true)
      end

      mark_am_support!(contact_payload)
      owner = safe_owner(existing_routed_owner(@stage.reload))
      owner ||= safe_owner(route_owner(@stage.reload))
      owner ||= safe_owner(@stage.reload.user)
      posted = post_slack_once!(owner)
      confirmation = if posted
        contact_collection_confirmation(owner, contact_payload)
      else
        handoff_failed_reply
      end
      review_draft_saved = save_review_draft!(owner, body: confirmation.presence || @review_body)
      mark_slack_status!(posted ? "posted" : "failed")
      Result.new(handled: !allow_autopilot_confirmation_after_handoff?, reason: @reason, owner: owner, slack_posted: posted, review_draft_saved: review_draft_saved)
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsHandoff] failed stage=#{@stage&.id} reason=#{@reason} #{error.class}: #{error.message}")
      mark_slack_status!("failed", error.message) if @stage.present?
      Result.new(handled: true, reason: @reason, owner: nil, slack_posted: false)
    end

    private

    def immediate_fulfillment_escalation?
      @reason == "rush_or_deadline_confirmation_sms"
    end

    def immediate_fulfillment_handoff!(contact_payload)
      mark_am_support!(contact_payload)
      owner = safe_owner(existing_routed_owner(@stage.reload))
      owner ||= safe_owner(route_owner(@stage.reload))
      owner ||= safe_owner(@stage.reload.user)
      posted = post_slack_once!(owner)
      confirmation = if posted
        fulfillment_handoff_confirmation(owner, contact_payload)
      else
        fulfillment_escalation_reply(false)
      end
      review_draft_saved = save_review_draft!(owner, body: confirmation)
      mark_slack_status!(posted ? "posted" : "failed")

      Result.new(
        handled: !allow_autopilot_confirmation_after_handoff?,
        reason: @reason,
        owner: owner,
        slack_posted: posted,
        review_draft_saved: review_draft_saved
      )
    end

    def fulfillment_contact_collection_reply(payload)
      data = payload.to_h
      return contact_collection_reply(data) if data["sms_autopilot_handoff_contact_preference"].present?

      [
        "That timing needs a live production check, and I can't promise a rush or next-day turnaround here.",
        "I can still answer product, pricing, and checkout questions while they check it.",
        "What is the best way for a marketing consultant to reach you: email, text/SMS, or phone call?"
      ].join(" ")
    end

    def fulfillment_handoff_confirmation(owner, payload)
      handoff_confirmation(owner, payload, fulfillment: true)
    end

    def fulfillment_escalation_reply(posted)
      if posted
        "That timing needs a live production check. I can't promise a rush or next-day turnaround here, so I've sent your request to our marketing team to confirm availability and timing."
      else
        "That timing needs a live production check. I can't promise a rush or next-day turnaround here. A marketing consultant needs to confirm availability and timing."
      end
    end

    def slack_context_body
      messages = Array(@stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).filter_map do |event|
        next unless event["direction"].to_s == "inbound"
        next if event["status"].to_s.in?(%w[failed canceled])

        event["body"].to_s.squish.presence
      end.last(4)
      messages.presence&.map { |message| "Customer: #{message}" }&.join(" | ") || @body
    end

    def existing_contact_collection_reason
      return if @stage.blank?

      metadata = @stage.reload.metadata.to_h
      return unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_handoff_contact_pending"])

      metadata["sms_autopilot_handoff_contact_reason"].to_s.squish.presence ||
        metadata["comms_support_reason"].to_s.squish.presence ||
        "am_support_contact_collection_sms"
    rescue StandardError
      "am_support_contact_collection_sms"
    end

    def record_contact_collection!
      @stage.with_lock do
        @stage.reload
        metadata = @stage.metadata.to_h.deep_dup
        now = Time.current
        contact_payload = handoff_contact_payload(metadata)
        contact_payload["sms_autopilot_handoff_contact_permission"] = true if immediate_fulfillment_escalation?
        @stage.update!(
          generated_at: now,
          metadata: metadata.merge(
            contact_payload,
            "sms_autopilot_handoff_contact_pending" => true,
            "sms_autopilot_handoff_state" => handoff_contact_ready?(contact_payload) ? "contact_ready" : "collecting_contact",
            "sms_autopilot_handoff_contact_started_at" => metadata["sms_autopilot_handoff_contact_started_at"].presence || now.iso8601,
            "sms_autopilot_handoff_contact_updated_at" => now.iso8601,
            "sms_autopilot_handoff_contact_reason" => @reason.presence || metadata["sms_autopilot_handoff_contact_reason"].presence || "am_support_contact_collection",
            "sms_autopilot_handoff_contact_latest_body" => @body.presence,
            "sms_autopilot_slack_handoff_status" => handoff_contact_ready?(contact_payload) ? "contact_ready" : "waiting_for_contact_details",
            "sms_autopilot_slack_handoff_status_at" => now.iso8601,
            "comms_command_last_channel" => "sms",
            "comms_command_last_status" => handoff_contact_ready?(contact_payload) ? "am_support_contact_ready" : "am_support_contact_pending",
            "comms_command_last_at" => now.iso8601
          ).compact
        )
        @stage.reload.metadata.to_h.slice(
          "sms_autopilot_handoff_contact_preference",
          "sms_autopilot_handoff_contact_email",
          "sms_autopilot_handoff_contact_phone",
          "sms_autopilot_handoff_contact_time",
          "sms_autopilot_handoff_contact_day",
          "sms_autopilot_handoff_contact_timezone",
          "sms_autopilot_handoff_contact_not_before_at",
          "sms_autopilot_handoff_contact_not_after_at",
          "sms_autopilot_handoff_contact_scheduled_for",
          "sms_autopilot_handoff_contact_after_hours_rollover",
          "sms_autopilot_handoff_contact_effective_window",
          "sms_autopilot_handoff_contact_permission"
        )
      end
    end

    def handoff_contact_payload(metadata)
      existing = metadata.to_h
      active_collection = ActiveModel::Type::Boolean.new.cast(existing["sms_autopilot_handoff_contact_pending"])
      preference = contact_preference_from(@body).presence ||
        (active_collection ? normalize_contact_preference(existing["sms_autopilot_handoff_contact_preference"]) : nil)
      email = email_from(@body).presence ||
        (active_collection ? existing["sms_autopilot_handoff_contact_email"].presence : nil) ||
        known_contact_email(existing)
      phone = phone_from(@body).presence ||
        (active_collection ? existing["sms_autopilot_handoff_contact_phone"].presence : nil) ||
        known_contact_phone(existing)
      contact_window_explicit = active_collection || @body.match?(/\b(?:call|phone|ring|text|sms|message|email|reach|contact)\b/i)
      window = (contact_time_from(@body).presence if contact_window_explicit) ||
        (active_collection ? existing["sms_autopilot_handoff_contact_time"].presence : nil)
      window_payload = if window.present?
        Comms::ContactWindowParser.parse(@body).metadata
      else
        {}
      end
      permission = (active_collection && ActiveModel::Type::Boolean.new.cast(existing["sms_autopilot_handoff_contact_permission"])) || support_permission_from?(@body)

      preference ||= "call" if phone.present? && window.present? && @body.match?(/\b(?:this|same|that)\s+(?:number|phone)\b/i)
      preference ||= "call" if phone.present? && @body.match?(/\b(?:call|phone|ring)\b/i)
      preference ||= "text" if phone.present? && @body.match?(/\b(?:text|sms)\b/i)

      {
        "sms_autopilot_handoff_contact_preference" => preference,
        "sms_autopilot_handoff_contact_email" => email,
        "sms_autopilot_handoff_contact_phone" => phone,
        "sms_autopilot_handoff_contact_time" => window,
        "sms_autopilot_handoff_contact_permission" => permission
      }.merge(window_payload).compact_blank
    end

    def handoff_contact_ready?(payload)
      data = payload.to_h
      return false unless ActiveModel::Type::Boolean.new.cast(data["sms_autopilot_handoff_contact_permission"])

      preference = data["sms_autopilot_handoff_contact_preference"].to_s
      case preference
      when "email"
        data["sms_autopilot_handoff_contact_email"].present?
      when "call", "phone"
        data["sms_autopilot_handoff_contact_phone"].present? && data["sms_autopilot_handoff_contact_time"].present?
      when "text", "sms"
        data["sms_autopilot_handoff_contact_phone"].present? && data["sms_autopilot_handoff_contact_time"].present?
      else
        false
      end
    end

    def contact_collection_reply(payload)
      data = payload.to_h
      preference = data["sms_autopilot_handoff_contact_preference"].to_s
      permission = ActiveModel::Type::Boolean.new.cast(data["sms_autopilot_handoff_contact_permission"])

      return "I want to help you get the best support possible. Would it be helpful for me to have one of our marketing consultants reach out?" unless permission

      case preference
      when "email"
        return "Perfect. What email should our marketing consultant use?" if data["sms_autopilot_handoff_contact_email"].blank?
      when "call", "phone"
        missing = []
        missing << "the best number" if data["sms_autopilot_handoff_contact_phone"].blank?
        missing << "a good time to call or text" if data["sms_autopilot_handoff_contact_time"].blank?
        return "Perfect. What is #{missing.to_sentence}?" if missing.present?
      when "text", "sms"
        missing = []
        missing << "the best number" if data["sms_autopilot_handoff_contact_phone"].blank?
        missing << "a good time to text" if data["sms_autopilot_handoff_contact_time"].blank?
        return "Perfect. What is #{missing.to_sentence}?" if missing.present?
      else
        hint = known_contact_hint(data)
        return ["Perfect. What is the best way for them to reach you: email, call, or text?", hint].compact_blank.join(" ")
      end

      "Perfect. I am getting that to the right marketing consultant now."
    end

    def handoff_failed_reply
      "I have your contact preference, but I couldn't complete the marketing-consultant handoff yet. You can keep texting me here while I retry."
    end

    def contact_collection_confirmation(owner, payload)
      handoff_confirmation(owner, payload)
    end

    def handoff_confirmation(owner, payload, fulfillment: false)
      owner_name = owner&.display_name.to_s.squish.presence || "a marketing consultant"
      follow_up = contact_follow_up_description(payload)
      timing = contact_follow_up_timing(payload)
      sentences = [
        "Perfect. I assigned #{owner_name}, who will follow up#{follow_up.present? ? " #{follow_up}" : ""}#{timing.present? ? " #{timing}" : ""}.",
        ("They'll confirm rush availability and production timing; I can't promise the deadline from here." if fulfillment),
        "You can keep texting me here in the meantime."
      ]
      sentences.compact.join(" ")
    end

    def contact_follow_up_description(payload)
      data = payload.to_h
      case data["sms_autopilot_handoff_contact_preference"].to_s
      when "email"
        address = data["sms_autopilot_handoff_contact_email"].to_s.squish.presence
        address.present? ? "by email at #{address}" : "by email"
      when "call", "phone"
        number = data["sms_autopilot_handoff_contact_phone"].to_s.squish.presence
        number.present? ? "by phone at #{number}" : "by phone"
      when "text", "sms"
        number = data["sms_autopilot_handoff_contact_phone"].to_s.squish.presence
        number.present? ? "by text at #{number}" : "by text"
      end
    end

    def contact_follow_up_timing(payload)
      data = payload.to_h
      return if data["sms_autopilot_handoff_contact_preference"].to_s == "email"

      effective_window = data["sms_autopilot_handoff_contact_effective_window"].to_s.squish.presence
      explicit_day = data["sms_autopilot_handoff_contact_time"].to_s.match?(/\b(?:today|tomorrow|tonight|weekday|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b/i)
      if effective_window.present? && (explicit_day || ActiveModel::Type::Boolean.new.cast(data["sms_autopilot_handoff_contact_after_hours_rollover"]))
        return "on #{effective_window}"
      end

      window = data["sms_autopilot_handoff_contact_time"].to_s.squish.presence
      return if window.blank?
      return "when convenient" if window.downcase.match?(/\A(?:anytime|any time|whenever)\z/)

      "around #{window}"
    end

    def contact_preference_label(payload)
      data = payload.to_h
      case data["sms_autopilot_handoff_contact_preference"].to_s
      when "email"
        "by email"
      when "call", "phone"
        "by phone"
      when "text", "sms"
        "by text"
      end
    end

    def contact_preference_from(text)
      body = text.to_s.downcase.squish
      return "email" if body.match?(/\b(?:email|e-mail)\b/)
      return "text" if body.match?(/\b(?:text|sms)\b/) || body.match?(/\bmessage\s+me\b/)
      return "call" if body.match?(/\b(?:call|phone|ring)\b/)

      nil
    end

    def normalize_contact_preference(value)
      body = value.to_s.downcase.squish
      return "email" if body.match?(/\b(?:email|e-mail)\b/)
      return "text" if body.match?(/\b(?:text|sms)\b/)
      return "call" if body.match?(/\b(?:call|phone|ring)\b/)

      nil
    end

    def known_contact_preference(metadata)
      normalize_contact_preference(metadata["contact_preference"]) ||
        normalize_contact_preference(metadata["proof_delivery_method"])
    end

    def known_contact_email(metadata)
      candidates = [
        metadata["captured_email"],
        metadata["recipient_email"],
        selected_option_value(metadata, "recipient_email_options", "selected_recipient_email_id", "email", "value", "address"),
        option_value(metadata["aircall_selected_recipient_email"], "email", "value", "address")
      ]
      candidates << @stage&.crm_record&.email unless reset_discovery_active?(metadata)
      candidates.filter_map { |value| email_from(value).presence || value.to_s.squish.presence }.find { |value| email_from(value).present? }
    end

    def reset_discovery_active?(metadata)
      ActiveModel::Type::Boolean.new.cast(metadata["sms_discovery_reset"]) &&
        metadata["sms_conversation_reset_at"].present?
    end

    def known_contact_phone(metadata)
      [
        selected_option_value(metadata, "phone_options", "selected_phone_id", "phone", "value", "number"),
        option_value(metadata["aircall_selected_phone"], "phone", "value", "number"),
        metadata["captured_phone"],
        metadata["phone"],
        metadata["sms_listener_from"],
        metadata["comms_command_last_inbound_from"],
        latest_inbound_sms_from(metadata),
        @stage&.crm_record&.phone
      ].filter_map { |value| phone_from(value) }.first
    end

    def latest_inbound_sms_from(metadata)
      Array(metadata["sms_thread"]).map(&:to_h).reverse.find do |event|
        event["channel"].to_s == "sms" &&
          event["direction"].to_s == "inbound" &&
          event["from"].to_s.squish.present?
      end.to_h["from"]
    end

    def known_contact_window(metadata)
      [
        metadata["preferred_contact_window"],
        metadata["contact_window"]
      ].filter_map { |value| contact_time_from(value) }.first
    end

    def known_contact_hint(data)
      email = data["sms_autopilot_handoff_contact_email"].present?
      phone = data["sms_autopilot_handoff_contact_phone"].present?
      return "I can use the email or number we already have if that is best." if email && phone
      return "I can use the email we already have if that is best." if email
      return "I can use the number we are texting if that is best." if phone

      nil
    end

    def selected_option_value(metadata, options_key, selected_key, *fields)
      option = selected_option(metadata, options_key, selected_key)
      fields.filter_map { |field| option[field].to_s.squish.presence }.first
    end

    def selected_option(metadata, options_key, selected_key)
      selected_id = metadata[selected_key].to_s
      options = Array(metadata[options_key]).map { |option| option.respond_to?(:to_h) ? option.to_h : {} }
      match = options.find { |option| option["id"].to_s == selected_id }
      match || options.find { |option| option["value"].present? || option["email"].present? || option["phone"].present? } || {}
    end

    def option_value(option, *fields)
      data = option.respond_to?(:to_h) ? option.to_h : {}
      fields.filter_map { |field| data[field].to_s.squish.presence }.first
    end

    def email_from(text)
      text.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i]&.downcase
    end

    def phone_from(text)
      raw = text.to_s.scan(/(?:\+?1[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]?\d{4}/).first
      return if raw.blank?

      digits = raw.gsub(/\D/, "")
      digits = digits[1..] if digits.length == 11 && digits.start_with?("1")
      return if digits.length != 10

      "(#{digits[0, 3]}) #{digits[3, 3]}-#{digits[6, 4]}"
    end

    def contact_time_from(text)
      Comms::ContactWindowParser.extract(text)
    end

    def support_permission_from?(text)
      body = text.to_s.downcase.squish
      self.class.human_request?(body) ||
        self.class.affirmative_contact_reply?(body) ||
        body.match?(/\b(?:call|phone|ring|text|sms|message|email|e-mail)\s+me\b/) ||
        body.match?(/\b(?:have|get|connect|send|pass|let)\b.{0,80}\b(?:consultant|person|someone|team|teammate|rep|representative)\b/)
    end

    def allow_autopilot_confirmation_after_handoff?
      @source.match?(/(?:webhook|reply_enqueue|pending_reply|manual_autopilot|inbound_reply_job)/)
    end

    def mark_am_support!(contact_payload = {})
      @stage.with_lock do
        @stage.reload
        metadata = @stage.metadata.to_h.deep_dup
        now = Time.current
        autopilot_payload = am_support_autopilot_payload(metadata, now)
        next_metadata = metadata.merge(
          contact_payload.to_h,
          "comms_support_state" => "am_support",
          "sms_autopilot_handoff_state" => "slack_queued",
          "comms_support_state_at" => metadata["comms_support_state_at"].presence || now.iso8601,
          "comms_support_reason" => @reason,
          "comms_support_source" => @source,
          "comms_support_latest_body" => @body.presence,
          "sms_autopilot_handoff_contact_pending" => false,
          "sms_autopilot_handoff_contact_ready_at" => metadata["sms_autopilot_handoff_contact_ready_at"].presence || now.iso8601,
          "sms_autopilot_handoff_conversation_continues" => autopilot_payload["sms_autopilot_enabled"] == true,
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "am_support",
          "comms_command_last_at" => now.iso8601,
          "sms_autopilot_slack_handoff_status" => metadata["sms_autopilot_slack_handoff_status"].presence || "queued",
          "sms_autopilot_slack_handoff_queued_at" => metadata["sms_autopilot_slack_handoff_queued_at"].presence || now.iso8601,
          "sms_autopilot_slack_pending_body" => @body.presence
        )
        next_metadata = next_metadata.except("sms_autopilot_disabled_at", "sms_autopilot_disabled_reason") if autopilot_payload["sms_autopilot_enabled"] == true
        @stage.update!(
          generated_at: now,
          metadata: next_metadata.merge(autopilot_payload).compact
        )
      end
    end

    def am_support_autopilot_payload(metadata, now)
      return {} if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
      return {} if ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"])
      return {} if metadata["comms_board_state"].to_s == "opt_out"
      return {} if metadata["sms_autopilot_disabled_reason"].to_s == "operator_disabled" &&
        !ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"])

      {
        "sms_autopilot_enabled" => true,
        "sms_autopilot_am_support_enabled_at" => metadata["sms_autopilot_am_support_enabled_at"].presence || now.iso8601,
        "sms_autopilot_updated_at" => now.iso8601,
        "sms_autopilot_updated_by" => "am_support_handoff",
        "sms_listener_active" => true,
        "sms_listener_until" => 7.days.from_now.iso8601
      }
    end

    def route_owner(stage)
      return unless defined?(DealReports::CommsLeadRouter)

      Timeout.timeout(owner_route_timeout_seconds) do
        DealReports::CommsLeadRouter.route!(stage, force: true, reason: @reason)
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsHandoff] route failed stage=#{stage&.id} #{error.class}: #{error.message}")
      nil
    end

    def owner_route_timeout_seconds
      ENV.fetch("WIZWIKI_COMMS_HANDOFF_ROUTE_TIMEOUT_SECONDS", "6").to_i.clamp(1, 20)
    end

    def existing_routed_owner(stage)
      metadata = stage.metadata.to_h
      name = metadata["comms_routed_to_user_name"].to_s.squish.presence
      return if name.blank?

      routed_id = metadata["comms_routed_to_user_id"].to_s.squish.presence
      if routed_id.present? && !routed_id.start_with?("virtual:")
        routed_user = User.find_by(id: routed_id)
        return routed_user if routed_user.present?
      end

      Struct.new(:id, :display_name, :email_address, :hubspot_owner_id, :source, keyword_init: true).new(
        id: routed_id || "virtual:#{name.parameterize}",
        display_name: name,
        email_address: metadata["comms_routed_to_user_email"].to_s.squish.presence,
        hubspot_owner_id: metadata["comms_routed_to_hubspot_owner_id"].to_s.squish.presence,
        source: metadata["contact_owner_source"].to_s.squish.presence || "comms_route_metadata"
      )
    end

    def safe_owner(owner)
      return owner unless defined?(Comms::SlackNotifier)

      Comms::SlackNotifier.safe_owner(owner)
    end

    def post_slack_once!(owner)
      metadata = @stage.reload.metadata.to_h
      return true if metadata["sms_autopilot_slack_human_requested_at"].present? ||
        metadata["sms_autopilot_slack_handoff_at"].present? ||
        metadata["sms_autopilot_slack_handoff_status"].to_s == "posted"
      return false unless defined?(Comms::SlackNotifier)

      posted = Comms::SlackNotifier.post_human_requested!(
        stage: @stage.reload,
        owner: owner,
        latest_body: slack_context_body,
        reason: @reason
      )
      return false unless posted

      mark_contact_posted!
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsHandoff] slack failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def mark_contact_posted!
      metadata = @stage.reload.metadata.to_h.deep_dup
      now = Time.current.iso8601
      @stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_handoff_state" => "posted",
          "sms_autopilot_handoff_contact_posted_at" => metadata["sms_autopilot_handoff_contact_posted_at"].presence || now,
          "sms_autopilot_slack_handoff_at" => metadata["sms_autopilot_slack_handoff_at"].presence || now
        )
      )
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsHandoff] contact posted marker failed stage=#{@stage&.id} #{error.class}: #{error.message}")
    end

    def save_review_draft!(owner, body: @review_body)
      review_body = safe_customer_sms_body(body)
      return false if review_body.blank?

      @stage.with_lock do
        @stage.reload
        metadata = @stage.metadata.to_h.deep_dup
        now = Time.current
        owner_name = owner&.display_name.to_s.squish.presence
        draft = {
          "body" => review_body,
          "provider" => "wizwiki/am_support_handoff",
          "model" => "deterministic_handoff",
          "draft_source" => "am_support_handoff",
          "requires_am_support" => true,
          "am_support_reason" => @reason,
          "am_support_owner" => owner_name,
          "reason" => "AM support handoff saved this next text for human review.",
          "created_at" => now.iso8601
        }.compact_blank
        history = Array(metadata["sms_draft_history"]).last(24)
        history << draft.slice(
          "body",
          "provider",
          "model",
          "draft_source",
          "requires_am_support",
          "am_support_reason",
          "am_support_owner",
          "reason",
          "created_at"
        )
        contact_pending = ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_handoff_contact_pending"]) &&
          metadata["sms_autopilot_handoff_state"].to_s != "posted"

        @stage.update!(
          generated_at: now,
          metadata: metadata.merge(
            "comms_command_sms_draft_body" => review_body,
            "comms_command_sms_draft" => draft,
            "sms_draft_history" => history,
            "comms_command_last_channel" => "sms",
            "comms_command_last_status" => contact_pending ? "am_support_contact_pending" : "am_support",
            "comms_command_last_at" => now.iso8601,
            "sms_autopilot_handoff_confirmation_draft_at" => now.iso8601
          ).compact
        )
      end
      true
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsHandoff] review draft save failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def safe_customer_sms_body(value)
      return if value.blank?
      return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

      value.to_s.squish.presence
    end

    def mark_slack_status!(status, error = nil)
      metadata = @stage.reload.metadata.to_h.deep_dup
      now = Time.current.iso8601
      posted_update = status.to_s == "posted" ? { "sms_autopilot_slack_handoff_at" => metadata["sms_autopilot_slack_handoff_at"].presence || now } : {}
      state = status.to_s == "posted" ? "posted" : "slack_#{status}"
      @stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "sms_autopilot_handoff_state" => state,
          "sms_autopilot_slack_handoff_status" => status,
          "sms_autopilot_slack_handoff_status_at" => now,
          "sms_autopilot_slack_handoff_error" => error.to_s.squish.presence,
          "comms_command_last_status" => "am_support",
          "comms_command_last_at" => now
        ).merge(posted_update).compact
      )
    rescue StandardError => update_error
      Rails.logger.warn("[Comms::InboundSmsHandoff] status update failed stage=#{@stage&.id} #{update_error.class}: #{update_error.message}")
    end
  end
end
