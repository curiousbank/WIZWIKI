module DealReports
  class CommsProcessingCode
    CONTACT_OWNER_CODE = "CONTACT_OWNER".freeze
    DEFAULT_PRODUCT_LINKS = {}.freeze
    PRODUCT_INTENTS = {
      "PRO_PACK" => {
        label: "Pro Pack",
        next_step: "Send the Pro Pack Shopify link and watch for completed checkout."
      },
      "STARTER_PACK" => {
        label: "Starter Pack",
        next_step: "Send the Starter Pack Shopify link and watch for completed checkout."
      },
      "BUSINESS_CARDS" => {
        label: "Business Cards",
        next_step: "Send the Business Cards Shopify link only when the customer specifically wants business cards."
      },
      "DOOR_HANGERS" => {
        label: "Door Hangers",
        next_step: "Send the Door Hangers Shopify link only when the customer specifically wants door hangers."
      },
      "FLYERS" => {
        label: "Flyers",
        next_step: "Send the Flyers Shopify link only when the customer specifically wants flyers or handouts."
      },
      "EDDM" => {
        label: "EDDM",
        next_step: "Send the EDDM Shopify link and watch for completed checkout."
      },
      "NEIGHBORHOOD_BLITZ" => {
        label: "Neighborhood Blitz",
        next_step: "Send the neighborhood campaign Shopify link and watch for completed checkout."
      },
      "LAWN_SIGNS" => {
        label: "Lawn Signs",
        next_step: "Send the lawn signs Shopify link and watch for completed checkout."
      }
    }.freeze
    LANE_MONITOR_WINDOW = 12
    CHECKOUT_CONFIRMATION_PATTERN = /\b(?:that works|that should work|sounds good|looks good|ok|okay|cool|perfect|great|yes|yep|yeah|sure|yes please|send it|go ahead|please do)\b/i.freeze

    def self.call(stage:, metadata: nil, latest_body: nil)
      new(stage: stage, metadata: metadata, latest_body: latest_body).call
    end

    KEYWORDS = {
      "PRO_PACK" => [/pro pack/, /larger bundle/, /big bundle/, /pro bundle/, /signs?.*(business cards?).*(door hangers?)/, /door hangers?.*(business cards?).*signs?/],
      "STARTER_PACK" => [/starter pack/, /starter bundle/, /small bundle/, /signs?.*(business cards?).*(door hangers?)/, /door hangers?.*(business cards?).*signs?/],
      "BUSINESS_CARDS" => [/business cards?/],
      "DOOR_HANGERS" => [/door hangers?/, /doorhanger/, /\bhangers?\b/],
      "FLYERS" => [/flyers?/, /handouts?/],
      "EDDM" => [/\beddm\b/, /every door/, /direct mail/, /post\s*cards?/, /postcard/, /mailer/, /mailing/],
      "NEIGHBORHOOD_BLITZ" => [/neighborhood/, /neighbourhood/, /blitz/, /saturation/, /local push/, /\bcombo\b/, /\bcombined?\b/],
      "LAWN_SIGNS" => [/lawn sign/, /yard sign/, /signage/, /\bsigns?\b/]
    }.freeze

    def self.classify(text, latest_body: nil)
      explicit_latest_code = explicit_latest_product_code(latest_body)
      return explicit_latest_code if explicit_latest_code.present?

      scores = Hash.new(0)
      add_scores!(scores, text, 1)
      add_scores!(scores, latest_body, 4)
      code, score = scores.max_by { |candidate, value| [value, PRODUCT_INTENTS.keys.index(candidate) * -1] }
      score.to_i.positive? ? code : nil
    end

    def self.add_scores!(scores, text, weight)
      normalized = text.to_s.downcase
      return if normalized.blank?

      KEYWORDS.each do |code, patterns|
        patterns.each { |pattern| scores[code] += weight if normalized.match?(pattern) }
      end
    end

    def self.explicit_latest_product_code(text)
      normalized = text.to_s.downcase.squish
      return if normalized.blank?

      sign_design_or_order = normalized.match?(/\b(?:yard|lawn|jobsite|directional)?\s*signs?\b.{0,90}\b(?:design|logo|proof|order|help|need|want)\b/) ||
        normalized.match?(/\b(?:need|want|looking for|looking to get|would need|just need|only need|help with|send me|order|ordering|get)\b.{0,90}\b(?:yard|lawn|jobsite|directional)?\s*signs?\b/)
      wants_signs = normalized.match?(/\b(?:yard|lawn|jobsite|directional)\s+signs?\b/) ||
        normalized.match?(/\bsignage\b/) ||
        sign_design_or_order
      wants_postcards = normalized.match?(/\b(?:eddm|every door|direct mail|post\s*cards?|postcards?|mailers?|mailing)\b/) ||
        direct_mail_household_intent?(normalized)
      wants_business_cards = normalized.match?(/\bbusiness cards?\b/)
      wants_door_hangers = normalized.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/)
      wants_flyers = normalized.match?(/\b(?:flyers?|handouts?)\b/)
      wants_combo = normalized.match?(/\A(?:combo|both|both together|combined?|combined push|combination)\z/) ||
        normalized.match?(/\b(?:combo|both together|combined push|combine both|post\s*cards?.{0,40}signs?|signs?.{0,40}post\s*cards?)\b/)
      rejects_postcards = normalized.match?(/\b(?:do\s+not|don'?t|dont|no|not|isn'?t|is not|wasn'?t|was not|weren'?t|were not|without|instead of|rather than)\b.{0,80}\b(?:eddm|every door|direct mail|post\s*cards?|postcards?|mailers?|mailing)\b/) ||
        normalized.match?(/\b(?:eddm|every door|direct mail|post\s*cards?|postcards?|mailers?|mailing)\b.{0,60}\b(?:do\s+not|don'?t|dont|no|not|isn'?t|is not|aren'?t|are not|without)\b/)

      return "LAWN_SIGNS" if wants_signs && rejects_postcards
      return "NEIGHBORHOOD_BLITZ" if wants_combo
      return "BUSINESS_CARDS" if wants_business_cards && !wants_signs && !wants_postcards && !wants_door_hangers && !wants_flyers
      return "DOOR_HANGERS" if wants_door_hangers && !wants_signs && !wants_postcards && !wants_business_cards && !wants_flyers
      return "FLYERS" if wants_flyers && !wants_signs && !wants_postcards && !wants_business_cards && !wants_door_hangers
      return "LAWN_SIGNS" if wants_signs && (rejects_postcards || !wants_postcards)
      return "EDDM" if wants_postcards && !wants_signs
      nil
    end

    def initialize(stage:, metadata: nil, latest_body: nil)
      @stage = stage
      @metadata = metadata.to_h.presence || stage.metadata.to_h
      @latest_body = latest_body.to_s.squish
    end

    def call
      stored_code = valid_product_interest_code(@metadata["product_interest_code"])
      prompt_code = latest_outbound_checkout_prompt_route
      latest_code = prompt_code.presence || self.class.classify(customer_latest_body, latest_body: customer_latest_body)
      thread_scan = fresh_thread_lane_scan
      thread_code = valid_product_interest_code(thread_scan["route_code"])
      stored_code = nil if discovery_reset_active?
      product_code = prompt_code.presence || monitored_product_code(stored_code: stored_code, latest_code: latest_code, thread_scan: thread_scan)
      product_code = valid_product_interest_code(product_code)
      monitor = lane_monitor_payload(
        stored_code: stored_code,
        latest_code: latest_code,
        thread_scan: thread_scan,
        product_code: product_code,
        prompt_code: prompt_code
      )
      return pending_payload(monitor) if product_code.blank?

      config = PRODUCT_INTENTS.fetch(product_code)
      link = shopify_link(product_code)
      {
        "processing_code" => "PRODUCT_INTEREST",
        "processing_label" => "Product Interest",
        "processing_next_step" => config.fetch(:next_step),
        "processing_summary" => summary(product_code),
        "processing_source" => monitor["source"].presence || "customer_signal",
        "product_interest_code" => product_code,
        "product_interest_label" => config.fetch(:label),
        "sms_lane_monitor" => monitor,
        "sms_lane_monitor_updated_at" => monitor["updated_at"],
        "shopify_link" => link,
        "shopify_link_sent_at" => @metadata["shopify_link_sent_at"],
        "comms_bot_state" => normalized_bot_state(product_code, route_label: config.fetch(:label), shopify_link: link),
        "contact_owner_status" => @metadata["comms_routed_to_user_id"].present? ? "assigned" : "not_requested",
        "processing_updated_at" => Time.current.iso8601,
        "processing_embedding_plan" => "evening_batch"
      }.compact_blank
    end

    private

    def monitored_product_code(stored_code:, latest_code:, thread_scan:)
      thread_code = valid_product_interest_code(thread_scan.to_h["route_code"])
      if latest_code_override?(stored_code, latest_code)
        return latest_code
      end

      if thread_code.present? && thread_scan_overrides_stored?(stored_code, thread_scan)
        return thread_code
      end

      stored_code || thread_code || inferred_product_code_from_fit
    end

    def thread_scan_overrides_stored?(stored_code, thread_scan)
      thread_code = valid_product_interest_code(thread_scan.to_h["route_code"])
      return false if thread_code.blank?
      return true if stored_code.blank?
      return false if stored_code == thread_code

      thread_scan.to_h["confidence"].to_s.in?(%w[high medium]) &&
        thread_scan.to_h["source"].to_s.in?(%w[latest_inbound fresh_thread_scan])
    end

    def fresh_thread_lane_scan
      events = customer_signal_events.last(LANE_MONITOR_WINDOW)
      latest = customer_latest_body.to_s.squish
      scores = Hash.new(0.0)
      evidence = Hash.new { |hash, key| hash[key] = [] }

      events.each_with_index do |event, index|
        body = event.to_h["body"].to_s.squish
        next if body.blank?

        route = valid_product_interest_code(self.class.classify(body, latest_body: body))
        next if route.blank?

        latest_event = latest.present? && body == latest
        weight = 1.0 + (index.to_f / 4.0)
        weight += 4.0 if latest_event
        weight += 1.5 if direct_lane_signal?(body)
        scores[route] += weight
        evidence[route] << body.first(180)
      end

      route, score = scores.max_by { |candidate, value| [value, PRODUCT_INTENTS.keys.index(candidate).to_i * -1] }
      route = valid_product_interest_code(route)
      {
        "route_code" => route,
        "source" => latest.present? && route.present? && self.class.classify(latest, latest_body: latest).to_s == route.to_s ? "latest_inbound" : (route.present? ? "fresh_thread_scan" : "no_customer_lane"),
        "confidence" => lane_confidence(score.to_f, scores),
        "scores" => scores.transform_values { |value| value.round(2) },
        "evidence" => route.present? ? evidence[route].last(3) : [],
        "latest_body" => latest.presence,
        "thread_events_scanned" => events.length
      }.compact_blank
    end

    def lane_monitor_payload(stored_code:, latest_code:, thread_scan:, product_code:, prompt_code: nil)
      source = if product_code.present? && prompt_code.to_s == product_code.to_s
        "latest_outbound_checkout_prompt"
      elsif product_code.present? && latest_code.to_s == product_code.to_s
        "latest_inbound"
      elsif product_code.present? && thread_scan.to_h["route_code"].to_s == product_code.to_s
        thread_scan.to_h["source"].presence || "fresh_thread_scan"
      elsif product_code.present? && stored_code.to_s == product_code.to_s
        "stored_lane"
      else
        "no_customer_lane"
      end

      {
        "route_code" => product_code,
        "route_label" => product_code.present? ? PRODUCT_INTENTS.dig(product_code, :label) : nil,
        "source" => source,
        "confidence" => product_code.present? ? lane_confidence_for_source(source, thread_scan) : "none",
        "latest_code" => latest_code,
        "prompt_code" => prompt_code,
        "stored_code" => stored_code,
        "thread_code" => thread_scan.to_h["route_code"],
        "thread_source" => thread_scan.to_h["source"],
        "scores" => thread_scan.to_h["scores"],
        "evidence" => thread_scan.to_h["evidence"],
        "latest_body" => thread_scan.to_h["latest_body"],
        "thread_events_scanned" => thread_scan.to_h["thread_events_scanned"],
        "reason" => lane_monitor_reason(source, product_code, stored_code, latest_code, thread_scan),
        "updated_at" => Time.current.iso8601
      }.compact_blank
    end

    def lane_monitor_reason(source, product_code, stored_code, latest_code, thread_scan)
      case source.to_s
      when "latest_outbound_checkout_prompt"
        "Latest inbound accepted the most recent outbound checkout prompt for #{PRODUCT_INTENTS.dig(product_code, :label)}."
      when "latest_inbound"
        "Latest inbound clearly points to #{PRODUCT_INTENTS.dig(product_code, :label)}."
      when "fresh_thread_scan"
        "Latest inbound was ambiguous, so the lane was inherited from the recent customer thread scan."
      when "stored_lane"
        "No fresher customer lane signal was found, so the prior stored lane remains active."
      else
        "No clear product lane has been established yet."
      end
    end

    def lane_confidence_for_source(source, thread_scan)
      return "high" if source.to_s == "latest_outbound_checkout_prompt"
      return "high" if source.to_s == "latest_inbound"
      return thread_scan.to_h["confidence"].presence || "medium" if source.to_s == "fresh_thread_scan"
      return "low" if source.to_s == "stored_lane"

      "none"
    end

    def lane_confidence(score, scores)
      return "none" if score.to_f <= 0

      ordered = scores.values.sort.reverse
      runner_up = ordered[1].to_f
      return "high" if score >= 5.0 && (runner_up.zero? || score >= runner_up + 2.0)
      return "medium" if score >= 2.0

      "low"
    end

    def direct_lane_signal?(body)
      body.to_s.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|starter pack|pro pack|neighbou?rhood blitz|combo|both|signs?\s*(?:and|\+)\s*postcards?|postcards?\s*(?:and|\+)\s*signs?)\b/i)
    end

    def latest_outbound_checkout_prompt_route
      return unless customer_latest_body.to_s.match?(CHECKOUT_CONFIRMATION_PATTERN)

      checkout_prompt_route(latest_outbound_text_before_latest_inbound)
    end

    def latest_outbound_text_before_latest_inbound
      recent_outbound_texts_before_latest_inbound.first
    end

    def recent_outbound_texts_before_latest_inbound
      found_latest_inbound = false
      sms_thread_events.reverse_each.filter_map do |event|
        event = event.to_h
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

      route_from_checkout_prompt_text(body)
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

    def discovery_reset_active?
      ActiveModel::Type::Boolean.new.cast(@metadata["sms_discovery_reset"]) && conversation_reset_time.present?
    end

    def latest_code_override?(stored_code, latest_code)
      return false if latest_code.blank?
      return false if stored_code.blank? || stored_code == latest_code

      customer_latest_body.to_s.match?(/\b(what about|how about|instead|rather|only|just|combo|combined?|combination|both|post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing|mail|reach|target|homes?|houses?|households?|doors?|addresses?|mailboxes?|yard signs?|lawn signs?|signs?|business cards?|door hangers?|hangers?|flyers?|handouts?|pro pack|starter pack|blitz|artwork|design)\b/i)
    end

    def pending_payload(monitor = nil)
      {
        "processing_code" => nil,
        "processing_label" => nil,
        "processing_next_step" => "Keep the SMS chat focused on understanding what the customer wants to buy or build.",
        "processing_summary" => "Contact owner pending. Thumper is waiting for a customer product signal.",
        "processing_source" => "pending_customer_signal",
        "product_interest_code" => nil,
        "product_interest_label" => nil,
        "sms_lane_monitor" => monitor.presence || lane_monitor_payload(stored_code: nil, latest_code: nil, thread_scan: {}, product_code: nil),
        "sms_lane_monitor_updated_at" => Time.current.iso8601,
        "comms_bot_state" => normalized_bot_state(nil),
        "contact_owner_status" => "pending",
        "processing_updated_at" => Time.current.iso8601,
        "processing_embedding_plan" => "evening_batch"
      }
    end

    def normalized_bot_state(product_code, route_label: nil, shopify_link: nil)
      state = @metadata["comms_bot_state"].to_h.deep_dup
      prior_route = valid_product_interest_code(state["route_code"])
      state.except!(
        "route_code",
        "route_label",
        "product_interest_code",
        "product_interest",
        "product_label",
        "shopify_link"
      )
      state.delete("campaign_fit") if product_code.blank? || (prior_route.present? && prior_route != product_code)
      return state.compact_blank if product_code.blank?

      state.merge(
        "route_code" => product_code,
        "route_label" => route_label.presence || PRODUCT_INTENTS.dig(product_code, :label),
        "product_interest_code" => product_code,
        "product_interest" => route_label.presence || PRODUCT_INTENTS.dig(product_code, :label),
        "shopify_link" => shopify_link
      ).compact_blank
    end

    def customer_signal_text
      [
        inbound_thread_bodies,
        inbound_email_bodies,
        @metadata["location_capture_last"].to_h.values
      ].flatten.compact.join("\n")
    end

    def customer_latest_body
      latest_inbound = inbound_thread_bodies.last
      latest_inbound.presence || inbound_email_bodies.last
    end

    def customer_signal_events
      events = sms_thread_events.filter_map do |event|
        event = event.to_h
        next unless event["direction"].to_s == "inbound"
        next unless event["channel"].to_s == "sms"

        body = event["body"].to_s.squish.presence
        next if body.blank?

        { "body" => body, "created_at" => event["created_at"], "channel" => "sms" }
      end
      events.concat(email_thread_events.filter_map do |event|
        event = event.to_h
        next unless event["direction"].to_s == "inbound"

        body = [event["subject"], event["body"]].compact.join(" ").squish.presence
        next if body.blank?

        { "body" => body, "created_at" => event["created_at"], "channel" => "email" }
      end)
      events
    end

    def inferred_product_code_from_fit
      text = customer_signal_text
      return if text.blank?

      wants_both = text.match?(/\b(both|combo|combined?|combination|bundle|pack|signs?\s*(?:and|\+)\s*(?:post\s*cards?|postcards?)|(?:post\s*cards?|postcards?)\s*(?:and|\+)\s*signs?)\b/i)
      wants_signs = text.match?(/\b(?:just\s+)?(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signage|stakes?|signs?)\b/i)
      wants_postcards = text.match?(/\b(post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/i) ||
        direct_mail_household_intent?(text)
      budget = numeric_value(text[/\$\s?[\d,]+/] || text[/\b(?:budget|spend|around|under|up to|about)\s+([\d,]+)/i])
      households = numeric_value(text[/\b(?:reach|mail|send|target)?\s*([\d,]{2,6})\s*(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/i])

      if wants_both
        return "PRO_PACK" if (budget.present? && budget >= 1_000) || (households.present? && households >= 1_000)
        return "STARTER_PACK"
      end

      return "LAWN_SIGNS" if wants_signs && !wants_postcards
      return "EDDM" if wants_postcards && !wants_signs

      nil
    end

    def self.direct_mail_household_intent?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      sign_only = body.match?(/\b(?:yard|lawn|jobsite|directional)\s+signs?\b/) &&
        !body.match?(/\b(?:mail|mailers?|mailing|post\s*cards?|postcards?|eddm|direct mail)\b/)
      return false if sign_only

      body.match?(/\b(?:mail|send|hit|reach|target|cover)\b.{0,50}\b(?:\d[\d,]*\s*)?(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/) ||
        body.match?(/\b(?:\d[\d,]*\s*)?(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b.{0,50}\b(?:mail|mailers?|post\s*cards?|postcards?|reach|target)\b/)
    end

    def direct_mail_household_intent?(text)
      self.class.direct_mail_household_intent?(text)
    end

    def numeric_value(value)
      value.to_s[/\d[\d,]*/].to_s.tr(",", "").presence&.to_i
    end

    def classification_text
      [
        @latest_body,
        @metadata["comms_command_sms_draft_body"],
        @metadata["aircall_composed_sms_body"],
        @metadata["aircall_composed_email_body"],
        @metadata["composed_sms_body"],
        @metadata["composed_email_body"],
        sms_thread_events.last(8).map { |event| event.to_h["body"] },
        email_thread_events.last(4).map { |event| [event.to_h["subject"], event.to_h["body"]] },
        Array(@metadata["sms_options"]).map { |option| option.to_h["body"] },
        Array(@metadata["email_options"]).map { |option| [option.to_h["subject"], option.to_h["body"]] }
      ].flatten.compact.join("\n")
    end

    def inbound_thread_bodies
      sms_thread_events.filter_map do |event|
        event = event.to_h
        next unless event["direction"].to_s == "inbound"
        next unless event["channel"].to_s == "sms"

        event["body"].to_s.squish.presence
      end
    end

    def inbound_email_bodies
      email_thread_events.filter_map do |event|
        event = event.to_h
        next unless event["direction"].to_s == "inbound"

      [event["subject"], event["body"]].compact.join(" ").squish.presence
      end
    end

    def sms_thread_events
      Array(@metadata["sms_thread"]).map(&:to_h).select { |event| event_after_reset?(event) }
    end

    def email_thread_events
      Array(@metadata["email_thread"]).map(&:to_h).select { |event| event_after_reset?(event) }
    end

    def event_after_reset?(event)
      reset_at = conversation_reset_time
      return true if reset_at.blank?

      event_time = parsed_event_time(event)
      event_time.present? && event_time >= reset_at
    end

    def conversation_reset_time
      value = @metadata["sms_conversation_reset_at"].to_s
      return if value.blank?

      Time.zone.parse(value)
    rescue ArgumentError, TypeError
      nil
    end

    def parsed_event_time(event)
      value = event.to_h["created_at"].presence || event.to_h["at"].presence || event.to_h["timestamp"].presence
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def summary(code)
      company = @metadata["company_name"].presence || @stage.crm_record&.name.to_s.presence || @stage.title
      contact = selected_contact["name"].presence || selected_phone["name"].presence || selected_email["name"].presence || "selected contact"
      latest = customer_latest_body.presence || "No customer reply recorded yet."
      "#{company}: #{contact} is interested in #{PRODUCT_INTENTS.fetch(code).fetch(:label)}. Offer the best Shopify link when fit is clear, answer pricing from product data, and route CONTACT_OWNER when custom quantity, quote, order/payment, approval, or unsupported product questions need AM judgment. Latest signal: #{latest.first(220)}"
    end

    def shopify_link(product_code)
      specific = [
        ENV["WIZWIKI_SHOPIFY_#{product_code}_URL"].presence,
        ENV["SHOPIFY_#{product_code}_URL"].presence,
        training_shopify_links[product_code]
      ].compact_blank.find { |link| shopify_link_matches_route?(product_code, link) }
      specific ||
        conversation_shopify_link(product_code) ||
        metadata_shopify_link(product_code) ||
        DEFAULT_PRODUCT_LINKS[product_code]
    end

    def conversation_shopify_link(product_code)
      state = @metadata["comms_bot_state"].to_h
      return unless state["route_code"].to_s == product_code.to_s || @metadata["product_interest_code"].to_s == product_code.to_s

      link = state["shopify_link"].to_s.squish.presence
      link if link.present? && !generic_shopify_link?(link) && shopify_link_matches_route?(product_code, link)
    end

    def metadata_shopify_link(product_code)
      return unless @metadata["product_interest_code"].to_s == product_code.to_s

      link = @metadata["shopify_link"].to_s.squish.presence
      link if link.present? && !generic_shopify_link?(link) && shopify_link_matches_route?(product_code, link)
    end

    def generic_shopify_link?(link)
      link.to_s.match?(%r{/collections/(?:all|origin)(?:[/?#]|\z)}i) ||
        link.to_s.match?(%r{/collections/?(?:[?#]|\z)}i)
    end

    def shopify_link_matches_route?(route, url)
      text = url.to_s.downcase
      return false if text.blank?
      return true if route.to_s == "STORE"
      return false if disallowed_shopify_link?(text)

      case route.to_s
      when "PRO_PACK"
        text.match?(%r{/products/[^?#]*(?:pro-pack|pro[_-]?pack|100-ys|100-yard-signs)})
      when "STARTER_PACK"
        text.match?(%r{/products/[^?#]*(?:starter-pack|starter[_-]?pack|20-yard-signs)})
      when "EDDM"
        text.match?(%r{/products/[^?#]*(?:eddm|postcard|postcards|direct-mail|mailer|mailers|olderhomes|go-big-postcard|targeted-postcard)})
      when "NEIGHBORHOOD_BLITZ"
        text.match?(%r{/products/[^?#]*(?:main-course|neighborhood|neighbourhood|blitz)})
      when "LAWN_SIGNS"
        text.match?(%r{/products/[^?#]*(?:yard-sign|yard-signs|lawn-sign|lawn-signs|jobsite-sign|directional-sign|signage|stakes|18x24|24x18|wizwiki-deal-18x24)})
      else
        false
      end
    end

    def disallowed_shopify_link?(url)
      url.to_s.match?(%r{/products/[^?#\s]*\bdane\b}i)
    end

    def training_shopify_links
      return @training_shopify_links if defined?(@training_shopify_links)

      organization = @stage.organization || @stage.crm_record&.organization
      return @training_shopify_links = {} if organization.blank? || !defined?(TrainingDocument)

      documents = organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"]).order(updated_at: :desc).limit(300).to_a
      @training_shopify_links = documents.each_with_object({}) do |document, links|
        text = [document.title, document.file_name, document.body].compact.join("\n")
        urls = text.scan(%r{https?://[^\s<>"')\]]+}).map { |url| url.delete_suffix(".").delete_suffix(",") }.uniq
        next if urls.blank?

        code = classify_product_link_document(text)
        if code.present?
          matching_url = urls.find { |url| shopify_link_matches_route?(code, url) }
          links[code] ||= matching_url if matching_url.present?
        end
        links["STORE"] ||= urls.first if code.blank? && text.match?(/\b(shopify|shop\.wizwikimarketing|all products|collection|store)\b/i)
      end.compact_blank
    rescue StandardError => error
      Rails.logger.warn("[CommsProcessingCode] training Shopify links unavailable: #{error.class}: #{error.message}")
      @training_shopify_links = {}
    end

    def classify_product_link_document(text)
      body = text.to_s.downcase
      title_or_url = body.lines.first.to_s
      return "STARTER_PACK" if title_or_url.match?(/\b(starter pack|starter-pack|starter bundle)\b/) || title_or_url.include?("starter-pack-bundle")
      return "PRO_PACK" if title_or_url.match?(/\b(pro pack|pro-pack|pro bundle)\b/) || title_or_url.include?("pro-pack-bundle")
      return "BUSINESS_CARDS" if title_or_url.match?(/\b(business cards?|business-cards?)\b/) || title_or_url.include?("business-cards")
      return "DOOR_HANGERS" if title_or_url.match?(/\b(door hangers?|door-hangers?|doorhanger|hangers?)\b/) || title_or_url.include?("door-hangers")
      return "FLYERS" if title_or_url.match?(/\b(flyers?|flyers-canvasser|handouts?)\b/) || title_or_url.include?("flyers-canvasser")
      return "LAWN_SIGNS" if title_or_url.match?(/\b(24x18|yard signs?|lawn signs?|signage|stakes|signs?)\b/) || title_or_url.include?("24x18-yard-signs")

      pro_bundle = body.match?(/\b(pro pack|pro-pack|pro bundle)\b/) ||
        (body.match?(/\b100 yard signs?\b/) && body.match?(/\b(?:1000|1,000) business cards?\b/) && body.match?(/\b(?:1000|1,000) door hangers?\b/))
      starter_bundle = body.match?(/\b(starter pack|starter-pack|starter bundle)\b/) ||
        (body.match?(/\b20 yard signs?\b/) && body.match?(/\b500 business cards?\b/) && body.match?(/\b500 door hangers?\b/))
      return "PRO_PACK" if pro_bundle
      return "STARTER_PACK" if starter_bundle
      return "BUSINESS_CARDS" if body.match?(/\b(business cards?|business-cards?)\b/)
      return "DOOR_HANGERS" if body.match?(/\b(door hangers?|door-hangers?|doorhanger|hangers?)\b/)
      return "FLYERS" if body.match?(/\b(flyers?|flyers-canvasser|handouts?)\b/)
      return "LAWN_SIGNS" if body.match?(/\b(24x18|yard signs?|lawn signs?|signage|stakes|jobsite signs?|directional signs?|signs?)\b/)
      return "EDDM" if body.match?(/\b(eddm|every door|post\s*cards?|postcard|postcards|direct mail|mailer|mailers)\b/)
      return "NEIGHBORHOOD_BLITZ" if body.match?(/\b(neighborhood|neighbourhood|blitz|door hanger|doorhanger|saturation|local push)\b/)

      nil
    end

    def valid_product_interest_code(value)
      code = value.to_s.presence
      return if code.blank?

      PRODUCT_INTENTS.key?(code) ? code : nil
    end

    def selected_contact
      @metadata["aircall_selected_contact"].to_h.presence || option_by_id("contact_options", "selected_contact_id")
    end

    def selected_phone
      @metadata["aircall_selected_phone"].to_h.presence || option_by_id("phone_options", "selected_phone_id")
    end

    def selected_email
      @metadata["aircall_selected_recipient_email"].to_h.presence || option_by_id("recipient_email_options", "selected_recipient_email_id")
    end

    def option_by_id(options_key, selected_key)
      selected_id = @metadata[selected_key].to_s
      options = Array(@metadata[options_key])
      match = options.find { |option| option.to_h["id"].to_s == selected_id }
      (match || options.first).to_h
    end

    def latest_thread_body
      Array(@metadata["sms_thread"]).reverse_each do |event|
        body = event.to_h["body"].to_s.squish
        return body if body.present?
      end
      nil
    end
  end
end
