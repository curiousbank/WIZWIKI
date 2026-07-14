# frozen_string_literal: true

require "digest"

module Comms
  class SmsPreSendVerifier
    SHOPIFY_PRODUCT_URL = %r{https?://shop\.wizwikimarketing\.com/products/[^\s)]+}i
    INTERNAL_VOICE_PATTERN = /
      \b(?:here(?:'s| is)\s+(?:the\s+)?(?:next\s+)?(?:sms|text|message)|let me analyze|customer-facing|non-customer-facing|
      quality\s+gate|guardrail|reguidance|drafting\s+with\s+fresh\s+guidance|route\s+code|scenario\s+\d|attempt\s+\d)\b
    /ix.freeze
    PREMATURE_HANDOFF_PATTERN = /\b(?:will be contacting you|will contact you|i let them know|i've let them know|i have let them know|someone will reach out|they will reach out)\b/i.freeze
    PRICE_QUESTION_PATTERN = /\b(?:how much|price|pricing|cost|quote|what.*cost|what.*price|total)\b/i.freeze
    CHECKOUT_REQUEST_PATTERN = /\b(?:link|checkout|order|buy|ready|send|start|proceed|go ahead|purchase)\b/i.freeze
    CHECKOUT_CONFIRMATION_PATTERN = /\b(?:that works|that should work|sounds good|looks good|ok|okay|cool|perfect|great|yes|yep|yeah|sure|yes please|send it|go ahead|please do)\b/i.freeze

    Result = Struct.new(:allowed, :body, :metadata, :issue_codes, :reason, :corrected, keyword_init: true) do
      def blocked?
        !allowed
      end

      def to_h
        {
          "allowed" => allowed,
          "body" => body,
          "metadata" => metadata.to_h,
          "issue_codes" => Array(issue_codes),
          "reason" => reason,
          "corrected" => corrected
        }.compact_blank
      end
    end

    def self.call(stage:, body:, source: nil, metadata: nil)
      new(stage: stage, body: body, source: source, metadata: metadata).call
    end

    def initialize(stage:, body:, source: nil, metadata: nil)
      @stage = stage
      @body = body.to_s.squish
      @source = source.to_s.presence || "sms_pre_send"
      @metadata = (metadata || stage&.metadata).to_h.deep_dup
      @issue_codes = []
    end

    def call
      return result(false, body: body, reason: "blank_sms_body", issue_codes: ["blank_sms_body"]) if body.blank?
      return result(false, body: nil, reason: "internal_voice_leak", issue_codes: ["internal_voice_leak"]) if internal_voice_leak?
      return result(false, body: nil, reason: "unsafe_sms_body", issue_codes: ["unsafe_sms_body"]) if unsafe_sms_body?
      if unsupported_catalog_claim?
        return result(false, body: nil, reason: "unconfigured_catalog_claim", issue_codes: ["unconfigured_catalog_claim"])
      end

      verified = body.dup
      if defined?(Comms::ConsultantVoice)
        voice_review = Comms::ConsultantVoice.review(body: verified, inbound: latest_customer_text)
        if voice_review.blocked?
          return result(false, body: nil, reason: voice_review.reason, issue_codes: voice_review.issue_codes)
        end

        verified = voice_review.body
        issue_codes.concat(Array(voice_review.issue_codes)).uniq!
      end
      verified = verify_yard_sign_quantity(verified)
      verified = verify_product_links(verified)
      verified = verify_premature_handoff(verified)

      result(true, body: verified, reason: issue_codes.any? ? "verified_with_corrections" : "verified", issue_codes: issue_codes, corrected: verified != body)
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsPreSendVerifier] failed stage=#{stage&.id} #{error.class}: #{error.message}") if defined?(Rails)
      result(false, body: nil, reason: "#{error.class}: #{error.message}", issue_codes: ["verifier_error"])
    end

    private

    attr_reader :stage, :body, :source, :metadata, :issue_codes

    def internal_voice_leak?
      body.match?(INTERNAL_VOICE_PATTERN)
    end

    def unsafe_sms_body?
      defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(body)
    end

    def unsupported_catalog_claim?
      return false unless defined?(Comms::ProductCatalog)

      urls = body.scan(%r{https?://[^\s)]+}i).map { |url| Comms::ProductCatalog.normalize_url(url) }
      unreviewed_product_link = urls.any? do |url|
        url.to_s.match?(%r{/(?:products|collections|checkout)(?:/|\?|\z)}i) &&
          !Comms::ProductCatalog.known_checkout_url?(url)
      end
      unsupported_price = body.match?(/\$\s*\d|\b\d+(?:\.\d{2})?\s+(?:dollars?|usd)\b/i) &&
        Comms::ProductCatalog.products.blank?

      unreviewed_product_link || unsupported_price
    end

    def verify_yard_sign_quantity(current_body)
      quantity = exact_yard_sign_quantity_from_text(latest_customer_text)
      return current_body if quantity.blank?

      price = catalog_price("LAWN_SIGNS", quantity)
      return current_body if price.blank?

      lower = current_body.downcase
      mentions_signs = lower.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
      price_question = latest_customer_text.match?(PRICE_QUESTION_PATTERN)
      wrong_quantity = yard_sign_quantities_in(current_body).any? { |candidate| candidate != quantity }
      missing_price = price_question && !current_body.include?(price)
      wrong_price = mentions_signs && explicit_wrong_yard_sign_price?(current_body, expected_price: price)
      return current_body unless wrong_quantity || missing_price || wrong_price

      issue_codes << "yard_sign_quantity_authority"
      yard_sign_quantity_reply(quantity, price)
    end

    def verify_product_links(current_body)
      urls = current_body.scan(SHOPIFY_PRODUCT_URL).map { |url| Comms::ProductCatalog.normalize_url(url) }
      return current_body if urls.blank?

      if ambiguous_product_request?
        route_codes = urls.filter_map { |url| Comms::ProductCatalog.route_for_checkout_url(url) }
        if (route_codes - expected_product_routes).present? || !checkout_request?(latest_customer_text)
          issue_codes << "ambiguous_product_link_removed"
          return print_mix_reply
        end
      end

      unknown_urls = urls.reject { |url| Comms::ProductCatalog.known_checkout_url?(url) }
      if unknown_urls.present?
        expected_route = expected_product_route
        if expected_route.present? && (expected_url = catalog_checkout_url(expected_route)).present?
          issue_codes << "unknown_product_link_rewritten"
          current_body = replace_first_product_url(current_body, expected_url)
        else
          issue_codes << "unknown_product_link"
          return blocked_link_body
        end
      end

      expected_route = expected_product_route
      expected_url = catalog_checkout_url(expected_route) if expected_route.present?
      return current_body if expected_url.blank?
      return current_body if current_body.include?(expected_url)
      return current_body unless checkout_request?(latest_customer_text) || current_body.match?(CHECKOUT_REQUEST_PATTERN)

      issue_codes << "product_link_authority"
      product_link_reply(expected_route, expected_url)
    end

    def verify_premature_handoff(current_body)
      return current_body unless current_body.match?(PREMATURE_HANDOFF_PATTERN)
      return current_body if handoff_contact_posted? && handoff_contact_ready?

      issue_codes << "handoff_contact_details_missing"
      "I want to help you get the best support possible. What is the best way for a marketing consultant to reach you: email, call, or text? I can use this number if text is best."
    end

    def expected_product_route
      routes = expected_product_routes
      return routes.first if routes.one?

      metadata["product_interest_code"].presence ||
        metadata.dig("comms_bot_state", "route_code").presence
    end

    def expected_product_routes
      @expected_product_routes ||= begin
        explicit_routes = Array(Comms::ProductCatalog.routes_for_text(latest_customer_text)).compact_blank
        if explicit_routes.present?
          explicit_routes
        elsif checkout_confirmation?(latest_customer_text) && latest_outbound_checkout_prompt_route.present?
          [latest_outbound_checkout_prompt_route]
        else
          []
        end
      end
    end

    def ambiguous_product_request?
      expected_product_routes.many?
    end

    def catalog_checkout_url(route)
      return if route.blank?
      return if Comms::ProductCatalog.sold_out?(route)

      Comms::ProductCatalog.checkout_url(route)
    end

    def catalog_price(route, quantity)
      return if Comms::ProductCatalog.sold_out?(route)

      Comms::ProductCatalog.price_for_quantity(route, quantity)
    end

    def product_link_reply(route, url)
      label = Comms::ProductCatalog.label(route)
      start = Comms::ProductCatalog.starting_price_line(route)
      if route.to_s == "LAWN_SIGNS"
        quantity = exact_yard_sign_quantity_from_text(latest_customer_text)
        price = catalog_price(route, quantity)
        if quantity.present? && price.present?
          return "For #{quantity} yard signs, the listed price is #{price}, and design help, stakes, and shipping are included. Here is the Yard Signs checkout: #{url}"
        end
      end

      fixed = Comms::ProductCatalog.fixed_price(route)
      line = if start.present?
        "#{label} starts at #{start}"
      elsif fixed.present?
        "#{label} is #{fixed}"
      else
        label
      end
      "#{line}. Here is the checkout link: #{url}"
    end

    def yard_sign_quantity_reply(quantity, price)
      base = "For #{quantity} yard signs, the listed price is #{price}, and design help, stakes, and shipping are included."
      checkout_request?(latest_customer_text) ? "#{base} Here is the Yard Signs checkout: #{Comms::ProductCatalog.checkout_url('LAWN_SIGNS')}" : "#{base} Want me to send the #{quantity}-sign checkout?"
    end

    def blocked_link_body
      "I want to double-check the right checkout path before I send a link. What product should I price first?"
    end

    def print_mix_reply
      labels = expected_product_routes.map { |route| Comms::ProductCatalog.label(route) }
      if labels.present?
        "We can help with #{labels.to_sentence.downcase}. Since the sizes and quantities are still fuzzy, would it be helpful for me to get you connected with one of our marketing consultants to map out the cleanest print mix?"
      else
        "We can help with those print pieces. Since the sizes and quantities are still fuzzy, would it be helpful for me to get you connected with one of our marketing consultants to map out the cleanest print mix?"
      end
    end

    def replace_first_product_url(current_body, expected_url)
      current_body.sub(SHOPIFY_PRODUCT_URL, expected_url)
    end

    def latest_customer_text
      @latest_customer_text ||= inbound_events_since_previous_outbound.map { |event| event["body"].to_s.squish }.compact_blank.join(" ").presence ||
        sms_events.reverse.find { |event| event["direction"].to_s == "inbound" }.to_h["body"].to_s.squish
    end

    def inbound_events_since_previous_outbound
      events = sms_events
      last_outbound_index = events.rindex do |event|
        event["direction"].to_s == "outbound" &&
          !event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped])
      end
      candidates = last_outbound_index ? events[(last_outbound_index + 1)..] : events
      Array(candidates).select { |event| event["direction"].to_s == "inbound" }
    end

    def sms_events
      @sms_events ||= Array(metadata["sms_thread"]).map(&:to_h)
    end

    def exact_yard_sign_quantity_from_text(text)
      quantities = yard_sign_quantities_in(text)
      quantities.one? ? quantities.first : nil
    end

    def yard_sign_quantities_in(text)
      body_text = text.to_s.downcase.squish
      quantities = []
      body_text.scan(/\b(\d{1,5})\s*(?:yards?\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i) { |match| quantities << Array(match).first.to_s.delete(",").to_i }
      body_text.scan(/\b(?:yards?\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\s*(?:for|at|around|about|closer to)?\s*(\d{1,5})\b/i) { |match| quantities << Array(match).first.to_s.delete(",").to_i }
      quantities.select(&:positive?).uniq
    end

    def explicit_wrong_yard_sign_price?(current_body, expected_price:)
      expected = expected_price.delete("$,").to_f.round(2)
      amounts = current_body.scan(/\$([\d,]+(?:\.\d{2})?)/).flatten.map { |value| value.delete(",").to_f.round(2) }
      return false if amounts.blank? || amounts.include?(expected)

      current_body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i)
    end

    def checkout_request?(text)
      text.to_s.match?(CHECKOUT_REQUEST_PATTERN) ||
        (checkout_confirmation?(text) && latest_outbound_checkout_prompt_route.present?)
    end

    def checkout_confirmation?(text)
      text.to_s.match?(CHECKOUT_CONFIRMATION_PATTERN)
    end

    def latest_outbound_checkout_prompt_route
      return @latest_outbound_checkout_prompt_route if defined?(@latest_outbound_checkout_prompt_route)

      @latest_outbound_checkout_prompt_route = checkout_prompt_route(latest_outbound_text_before_latest_inbound)
    end

    def latest_outbound_text_before_latest_inbound
      recent_outbound_texts_before_latest_inbound.first
    end

    def recent_outbound_texts_before_latest_inbound
      found_latest_inbound = false
      sms_events.reverse_each.filter_map do |event|
        if !found_latest_inbound
          if event["direction"].to_s == "inbound" && event["body"].to_s.squish.present?
            found_latest_inbound = true
          end
          next
        end

        next unless event["direction"].to_s == "outbound"
        next if event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped])

        event["body"].to_s.squish.presence
      end
    end

    def checkout_prompt_route(text)
      body = text.to_s.downcase.squish
      return if body.blank?
      return unless checkout_prompt_text?(body)

      route_from_checkout_prompt_text(body).presence ||
        Array(Comms::ProductCatalog.routes_for_text(body)).compact_blank.first
    end

    def route_from_checkout_prompt_text(body)
      return "STARTER_PACK" if body.match?(/\bstarter\s*(?:pack|bundle)\b/)
      return "PRO_PACK" if body.match?(/\bpro\s*(?:pack|bundle)\b/)
      return "BUSINESS_CARDS" if body.match?(/\bbusiness[-\s]+cards?\b/)
      return "DOOR_HANGERS" if body.match?(/\b(?:door[-\s]*hangers?|doorhanger|hangers?)\b/)
      return "FLYERS" if body.match?(/\b(?:flyers?|handouts?)\b/)
      return "NEIGHBORHOOD_BLITZ" if body.match?(/\b(?:neighbou?rhood\s+blitz|blitz|main course)\b/)
      return "LAWN_SIGNS" if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
      return "EDDM" if body.match?(/\b(?:eddm|post\s*cards?|postcards?|direct mail|mailers?)\b/)

      nil
    end

    def checkout_prompt_text?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false unless body.match?(/\b(?:checkout|order|buy|purchase|product page)\s+links?\b|\blinks?\b.*\b(?:checkout|order|buy|purchase|product page)\b|\bcheckout\b.*\blinks?\b/)

      body.match?(/\b(?:want me to send|want the|send|share|text|give|get|let me get|can send|should i send|checkout link)\b/)
    end

    def handoff_contact_ready?
      metadata["sms_autopilot_handoff_contact_ready_at"].present? ||
        metadata["sms_autopilot_handoff_contact_posted_at"].present?
    end

    def handoff_contact_posted?
      metadata["sms_autopilot_handoff_contact_posted_at"].present? ||
        metadata["sms_autopilot_slack_handoff_at"].present? ||
        metadata["sms_autopilot_slack_handoff_status"].to_s == "posted"
    end

    def result(allowed, body:, reason:, issue_codes: [], corrected: false)
      payload = review_payload(allowed: allowed, reason: reason, issue_codes: issue_codes, corrected: corrected, final_body: body)
      Result.new(
        allowed: allowed,
        body: body,
        reason: reason,
        issue_codes: issue_codes,
        corrected: corrected,
        metadata: {
          "sms_pre_send_verifier_last" => payload,
          "sms_pre_send_verifier_history" => verifier_history(payload)
        }
      )
    end

    def review_payload(allowed:, reason:, issue_codes:, corrected:, final_body:)
      {
        "status" => allowed ? "passed" : "blocked",
        "reason" => reason,
        "source" => source,
        "issue_codes" => Array(issue_codes).compact_blank,
        "corrected" => corrected,
        "original_sha1" => Digest::SHA1.hexdigest(body),
        "final_sha1" => final_body.present? ? Digest::SHA1.hexdigest(final_body.to_s) : nil,
        "checked_at" => Time.current.iso8601
      }.compact_blank
    end

    def verifier_history(payload)
      (Array(metadata["sms_pre_send_verifier_history"]).last(9) + [payload]).compact_blank
    end
  end
end
