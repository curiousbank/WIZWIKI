# frozen_string_literal: true

module Comms
  module SmsBodySafety
    ROUTE_CODE_PATTERN = /\A(?:starter_pack|pro_pack|lawn_signs|eddm|neighborhood_blitz|custom_artwork|direct_mail|yard_signs?)\z/i
    INTERNAL_ROUTE_TOKEN_PATTERN = /\b(?:starter_pack|pro_pack|lawn_signs|neighborhood_blitz|custom_artwork|direct_mail|yard_signs?|LAWN_SIGNS|NEIGHBORHOOD_BLITZ|STARTER_PACK|PRO_PACK|CUSTOM_ARTWORK|DIRECT_MAIL)\b/
    INTERNAL_KEY_PATTERN = /\b(?:missing_fields|next_missing_field|prompt_if_missing|current_next_text|captured_contact_name|captured_company_name|captured_industry|customer_first_name|customer_company_name|context_json|identity_capture|conversation_state|conversation\s+state|latest_inbound_event|latest_sms_event|latest_outbound_event|latest_inbound_sms|latest_outbound_sms|latest_customer_message|latest\s+inbound\s+message|recent_unsent_drafts|recent_outbound_texts|prior_thumper_messages|operator_prompt|thread_authority|full_sms_thread|recent_sms_thread|product_decision_guide|product\s+decision\s+guide|decision_guide|decision\s+guide|fine_training|campaign_fit_payload|campaign_fit|product_interest|product_interest_code|route_code|shopify_link|product_key|product_label|checkout_url|style_variation|sms_generation_pipeline|sms_quality_gate|autos_question_id|artwork_status|missing\s+fit\s+signal|sign_quantity|ask_if_unclear)\b/i
    INTERNAL_KEY_PREFIX_PATTERN = /\A["']?(?:latest_inbound_event|latest_sms_event|latest_outbound_event|latest_inbound_sms|latest_outbound_sms|full_sms_thread|recent_sms_thread|conversation_state|operator_prompt|context_json|thread_authority|missing_fields|next_missing_field|prompt_if_missing|current_next_text|captured_contact_name|captured_company_name|captured_industry|customer_first_name|customer_company_name|product_interest|product_interest_code|route_code|shopify_link|product_key|product_label|checkout_url|style_variation|sms_generation_pipeline|sms_quality_gate|autos_question_id|sign_quantity|ask_if_unclear)["']?\s*[:=]/i
    JSONISH_PREFIX_PATTERN = /\A(?:\{|\[|["']?(?:body|sms|text|answer|analysis|reason|draft|message|provider|model|latest_inbound_event|conversation_state|operator_prompt)["']?\s*:)/i
    DISALLOWED_SHOPIFY_LINK_PATTERN = %r{https?://(?:shop\.)?wizwikimarketing\.com/products/[^ \t\r\n]*\bdane\b}i
    ANSWER_WRAPPER_PREFIX_PATTERN = /\A(?:(?:here(?:'|’)?s|here\s+is)\s+)?(?:the\s+)?(?:(?:best|strongest|recommended|suggested|cleanest|next|short|quick|final|sendable|customer[-\s]?facing|customer\s+ready)\s+)*(?:sms|text|body|reply|draft|answer|message)(?:\s+(?:sms|text|body|reply|draft|answer|message))*?(?:\s+(?:as|for|to\s+send\s+to|to)\s+[^:\n]{1,140})?\s*:\s*/i
    CRM_DEAL_LEAK_PATTERNS = [
      /\bwe(?:'|’)?ve got\b.{0,120}\b(?:active|open|recent)\s+(?:deals?|orders?)\b/i,
      /\b(?:active|open|recent)\s+(?:deals?|orders?)\b.{0,120}\b(?:like|such as|including)\b/i,
      /\b(?:jadon feld|jay dietz)\b/i
    ].freeze
    OPT_OUT_NOTICE = "Reply STOP to opt out.".freeze
    OPT_OUT_NOTICE_PATTERN = /\breply\s+stop\s+(?:to\s+)?(?:opt\s*out|unsubscribe|cancel|end)\b/i
    TRAILING_OPT_OUT_NOTICE_PATTERN = /\s*(?:and\s+)?reply\s+stop\s+(?:to\s+)?(?:opt\s*out|unsubscribe|cancel|end)\.?\s*\z/i
    SENTENCE_ABBREVIATION_PATTERN = /\b(?:a\.m|p\.m|e\.g|i\.e|mr|mrs|ms|dr|st|vs|etc)\z/i
    MODEL_THINKING_BLOCK_PATTERN = /<think\b[^>]*>.*?<\/think>/im
    MODEL_THINKING_TAG_PATTERN = %r{</?think\b[^>]*>}i
    CUSTOMER_LANGUAGE_REPLACEMENTS = [
      [/\b(?:For the signs,\s*)?(?:are\s+these|are\s+the\s+signs|are\s+they)\s+for\s+job\s*sites?\s*,\s*directions?\s*,\s*(?:an?\s+event\s*,\s*)?or\s+a\s+promo(?:tion)?\?/i, "What quantity should I price for the signs?"],
      [/\bThe\s+24x18\s+yard\s+sign\s+options\s+I\s+see\s+are\b/i, "For 18x24 yard signs, the options are"],
      [/\bThe\s+yard\s+sign\s+ladder\s+I\s+see\s+(?:is|has)\b/i, "For 18x24 yard signs, the options are"],
      [/\bThe\s+active\s+special\s+I\s+see\s+is\s+postcard-only:/i, "The active postcard-only special is:"],
      [/\bWant me to connect someone\?/i, "Want me to have a marketing consultant check this with you?"],
      [/\bWant me to get someone connected with you\?/i, "Want me to have a marketing consultant check this with you?"],
      [/\bWant me to get you connected with (?:one of )?(?:our )?marketing consultants?\?/i, "Want me to have a marketing consultant check this with you?"],
      [/\bWould it be helpful for me to get you connected with (?:one of )?(?:our )?marketing consultants? to go over the details\?/i, "Would it be helpful for me to have one of our marketing consultants reach out to go over the details?"],
      [/\bthe\s+options\s+I\s+see\s+are\b/i, "the options are"],
      [/\bthe\s+pricing\s+I\s+see\s+is\b/i, "the pricing is"]
    ].freeze
    YARD_SIGN_TERM_PATTERN = /\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|yard\s+signs?\s+package)\b/i.freeze

    PROMPT_LEAK_PATTERNS = [
      /\A(?:true|false|null)\s*[\]}:,]/i,
      /\A(?:please\s+)?(?:apologize|mention|reconnect|follow|convert|write|draft|ask)\b/i,
      /\A(?:use when|fit\s*:|usage_rule\s*:|recommended_next_question\s*:)/i,
      /\A[-*]\s*(?:the\s+)?(?:route|route_code|shopify_link|product_key|known|missing|latest|prior|context|answer|fit|usage_rule|steps?)\b/i,
      /\b(?:operator instruction|follow the operator|ask at most one useful next question|reconnect to the current thread|mention my boss|mention the boss|in a casual human way)\b/i,
      /\b(?:never return|do not return|don't return)\b.*\b(?:current draft|recent unsent drafts?|minor word swaps|verbatim)\b/i,
      /\b(?:current draft|recent unsent drafts?)\b.*\b(?:verbatim|minor word swaps|materially different|avoid)\b/i,
      /\b(?:manual rewrite id|this click must produce|materially different next sms|recent unsent drafts to avoid)\b/i,
      /\A(?:however,?\s+)?(?:let me|looking at|we are drafting|we are in the middle of|i need to|i should|analysis|reasoning|based on the context|from the context|from the conversation|the context shows|the conversation|the customer'?s latest|the previous sms|the latest inbound|the latest outbound|latest inbound|latest outbound|the latest inbound message|context json|conversation_state)\b/i,
      /\A(?:however,?\s+)?(?:important|note that|the opening offer|the problem is|we are now|we are in\b|since there is no|we must|we must not|we have to answer|steps?|the instructions say)\b/i,
      /\A(?:to the question about|this answers|the next step is to (?:provide|ask|collect|route)|they (?:want|asked|said|need|gave)|they'?ve (?:given|asked|said)|we'?ve (?:learned|got|received)|we have (?:learned|got|received))\b/i,
      /\b(?:let me analyze|looking at the context|context from the json|current situation|craft the next sms|latest inbound event|latest sms event|latest outbound event|latest customer message|latest outbound sms|unanswered question|household count question|from the context|from the conversation|operator_prompt|context json|customer-facing sms)\b/i,
      /\b(?:we are in (?:the\s+)?["']?[a-z_]+["']?\s+lane|the instructions say|the prompt says|according to (?:the\s+)?(?:product\s+)?decision guide|the product_decision_guide|the product decision guide|the decision guide|the guide says|customer-facing response|recommended next question|use when they only need|use when the customer|the customer has already been engaged|history of conversation|we are to answer|we are to write|we are writing|we have to answer|we need to answer|we know the customer|we know they|we do not have|we don't have|we must ask|we must not|we must follow up|we need to follow up|there is no inbound sms|the customer hasn't replied|customer has not replied|the route code is|the shopify link is)\b/i,
      /\b(?:return only the sms|operator prompt|internal note|system prompt|developer prompt|prompt job|guardrail instruction)\b/i
    ].freeze

    module_function

    def sanitize_customer_body(value, include_opt_out_notice: false)
      text = strip_model_thinking(value)
        .sub(/\A```(?:json|text)?\s*/i, "")
        .sub(/\s*```\z/, "")
        .gsub(/\r\n?/, "\n")
        .gsub(ANSWER_WRAPPER_PREFIX_PATTERN, "")
        .strip
      text = strip_outer_quotes(text)
      text = extract_customer_candidate(text).presence || text.squish
      return if text.blank?
      return if internal_leak?(text)

      body = customerize_sms_language(with_current_special(text.squish))
      include_opt_out_notice ? ensure_opt_out_notice(body) : without_opt_out_notice(body)
    end

    def customer_facing?(value)
      sanitize_customer_body(value).present?
    end

    def unsafe_outbound?(value)
      sanitize_customer_body(value).blank?
    end

    def internal_leak?(value)
      leak_reason(value).present?
    end

    def leak_reason(value)
      text = value.to_s.squish
      return if text.blank?

      downcase = text.downcase
      return "route_code_only" if text.match?(ROUTE_CODE_PATTERN)
      return "internal_route_token" if text.match?(INTERNAL_ROUTE_TOKEN_PATTERN)
      return "disallowed_shopify_link" if text.match?(DISALLOWED_SHOPIFY_LINK_PATTERN)
      return "answer_wrapper" if text.match?(ANSWER_WRAPPER_PREFIX_PATTERN)
      return "internal_context_key" if text.match?(INTERNAL_KEY_PATTERN)
      return "internal_context_prefix" if text.match?(INTERNAL_KEY_PREFIX_PATTERN)
      return "jsonish_or_metadata" if text.match?(JSONISH_PREFIX_PATTERN)
      return "crm_deal_leak" if CRM_DEAL_LEAK_PATTERNS.any? { |pattern| text.match?(pattern) }
      return "prompt_instruction" if PROMPT_LEAK_PATTERNS.any? { |pattern| text.match?(pattern) }
      return "worker_invalid_answer" if worker_invalid_answer?(downcase)

      nil
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsBodySafety] safety check failed #{error.class}: #{error.message}") if defined?(Rails)
      "safety_check_failed"
    end

    def worker_invalid_answer?(text)
      defined?(Autos::WorkerQueue) && Autos::WorkerQueue.send(:invalid_comms_sms_answer?, text)
    rescue StandardError
      false
    end

    def extract_customer_candidate(text)
      text = strip_model_thinking(text).strip
      return if text.blank?

      candidates = []
      candidates << text
      [
        /(?:\A|\n)\s*(?:FINAL\s+ANSWER|VISIBLE\s+ANSWER|CUSTOMER[-\s]?FACING\s+ANSWER|SENDABLE\s+(?:SMS|TEXT)|SMS|TEXT|REPLY|ANSWER|A)\s*:\s*/i
      ].each do |pattern|
        text.enum_for(:scan, pattern).each do
          candidates << text[Regexp.last_match.end(0)..].to_s.strip
        end
      end
      text.scan(/["“]([^"”]{18,900})["”]/m) { |match| candidates << match.first }
      candidates.concat(text.lines.map(&:strip).reject(&:blank?).reverse.take(8))

      candidates.each do |candidate|
        body = candidate.to_s
          .then { |candidate_text| strip_model_thinking(candidate_text) }
          .sub(/\A```(?:json|text)?\s*/i, "")
          .sub(/\s*```\z/, "")
          .sub(/\A[-*\d.)\s]+/, "")
          .sub(ANSWER_WRAPPER_PREFIX_PATTERN, "")
          .squish
        body = strip_outer_quotes(body)
        next if body.blank?
        next if internal_leak?(body)

        return body
      end

      nil
    end

    def with_current_special(value)
      return value unless defined?(Comms::CurrentSpecials)

      Comms::CurrentSpecials.ensure_sms_mention(value)
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsBodySafety] current special append failed #{error.class}: #{error.message}") if defined?(Rails)
      value
    end

    def ensure_opt_out_notice(value)
      body = value.to_s.squish
      return body if body.blank?
      return body if opt_out_notice_present?(body)

      [body, OPT_OUT_NOTICE].join(" ")
    end

    def prepare_outbound_body(value, metadata: nil, include_opt_out_notice: nil)
      body = customerize_sms_language(strip_model_thinking(value).squish)
      return body if body.blank?

      if include_opt_out_notice.nil?
        metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
        return body if metadata.blank?

        include_opt_out_notice = metadata.any? && initial_opt_out_notice_needed?(metadata)
      end

      include_opt_out_notice ? ensure_opt_out_notice(body) : without_opt_out_notice(body)
    end

    def strip_model_thinking(value)
      value.to_s
        .gsub(MODEL_THINKING_BLOCK_PATTERN, " ")
        .gsub(MODEL_THINKING_TAG_PATTERN, " ")
    end

    def initial_opt_out_notice_needed?(metadata)
      !prior_outbound_sms?(metadata)
    end

    def prior_outbound_sms?(metadata)
      metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
      Array(metadata["sms_thread"]).any? do |event|
        event = event.to_h
        next false unless event["direction"].to_s == "outbound"
        next false unless event["body"].to_s.squish.present?

        !event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped])
      end
    end

    def without_opt_out_notice(value)
      body = value.to_s.squish
      return body if body.blank?

      loop do
        stripped = body.sub(TRAILING_OPT_OUT_NOTICE_PATTERN, "").squish
        break body if stripped == body

        body = stripped
      end
    end

    def opt_out_notice_present?(value)
      value.to_s.match?(OPT_OUT_NOTICE_PATTERN)
    end

    def customerize_sms_language(value)
      normalized = CUSTOMER_LANGUAGE_REPLACEMENTS.reduce(value.to_s) do |text, (pattern, replacement)|
        text.gsub(pattern, replacement)
      end.squish
      polish_sms_grammar(normalize_yard_sign_package_price_quantities(normalized))
    end

    def polish_sms_grammar(value)
      text = value.to_s.squish
      return text if text.blank?

      text = text.sub(/\A([[:space:]"'“‘(\[]*)([a-z])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}" }
      text = text.gsub(/\bi(?=(?:['’](?:m|ll|d|ve|re))?\b)/, "I")
      text.gsub(/([.!?]\s+)([a-z])/) do
        prefix = Regexp.last_match(1)
        letter = Regexp.last_match(2)
        prior = Regexp.last_match.pre_match
        prior.match?(SENTENCE_ABBREVIATION_PATTERN) ? "#{prefix}#{letter}" : "#{prefix}#{letter.upcase}"
      end
    end

    def normalize_yard_sign_package_price_quantities(value)
      text = value.to_s.squish
      return text if text.blank?

      configured_yard_sign_package_prices.reduce(text) do |body, (quantity, price)|
        price_pattern = /\$\s*#{Regexp.escape(price.delete_prefix("$"))}\b/i
        body
          .gsub(/(?:\bfor\s+)?(?:\b18x24\s+)?(?:\b[\d,]{1,6}\s+)?#{YARD_SIGN_TERM_PATTERN.source}\s+(?:are|is|costs?|run|runs|would\s+be|come\s+to|comes\s+to)\s*#{price_pattern}/i, "#{quantity} yard signs are #{price}")
          .gsub(/#{YARD_SIGN_TERM_PATTERN.source}\s+(?:start|starts|starting)\s+(?:at|around)?\s*#{price_pattern}/i, "Yard signs start at #{quantity} for #{price}")
      end.squish
    end

    def configured_yard_sign_package_prices
      return {} unless defined?(Comms::ProductCatalog)

      Comms::ProductCatalog.price_table("LAWN_SIGNS").transform_values do |values|
        values["price"].presence || values.values.find(&:present?)
      end.compact_blank
    end

    def strip_outer_quotes(value)
      text = value.to_s.strip
      pairs = { '"' => '"', "'" => "'", "“" => "”", "‘" => "’" }
      closing = pairs[text[0]]
      return text if closing.blank?
      return text unless text.end_with?(closing)

      text[1...-1].to_s.strip
    end
  end
end
