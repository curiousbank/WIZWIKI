# frozen_string_literal: true

module Comms
  class PostSendSupervisor
    YARD_SIGN_CHECKOUT_URL = defined?(Comms::ProductCatalog) && Comms::ProductCatalog.checkout_url("LAWN_SIGNS")
    YARD_SIGN_PACKAGE_PRICES = if defined?(Comms::ProductCatalog)
      Comms::ProductCatalog.price_table("LAWN_SIGNS").transform_values { |values| values["price"].presence || values["double_sided_included"].presence }.compact_blank
    else
      {}
    end.freeze
    PRODUCT_LINKS = if defined?(Comms::ProductCatalog)
      Comms::ProductCatalog.shopify_links.slice("BUSINESS_CARDS", "DOOR_HANGERS", "FLYERS", "LAWN_SIGNS")
    else
      {}
    end.freeze
    PRODUCT_LABELS = if defined?(Comms::ProductCatalog)
      Comms::ProductCatalog.route_labels.slice("BUSINESS_CARDS", "DOOR_HANGERS", "FLYERS", "LAWN_SIGNS")
    else
      {}
    end.freeze
    CORRECTION_COOLDOWN = ENV.fetch("WIZWIKI_SMS_POST_SEND_SUPERVISOR_COOLDOWN_SECONDS", "600").to_i.clamp(60, 86_400).seconds
    MAX_CORRECTIONS_PER_THREAD = ENV.fetch("WIZWIKI_SMS_POST_SEND_SUPERVISOR_MAX_CORRECTIONS", "2").to_i.clamp(0, 10)

    class << self
      def call(stage:, outbound_event: nil, source: nil, sender_profile: nil, auto_correct: nil)
        new(
          stage: stage,
          outbound_event: outbound_event,
          source: source,
          sender_profile: sender_profile,
          auto_correct: auto_correct
        ).call
      end
    end

    def initialize(stage:, outbound_event: nil, source: nil, sender_profile: nil, auto_correct: nil)
      @stage = stage
      @outbound_event = outbound_event.respond_to?(:to_h) ? outbound_event.to_h : outbound_event
      @source = source.to_s.presence || "post_send_supervisor"
      @sender_profile = sender_profile.respond_to?(:to_h) ? sender_profile.to_h : {}
      @auto_correct = auto_correct
    end

    def call
      return result("skipped", reason: "disabled") unless enabled?
      return result("skipped", reason: "stage_missing") if stage.blank?

      stage.with_lock do
        stage.reload
        @metadata = stage.metadata.to_h.deep_dup
        @events = sms_events_after_reset
        @outbound = resolve_outbound_event

        return record_result(result("skipped", reason: "outbound_missing")) if outbound.blank?
        return record_result(result("skipped", reason: "not_sent_outbound")) unless sent_outbound?(outbound)
        return record_result(result("skipped", reason: "supervisor_correction_event")) if supervisor_event?(outbound)
        return record_result(result("blocked", reason: "do_not_contact")) if do_not_contact?
        return record_result(result("blocked", reason: "hard_stop_seen")) if hard_stop_seen?
        return record_result(result("skipped", reason: "customer_replied_after_outbound")) if customer_replied_after_outbound?
        return record_result(result("skipped", reason: "cooldown")) if correction_cooldown_active?
        return record_result(result("skipped", reason: "correction_limit")) if correction_count >= MAX_CORRECTIONS_PER_THREAD

        issue = classify_issue
        return record_result(result("skipped", reason: "no_high_confidence_issue", issue_codes: issue.fetch(:codes))) if issue[:correction_body].blank?

        if auto_correct?
          send_correction!(issue)
        else
          record_result(result("review_only", reason: "auto_correct_disabled", issue_codes: issue.fetch(:codes), correction_body: issue[:correction_body]))
        end
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::PostSendSupervisor] failed stage=#{stage&.id} #{error.class}: #{error.message}") if defined?(Rails)
      record_error(error)
    end

    private

    attr_reader :stage, :outbound_event, :source, :sender_profile, :metadata, :events, :outbound

    def enabled?
      !ActiveModel::Type::Boolean.new.cast(ENV["WIZWIKI_SMS_POST_SEND_SUPERVISOR_DISABLED"])
    end

    def auto_correct?
      return ActiveModel::Type::Boolean.new.cast(@auto_correct) unless @auto_correct.nil?

      !ActiveModel::Type::Boolean.new.cast(ENV["WIZWIKI_SMS_POST_SEND_SUPERVISOR_REVIEW_ONLY"])
    end

    def sms_events_after_reset
      all_events = Array(metadata["sms_thread"]).map(&:to_h)
      reset_at = parse_time(metadata["sms_conversation_reset_at"])
      return all_events if reset_at.blank?

      all_events.select do |event|
        event_time = event_time(event)
        event_time.present? && event_time >= reset_at
      end
    end

    def resolve_outbound_event
      supplied_id = outbound_event.to_h["id"].presence
      supplied_sid = outbound_event.to_h["provider_message_id"].presence
      if supplied_id.present? || supplied_sid.present?
        match = events.reverse_each.find do |event|
          event = event.to_h
          (supplied_id.present? && event["id"].to_s == supplied_id.to_s) ||
            (supplied_sid.present? && event["provider_message_id"].to_s == supplied_sid.to_s)
        end
        return match if match.present?
      end

      return outbound_event if sent_outbound?(outbound_event.to_h)

      events.reverse_each.find { |event| sent_outbound?(event.to_h) }
    end

    def sent_outbound?(event)
      event = event.to_h
      event["channel"].to_s == "sms" &&
        event["direction"].to_s == "outbound" &&
        !event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped])
    end

    def supervisor_event?(event)
      ActiveModel::Type::Boolean.new.cast(event.to_h["post_send_supervisor"])
    end

    def outbound_body
      outbound.to_h["body"].to_s.squish
    end

    def outbound_at
      event_time(outbound)
    end

    def event_time(event)
      parse_time(event.to_h["created_at"].presence || event.to_h["at"].presence || event.to_h["timestamp"].presence)
    end

    def parse_time(value)
      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError, TypeError
      nil
    end

    def do_not_contact?
      ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) ||
        ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"]) ||
        metadata["comms_board_state"].to_s == "opt_out"
    end

    def hard_stop_seen?
      latest_inbound = latest_inbound_event
      hard_stop_intent?(latest_inbound.to_h["body"])
    end

    def hard_stop_intent?(text)
      body = text.to_s.squish.downcase
      return false if body.blank?
      return true if body.match?(/\A(?:stop|unsubscribe|cancel|end|quit)\z/)

      body.match?(/\b(?:stop texting|stop messaging|do not text|don't text|dont text|leave me alone|remove me|unsubscribe me)\b/)
    end

    def customer_replied_after_outbound?
      sent_at = outbound_at
      return false if sent_at.blank?

      events.any? do |event|
        next false unless event.to_h["direction"].to_s == "inbound"

        inbound_at = event_time(event)
        inbound_at.present? && inbound_at > sent_at
      end
    end

    def correction_cooldown_active?
      last_at = parse_time(metadata["sms_post_send_supervisor_last_correction_at"])
      last_at.present? && last_at > CORRECTION_COOLDOWN.ago
    end

    def correction_count
      metadata["sms_post_send_supervisor_correction_count"].to_i
    end

    def latest_inbound_event
      events.reverse_each.find { |event| event.to_h["direction"].to_s == "inbound" }
    end

    def inbound_events_since_previous_outbound
      out_index = events.rindex { |event| same_event?(event, outbound) }
      before_outbound = out_index ? events[0...out_index] : events
      last_prior_outbound_index = before_outbound.rindex do |event|
        event.to_h["direction"].to_s == "outbound" && !supervisor_event?(event)
      end
      candidates = last_prior_outbound_index ? before_outbound[(last_prior_outbound_index + 1)..] : before_outbound
      Array(candidates).select { |event| event.to_h["direction"].to_s == "inbound" }
    end

    def same_event?(left, right)
      left = left.to_h
      right = right.to_h
      return true if left["id"].present? && left["id"].to_s == right["id"].to_s
      return true if left["provider_message_id"].present? && left["provider_message_id"].to_s == right["provider_message_id"].to_s

      false
    end

    def classify_issue
      codes = []
      codes << "stacked_inbound" if inbound_events_since_previous_outbound.length > 1

      issue = yard_sign_quantity_issue(codes)
      return issue if issue[:correction_body].present?

      issue = wrong_product_link_issue(codes)
      return issue if issue[:correction_body].present?

      issue = premature_handoff_issue(codes)
      return issue if issue[:correction_body].present?

      { codes: codes, confidence: codes.any? ? "medium" : "low" }
    end

    def latest_customer_text
      inbound_events_since_previous_outbound.map { |event| event.to_h["body"].to_s.squish }.compact_blank.join(" ").squish.presence ||
        latest_inbound_event.to_h["body"].to_s.squish
    end

    def yard_sign_quantity_issue(codes)
      quantity = exact_yard_sign_quantity_from_text(latest_customer_text)
      return { codes: codes, confidence: "low" } if quantity.blank? || !YARD_SIGN_PACKAGE_PRICES.key?(quantity)

      expected_price = YARD_SIGN_PACKAGE_PRICES.fetch(quantity)
      text = outbound_body.downcase
      mentions_signs = text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i)
      missing_price = latest_customer_text.match?(/\b(?:how much|price|cost|quote|what.*cost|what.*price)\b/i) && !outbound_body.include?(expected_price)
      wrong_quantity = YARD_SIGN_PACKAGE_PRICES.keys.any? do |candidate|
        next false if candidate == quantity

        text.match?(/\b#{candidate}\s*(?:-| )?\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|sign\s+option)\b/i)
      end
      wrong_price = dollar_amounts(outbound_body).any? do |amount|
        amount.positive? && amount.round(2) != expected_price.delete("$,").to_f.round(2)
      end

      return { codes: codes, confidence: "low" } unless missing_price || wrong_quantity || (mentions_signs && wrong_price)

      issue_codes = codes + ["wrong_or_missing_yard_sign_price"]
      {
        codes: issue_codes.uniq,
        confidence: "high",
        correction_body: yard_sign_quantity_correction(quantity, expected_price)
      }
    end

    def yard_sign_quantity_correction(quantity, price)
      base = "Quick correction: #{quantity} yard signs are #{price}."
      if checkout_request?(latest_customer_text) && YARD_SIGN_CHECKOUT_URL.present?
        "#{base} You can use the Yard Signs checkout and choose #{quantity} on the page: #{YARD_SIGN_CHECKOUT_URL}"
      else
        "#{base} Want me to send the #{quantity}-sign checkout?"
      end
    end

    def wrong_product_link_issue(codes)
      route = print_only_route(latest_customer_text)
      return { codes: codes, confidence: "low" } if route.blank?

      expected_link = PRODUCT_LINKS[route]
      return { codes: codes, confidence: "low" } if expected_link.blank?
      body = outbound_body
      supplied_links = body.scan(%r{https?://\S+}i).map { |url| Comms::ProductCatalog.normalize_url(url) }
      wrong_link = supplied_links.any? { |url| Comms::ProductCatalog.known_checkout_url?(url) && url != expected_link }
      missing_expected = checkout_request?(latest_customer_text) && supplied_links.present? && !body.include?(expected_link)
      return { codes: codes, confidence: "low" } unless wrong_link || missing_expected

      {
        codes: (codes + ["wrong_product_link"]).uniq,
        confidence: "high",
        correction_body: product_link_correction(route, expected_link)
      }
    end

    def product_link_correction(route, link)
      label = PRODUCT_LABELS[route].presence || Comms::ProductCatalog.label(route)
      base = "Quick correction: for #{label}, use this checkout link: #{link}"
      starting_price = Comms::ProductCatalog.starting_price_line(route)
      starting_price.present? ? "#{base} The reviewed catalog starts at #{starting_price}." : base
    end

    def premature_handoff_issue(codes)
      body = outbound_body.downcase
      premature = body.match?(/\b(?:will be contacting you|will contact you|i let them know|i've let them know|i have let them know|someone will reach out|they will reach out)\b/i)
      return { codes: codes, confidence: "low" } unless premature
      return { codes: codes, confidence: "low" } if current_contact_preference_present?

      {
        codes: (codes + ["handoff_details_missing"]).uniq,
        confidence: "high",
        correction_body: "Quick follow-up so I get this to the right person: what is the best way for a marketing consultant to reach you, email, call, or text? I can use this number if text is best."
      }
    end

    def current_contact_preference_present?
      preference = metadata["sms_autopilot_handoff_contact_preference"].to_s.downcase.squish
      return true if preference == "email" && metadata["sms_autopilot_handoff_contact_email"].present?
      return true if preference.in?(%w[call phone text sms]) && metadata["sms_autopilot_handoff_contact_phone"].present?

      text = inbound_events_since_previous_outbound.map { |event| event.to_h["body"].to_s }.join(" ").squish
      return true if text.match?(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)
      return true if text.match?(/\b(?:email|call|phone|text|sms)\b/i) && text.match?(/\b(?:best|works|prefer|reach|contact|use)\b/i)
      return true if text.match?(/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/)

      false
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

    def print_only_route(text)
      body = text.to_s.downcase.squish
      return if body.blank?
      return "BUSINESS_CARDS" if body.match?(/\bbusiness cards?\b/) && !mixed_product_context?(body)
      return "DOOR_HANGERS" if body.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/) && !body.match?(/\bbusiness cards?|flyers?|yard\s+signs?|lawn\s+signs?|postcards?|eddm\b/)
      return "FLYERS" if body.match?(/\b(?:flyers?|handouts?)\b/) && !mixed_product_context?(body)

      nil
    end

    def mixed_product_context?(body)
      body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|postcards?|eddm|door\s*hangers?|business cards?|flyers?|starter\s*pack|pro\s*pack|bundle)\b.*\b(?:and|plus|also|maybe|or)\b/i)
    end

    def checkout_request?(text)
      text.to_s.match?(/\b(?:link|checkout|order|buy|ready|send|start|proceed|go ahead)\b/i)
    end

    def dollar_amounts(text)
      text.to_s.scan(/\$([\d,]+(?:\.\d{2})?)/).flatten.map { |value| value.delete(",").to_f }
    end

    def send_correction!(issue)
      correction_body = deliverable_correction_body(issue.fetch(:correction_body))
      return record_result(result("blocked", reason: "unsafe_correction_body", issue_codes: issue.fetch(:codes))) if correction_body.blank?

      delivery = Comms::SmsProvider.deliver!(
        to: outbound.to_h["to"],
        body: correction_body,
        from_number: outbound.to_h["from"].presence || sender_profile["from_number"].presence,
        messaging_service_sid: sender_profile["messaging_service_sid"].presence,
        metadata: stage.metadata
      )
      correction_event = correction_event_payload(correction_body, delivery, issue)
      metadata = stage.reload.metadata.to_h.deep_dup
      thread = Array(metadata["sms_thread"]).last(50)
      thread << correction_event
      review = result("correction_sent", issue_codes: issue.fetch(:codes), correction_body: correction_body, confidence: issue[:confidence])
      now = Time.current.iso8601
      stage.update!(
        metadata: metadata.merge(
          "sms_thread" => thread,
          "sms_post_send_supervisor_last_review" => review.merge("worker_health_snapshot" => worker_health_snapshot),
          "sms_post_send_supervisor_review_history" => review_history(metadata, review),
          "sms_post_send_supervisor_last_correction_at" => now,
          "sms_post_send_supervisor_correction_count" => metadata["sms_post_send_supervisor_correction_count"].to_i + 1,
          "comms_command_last_status" => "post_send_correction_sent",
          "comms_command_last_at" => now
        ).compact_blank
      )
      review
    end

    def deliverable_correction_body(body)
      @last_sms_delivery_language_event = nil
      if defined?(Comms::SmsBodySafety)
        body = Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage.metadata)
      else
        body = body.to_s.squish
      end
      if defined?(Comms::SmsLanguageSupport)
        result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
        @last_sms_delivery_language_event = result.to_h["event"]
        persist_sms_language_metadata!(result.to_h["metadata"])
        body = result.to_h["body"].presence || body
      end
      body
    end

    def sms_delivery_language_event_payload
      @last_sms_delivery_language_event.to_h.compact_blank
    end

    def persist_sms_language_metadata!(updates)
      return if updates.to_h.blank?

      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(metadata: metadata.merge(updates.to_h).compact_blank)
    rescue StandardError => error
      Rails.logger.warn("[Comms::PostSendSupervisor] SMS language metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
    end

    def correction_event_payload(body, delivery, issue)
      {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "outbound",
        "status" => normalized_status(delivery),
        "to" => outbound.to_h["to"].to_s,
        "from" => delivery.to_h["from"].presence || outbound.to_h["from"].to_s,
        "body" => body,
        "provider" => delivery.to_h["provider"].presence || outbound.to_h["provider"].presence || "twilio",
        "provider_message_id" => delivery.to_h["sid"].presence,
        "provider_status" => delivery.to_h["status"].presence,
        "autopilot" => true,
        "post_send_supervisor" => true,
        "post_send_supervisor_source" => source,
        "post_send_supervisor_issue_codes" => issue.fetch(:codes),
        "post_send_supervisor_confidence" => issue[:confidence],
        "related_outbound_id" => outbound.to_h["id"].presence,
        "related_outbound_provider_message_id" => outbound.to_h["provider_message_id"].presence,
        "created_at" => Time.current.iso8601
      }.merge(sms_delivery_language_event_payload).compact_blank
    end

    def normalized_status(delivery)
      status = delivery.to_h["status"].to_s.squish.downcase
      return status if status.in?(%w[queued accepted scheduled sending sent delivered])

      "sent"
    end

    def record_result(payload)
      current_metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(
        metadata: current_metadata.merge(
          "sms_post_send_supervisor_last_review" => payload.merge("worker_health_snapshot" => worker_health_snapshot),
          "sms_post_send_supervisor_review_history" => review_history(current_metadata, payload)
        ).compact_blank
      )
      payload
    end

    def record_error(error)
      return result("failed", reason: error.message) if stage.blank?

      metadata = stage.reload.metadata.to_h.deep_dup
      payload = result("failed", reason: error.message)
      stage.update!(
        metadata: metadata.merge(
          "sms_post_send_supervisor_last_review" => payload,
          "sms_post_send_supervisor_last_error" => error.message,
          "sms_post_send_supervisor_last_error_at" => Time.current.iso8601
        ).compact_blank
      )
      payload
    rescue StandardError
      payload || result("failed", reason: error.message)
    end

    def review_history(current_metadata, payload)
      (Array(current_metadata["sms_post_send_supervisor_review_history"]).last(9) + [payload]).compact_blank
    end

    def result(status, reason: nil, issue_codes: [], correction_body: nil, confidence: nil)
      {
        "supervisor_status" => status,
        "reason" => reason,
        "issue_codes" => Array(issue_codes).compact_blank,
        "confidence" => confidence,
        "correction_body" => correction_body,
        "source" => source,
        "related_outbound_id" => outbound.to_h["id"].presence,
        "related_outbound_provider_message_id" => outbound.to_h["provider_message_id"].presence,
        "reviewed_at" => Time.current.iso8601
      }.compact_blank
    end

    def worker_health_snapshot
      return {} unless defined?(Autos::WorkerQueue)

      status = Autos::WorkerQueue.status_for(worker_id: "post-send-supervisor", worker_queue: "sms").with_indifferent_access
      snapshot = status.slice(:enabled, :queued_sms, :queued_comms, :queued_all, :claimed, :active, :local_model, :local_frontier_model, :qwen_only, :generated_at)
      if status[:enabled] && status[:queued_sms].to_i.positive? && status[:claimed].to_i.zero?
        snapshot[:attention] = "sms_jobs_queued_with_no_claimed_worker"
      elsif !status[:enabled]
        snapshot[:attention] = "local_worker_disabled"
      end
      snapshot
    rescue StandardError => error
      { error: error.message }
    end
  end
end
