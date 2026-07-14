require "json"
require "net/http"
require "uri"
require "digest"
require "set"

module DealReports
  class CommsDraftWriter
    MAX_SMS_CHARS = 480
    MIN_SELF_CHECKOUT_BUDGET = 99
    PRO_PACK_BUDGET_FLOOR = 1_000
    LARGE_CAMPAIGN_BUDGET = 5_000
    STARTER_PACK_SIGN_LIMIT = 20
    STARTER_PACK_REACH_LIMIT = 500
    LOW_BUDGET_CLARIFICATION = "Did you mean a budget in the thousands, or are you looking for the lowest entry point?".freeze
    PRODUCT_OFFERINGS_PATH = Rails.root.join("config", "autos", "product_offerings.md")
    PRODUCT_CATALOG_PATH = Rails.root.join("config", "autos", "product_catalog.yml")
    SMS_EXAMPLES_PATH = Rails.root.join("config", "autos", "sms_examples.md")
    SMS_SKILLS_PATH = Rails.root.join("config", "autos", "sms_skills.md")
    SHOPIFY_DETAIL_CACHE_TTL = 30.minutes
    SHOPIFY_CATALOG_CACHE_TTL = 30.minutes
    SHOPIFY_CATALOG_PRODUCTS_URL = "https://shop.example.invalid/products.json?limit=250".freeze
    STALE_SHOPIFY_PRODUCT_HANDLES = %w[
      every-door-direct-mail-sample_owner
      neighborhood-blitz-sample_owner
      pro-pack-bundle-deal-100-yard-signs-1000-business-cards-1000-door-hangers-sample_owner
      starter-pack-bundle-deal-20-yard-signs-500-business-cards-500-door-hangers-sample_owner
    ].freeze
    FINE_TRAINING_DOCUMENT_LIMIT = 36
    FINE_TRAINING_CHUNK_LIMIT = 32
    ADAPTIVE_TRAINING_CHUNK_LIMIT = 2
    FINE_TRAINING_COMPACT_DOCUMENT_LIMIT = 3
    FINE_TRAINING_COMPACT_CHUNK_LIMIT = 5
    FINE_TRAINING_INVENTORY_LIMIT = 16
    FINE_TRAINING_DOCUMENT_EXCERPT_CHARS = 320
    FINE_TRAINING_CHUNK_EXCERPT_CHARS = 320
    CALL_SCENARIO_COMPACT_LIMIT = 2
    CALL_SCENARIO_CONTEXT_CHARS = 500
    GUARDRAIL_RETRY_LIMIT = 2
    SMS_QUALITY_REJECTION_REASONS = %w[
      asks_for_known_fit_field
      broad_direct_mail_checkout_before_ready
      direct_mail_strategy_reply_missing_handoff
      marketing_channel_recommendation_missing
      missing_requested_product_context
      misses_open_customer_messages
      price_only_question_with_checkout_url
      print_products_answer_missing
      signs_only_reply_against_mail_or_both_intent
      stacked_yard_sign_price_process_missing
      turnaround_answer_missing
      unsolicited_yard_sign_quantity_checkout_url
      consultant_voice_policy_language
      consultant_voice_corporate_language
      consultant_voice_meta_capability
      consultant_voice_multiple_questions
      consultant_voice_prompt_preface
      consultant_voice_generic_closer
      consultant_voice_canned_opener
      consultant_voice_em_dash
    ].freeze
    SMS_SOFT_GUARDRAIL_OVERRIDE_REASONS = %w[
      asks_for_known_fit_field
      broad_direct_mail_checkout_before_ready
      price_only_question_with_checkout_url
      unsolicited_yard_sign_quantity_checkout_url
    ].freeze
    SMS_PRODUCT_OFFERINGS_CHARS = 2_400
    SMS_EXAMPLES_CHARS = 7_500
    SMS_EXAMPLES_SECTION_LIMIT = 6
    SMS_SKILLS_CHARS = 10_000
    SMS_SKILLS_SECTION_LIMIT = 6
    SMS_THREAD_CONTEXT_LIMIT = 12
    SMS_RECENT_THREAD_CONTEXT_LIMIT = 8
    SMS_RECENT_OUTBOUND_LIMIT = 5
    SMS_RECENT_DRAFT_LIMIT = 3
    SHOPIFY_PRODUCT_DETAIL_LIMIT = 5
    SMS_SHOPIFY_PRODUCT_DETAIL_LIMIT = 3
    SHOPIFY_PRICE_ROW_LIMIT = 14
    SMS_SHOPIFY_PRICE_ROW_LIMIT = 8
    SHOPIFY_VARIANT_LIMIT = 7
    SMS_SHOPIFY_VARIANT_LIMIT = 3
    PRICING_INTENT_PATTERN = /\b(?:how\s+(?:much|mush|mauch|mutch|muxh)|howmuch|cost|costs|price|prices|pricing|total|rate|rates|charge|charges|quote|quotes)\b/i
    OPENING_OFFER = "Hi, I'm Thumper from WIZWIKI Marketing. You've got a few good ways to get local attention. Are you looking at postcards, yard signs, or both?".freeze
    YARD_SIGN_OPENING_OFFER = "Hi, this is Thumper with WIZWIKI Marketing. Saw you were looking at yard signs. Design, stakes, and shipping are included. Were you thinking closer to 20, 50, or 100?".freeze
    CUSTOMER_LANGUAGE_REPLACEMENTS = [
      [/\bThe\s+24x18\s+yard\s+sign\s+options\s+I\s+see\s+are\b/i, "For 18x24 yard signs, the options are"],
      [/\bThe\s+yard\s+sign\s+ladder\s+I\s+see\s+(?:is|has)\b/i, "For 18x24 yard signs, the options are"],
      [/\bThe\s+active\s+special\s+I\s+see\s+is\s+postcard-only:/i, "The active postcard-only special is:"],
      [/\bthe\s+options\s+I\s+see\s+are\b/i, "the options are"],
      [/\bthe\s+pricing\s+I\s+see\s+is\b/i, "the pricing is"]
    ].freeze
    GENERIC_IDENTITY_VALUES = [
      "wizwiki comms",
      "sample comms",
      "manual comms",
      "choose in lab",
      "contact",
      "customer",
      "them",
      "they",
      "those",
      "that",
      "it"
    ].freeze
    COMPANY_PROFILE = {
      "assistant_name" => "Thumper",
      "brand" => "WIZWIKI Marketing",
      "core_offer" => "WIZWIKI Marketing helps local businesses run direct mail and neighborhood marketing campaigns.",
      "offer_details" => {
        "Pro Pack" => "a larger bundle with 100 yard signs, 1,000 business cards, and 1,000 door hangers",
        "Starter Pack" => "a smaller starter bundle with 20 yard signs, 500 business cards, and 500 door hangers",
        "Business Cards" => "standalone 16pt premium matte business cards with quantity options",
        "Door Hangers" => "standalone 4.25x11 door hangers with quantity and finish options",
        "Flyers" => "standalone flyer and handout printing with size and quantity options",
        "EDDM" => "route-based postcard mailings that reach local homes without needing a purchased list",
        "neighborhood blitz" => "a coordinated push using postcards, door hangers, yard signs, and follow-up",
        "yard signs" => "custom yard signs, jobsite signs, directional signs, stakes, and campaign artwork"
      },
      "offer_menu" => [
        "Pro Pack",
        "Starter Pack",
        "Business Cards",
        "Door Hangers",
        "Flyers",
        "Yard Signs",
        "EDDM",
        "neighborhood blitz"
      ],
      "voice_rules" => [
        "Use the WIZWIKI Copy Playbook and Sample Operator Fathom analysis as paramount voice memory.",
        "Sound like a practical, direct, candid owner-operator who knows the customer.",
        "Be warm, thoughtful, and thorough without turning wordy; help instead of instructing.",
        "Answer the customer's direct question first, then ask at most one low-friction next question.",
        "Do not narrate capabilities when the answer should simply compare, quote, or explain the path.",
        "Use real numbers when available. Specifics beat adjectives.",
        "No corporate words, no habitual Yep, no premature goodbye, and no fake-energy punctuation.",
        "Answer basic questions about WIZWIKI from supplied company facts.",
        "Do not oversell, invent approvals, promise specials, or approve discounts.",
        "If a detail is not supplied, ask a short follow-up instead of inventing it."
      ]
    }.freeze
    DESIGN_PROCESS_PROFILE = {
      "normal_questions_are_bot_answerable" => true,
      "order_path" => [
        "The customer places the order first.",
        "After checkout, the design team sends an intake form to the email used at checkout.",
        "The customer submits images, logo, wording, colors, layout notes, and any existing artwork through that form.",
        "A PDF or vector logo/design file is best when available, but the customer can send what they have.",
        "The design team creates or reviews the proof.",
        "The customer reviews the proof and can request changes if needed.",
        "Nothing goes to print until the customer approves the proof.",
        "Payment starts the order and gets the customer into the design queue; it does not mean WIZWIKI prints blindly without approval."
      ],
      "confidence_questions" => [
        "Where do I upload my logo?",
        "How does the design work?",
        "Do I need a finished design?",
        "What if I do not like the proof?",
        "Can I send you my logo?",
        "Why is it asking me to pay first?",
        "When do I get the proof?",
        "Can I see the design before it prints?"
      ],
      "handoff_only_when" => [
        "The customer specifically asks to speak with someone.",
        "The customer asks for an assistant, account manager, rep, call, or human follow-up.",
        "The customer says checkout, payment, cart, order, or a product link is not working.",
        "The customer is still stuck after the bot answers the checkout/order problem.",
        "The customer is frustrated and asks for support from a person."
      ],
      "guardrails" => [
        "Do not promise a proof before payment.",
        "Do not imply a human will do design work before an order is placed.",
        "Do not promise a specific delivery date.",
        "Do not invent pricing, discounts, or product options.",
        "Do not collect payment information in chat.",
        "Do not route normal process questions to a human too early.",
        "Do not offer a human handoff as the default ending to every design-process explanation."
      ],
      "recovery_pattern" => [
        "Acknowledge the confusion briefly.",
        "Re-explain the relevant process step.",
        "Reassure them that proof approval happens before print.",
        "Move them back to the next logical step."
      ]
    }.freeze
    ROUTE_NEXT_QUESTIONS = {
      "PRO_PACK" => [
        "Do you want signs plus cards and door hangers for a bigger local push, or mostly postcards?",
        "Roughly how many homes or doors are you trying to reach?",
        "Do you already have artwork, or should WIZWIKI help shape the campaign?"
      ],
      "STARTER_PACK" => [
        "Do you want signs included, or mostly postcards/direct mail?",
        "About how many homes do you want to reach?",
        "Do you already have artwork, or should WIZWIKI help shape the campaign?"
      ],
      "BUSINESS_CARDS" => [
        "About how many business cards are you thinking about?",
        "Is this a reorder or a new business card design?",
        "Do you want standard premium matte cards, or are you looking for a special finish?"
      ],
      "DOOR_HANGERS" => [
        "About how many door hangers are you thinking about?",
        "Do you want gloss or uncoated door hangers?",
        "Is this for a door-to-door push, leave-behinds, or a broader campaign?"
      ],
      "FLYERS" => [
        "What flyer size are you thinking about?",
        "About how many flyers do you need?",
        "Is this a handout, mailer insert, or event piece?"
      ],
      "EDDM" => [
        "About how many homes do you want to reach with postcards?",
        "Do you want postcards only, or postcards plus signs for more neighborhood visibility?",
        "Do you already have artwork and an offer for the postcard?"
      ],
      "NEIGHBORHOOD_BLITZ" => [
        "Do you want postcards plus signs, door hangers, or all three?",
        "Roughly how many homes do you want to reach?",
        "Is this for a launch, seasonal push, or getting more booked jobs?"
      ],
      "LAWN_SIGNS" => [
        "How many signs are you thinking about?",
        "Do you want signs only, or a bundle with postcards/cards/door hangers too?",
        "Do you already have artwork, or should WIZWIKI help with the layout?"
      ]
    }.freeze
    ROUTE_LABELS = {
      "PRO_PACK" => "Pro Pack",
      "STARTER_PACK" => "Starter Pack",
      "BUSINESS_CARDS" => "Business Cards",
      "DOOR_HANGERS" => "Door Hangers",
      "FLYERS" => "Flyers",
      "EDDM" => "EDDM",
      "NEIGHBORHOOD_BLITZ" => "Neighborhood Blitz",
      "LAWN_SIGNS" => "Lawn Signs"
    }.freeze
SIGN_INTEREST_PATTERN = /\b(?:just\s+)?(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signage|stakes?|signs?)\b/i.freeze
POSTCARD_INTEREST_PATTERN = /\b(?:eddm|every door|post\s*cards?|postcards?|mailers?|direct mail|mailing|mailboxes?)\b/i.freeze
POSTCARD_SPECIAL_QUANTITY_PATTERN = /\b(?:1,?000|1000|1k|2,?500|2500|2\.5k|5,?000|5000|5k|10,?000|10000|10k|25,?000|25000|25k)\b/i.freeze
POSTCARD_REJECTION_PATTERN = /
  \b(?:do\s+not|don'?t|dont|no|not|without|instead\sof|rather\sthan)\b.{0,60}\b(?:eddm|every door|post\s*cards?|postcards?|mailers?|direct mail|mailing|mailboxes?)\b |
  \b(?:eddm|every door|post\s*cards?|postcards?|mailers?|direct mail|mailing|mailboxes?)\b.{0,60}\b(?:do\s+not|don'?t|dont|no|not|isn'?t|is\snot|aren'?t|are\snot|without)\b
/ix.freeze
DISCOVERY_FIELD_ORDER = %w[
  product_interest
  contact_name
  company_name
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

    def self.call(stage:, user:, operator_prompt: nil, wait_seconds: nil, challenger_model: nil, writer_model: nil, copilot: false)
      new(stage: stage, user: user, operator_prompt: operator_prompt, wait_seconds: wait_seconds, challenger_model: challenger_model, writer_model: writer_model, copilot: copilot).call
    end

    def self.queue_background_and_fallback(stage:, user:, operator_prompt: nil, challenger_model: nil, writer_model: nil, copilot: false)
      new(stage: stage, user: user, operator_prompt: operator_prompt, challenger_model: challenger_model, writer_model: writer_model, copilot: copilot).queue_background_and_fallback
    end

    def self.queue_background(stage:, user:, operator_prompt: nil, challenger_model: nil, writer_model: nil, copilot: false)
      new(stage: stage, user: user, operator_prompt: operator_prompt, challenger_model: challenger_model, writer_model: writer_model, copilot: copilot).queue_background
    end

    def self.apply_worker_answer!(question)
      metadata = question.metadata.to_h
      return false unless metadata["surface"].to_s == "comms_sms_draft"

      stage = CrmRecordArtifact.find_by(id: metadata["comms_stage_id"])
      return false unless stage.present?
      return false if recursive_dojo_canceled_stage?(stage)

      new(
        stage: stage,
        user: question.user,
        operator_prompt: metadata["operator_prompt"],
        writer_model: metadata["writer_model"],
        copilot: metadata["copilot_only"],
        guardrail_retry_instruction: metadata["guardrail_retry_instruction"]
      ).apply_worker_answer!(question)
    end

    def self.apply_worker_rejection!(question, reason: nil)
      metadata = question.metadata.to_h
      return false unless metadata["surface"].to_s == "comms_sms_draft"

      stage = CrmRecordArtifact.find_by(id: metadata["comms_stage_id"])
      return false unless stage.present?
      return false if recursive_dojo_canceled_stage?(stage)

      new(
        stage: stage,
        user: question.user,
        operator_prompt: metadata["operator_prompt"],
        writer_model: metadata["writer_model"],
        copilot: metadata["copilot_only"],
        guardrail_retry_instruction: metadata["guardrail_retry_instruction"]
      ).clear_worker_rejection!(
        question,
        reason.presence || metadata.dig("local_worker", "reject_reason").presence || "rejected_worker_answer"
      )
    end

    def self.recursive_dojo_canceled_stage?(stage)
      stage.metadata.to_h["recursive_dojo_status"].to_s.in?(%w[canceled cancelled])
    end

    def self.perform_cloud_worker_answer!(question)
      metadata = question.metadata.to_h
      return false unless metadata["surface"].to_s == "comms_sms_draft"

      stage = CrmRecordArtifact.find_by(id: metadata["comms_stage_id"])
      return false unless stage.present?

      new(
        stage: stage,
        user: question.user || stage.user,
        operator_prompt: metadata["operator_prompt"],
        writer_model: metadata["writer_model"],
        copilot: metadata["copilot_only"],
        guardrail_retry_instruction: metadata["guardrail_retry_instruction"]
      ).perform_cloud_worker_answer!(question)
    end

    def initialize(stage:, user:, operator_prompt: nil, wait_seconds: nil, challenger_model: nil, writer_model: nil, copilot: false, guardrail_retry_instruction: nil)
      @stage = stage
      @user = user
      @operator_prompt = operator_prompt.to_s.strip
      @wait_seconds = wait_seconds
      @metadata = refreshed_lane_monitor_metadata(stage.metadata.to_h)
      @rag_profile = if defined?(Comms::RagProfile)
        Comms::RagProfile.for_stage(stage)
      else
        { "key" => "wizwiki", "label" => "WIZWIKI CRM", "scope" => "wizwiki", "kind" => "sales" }
      end
      @writer_model = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.sms_writer_model_from_metadata(@metadata))
      @copilot = ActiveModel::Type::Boolean.new.cast(copilot)
      @guardrail_retry_instruction = guardrail_retry_instruction.to_s.squish.presence || @metadata["sms_guardrail_retry_instruction"].to_s.squish.presence
    end

    def refreshed_lane_monitor_metadata(metadata)
      return metadata unless defined?(DealReports::CommsProcessingCode)

      latest_inbound = Array(metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
        event["channel"].to_s == "sms" &&
          event["direction"].to_s == "inbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled])
      end
      return metadata if latest_inbound.blank?

      monitor = metadata.to_h["sms_lane_monitor"].to_h
      latest_body = latest_inbound["body"].to_s.squish
      return metadata if monitor["latest_body"].to_s.squish == latest_body && monitor["route_code"].present?

      processing = DealReports::CommsProcessingCode.call(stage: @stage, metadata: metadata, latest_body: latest_body)
      metadata.merge(processing)
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] lane monitor refresh failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      metadata
    end

    def call
      draft = cloud_writer? ? cloud_draft_with_repair : alice_draft
      if support_rag_profile?
        return draft if support_draft_acceptable?(draft)
        return draft if draft["pending"]

        return support_fallback_draft(draft["error"])
      end
      return draft if acceptable_draft?(draft)
      return draft if draft["pending"]
      if repeated_rejection?(draft) || repeated_draft?(draft["body"])
        guardrail = repeated_answer_guardrail_draft(draft["error"].presence || draft["reject_reason"])
        return guardrail if acceptable_draft?(guardrail)
      end

      duplicate_error = repeated_draft?(draft["body"]) ? "Alice repeated the current or recent unsent SMS draft." : draft["error"]
      unless cloud_writer?
        draft = ollama_draft
        return draft if acceptable_draft?(draft)
      end

      fallback_draft(draft["error"].presence || duplicate_error)
    end

    def reset_conversation_opening_body
      reset_conversation_opening_fallback
    end

    def queue_background_and_fallback
      if (draft = deterministic_fast_path_draft).present?
        return draft
      end

      question = enqueue_background_draft_question
      draft = fallback_draft("#{background_writer_label} comms draft queued in background.")
      queued_guardrail = draft["draft_source"].to_s == "thumper_guardrail"
      draft.merge(
        "provider" => queued_guardrail ? "local/guardrail+#{background_writer_provider}_queued" : "local/fallback+#{background_writer_provider}_queued",
        "reason" => queued_guardrail ? "Route-ready deterministic guardrail saved while #{background_writer_label} drafts in the background." : "Quick fallback saved while #{background_writer_label} drafts in the background.",
        "autos_question_id" => question&.id,
        "background_queued" => question.present?
      ).compact_blank
    rescue StandardError => error
      fallback_draft("#{error.class}: #{error.message}")
    end

    def queue_background
      if (draft = deterministic_fast_path_draft).present?
        return draft
      end

      question = enqueue_background_draft_question
      pending_draft_for(question)
    rescue StandardError => error
      fallback_draft("#{error.class}: #{error.message}")
    end

    def deterministic_fast_path_draft
      inbound = latest_inbound_sms.to_s.squish
      return if inbound.blank? || (@operator_prompt.present? && !webhook_auto_prompt?)
      return if support_rag_profile?

      body = if handoff_contact_fast_path_turn?
        handoff_contact_collection_reply
      elsif (known_reply = deterministic_known_sms_answer(inbound)).present?
        known_reply
      elsif messy_print_consultant_question?(inbound)
        messy_print_consultant_reply
      elsif direct_mail_strategy_handoff_question?(inbound)
        direct_mail_strategy_handoff_reply
      elsif buyer_close_signal?(inbound) && accepted_recent_recommendation_route.present?
        direct_checkout_link_reply(inbound)
      elsif multi_product_link_request?(inbound)
        multi_product_link_reply(inbound)
      elsif direct_checkout_link_request?(inbound) && checkout_request_route(inbound).present?
        direct_checkout_link_reply(inbound)
      end
      body = safe_persisted_sms_body(body)
      return if body.blank?
      return unless fallback_sms_sendable?(body) || acceptable_sms_body?(body, include_drafts: false)

      {
        "body" => body,
        "provider" => "local/fast_path",
        "model" => "deterministic_sms_fast_path",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "fast_path",
        "draft_source" => "thumper_guardrail",
        "reason" => "Thumper used a deterministic SMS fast path for a simple product-link or custom print handoff reply.",
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "background_queued" => false
      }.merge(
        am_support_required_metadata(fast_path_requires_am_support?(inbound, body))
      ).compact_blank
    end

    def deterministic_known_sms_answer(inbound)
      body = inbound.to_s.squish
      return if body.blank?

      if explicit_support_handoff_request?(body) && (recent_handoff_offer_accepted? || recent_sms_context.match?(/\bmarketing consultant\b/i))
        return handoff_contact_collection_reply
      end

      if language_preference_confirmation_question?(body)
        return language_preference_confirmation_reply
      end

      special_quantity = postcard_special_quantity_from_text(body)
      if current_postcard_special_active? &&
          special_quantity.present? &&
          body.match?(/\b(?:post\s*cards?|postcards?)\b/i) &&
          body.match?(/\b(?:total|cost|price|pricing|how much)\b/i)
        return "For #{format_quantity_count(special_quantity)} postcards, the postcard-only 4th of July special is #{postcard_special_price_for_quantity(special_quantity)}. Want the checkout link for that block?"
      end

      if (stacked_reply = stacked_open_messages_reply).present?
        return stacked_reply
      end

      if general_bundle_question?(body)
        return general_bundle_reply
      end

      if postcard_special_quantity_only_followup?(body)
        return postcard_large_quantity_followup_reply(body)
      end

      if postcard_special_below_minimum_followup?(body)
        return postcard_special_below_minimum_reply
      end

      if current_specials_question?(body) || postcard_special_all_tiers_request?(body) || postcard_special_quantity_followup?(body)
        return current_specials_reply(body)
      end

      if standalone_print_product_quantity_followup?(body)
        return standalone_print_product_quantity_reply(body)
      end

      if print_products_question?(body)
        return messy_print_consultant_reply if messy_print_consultant_question?(body)

        return print_products_reply(body)
      end

      if turnaround_question?(body) || rush_checkout_boundary_question?(body)
        return turnaround_reply(body)
      end

      if yard_sign_included_items_question?(body) || shipping_included_question?(body)
        return yard_sign_included_items_reply(body)
      end

      if pricing_question?(body)
        reply = pricing_reply(body)
        return reply if reply.present?
      end

      return initial_yard_sign_interest_reply if initial_yard_sign_interest_question?(body)

      nil
    end

    def language_preference_confirmation_question?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?

      code = @metadata.to_h["sms_language_preferred_code"].to_s.downcase
      return false if code.blank? || code == "en"

      label = @metadata.to_h["sms_language_preferred_label"].to_s.downcase.presence ||
        Comms::SmsLanguageSupport.language_label(code).to_s.downcase
      aliases = Comms::SmsLanguageSupport.language_alias_terms_for_code(code)
      terms = ([label, code] + aliases).compact_blank.uniq
      language_pattern = terms.map { |term| Regexp.escape(term) }.join("|")
      return false if language_pattern.blank?

      body.match?(/\A(?:if\s+)?i\s+(?:prefer|want|would\s+like|need)\s+(?:to\s+)?(?:text|speak|talk|use|write|reply|respond|answer)?\s*(?:in\s+)?(?:#{language_pattern})[.!?]?\z/i) ||
        body.match?(/\A(?:please\s+)?(?:text|speak|talk|write|reply|respond|answer)\s+(?:to\s+me\s+)?(?:in\s+)?(?:#{language_pattern})[.!?]?\z/i) ||
        body.match?(/\A(?:#{language_pattern})(?:\s+please)?[.!?]?\z/i) ||
        body.match?(/\A(?:yes|yeah|yep|si|sí),?\s*(?:please\s+)?(?:#{language_pattern})[.!?]?\z/i)
    end

    def language_preference_confirmation_reply
      label = @metadata.to_h["sms_language_preferred_label"].to_s.presence ||
        Comms::SmsLanguageSupport.language_label(@metadata.to_h["sms_language_preferred_code"])
      "Yes, I can text you in #{label}. Are you thinking postcards, yard signs, or both?"
    end

    def initial_yard_sign_interest_question?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false unless sign_interest?(body)
      return false if pricing_intent?(body) || direct_checkout_link_request?(body)
      return false if requested_quantities(body).present?
      return false if body.match?(POSTCARD_INTEREST_PATTERN)

      body.match?(/\b(?:want|need|looking for|interested in|thinking about|considering|yard signs? please|signs? please)\b/)
    end

    def initial_yard_sign_interest_reply
      "We can help with yard signs. The lowest entry point is 10 for $99, and 100 are $399. Design, stakes, and shipping are included. What quantity are you thinking?"
    end

    def handoff_contact_fast_path_turn?
      handoff_contact_confirmation_due? ||
        handoff_contact_collection_response_turn? ||
        recent_handoff_offer_accepted?
    end

    def fast_path_requires_am_support?(inbound, body)
      return true if handoff_contact_fast_path_turn?
      return true if messy_print_consultant_question?(inbound)
      return true if direct_mail_strategy_handoff_question?(inbound)
      return true if human_handoff_answer?(body)

      am_support_required_for_latest_inbound?
    end

    def apply_worker_answer!(question)
      @stage.reload
      @metadata = @stage.metadata.to_h
      return false if @metadata["recursive_dojo_status"].to_s.in?(%w[canceled cancelled])
      return false unless question.status == "answered" && question.answer.present?
      return false unless @stage.status.in?(%w[staged aircall_ready aircall_sent aircall_failed])
      return reject_worker_answer!(question, "ignored_am_support_handoff", failed: false) if am_support_handoff?(@metadata) && !am_support_autopilot_enabled?(@metadata)
      return reject_worker_answer!(question, "ignored_after_auto_thumper_reset", failed: false) if auto_thumper_reset_after?(question.created_at)
      return reject_worker_answer!(question, "ignored_after_reset_opener", failed: false) if reset_opener_after?(question.created_at)
      return reject_worker_answer!(question, "ignored_stale_inbound_generation", failed: false) if worker_generation_superseded?(question)
      return reject_worker_answer!(question, "ignored_after_newer_inbound", failed: false) if inbound_received_after?(question.created_at)
      return reject_worker_answer!(question, "ignored_customer_acknowledgment", failed: false) if customer_acknowledgment_no_reply?(latest_inbound_sms)

      body = sanitize_sms(question.answer)
      requires_am_support = support_rag_profile? ? false : am_support_required_for_latest_inbound?
      body = account_manager_answer_needed_reply if requires_am_support && !am_support_reply_sendable?(body)
      body = safe_persisted_sms_body(body)
      unless support_rag_profile?
        body = latest_intent_guardrail_body(body).presence || body
        body = ensure_next_question_body(body)
      end
      guardrail_override = nil
      if (numeric_guardrail_body = numeric_route_guardrail_reply(body)).present?
        body = safe_persisted_sms_body(numeric_guardrail_body)
        guardrail_override = {
          "provider" => "local/thumper_guardrail",
          "model" => "numeric_context_guardrail",
          "writer_model" => writer_model,
          "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
          "sms_generation_pipeline" => "single_writer_guardrailed",
          "sms_quality_gate" => "rewritten",
          "draft_source" => "thumper_guardrail",
          "reason" => "Worker answer asked again for a count the customer just answered; numeric context guardrail rewrote the SMS."
        }
      end
      if body.blank?
        reject_worker_answer!(question, "rejected_empty_or_analysis")
        return false
      end
      return reject_worker_answer!(question, "ignored_after_outbound_sent", failed: false) if outbound_sent_after?(question.created_at)
      return reject_worker_answer!(question, "ignored_superseded", failed: false) if superseded_worker_answer?(question)
      quality_rejection_reason = support_rag_profile? ? support_sms_quality_rejection_reason(body) : sms_quality_rejection_reason(body)
      if quality_rejection_reason.present?
        if (stacked_body = stack_completion_guardrail_body(body)).present?
          body = stacked_body
          guardrail_override = {
            "provider" => "local/thumper_guardrail",
            "model" => "stack_open_messages",
            "writer_model" => writer_model,
            "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "rewritten",
            "draft_source" => "thumper_guardrail",
            "reason" => "Worker answer missed another active customer message; stack-aware guardrail reply saved."
          }
        elsif repeated_draft?(body)
          guardrail = repeated_answer_guardrail_draft("rejected_repeated_answer")
          guardrail_body = safe_persisted_sms_body(guardrail.to_h["body"])
          if guardrail_body.present? && acceptable_sms_body?(guardrail_body, include_drafts: false)
            body = guardrail_body
            guardrail_override = guardrail
          else
            reject_worker_answer!(question, "rejected_repeated_answer")
            return false
          end
        else
          reject_worker_answer!(question, quality_rejection_reason)
          return false
        end
      end

      applied_at = Time.current
      draft_time_seconds = if question.created_at.present?
        (applied_at - question.created_at).round(1)
      end

      copilot_only = ActiveModel::Type::Boolean.new.cast(question.metadata.to_h["copilot_only"])
      operator_prompt = question.metadata.to_h["operator_prompt"].presence || @operator_prompt.presence
      result = {
        "body" => body,
        "provider" => guardrail_override.to_h["provider"].presence || question.metadata.to_h.dig("local_worker", "provider").presence || "alice/local_cc",
        "model" => guardrail_override.to_h["model"].presence || question.metadata.to_h.dig("local_worker", "model").presence || writer_model,
        "writer_model" => guardrail_override.to_h["writer_model"].presence || writer_model,
        "writer_model_label" => guardrail_override.to_h["writer_model_label"].presence || WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => guardrail_override.present? || requires_am_support ? "rewritten" : "passed",
        "draft_source" => guardrail_override.to_h["draft_source"].presence || (requires_am_support ? "thumper_guardrail" : (copilot_only ? "copilot" : (support_rag_profile? ? "rag_support" : "thumper"))),
        "draft_mode" => copilot_only ? "copilot" : nil,
        "copilot" => copilot_only,
        "reason" => guardrail_override.to_h["reason"].presence || (copilot_only ? "Generated by Copilot for human approval after the first request returned." : (support_rag_profile? ? "Generated from the selected #{rag_profile.fetch('label')} knowledge profile after the first request returned." : "Generated by Alice local worker after the first request returned.")),
        "operator_prompt" => operator_prompt,
        "conversation_state" => conversation_state,
        "autos_question_id" => question.id,
        "late_worker_writeback" => true,
        "draft_time_seconds" => draft_time_seconds,
        "draft_time_label" => draft_time_seconds.present? ? "#{draft_time_seconds}s" : nil,
        "created_at" => applied_at.iso8601
      }.merge(am_support_required_metadata(requires_am_support)).compact_blank

      metadata = @stage.metadata.to_h.deep_dup
      history = Array(metadata["sms_draft_history"]).last(24)
      history << {
        "id" => SecureRandom.uuid,
        "body" => body,
        "provider" => result["provider"],
        "model" => result["model"],
        "writer_model" => result["writer_model"],
        "writer_model_label" => result["writer_model_label"],
        "sms_generation_pipeline" => result["sms_generation_pipeline"],
        "sms_quality_gate" => result["sms_quality_gate"],
        "draft_source" => result["draft_source"],
        "draft_mode" => result["draft_mode"],
        "copilot" => result["copilot"],
        "requires_am_support" => result["requires_am_support"],
        "am_support_reason" => result["am_support_reason"],
        "reason" => result["reason"],
        "operator_prompt" => operator_prompt,
        "autos_question_id" => question.id,
        "late_worker_writeback" => true,
        "draft_time_seconds" => draft_time_seconds,
        "draft_time_label" => result["draft_time_label"],
        "created_at" => applied_at.iso8601
      }.compact_blank
      processing = if defined?(DealReports::CommsProcessingCode)
        DealReports::CommsProcessingCode.call(stage: @stage, metadata: metadata, latest_body: latest_inbound_sms)
      else
        {}
      end
      return reject_worker_answer!(question, "ignored_stale_inbound_generation", failed: false) if worker_generation_superseded?(question)

      @stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_sms_draft_body" => body,
          "comms_command_sms_draft" => result,
          "sms_writer_model" => result["writer_model"],
          "sms_writer_model_label" => result["writer_model_label"],
          "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(result["writer_model"]),
          "sms_draft_history" => history,
          "comms_bot_state" => result["conversation_state"].presence,
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "reply_drafted",
          "comms_command_last_at" => applied_at.iso8601,
          "comms_command_late_worker_question_id" => question.id,
          "comms_command_late_worker_applied_at" => applied_at.iso8601,
          "comms_command_background_question_id" => question.id,
          "comms_command_background_status" => "applied",
          "comms_command_background_at" => applied_at.iso8601,
          "sms_reply_question_id" => question.id,
          "sms_reply_job_status" => "drafted",
          "sms_reply_job_completed_at" => applied_at.iso8601,
          "ask_autopilot_pending_started_at" => nil,
          "ask_autopilot_pending_phase" => nil
        ).compact_blank.merge(processing)
      )
      if simulation_stage?(@stage.reload.metadata.to_h)
        materialize_ask_simulator_reply!
        return true
      end

      autopilot_sent = copilot_only ? false : maybe_send_late_autopilot_reply!(question, result)
      mark_am_support_from_draft!(result, inbound_body: latest_inbound_sms, source: "late_worker_draft") unless autopilot_sent || copilot_only
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] late worker writeback failed question=#{question&.id} stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def stack_completion_guardrail_body(candidate_body)
      if (body = latest_intent_guardrail_body(candidate_body)).present?
        return body
      end

      if (body = rush_checkout_boundary_guardrail_body(candidate_body)).present?
        return body
      end

      return unless misses_open_customer_messages?(candidate_body) || stacked_yard_sign_price_process_missing?(candidate_body)

      body = safe_persisted_sms_body(stacked_open_messages_reply)
      return if body.blank?
      return unless acceptable_sms_body?(body, include_drafts: false)

      body
    end

    def ensure_next_question_body(value)
      body = value.to_s.squish
      return body if body.blank?
      return body unless next_question_needed_for_sms?(body)

      question = next_question_for_sms_context.presence || "What should I price first?"
      stem = sms_sentence_stem_for_next_question(body)
      candidate = "#{stem} #{question}".squish
      return candidate if candidate.length <= MAX_SMS_CHARS

      short_question = "What should I price first?"
      short_candidate = "#{stem} #{short_question}".squish
      return short_candidate if short_candidate.length <= MAX_SMS_CHARS

      body
    end

    def sms_sentence_stem_for_next_question(body)
      stem = body.to_s.squish
      return stem if stem.blank?
      return stem if stem.match?(/[.!?]\z/)

      "#{stem}."
    end

    def next_question_needed_for_sms?(body)
      text = body.to_s.squish
      return false if text.blank?
      return false if customer_visible_question_present?(text)
      return false if text.match?(%r{https?://}i)
      return false if text.match?(/\b(?:reply\s+stop|stop\s+to\s+opt\s+out|do not contact|stop messaging|unsubscribe)\b/i)
      return false if text.match?(/\b(?:will be contacting you|i let them know|getting that to the right marketing consultant|getting that to a marketing consultant)\b/i)
      return false if text.match?(/\b(?:checkout link|use this checkout|here is the checkout)\b/i)
      return false if am_support_required_for_latest_inbound? && human_handoff_answer?(text)

      latest_inbound_sms.to_s.squish.present?
    end

    def customer_visible_question_present?(body)
      body.to_s.gsub(%r{https?://\S+}i, "").include?("?")
    end

    def next_question_for_sms_context
      inbound = latest_inbound_sms.to_s.squish
      context = [recent_customer_sms_context, inbound].compact.join(" ").downcase
      fit = campaign_fit_payload
      route = current_route_code.to_s
      postcard_only_pivot = postcards_only_pivot?(inbound)

      if design_process_question?(inbound) || design_process_priority_question?(inbound) || proof_handoff_request?(inbound) || artwork_creation_followup_request?(inbound)
        return "How many homes should the postcard mailing reach?" if route == "EDDM" || postcard_only_pivot
        return "What product or quantity should the design team build this around first?" unless route == "LAWN_SIGNS"

        return "What quantity of yard signs should the design team build this around first?"
      end

      if route == "EDDM" && postcard_only_pivot
        return "How many homes do you want to reach with postcards?"
      end

      if fit[:wants_both] || context.match?(/\b(?:both|mixture|mix|combo|combined?|combination|postcards?.{0,80}signs?|signs?.{0,80}postcards?)\b/)
        return "Are you thinking mostly yard signs with some postcards, or more of a Neighborhood Blitz style mix?"
      end

      case route
      when "LAWN_SIGNS"
        "How many yard signs do you want to start with?"
      when "EDDM"
        "How many homes do you want to reach?"
      when "NEIGHBORHOOD_BLITZ"
        "How many homes should this push cover?"
      when "STARTER_PACK", "PRO_PACK"
        "Are you leaning toward Starter, Pro, or signs-only?"
      when "BUSINESS_CARDS", "DOOR_HANGERS", "FLYERS"
        "What quantity are you thinking?"
      else
        "Are you thinking postcards, yard signs, or both?"
      end
    end

    def stack_recovery_guardrail_draft(error)
      body = safe_persisted_sms_body(stacked_open_messages_reply)
      source = "stack_open_messages"
      reason = "Worker answer missed another active customer message; stack-aware guardrail reply saved."
      if body.blank?
        body = safe_persisted_sms_body(must_answer_reply_for(latest_inbound_sms))
        source = "must_answer_reply"
        reason = "Worker answer missed the latest customer question; deterministic guardrail reply saved."
      end
      return if body.blank?
      return unless guardrail_recovery_body_sendable?(body)

      {
        "body" => body,
        "provider" => "local/thumper_guardrail",
        "model" => source,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "rewritten",
        "draft_source" => "thumper_guardrail",
        "reason" => reason,
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.presence
      }.compact_blank
    end

    def guardrail_recovery_body_sendable?(body)
      return true if current_specials_question?(latest_inbound_sms) && current_specials_answer?(body)

      acceptable_sms_body?(body, include_drafts: false) || fallback_sms_sendable?(body)
    end

    def rush_checkout_boundary_guardrail_body(candidate_body)
      boundary_context = [latest_inbound_sms, current_open_customer_message_bodies, @operator_prompt].flatten.compact.join(" ").squish
      return unless rush_checkout_boundary_question?(boundary_context)
      return if turnaround_answer_for_inbound?(candidate_body, boundary_context)

      route = current_route_code.presence || turnaround_route(boundary_context).presence || inferred_product_route_from_fit.presence
      body = safe_persisted_sms_body(rush_checkout_boundary_reply(route))
      return if body.blank?
      return unless acceptable_sms_body?(body, include_drafts: false) || turnaround_answer_for_inbound?(body, boundary_context)

      body
    end

    def latest_intent_guardrail_body(candidate_body)
      inbound = latest_inbound_sms.to_s.squish
      return if inbound.blank?

      candidate = candidate_body.to_s.squish
      replacement = nil

      if turnaround_question?(inbound) || rush_checkout_boundary_question?(inbound)
        replacement = turnaround_reply(inbound) unless turnaround_answer_for_inbound?(candidate, inbound)
      elsif direct_mail_strategy_handoff_question?(inbound)
        replacement = direct_mail_strategy_handoff_reply if direct_mail_strategy_reply_missing_handoff?(candidate)
      elsif multi_product_link_request?(inbound)
        replacement = multi_product_link_reply(inbound) unless multi_product_link_reply_sendable?(candidate)
      elsif direct_checkout_link_request?(inbound)
        replacement = direct_checkout_link_reply(inbound) unless direct_checkout_link_reply_sendable?(candidate) || route_link_answer_has_required_fit?(candidate)
      elsif mixed_postcards_signs_question?(inbound)
        replacement = mixed_postcards_signs_reply unless mixed_postcards_signs_answer?(candidate)
      elsif print_products_question?(inbound) || messy_print_consultant_question?(inbound)
        replacement = if messy_print_consultant_question?(inbound)
          messy_print_consultant_reply
        else
          print_products_reply(inbound)
        end unless print_products_answer_for_inbound?(candidate, inbound)
      end

      body = safe_persisted_sms_body(replacement)
      return if body.blank?
      return unless fallback_sms_sendable?(body) || acceptable_sms_body?(body, include_drafts: false)

      body
    end

    def perform_cloud_worker_answer!(question)
      raise "Cloud SMS writer expected, got #{writer_model}" unless cloud_writer?

      question.reload
      return true if question.status.to_s == "answered" && question.answer.present?
      return reject_worker_answer!(question, "ignored_stale_inbound_generation", failed: false) if worker_generation_superseded?(question)

      started_at = nil
      already_claimed = false
      superseded = false
      question.with_lock do
        question.reload
        worker = question.metadata.to_h["local_worker"].to_h
        already_claimed = (question.status.to_s == "answered" && question.answer.present?) ||
          cloud_worker_processing_claim_active?(worker)
        superseded = worker_generation_superseded?(question) unless already_claimed
        next if already_claimed || superseded

        started_at = Time.current
        question_metadata = question.metadata.to_h.deep_dup
        worker = question_metadata["local_worker"].to_h
        worker.merge!(
          "status" => "processing",
          "provider" => WizwikiSettings.sms_writer_cloud_provider(writer_model),
          "model" => WizwikiSettings.sms_writer_cloud_model(writer_model),
          "started_at" => started_at.iso8601
        )
        question.update!(status: "queued", metadata: question_metadata.merge("local_worker" => worker))
      end
      return true if already_claimed
      return reject_worker_answer!(question, "ignored_stale_inbound_generation", failed: false) if superseded

      result = cloud_draft_with_repair
      unless acceptable_draft?(result)
        result_payload = result.to_h
        reason = result_payload["error"].presence || sms_quality_rejection_reason(result_payload["body"]).presence || "cloud_sms_writer_rejected"
        result = stack_recovery_guardrail_draft(reason) || local_cloud_fallback_draft(reason) || fallback_draft(reason)
      end
      result ||= { "error" => "cloud_sms_writer_failed" }
      body = safe_persisted_sms_body(result["body"])

      completed_at = Time.current
      question_metadata = question.reload.metadata.to_h.deep_dup
      worker = question_metadata["local_worker"].to_h
      worker.merge!(
        "status" => body.present? ? "answered" : "failed",
        "completed_at" => completed_at.iso8601,
        "provider" => result["provider"].presence || WizwikiSettings.sms_writer_cloud_provider(writer_model),
        "model" => result["model"].presence || WizwikiSettings.sms_writer_cloud_model(writer_model),
        "last_error" => result["error"].presence,
        "elapsed_seconds" => (completed_at - started_at).round(1)
      )
      question_metadata["local_worker"] = worker.compact
      question_metadata["cloud_worker_result"] = result.except("body").merge(
        "completed_at" => completed_at.iso8601,
        "elapsed_seconds" => (completed_at - started_at).round(1)
      ).compact_blank

      if body.present?
        question.update!(answer: body, status: "answered", metadata: question_metadata)
        Comms::SmsDraftWritebackJob.perform_later(autos_question_id: question.id) if defined?(Comms::SmsDraftWritebackJob)
      else
        question.update!(
          answer: result["error"].presence || "#{background_writer_label} returned an empty SMS",
          status: "failed",
          metadata: question_metadata
        )
        Comms::SmsDraftWritebackJob.perform_later(
          autos_question_id: question.id,
          reason: result["error"].presence || "cloud_sms_writer_failed"
        ) if defined?(Comms::SmsDraftWritebackJob)
      end

      true
    rescue StandardError => error
      question_metadata = question.metadata.to_h.deep_dup
      worker = question_metadata["local_worker"].to_h
      worker.merge!(
        "status" => "failed",
        "provider" => WizwikiSettings.sms_writer_cloud_provider(writer_model),
        "model" => WizwikiSettings.sms_writer_cloud_model(writer_model),
        "last_error" => "#{error.class}: #{error.message}",
        "failed_at" => Time.current.iso8601
      )
      question.update!(
        answer: "#{error.class}: #{error.message}",
        status: "failed",
        metadata: question_metadata.merge("local_worker" => worker.compact)
      )
      Comms::SmsDraftWritebackJob.perform_later(
        autos_question_id: question.id,
        reason: "cloud_sms_writer_failed"
      ) if defined?(Comms::SmsDraftWritebackJob)
      Rails.logger.warn("[CommsDraftWriter] cloud SMS draft failed question=#{question&.id} stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def clear_worker_rejection!(question, reason)
      @stage.reload
      @metadata = @stage.metadata.to_h
      clear_background_draft!(question, reason)
    end

    private

    def reject_worker_answer!(question, reason, failed: true)
      question_metadata = question.metadata.to_h.deep_dup
      worker = question_metadata["local_worker"].to_h
      worker["status"] = failed ? "rejected" : "ignored"
      worker["reject_reason"] = reason
      worker["rejected_at"] = Time.current.iso8601
      question_metadata["local_worker"] = worker
      question.update!(
        status: failed ? "failed" : question.status,
        metadata: question_metadata
      )
      clear_background_draft!(question, reason)
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] failed rejecting worker answer question=#{question&.id} stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def clear_background_draft!(question, reason)
      metadata = @stage.metadata.to_h.deep_dup
      draft_question_id = metadata.dig("comms_command_sms_draft", "autos_question_id").to_s
      background_question_id = metadata["comms_command_background_question_id"].to_s
      stage_question_id = question.metadata.to_h["comms_stage_id"].to_s
      return true if stale_worker_rejection_reason?(reason) && ![draft_question_id, background_question_id].include?(question.id.to_s)
      return false unless [draft_question_id, background_question_id].include?(question.id.to_s) || stage_question_id == @stage.id.to_s

      recovery_draft = nil
      updates = {
        "comms_command_background_question_id" => question.id,
        "comms_command_background_status" => reason,
        "comms_command_background_error" => question.answer.to_s.squish.first(300),
        "comms_command_background_at" => Time.current.iso8601,
        "comms_command_last_at" => Time.current.iso8601
      }
      processing = if defined?(DealReports::CommsProcessingCode)
        DealReports::CommsProcessingCode.call(stage: @stage, metadata: metadata, latest_body: latest_inbound_sms)
      else
        {}
      end
      if processing["shopify_link"].present? && metadata["shopify_link"].present? && processing["shopify_link"].to_s != metadata["shopify_link"].to_s
        processing["shopify_link_sent_at"] = nil
        processing["comms_link_reached_at"] = nil
      end
      updates.merge!(processing)

      if reason.to_s == "ignored_am_support_handoff"
        draft = rejected_worker_recovery_draft(reason)
        body = safe_persisted_sms_body(draft.to_h["body"])
        if body.present?
          history = Array(metadata["sms_draft_history"]).last(24)
          history << {
            "body" => body,
            "provider" => draft["provider"],
            "model" => draft["model"],
            "writer_model" => draft["writer_model"],
            "writer_model_label" => draft["writer_model_label"],
            "sms_generation_pipeline" => draft["sms_generation_pipeline"],
            "sms_quality_gate" => draft["sms_quality_gate"],
            "draft_source" => draft["draft_source"],
            "reason" => "AM support is active; saved a human-reviewable next text instead of applying the late worker answer.",
            "created_at" => Time.current.iso8601
          }.compact_blank
          updates.merge!(
            "comms_command_sms_draft_body" => body,
            "comms_command_sms_draft" => draft.merge(
              "created_at" => Time.current.iso8601,
              "am_support_review_draft" => true,
              "ignored_question_id" => question.id
            ),
            "sms_draft_history" => history,
            "comms_bot_state" => draft["conversation_state"].presence || metadata["comms_bot_state"],
            "comms_command_last_status" => "am_support"
          )
        else
          updates.merge!(
            "comms_command_sms_draft" => metadata["comms_command_sms_draft"].to_h.merge(
              "pending" => false,
              "draft_source" => "am_support_handoff",
              "ignored_question_id" => question.id,
              "created_at" => Time.current.iso8601
            ).compact_blank,
            "comms_command_last_status" => "am_support"
          )
        end
      elsif reason.to_s == "rejected_repeated_answer"
        retry_updates = guardrail_retry_updates(question, reason, metadata)
        if retry_updates.present?
          updates.merge!(retry_updates)
        else
          draft = repeated_answer_guardrail_draft(reason)
          body = safe_persisted_sms_body(draft.to_h["body"])
          if body.present?
            history = Array(metadata["sms_draft_history"]).last(24)
            history << {
              "body" => body,
              "provider" => draft["provider"],
              "model" => draft["model"],
              "reason" => "Worker repeated a recent draft; fresh guardrail draft saved.",
              "created_at" => Time.current.iso8601
            }.compact_blank
            updates.merge!(
              "comms_command_sms_draft_body" => body,
              "comms_command_sms_draft" => draft.merge(
                "created_at" => Time.current.iso8601,
                "repeated_worker_recovery" => true,
                "rejected_question_id" => question.id
              ),
              "sms_draft_history" => history,
              "comms_bot_state" => draft["conversation_state"].presence || metadata["comms_bot_state"],
              "comms_command_last_status" => "reply_drafted"
            )
            recovery_draft = draft.merge("body" => body) if safe_sms_body_for_autopilot?(body)
          end
        end
      elsif sms_quality_rejection_reason?(reason) || reason.to_s.match?(/analysis|rejected|internal/i)
        current_draft = metadata["comms_command_sms_draft"].to_h
        current_body = safe_persisted_sms_body(current_draft["body"])
        current_source = current_draft["draft_source"].to_s
        if current_body.present? && current_source != "fallback"
          updates["comms_command_last_status"] = "reply_drafted"
          @stage.update!(metadata: metadata.merge(updates).compact_blank)
          materialize_ask_simulator_reply! if simulation_stage?(@stage.reload.metadata.to_h)
          return true
        end

        draft = stack_recovery_guardrail_draft(reason)
        unless draft.present?
          draft = guardrail_override_draft(question, reason, metadata)
          unless draft.present?
            retry_updates = guardrail_retry_updates(question, reason, metadata)
            if retry_updates.present?
              updates.merge!(retry_updates)
              draft = nil
            else
              draft = fallback_draft(reason)
            end
          end
        end
        if draft.present? && (body = safe_persisted_sms_body(draft.to_h["body"])).present?
          history = Array(metadata["sms_draft_history"]).last(24)
          history << {
            "body" => body,
            "provider" => draft["provider"],
            "model" => draft["model"],
            "writer_model" => draft["writer_model"],
            "writer_model_label" => draft["writer_model_label"],
            "sms_generation_pipeline" => draft["sms_generation_pipeline"],
            "sms_quality_gate" => draft["sms_quality_gate"],
            "draft_source" => draft["draft_source"],
            "reason" => draft["reason"].presence || (draft["draft_source"].to_s == "thumper_guardrail" ? "Worker answer rejected; route-ready deterministic guardrail saved." : "Worker answer rejected; deterministic fallback saved."),
            "created_at" => Time.current.iso8601
          }.compact_blank
          updates.merge!(
            "comms_command_sms_draft_body" => body,
            "comms_command_sms_draft" => draft.merge(
              "created_at" => Time.current.iso8601,
              "fallback_after_worker_rejection" => draft["draft_source"].to_s == "fallback",
              "guardrail_after_worker_rejection" => draft["draft_source"].to_s == "thumper_guardrail",
              "guardrail_override_after_retry_loop" => draft["draft_source"].to_s == "guardrail_override",
              "rejected_question_id" => question.id
            ),
            "sms_draft_history" => history,
            "comms_bot_state" => draft["conversation_state"].presence || metadata["comms_bot_state"],
            "comms_command_last_status" => "reply_drafted"
          )
          recovery_draft = draft.merge("body" => body) if draft["draft_source"].to_s == "guardrail_override" || safe_sms_body_for_autopilot?(body)
        elsif retry_updates.blank?
          failure_note = "SMS quality gate rejected the worker draft: #{reason.to_s.squish.truncate(220, separator: " ")}"
          updates.merge!(
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => current_draft.merge(
              "pending" => false,
              "draft_source" => "quality_rejected",
              "reason" => failure_note,
              "rejected_question_id" => question.id,
              "created_at" => Time.current.iso8601
            ).compact_blank,
            "comms_command_background_status" => "rejected_quality_gate",
            "comms_command_background_error" => failure_note,
            "comms_command_background_failed_at" => Time.current.iso8601,
            "comms_command_last_status" => "reply_needs_attention",
            "sms_reply_job_status" => "needs_attention",
            "sms_reply_job_failed_at" => Time.current.iso8601,
            "sms_no_ghost_watchdog" => {
              "status" => "needs_attention",
              "reason" => reason.to_s.presence || "sms_quality_gate_rejected",
              "inbound_sid" => latest_inbound_sms_event.to_h["provider_message_id"].presence || latest_inbound_sms_event.to_h["id"].presence,
              "inbound_created_at" => latest_inbound_sms_event.to_h["created_at"].presence,
              "checked_at" => Time.current.iso8601
            }.compact_blank,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          )
        end
      elsif local_worker_failure_reason?(reason)
        current_draft = metadata["comms_command_sms_draft"].to_h
        failure_note = "Local SMS writer failed: #{reason.to_s.squish.truncate(220, separator: " ")}"
        if draft_question_id.blank? || draft_question_id == question.id.to_s || current_draft["pending"]
          draft = stack_recovery_guardrail_draft(reason) || fallback_draft(reason)
          body = safe_persisted_sms_body(draft.to_h["body"])
          if body.present?
            history = Array(metadata["sms_draft_history"]).last(24)
            history << {
              "body" => body,
              "provider" => draft["provider"],
              "model" => draft["model"],
              "writer_model" => draft["writer_model"],
              "writer_model_label" => draft["writer_model_label"],
              "sms_generation_pipeline" => draft["sms_generation_pipeline"],
              "sms_quality_gate" => draft["sms_quality_gate"],
              "draft_source" => draft["draft_source"],
              "reason" => "Local SMS writer failed; deterministic guardrail reply saved.",
              "created_at" => Time.current.iso8601
            }.compact_blank
            updates.merge!(
              "comms_command_sms_draft_body" => body,
              "comms_command_sms_draft" => draft.merge(
                "created_at" => Time.current.iso8601,
                "guardrail_after_worker_failure" => true,
                "failed_question_id" => question.id
              ),
              "sms_draft_history" => history,
              "comms_bot_state" => draft["conversation_state"].presence || metadata["comms_bot_state"],
              "comms_command_last_status" => "reply_drafted",
              "comms_command_background_status" => reason.to_s,
              "comms_command_background_error" => failure_note,
              "sms_reply_job_status" => "drafted",
              "ask_autopilot_pending_started_at" => nil,
              "ask_autopilot_pending_phase" => nil
            )
            recovery_draft = draft.merge("body" => body) if guardrail_recovery_body_sendable?(body)
          else
            updates.merge!(
              "comms_command_sms_draft_body" => nil,
              "comms_command_sms_draft" => current_draft.merge(
                "pending" => false,
                "draft_source" => "worker_failed",
                "reason" => failure_note,
                "failed_question_id" => question.id,
                "created_at" => Time.current.iso8601
              ).compact_blank,
              "comms_command_background_status" => "failed",
              "comms_command_background_error" => failure_note,
              "comms_command_background_failed_at" => Time.current.iso8601,
              "comms_command_last_status" => "draft_failed",
              "sms_reply_job_status" => "failed",
              "sms_reply_job_failed_at" => Time.current.iso8601,
              "ask_autopilot_pending_started_at" => nil,
              "ask_autopilot_pending_phase" => nil
            )
          end
        end
      elsif stale_worker_rejection_reason?(reason)
        if draft_question_id == question.id.to_s
          updates.merge!(
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_last_status" => metadata["comms_command_last_status"].presence || "reply_drafted"
          )
        end
      elsif reason.to_s == "ignored_customer_acknowledgment"
        updates.merge!(
          "comms_command_sms_draft_body" => nil,
          "comms_command_sms_draft" => {
            "pending" => false,
            "draft_source" => "no_reply_needed",
            "reason" => "Customer acknowledgement did not need an automated reply.",
            "ignored_question_id" => question.id,
            "created_at" => Time.current.iso8601
          },
          "comms_command_last_status" => "listening",
          "comms_command_background_status" => "no_reply_needed",
          "comms_command_background_at" => Time.current.iso8601,
          "sms_reply_job_status" => "no_reply_needed",
          "sms_reply_job_completed_at" => Time.current.iso8601,
          "ask_autopilot_pending_started_at" => nil,
          "ask_autopilot_pending_phase" => nil
        )
      else
        updates["comms_command_last_status"] = "drafted" if metadata["comms_command_last_status"].to_s == "drafting"
      end
      @stage.update!(metadata: metadata.merge(updates).compact_blank)
      if simulation_stage?(@stage.reload.metadata.to_h)
        materialize_ask_simulator_reply!
        return true
      end

      maybe_send_late_autopilot_reply!(question, recovery_draft) if recovery_draft.present?
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] failed clearing background draft question=#{question&.id} stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def guardrail_retry_updates(question, reason, metadata)
      return unless guardrail_retryable_rejection?(reason)
      return unless guardrail_retry_allowed?(metadata)

      retry_count = guardrail_retry_count(metadata) + 1
      instruction = guardrail_retry_instruction(question, reason, retry_count)
      previous_instruction = @guardrail_retry_instruction
      @guardrail_retry_instruction = instruction
      retry_question = enqueue_background_draft_question(
        extra_metadata: {
          "guardrail_retry" => true,
          "guardrail_retry_count" => retry_count,
          "guardrail_retry_reason" => reason.to_s,
          "guardrail_retry_instruction" => instruction,
          "rejected_autos_question_id" => question.id
        }.compact_blank
      )
      pending = pending_draft_for(retry_question).merge(
        "guardrail_retry" => true,
        "guardrail_retry_count" => retry_count,
        "guardrail_retry_reason" => reason.to_s,
        "rejected_autos_question_id" => question.id,
        "reason" => "#{background_writer_label} is retrying after the SMS guardrail blocked the prior answer."
      ).compact_blank
      now = Time.current.iso8601
      {
        "comms_command_sms_draft_body" => nil,
        "comms_command_sms_draft" => pending.merge("created_at" => now),
        "comms_command_background_question_id" => retry_question.id,
        "comms_command_background_status" => "queued",
        "comms_command_background_error" => "Retrying after guardrail rejection: #{reason}",
        "comms_command_background_at" => now,
        "comms_command_background_running_at" => nil,
        "comms_command_last_status" => "drafting",
        "sms_reply_job_status" => "draft_pending",
        "ask_autopilot_pending_started_at" => metadata["ask_autopilot_pending_started_at"].presence || now,
        "ask_autopilot_pending_phase" => "drafting_message",
        "sms_guardrail_retry_key" => guardrail_retry_key,
        "sms_guardrail_retry_count" => retry_count,
        "sms_guardrail_retry_reason" => reason.to_s,
        "sms_guardrail_retry_instruction" => instruction,
        "sms_guardrail_retry_last_question_id" => retry_question.id,
        "sms_guardrail_retry_rejected_question_id" => question.id,
        "sms_guardrail_retry_at" => now
      }.compact_blank
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] guardrail retry queue failed stage=#{@stage&.id} question=#{question&.id} #{error.class}: #{error.message}")
      nil
    ensure
      @guardrail_retry_instruction = previous_instruction
    end

    def guardrail_retryable_rejection?(reason)
      sms_quality_rejection_reason?(reason) ||
        reason.to_s.match?(/(?:rejected|analysis|internal|quality|repeated|empty|cloud_sms_writer_rejected|cloud_sms_writer_failed)/i)
    end

    def sms_quality_rejection_reason?(reason)
      SMS_QUALITY_REJECTION_REASONS.include?(reason.to_s)
    end

    def local_worker_failure_reason?(reason)
      reason.to_s.match?(/(?:econnrefused|connection refused|failed to open tcp connection|timed? ?out|ollama|local context cache failed|worker failed)/i)
    end

    def guardrail_retry_allowed?(metadata)
      return false if am_support_required_for_latest_inbound?
      return false if latest_inbound_sms.to_s.squish.blank?

      guardrail_retry_count(metadata) < guardrail_retry_limit
    end

    def guardrail_override_draft(question, reason, metadata)
      return unless soft_guardrail_override_reason?(reason)
      return unless guardrail_override_ready?(metadata)

      body = guardrail_override_candidate_body(question, reason)
      return unless guardrail_override_body_safe?(body)

      question_metadata = question.metadata.to_h
      {
        "body" => body,
        "provider" => question_metadata.dig("local_worker", "provider").presence || "local/guardrail_override",
        "model" => question_metadata.dig("local_worker", "model").presence || writer_model,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "override_after_retry_loop",
        "draft_source" => "guardrail_override",
        "reason" => "Retry loop hit a soft SMS guardrail (#{reason}); saved the best customer-safe answer instead of jamming.",
        "conversation_state" => conversation_state,
        "guardrail_override" => true,
        "guardrail_override_reason" => reason.to_s,
        "guardrail_retry_count" => guardrail_retry_count(metadata),
        "guardrail_override_min_retries" => guardrail_override_min_retries
      }.compact_blank
    end

    def soft_guardrail_override_reason?(reason)
      SMS_SOFT_GUARDRAIL_OVERRIDE_REASONS.include?(reason.to_s)
    end

    def guardrail_override_ready?(metadata)
      return false if am_support_required_for_latest_inbound?
      return false if latest_inbound_sms.to_s.squish.blank?

      guardrail_retry_count(metadata) >= guardrail_override_min_retries
    end

    def guardrail_override_min_retries
      if recursive_dojo_compact_cloud_prompt?
        return ENV.fetch("ASK_RECURSIVE_DOJO_NEMOTRON_GUARDRAIL_OVERRIDE_MIN_RETRIES", "1").to_i.clamp(1, 5)
      end

      ENV.fetch("WIZWIKI_COMMS_GUARDRAIL_OVERRIDE_MIN_RETRIES", "3").to_i.clamp(1, 15)
    end

    def guardrail_override_candidate_body(question, reason)
      raw = question.answer.to_s.squish
      return if raw.blank?
      return if raw == reason.to_s
      return if SMS_QUALITY_REJECTION_REASONS.include?(raw)

      safe_persisted_sms_body(raw)
    end

    def guardrail_override_body_safe?(body)
      text = body.to_s.squish
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || internal_context_fragment?(text)
      return false if sold_out_shopify_link_in_text?(text)
      return false if wrong_route_shopify_link?(text) && !open_customer_stack_link_answer_sendable?(text)
      return false if stale_latest_pivot_reply?(text)
      return false if repeated_recent_outbound?(text)
      return false if misses_open_customer_messages?(text)
      return false if signs_only_reply_against_mail_or_both_intent?(text)
      return false if missing_requested_product_context?(text, latest_inbound_sms)
      return false if latest_rush_or_turnaround_question? && !turnaround_answer_for_inbound?(text, latest_inbound_sms)
      return false if latest_print_products_question? && !print_products_answer_for_inbound?(text, latest_inbound_sms)
      return false if stacked_yard_sign_price_process_missing?(text)

      true
    end

    def guardrail_retry_limit
      if recursive_dojo_compact_cloud_prompt?
        return ENV.fetch("ASK_RECURSIVE_DOJO_NEMOTRON_GUARDRAIL_RETRY_LIMIT", "2").to_i.clamp(0, 5)
      end

      ENV.fetch("WIZWIKI_COMMS_GUARDRAIL_RETRY_LIMIT", GUARDRAIL_RETRY_LIMIT.to_s).to_i.clamp(0, 15)
    end

    def guardrail_retry_count(metadata)
      return 0 unless metadata.to_h["sms_guardrail_retry_key"].to_s == guardrail_retry_key

      metadata.to_h["sms_guardrail_retry_count"].to_i
    end

    def guardrail_retry_key
      inbound = latest_inbound_sms_event.to_h
      Digest::SHA1.hexdigest([
        @stage.id,
        inbound["provider_message_id"].presence || inbound["id"].presence,
        inbound["from"].to_s.squish,
        inbound["body"].to_s.squish,
        writer_model
      ].join(":"))
    end

    def guardrail_retry_instruction(question, reason, retry_count)
      rejected = question.answer.to_s.squish.first(220)
      inbound = latest_inbound_sms.to_s.squish
      known_quantity = inbound.match?(/\A(?:maybe\s+|about\s+|around\s+)?[\d,]{1,6}\s*(?:homes?|households?|mailboxes?|doors?|postcards?|signs?)?\z/i) ?
        "If the latest customer message is a quantity or count, treat that quantity as already known; do not ask for it again." :
        nil
      pricing_answer = inbound.match?(/\b(?:how\s+(?:much|many)|cost|costs|price|pricing|total|rate|quote|cheapest|specials?)\b/i) ?
        "If the customer asked price, specials, cheapest option, or a numeric fit question, include the relevant price from retrieved context before asking a follow-up." :
        nil
      price_only_link = price_only_pricing_question?(inbound) ?
        "If the customer only asked what a yard-sign quantity costs, quote the price and ask whether they want the checkout link; do not include a Shopify URL until they ask for the link or say they are ready." :
        nil
      quality_feedback = guardrail_retry_quality_feedback(reason)
      [
        "This is guardrail retry #{retry_count} after the prior SMS draft was blocked for #{reason}.",
        "Regenerate from scratch through the retrieved RAG/pricing context in the required output format for this prompt.",
        "The customer-facing SMS body must not include labels, wrappers, analysis, JSON keys, internal context names, or meta commentary.",
        "Answer the active unread customer stack when open_customer_messages is present; otherwise answer the latest customer message directly. Use only supplied product/pricing facts, keep it warm and natural, and ask at most one useful next question.",
        numbered_open_customer_requirements_instruction,
        quality_feedback,
        known_quantity,
        pricing_answer,
        price_only_link,
        rejected.present? ? "Avoid repeating this rejected text: #{rejected}" : nil
      ].compact.join(" ")
    end

    def guardrail_retry_quality_feedback(reason)
      case reason.to_s
      when "asks_for_known_fit_field"
        "Do not ask for a fit field that is already known from the conversation, CRM metadata, selected options, or the active unread customer stack."
      when "broad_direct_mail_checkout_before_ready"
        "Do not send a broad direct-mail or postcard checkout link before the customer is ready; answer the question and collect the missing homes, route, artwork, or timing detail."
      when "direct_mail_strategy_reply_missing_handoff"
        "Answer the direct-mail strategy question briefly, then offer a marketing consultant for route, list, timing, or campaign-planning help if needed."
      when "marketing_channel_recommendation_missing"
        "The customer asked which marketing channel to start with. Pick a clear starting move, explain the practical reason, and position the other channel as reinforcement when it fits. Do not answer only that both are available."
      when "missing_requested_product_context"
        "Include the requested product context from the retrieved facts before asking the next question."
      when "misses_open_customer_messages"
        "Answer every active unread customer message in open_customer_messages before asking one follow-up; do not only answer the newest text."
      when "price_only_question_with_checkout_url"
        "For a price-only question, quote the price and ask whether they want the checkout link; do not include a URL unless they asked for the link or said they are ready."
      when "print_products_answer_missing"
        "Answer the print-product question directly using retrieved pricing or process facts before routing, qualifying, or asking a follow-up."
      when "signs_only_reply_against_mail_or_both_intent"
        "Respect the customer's current product lane. If they are asking about postcards, direct mail, or both postcards and signs, do not reply as if they only asked about yard signs."
      when "stacked_yard_sign_price_process_missing"
        "For a stacked yard-sign question, include both the relevant price and the design, proof, rush, or shipping process fact the customer asked about."
      when "turnaround_answer_missing"
        "Answer the rush or turnaround question directly. Mention that rush timing starts after proof approval, availability and pricing may need a marketing consultant check, and shipping can still add time."
      when "unsolicited_yard_sign_quantity_checkout_url"
        "Do not include a yard-sign checkout URL until the customer asks for the link or confirms they are ready; give the quantity price and one next step."
      else
        Comms::ConsultantVoice.feedback_for(reason) if defined?(Comms::ConsultantVoice)
      end
    end

    def superseded_worker_answer?(question)
      AutosQuestion
        .where("id > ?", question.id)
        .where("metadata ->> 'surface' = ?", "comms_sms_draft")
        .where("metadata ->> 'comms_stage_id' = ?", @stage.id.to_s)
        .exists?
    end

    def outbound_sent_after?(time)
      Array(@metadata["sms_thread"]).any? do |event|
        event = event.to_h
        next false unless event["channel"].to_s == "sms"
        next false unless event["direction"].to_s == "outbound"
        next false if event["status"].to_s.in?(%w[failed canceled])

        event_time = parse_time(event["created_at"])
        event_time.present? && event_time > time
      end
    end

    def inbound_received_after?(time)
      Array(@metadata["sms_thread"]).any? do |event|
        event = event.to_h
        next false unless event["channel"].to_s == "sms"
        next false unless event["direction"].to_s == "inbound"
        next false if event["status"].to_s.in?(%w[failed canceled])

        event_time = parse_time(event["created_at"])
        event_time.present? && time.present? && event_time > time
      end
    end

    def auto_thumper_reset_after?(time)
      reset_at = parse_time(@metadata["sms_auto_thumper_command_at"]) || parse_time(@metadata["sms_conversation_reset_at"])
      reset_at.present? && time.present? && reset_at > time
    end

    def reset_opener_after?(time)
      return false unless @metadata.dig("comms_command_sms_draft", "draft_source").to_s == "reset_conversation_opener"

      draft_at = parse_time(@metadata.dig("comms_command_sms_draft", "created_at")) ||
        parse_time(@metadata["comms_command_last_at"])
      draft_at.present? && time.present? && draft_at > time
    end

    def stale_worker_rejection_reason?(reason)
      reason.to_s.in?(%w[
        ignored_after_auto_thumper_reset
        ignored_after_reset_opener
        ignored_after_outbound_sent
        ignored_after_newer_inbound
        ignored_superseded
        ignored_stale_inbound_generation
        ignored_stale_simulator_inbound
      ])
    end

    def worker_generation_superseded?(question)
      return true if simulator_worker_inbound_superseded?(question)

      expected = question.metadata.to_h["sms_reply_generation"].to_s.presence
      current = @stage.reload.metadata.to_h["sms_reply_generation"].to_s
      return false if expected.blank? && current.blank?
      return true if expected.blank? && current.present?

      current.blank? || current != expected
    end

    def simulator_worker_inbound_superseded?(question)
      metadata = @stage.reload.metadata.to_h
      return false unless simulation_stage?(metadata)

      question_metadata = question.metadata.to_h
      expected_sid = question_metadata["sms_reply_generation_inbound_sid"].presence ||
        question_metadata["sms_reply_generation_inbound_id"].presence
      current_sid = metadata["sms_reply_generation_inbound_sid"].presence ||
        metadata["sms_reply_generation_inbound_id"].presence
      return false if expected_sid.blank? || current_sid.blank?

      expected_sid != current_sid
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def cloud_worker_processing_claim_active?(worker)
      return false unless worker.to_h["status"].to_s == "processing"

      started_at = parse_time(worker.to_h["started_at"])
      started_at.present? && started_at >= 15.minutes.ago
    end

    def safe_persisted_sms_body(value)
      return if value.blank?
      if defined?(Comms::SmsBodySafety)
        return normalize_customer_sms_phrasing(Comms::SmsBodySafety.sanitize_customer_body(value))
      end

      normalize_customer_sms_phrasing(value.to_s.squish.presence)
    end

    def normalize_customer_sms_phrasing(value)
      body = normalize_consultant_handoff_phrase(value)
      body = normalize_unearned_instead_phrase(body)
      if defined?(Comms::ConsultantVoice)
        review = Comms::ConsultantVoice.review(body: body, inbound: latest_inbound_sms)
        body = review.body if review.body.present?
      end
      body
    end

    def normalize_consultant_handoff_phrase(value)
      body = value.to_s.squish
      return if body.blank?

      body
        .gsub(/\bWant me to connect someone\?/i, "Want me to have a marketing consultant check this with you?")
        .gsub(/\bWant me to get someone connected with you\?/i, "Want me to have a marketing consultant check this with you?")
        .gsub(/\bWant me to get you connected with (?:one of )?(?:our )?marketing consultants?\?/i, "Want me to have a marketing consultant check this with you?")
        .gsub(/\bWould it be helpful for me to get you connected with (?:one of )?(?:our )?marketing consultants? to go over the details\?/i, "Would it be helpful for me to have one of our marketing consultants reach out to go over the details?")
        .squish
    end

    def normalize_unearned_instead_phrase(value)
      body = value.to_s.squish
      return if body.blank?

      latest = latest_inbound_sms.to_s.downcase.squish
      return body if latest.match?(/\b(?:actually|instead|rather|prefer|switch|change|meant|correct|no|not|only|just|scratch|nevermind|never mind|what about|how about)\b/)

      body
        .gsub(/\bGot it,\s+(postcards?|yard signs?|signs?|business cards?|door hangers?)\s+instead\./i, 'Got it, \1.')
        .squish
    end

    def maybe_send_late_autopilot_reply!(question, draft)
      @stage.reload
      metadata = @stage.metadata.to_h.deep_dup
      return false if worker_generation_superseded?(question)
      return false if simulation_stage?(metadata)
      return false if ActiveModel::Type::Boolean.new.cast(question.metadata.to_h["copilot_only"])
      return false if ActiveModel::Type::Boolean.new.cast(draft.to_h["copilot"])
      return false unless ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"])
      return false if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
      return false if draft.to_h["body"].to_s.squish.blank?

      inbound = latest_unanswered_inbound_sms(metadata)
      return false if inbound.blank?

      inbound_sid = inbound["provider_message_id"].presence ||
        inbound["sid"].presence ||
        inbound["message_sid"].presence ||
        inbound["id"].presence
      inbound_body = inbound["body"].to_s
      from = inbound["from"].to_s.presence
      to = inbound["to"].to_s.presence || metadata["sms_listener_from"].to_s.presence
      return false if inbound_sid.blank? || inbound_body.blank? || from.blank?
      return false if customer_acknowledgment_no_reply?(inbound_body)
      if defined?(Comms::InboundSmsHandoff) && Comms::InboundSmsHandoff.required?(inbound_body, stage: @stage)
        result = Comms::InboundSmsHandoff.call(stage: @stage.reload, body: inbound_body, source: "late_worker_autopilot")
        return false unless ActiveModel::Type::Boolean.new.cast(result&.handled)
        return false unless ActiveModel::Type::Boolean.new.cast(draft.to_h["requires_am_support"])
        return false unless am_support_reply_sendable?(draft.to_h["body"])
      end

      ActiveModel::Type::Boolean.new.cast(TwilioWebhooksController.new.send(
        :maybe_autopilot_reply!,
        @stage,
        draft: draft,
        inbound_sid: inbound_sid,
        inbound_body: inbound_body,
        from: from,
        to: to
      ))
    rescue StandardError => error
      failure_metadata = @stage.reload.metadata.to_h.deep_dup
      @stage.update!(
        generated_at: Time.current,
        metadata: failure_metadata.merge(
          "comms_command_background_status" => "late_send_failed",
          "comms_command_background_error" => "#{error.class}: #{error.message}",
          "comms_command_background_at" => Time.current.iso8601,
          "sms_autopilot_last_error" => "#{error.class}: #{error.message}"
        ).compact_blank
      )
      Rails.logger.warn("[CommsDraftWriter] late autopilot send failed question=#{question&.id} stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def materialize_ask_simulator_reply!
      return false unless defined?(Comms::AskAutopilotTest)

      stage = @stage.reload
      organization = stage.organization || stage.crm_record&.organization
      user = stage.user || @user
      return false if organization.blank? || user.blank?

      Comms::AskAutopilotTest.load(
        { "stage_id" => stage.id },
        user: user,
        organization: organization
      )
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] ask simulator materialize failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def latest_unanswered_inbound_sms(metadata)
      events = Array(metadata["sms_thread"]).map(&:to_h)
      latest = events.reverse.find do |event|
        event["channel"].to_s == "sms" &&
          event["direction"].to_s == "inbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled])
      end
      return nil unless latest.present?

      inbound_sid = latest["provider_message_id"].presence ||
        latest["sid"].presence ||
        latest["message_sid"].presence ||
        latest["id"].presence
      return nil if inbound_sid.blank?

      latest_index = events.rindex(latest)
      later_events = latest_index ? events[(latest_index + 1)..] : []
      return nil if Array(later_events).any? do |event|
        event["channel"].to_s == "sms" &&
          event["direction"].to_s == "outbound" &&
          !event["status"].to_s.in?(%w[failed canceled])
      end
      return nil if events.any? { |event| event["autopilot_reply_to_sid"].to_s == inbound_sid.to_s }

      latest
    end

    def mark_am_support_from_draft!(draft, inbound_body:, source:)
      return false if simulation_stage?(@stage.reload.metadata.to_h)
      return false unless ActiveModel::Type::Boolean.new.cast(draft.to_h["requires_am_support"])
      return false unless defined?(Comms::InboundSmsHandoff)

      result = Comms::InboundSmsHandoff.call(
        stage: @stage.reload,
        body: inbound_body.to_s,
        reason: draft.to_h["am_support_reason"].presence || "customer_requested_am_support",
        source: source,
        review_body: safe_persisted_sms_body(draft.to_h["body"])
      )
      ActiveModel::Type::Boolean.new.cast(result&.handled)
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] AM support handoff failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      false
    end

    def simulation_stage?(metadata = @stage&.metadata.to_h)
      metadata = metadata.to_h
      ActiveModel::Type::Boolean.new.cast(metadata["ask_autopilot_test"]) ||
        ActiveModel::Type::Boolean.new.cast(metadata["comms_simulation_mode"])
    end

    def am_support_handoff?(metadata)
      metadata = metadata.to_h
      metadata["comms_support_state"].to_s == "am_support" ||
        metadata["comms_command_last_status"].to_s.in?(%w[human_requested account_manager_support am_support]) ||
        metadata["sms_autopilot_slack_human_requested_at"].present? ||
        metadata["sms_autopilot_slack_handoff_at"].present?
    end

    def am_support_autopilot_enabled?(metadata)
      metadata = metadata.to_h
      ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) &&
        !ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"]) &&
        !ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) &&
        metadata["comms_board_state"].to_s != "opt_out"
    end

    def alice_draft
      question = enqueue_alice_draft_question
      deadline = Time.current + alice_wait_seconds.seconds
      loop do
        question.reload
        if question.status == "answered" && question.answer.present?
          body = sanitize_sms(question.answer)
          return {
            "body" => body,
            "provider" => question.metadata.to_h.dig("local_worker", "provider").presence || "alice/local_cc",
            "model" => question.metadata.to_h.dig("local_worker", "model").presence || writer_model,
            "writer_model" => writer_model,
            "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "passed",
            "draft_source" => "thumper",
            "reason" => "Generated by Alice local worker.",
            "operator_prompt" => @operator_prompt.presence,
            "conversation_state" => conversation_state,
            "autos_question_id" => question.id
          }.compact_blank if body.present?

          return { "error" => "Alice returned an empty SMS", "autos_question_id" => question.id }
        end
        if question.status == "failed"
          worker = question.metadata.to_h["local_worker"].to_h
          reject_reason = worker["reject_reason"].to_s.presence
          return {
            "body" => question.answer.to_s.presence,
            "error" => "Alice comms draft failed: #{reject_reason.presence || question.answer.presence || worker['last_error']}",
            "reject_reason" => reject_reason,
            "autos_question_id" => question.id
          }.compact_blank
        end
        break if Time.current >= deadline

        sleep 0.75
      end

      if question.status.to_s.in?(%w[queued claimed processing])
        return pending_draft_for(question).merge(
          "error" => "Alice comms draft still running after #{alice_wait_seconds}s"
        ).compact_blank
      end

      { "error" => "Alice comms draft timed out after #{alice_wait_seconds}s", "autos_question_id" => question.id }
    rescue StandardError => error
      {
        "provider" => "alice/local_cc",
        "model" => writer_model,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "error" => "#{error.class}: #{error.message}"
      }.compact_blank
    end

    def enqueue_background_draft_question(extra_metadata: {})
      cloud_writer? ? enqueue_cloud_draft_question(extra_metadata: extra_metadata) : enqueue_alice_draft_question(extra_metadata: extra_metadata)
    end

    def enqueue_alice_draft_question(extra_metadata: {})
      raise "Alice comms draft disabled" unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_ALICE_DRAFT_ENABLED", "1"))
      raise "Alice worker queue disabled" unless defined?(Autos::WorkerQueue) && Autos::WorkerQueue.enabled?

      question = create_background_draft_question!(extra_metadata: extra_metadata)
      Autos::WorkerQueue.queue!(question)
      question
    end

    def enqueue_cloud_draft_question(extra_metadata: {})
      raise "#{background_writer_label} SMS writer is not configured" unless WizwikiSettings.sms_writer_cloud_configured?(writer_model)
      raise "#{background_writer_label} SMS draft job is unavailable" unless defined?(Comms::SmsCloudDraftJob)

      provider = WizwikiSettings.sms_writer_cloud_provider(writer_model)
      question = create_background_draft_question!(
        worker_metadata: {
          "status" => "queued",
          "provider" => provider,
          "model" => WizwikiSettings.sms_writer_cloud_model(writer_model),
          "queued_at" => Time.current.iso8601
        }.compact_blank,
        extra_metadata: {
          "cloud_sms_writer" => true,
          "cloud_sms_writer_provider" => provider,
          "cloud_sms_writer_model" => WizwikiSettings.sms_writer_cloud_model(writer_model)
        }.merge(extra_metadata).compact_blank
      )
      Comms::SmsCloudDraftJob.perform_later(autos_question_id: question.id)
      question
    end

    def create_background_draft_question!(worker_metadata: nil, extra_metadata: {})
      organization = @stage.organization || @stage.crm_record&.organization
      user = @user || @stage.user
      raise "#{background_writer_label} comms draft missing organization/user" if organization.blank? || user.blank?

      request_key = sms_draft_request_key
      if (active_question = active_alice_draft_question(organization, request_key))
        return active_question
      end

      context_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      context_payload = alice_context_payload
      context_json = JSON.pretty_generate(context_payload)
      context_build_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - context_started) * 1_000).round
      fine_training_payload = if support_rag_profile?
        context_payload[:retrieved_support].to_h
      else
        context_payload[:fine_training_context].to_h
      end
      rag_trace = rag_trace_payload(context_payload, fine_training_payload)
      prompt_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      question_prompt = alice_prompt
      prompt_build_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - prompt_started) * 1_000).round
      question_attributes = {
        user: user,
        status: "queued",
        question: question_prompt,
        context: context_json,
        metadata: {
          "surface" => "comms_sms_draft",
          "context_mode" => "compact_sms_v2",
          "context_chars" => context_json.length,
          "context_build_ms" => context_build_ms,
          "prompt_chars" => question_prompt.length,
          "prompt_build_ms" => prompt_build_ms,
          "fine_training_documents" => Array(fine_training_payload[:selected_documents]).length,
          "fine_training_chunks" => Array(fine_training_payload[:selected_chunks]).length,
          "input_mode" => "internal_comms",
          "draft_mode" => @copilot ? "copilot" : "standard",
          "copilot_only" => @copilot,
          "ask_autopilot_test" => ActiveModel::Type::Boolean.new.cast(@metadata["ask_autopilot_test"]),
          "comms_simulation_mode" => simulation_stage?,
          "operator_prompt" => @operator_prompt.presence,
          "skip_voice" => true,
          "skip_chat_memory" => true,
          "skip_ui_broadcast" => true,
          "comms_stage_id" => @stage.id,
          "comms_company_name" => company_name,
          "sms_reply_generation" => @metadata["sms_reply_generation"].presence,
          "sms_reply_generation_at" => @metadata["sms_reply_generation_at"].presence,
          "sms_reply_generation_inbound_id" => @metadata["sms_reply_generation_inbound_id"].presence || latest_inbound_sms_event.to_h["id"].presence,
          "sms_reply_generation_inbound_sid" => @metadata["sms_reply_generation_inbound_sid"].presence || latest_inbound_sms_event.to_h["provider_message_id"].presence,
          "sms_draft_request_key" => request_key,
          "writer_model" => writer_model,
          "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
          "sms_generation_pipeline" => "single_writer_guardrailed",
          "challenge_policy" => "The selected SMS writer composes the draft. Rails validates facts, product fit, Thumper voice, directness, and non-repetition; a failed cloud draft gets one focused self-repair before deterministic fallback.",
          "semantic_query" => rag_semantic_query,
          "rag_profile" => rag_profile.fetch("key"),
          "rag_profile_label" => rag_profile.fetch("label"),
          "rag_scope" => rag_profile.fetch("scope"),
          "rag_trace" => rag_trace,
          "submitted_at" => Time.current.iso8601
        }.merge(extra_metadata).tap do |metadata|
          metadata["local_worker"] = worker_metadata if worker_metadata.present?
        end.compact_blank
      }
      create_question = -> { organization.autos_questions.create!(question_attributes) }
      return create_question.call if request_key.blank?

      @stage.with_lock do
        active_alice_draft_question(organization, request_key) || create_question.call
      end
    end

    def pending_draft_for(question)
      metadata = question.metadata.to_h
      {
        "body" => nil,
        "provider" => metadata.dig("local_worker", "provider").presence || "alice/local_cc",
        "model" => metadata.dig("local_worker", "model").presence || writer_model,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "draft_source" => "pending",
        "draft_mode" => metadata["draft_mode"].presence,
        "copilot" => ActiveModel::Type::Boolean.new.cast(metadata["copilot_only"]),
        "reason" => "#{background_writer_label} is composing the #{support_rag_profile? ? rag_profile.fetch('label') : 'Thumper'} SMS draft in the background.",
        "operator_prompt" => @operator_prompt.presence,
        "autos_question_id" => question.id,
        "background_queued" => true,
        "pending" => true
      }.compact_blank
    end

    def background_writer_label
      cloud_writer? ? WizwikiSettings.sms_writer_model_label(writer_model) : "Alice local worker"
    end

    def background_writer_provider
      cloud_writer? ? WizwikiSettings.sms_writer_cloud_provider(writer_model).to_s.presence || "cloud" : "alice"
    end

    def alice_wait_seconds
      value = @wait_seconds.presence || ENV.fetch("WIZWIKI_COMMS_ALICE_DRAFT_WAIT_SECONDS", "75")
      value.to_i.clamp(2, 180)
    end

    def guardrail_retry_prompt_section
      instruction = @guardrail_retry_instruction.to_s.squish
      return "" if instruction.blank?

      "GUARDRAIL RETRY INSTRUCTION: #{instruction}"
    end

    def support_alice_prompt(json_output: false)
      output_instruction = if json_output
        'Return exactly one compact JSON object: {"body":"...","reason":"..."}. Put the customer SMS only in body.'
      else
        "Return only the exact customer-facing SMS body."
      end

      <<~PROMPT.squish
        You are Thumper von AUTOS, a concise SMS guide for the selected #{rag_profile.fetch("label")} knowledge profile.
        #{output_instruction}
        Use only facts in the retrieved documents for this selected profile and the current SMS thread. Never use unrelated profile documents, CRM records, or memory.
        Answer the newest question first in plain language. Give at most one next step and stay under #{MAX_SMS_CHARS} characters.
        Never claim that an order, payment, transfer, refund, account change, or other external action happened unless the supplied context explicitly confirms it.
        If the selected profile does not support an answer, say that briefly and offer operator confirmation. Do not invent prices, links, delivery details, account details, or transaction facts.
        No markdown, labels, bullets, analysis, internal notes, or wrapper text.
      PROMPT
    end

def alice_prompt(json_output: false)
  return support_alice_prompt(json_output: json_output) if support_rag_profile?

  output_instruction = if json_output
    'Return exactly one compact JSON object: {"body":"...","reason":"..."}. Put the customer SMS only in body.'
  else
    "Return only the exact customer-facing SMS body."
  end

  <<~PROMPT.squish
    Write exactly one customer-facing SMS body as Thumper from WIZWIKI Marketing.
    #{output_instruction}
    No markdown, labels, bullets, emojis, fake stats, visible reasoning, analysis, or internal notes.
    Never introduce, label, describe, or quote the SMS. Do not write wrapper phrases like "Here's the next SMS", "SMS body:", "Suggested reply:", "Message for Sample Contact:", or "The customer-facing text is:".
    Voice hierarchy: follow the Thumper Thumper Voice Canon and WIZWIKI Copy Playbook above older examples. Use current catalog/thread context for facts. Use skills as procedures, examples as patterns, and correction memory only as a checklist. Never imitate judge, rejected, simulator, opt-out, or quarantined memory.
    #{current_specials_prompt_instruction}
    #{guardrail_retry_prompt_section}
    You may reason privately if useful, but the visible response must follow the required output format with no extra text.
    Never write "let me analyze", "from the context", "latest inbound", or describe what you are doing.
    Do not start by paraphrasing or summarizing the customer's message. Start with the answer or useful next step.
    Do not use habitual "Yep" or repetitive one-word "Yes." openers in customer SMS. If the answer is affirmative, lead with the useful fact or a natural acknowledgement such as "Got it" only when it truly fits.
    Stay under #{MAX_SMS_CHARS} characters.
    Write one concise, complete SMS. If the customer asks for pricing, comparisons, process details, or multiple links, answer the full request in that SMS before any next-step question.
    Use complete, clear sentences that sound like a helpful person. Do not use clipped fragments, robotic checklist phrasing, or policy-note language.
    Do not say goodbye, "nice to meet you," "thank you for choosing," or "let me know if you need anything else" unless the customer has clearly ended the conversation.
    Use the supplied JSON as authority. If CONTEXT JSON has open_customer_messages, those are the active unread customer texts since Thumper last replied. Answer every non-superseded open customer question in one SMS before asking a follow-up; the latest inbound is only the newest item in that stack.
    Multilingual SMS rule: language_code, language_label, original_body, and translated fields are translation metadata. Compose this internal draft in English from the English body/latest_inbound_sms. Do not write the outbound SMS in Spanish, Chinese, Vietnamese, Russian, Arabic, Tagalog, Korean, Portuguese, or any other non-English language; the SMS language layer will translate the accepted English draft and preserve english_body for QA.
    If open_customer_reply_requirements is present, use it as the checklist of facts the SMS must cover. Do not describe the checklist; turn it into one natural customer-facing reply.
    If the latest inbound SMS asks a direct question, the first sentence must answer that newest question directly, while still including prior open pricing/process facts from the active stack when needed.
    If the latest inbound SMS includes something unexpected, joking, off-menu, or not in the product data, respond like a relaxed human first. A small spontaneous joke is okay, then bring the answer back to the useful product, link, or discovery step without pretending WIZWIKI sells something it does not.
    Do not dodge product/process comparison questions by asking for quantity, industry, budget, artwork, or company info first.
    If the latest inbound asks what a bundle includes, what they get for $299 vs $599, whether cards/hangers are included, or how much "they" cost after discussing signs/cards/hangers, give the full Starter Pack and Pro Pack comparison before any follow-up question.
    If the latest inbound asks whether Pro Pack or Starter Pack is better when they only need yard signs, answer directly: Yard Signs is the cleaner signs-only package; Pro/Starter bundles add business cards and door hangers and only fit better if they want those extras.
    If the latest inbound asks what other print products WIZWIKI offers, answer the product question first. Mention practical print pieces such as business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials when relevant. Do not default straight into Starter/Pro unless the fixed bundle clearly fits.
    If the latest inbound is a messy or custom print request with unclear sizes, quantities, or product mix, answer what can be answered and offer a marketing consultant to go over the details. Do not force a checkout link.
    If the latest inbound asks direct-mail strategy, route/list targeting, software setup, or what would work best for their business, give one grounded high-level recommendation from known context and explain the practical tradeoff. Offer a human marketing consultant for account-specific routes, lists, forecasts, setup, or unsupported details.
    If the customer compares postcards/direct mail with signs and asks what to start with, choose a starting move and explain why. Do not hedge with only "we can do both"; use the second channel as reinforcement when that is the practical strategy.
    If the current product is Yard Signs and the latest inbound asks for options, choices, quantities, tiers, prices, or pricing, answer with the Yard Signs options from product data before asking anything else. Include several listed 18x24 quantity tiers with prices and mention what is included when supplied, such as stakes, shipping, and design. Do not re-ask quantity before answering, and do not jump straight to checkout unless the customer clearly asks to order or wants the link.
    If the first outbound, lead source, current product, or latest customer intent is Yard Signs, start in yard signs. Do not open with "postcards, yard signs, or both" unless the lane is truly unknown.
    For yard-sign options/pricing, write customer-facing copy like "For 18x24 yard signs, the options are..." Never write "the yard sign ladder I see," "the options I see," "from product data," or any phrase that sounds like the system is reading a table.
    #{current_specials_prompt_instruction || "No promotional special is active. Never describe an expired offer as current or active."}
    Start from the current product lane, but do not permanently lock the customer there. If the latest inbound clearly asks about postcards, EDDM, Neighborhood Blitz, bundles, or another product, follow that current intent.
    Use sms_skills as procedural playbooks for recurring workflows: yard-sign lane keeping, exact pricing, checkout links, artwork/proof confidence, turnaround/rush, product switching, and reset hygiene. Pick the relevant skill for the latest customer message; do not copy it verbatim.
    Use sms_examples as pattern training for hard cases like lane switching, one-sign unit math, no-ghost recovery, specials, design process, and STOP handling. Do not copy examples verbatim unless the exact wording is still the best fresh answer.
    If the latest inbound compares EDDM and Neighborhood Blitz, answer both lanes: EDDM is mail-only postcards by route; Neighborhood Blitz is the fuller mail-plus-visibility push with pieces like signs, door hangers, rack cards, or job-area materials.
    If the latest inbound asks for all options, packages, or deals with prices, the entire SMS job is the price comparison. Do not say thank you, do not close the conversation, and do not send only one checkout link. Compare the standard options you can price first.
    Use product prices, quantities, timing, links, and fine-training examples only when they are supplied in the JSON.
    Use unit_pricing_guide only as support math. Default to package totals. Mention per-unit pricing only when the customer explicitly asks "each/per unit/per sign" or is bantering about one or two units; do not imply WIZWIKI sells one or two if the listed package minimum is higher.
    Fine-training examples are inspiration, not a script. Create a fresh, sales-friendly SMS for this specific lead and thread.
    Vary sentence shape and rhythm using style_variation from the JSON. Do not reuse openings, sentence frames, or exact questions from recent_outbound_texts or recent_unsent_drafts.
    If you need the same missing field as a prior draft, ask it in a different human way tied to the customer's latest words.
    Take a genuine discovery approach: learn what they want to accomplish, ask one practical fit question, then recommend the best link when there is enough signal.
    When the factual answer is complete but product fit or discovery is still incomplete, keep discovery alive with one natural follow-up tied to product use, quantity, reach, artwork, or campaign goal.
    Do not ask again for known budget, quantity, homes/reach, artwork/logo status, name, or company.
    Product interest alone is not checkout-ready. If the customer only chose postcards, signs, or both, ask one useful discovery question before sending a Shopify link.
    If the customer wants more reach or quantity than one Starter Pack includes, answer with the listed package options first. A few Starter Pack bundles can be a great deal, Pro Pack may fit better, and custom larger-volume specials can be checked if the customer wants that. Do not promise or approve any discount.
    If the customer asks whether supplying their own art, logo, design, or files creates a discount, answer directly: no automatic discount from the listed checkout price unless product data says so. Explain that their art helps the intake/proof path and can be used across the run, then mention larger-volume specials only as optional.
    If the customer presses for a custom, exact, bulk, unlisted, off-menu, or outside-the-deal quantity or price, do not invent pricing or force the wrong checkout link. Explain what standard pricing you can stand behind, then offer AM help only as an option unless the customer asks for a person, is frustrated, or the product data truly cannot answer.
    If product interest and quantity are known but business/campaign context is missing, ask only what kind of business or campaign this is for.
    If a product fit and one fit signal are known, recommend the best offer and put the best Shopify URL last with no punctuation after it.
    If the customer wants more than one product path, especially postcards plus yard signs, you may offer two or three relevant Shopify links in one compact compare SMS. Label each link plainly and keep the final character of the SMS as the last URL.
    For postcard, mailer, EDDM, or design conversations, naturally mention that WIZWIKI has an easy-to-use AI postcard/art builder when it helps the customer feel confident about creative.
    If the customer asks whether they need a finished design or whether WIZWIKI can create/clean up artwork, prefer this shape: they do not need a finished design; the customer completes checkout first; after checkout the design team sends the intake/proof path to the checkout email; the customer uploads images, logo, wording, colors, notes, and files there; if they have artwork, WIZWIKI can use it or clean it up; if not, WIZWIKI has an easy-to-use AI postcard/art builder and in-house designers who can create the design work; nothing prints until proof approval; then ask one practical product-use question when useful.
    Normal design, proofing, logo upload, artwork, and payment-before-artwork questions are buyer-confidence moments, not default AM handoffs. Answer them directly from design_process in the JSON.
    For those questions explain the order path: the customer places the order first; after checkout the design team sends an intake form to the checkout email; the customer uploads images, logo, wording, colors, layout notes, and any existing artwork there; PDF/vector files are best when available; the team creates or reviews the proof; the customer can request changes; nothing prints until proof approval; payment starts the order/design queue and does not mean WIZWIKI prints blindly.
    If a link was already sent and the customer asks where to design, where to upload a logo, why payment comes first, or whether they can see proof before print, do not just repeat the link or route away. Acknowledge the confusion, explain the process, reassure them that proof approval happens before print, then guide them back to checkout as the next step.
    Do not offer a human as the default ending after a design-process explanation. Hand off only when the customer explicitly asks for a person, is still confused after the process was explained, has a complex/unusual design or order situation, has a larger consultative order, keeps asking for an exception such as a proof before payment, or seems uncomfortable after the explanation.
    If handoff is needed, frame it as help understanding the order path. Do not imply the teammate will create a proof before payment, bypass checkout, or do unpaid design work. Never promise specific delivery dates, invented pricing, discounts, options, or collect payment info in chat.
    If handoff is needed, ask how or when they prefer to be contacted. Never use teammate last names.
    Silently grade the finished draft for direct answer, complete unread stack, factual grounding, Thumper voice, fresh wording, and one-question maximum. Rewrite before returning if it fails. Never mention this self-check.

    OPERATOR PROMPT:
    #{@operator_prompt.presence || "(blank - generate a fresh alternate)"}

    If OPERATOR PROMPT is present, treat it as the human operator's direct rewrite instruction. Follow it unless it asks for unsafe, invented, or non-customer-facing content. Do not copy, quote, summarize, or restate the OPERATOR PROMPT as instructions. Convert it into the actual customer-facing SMS. Never output instruction phrases such as "Apologize for...", "mention...", "reconnect to...", "ask at most...", or "follow the operator instruction." The full CONTEXT JSON is supplied separately with this worker job; use that context as authority for the SMS thread, product fit, links, and current draft.
  PROMPT
end

def cloud_sms_context_prompt
  <<~PROMPT
    Use the following live conversation and retrieved training context as factual authority.
    Produce the next SMS now; do not describe this context or these instructions.

    CONTEXT JSON:
    #{JSON.generate(alice_context_payload)}
  PROMPT
end

def ollama_draft
      return { "error" => "local draft model disabled" } unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_DRAFT_LLM_ENABLED", "1"))

      base = URI.parse(ENV["WIZWIKI_COMMS_DRAFT_URL"].presence || ENV["WIZWIKI_COMMS_SELECTOR_URL"].presence || ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434")
      uri = URI.join(base.to_s.chomp("/") + "/", "api/generate")
      model = writer_model
      payload = {
        model: model,
        stream: false,
        format: "json",
        options: {
          temperature: manual_regeneration_prompt? ? 0.68 : (@operator_prompt.present? ? 0.45 : 0.55),
          top_p: 0.9,
          repeat_penalty: 1.14
        },
        prompt: [alice_prompt(json_output: true), cloud_sms_context_prompt].join("\n\n")
      }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: local_ollama_read_timeout) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        http.request(request)
      end
      return { "error" => "local draft model returned HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      parsed = parse_model_response(body["response"])
      sms = sanitize_sms(parsed["body"].presence || parsed["sms"].presence || body["response"])
      requires_am_support = support_rag_profile? ? false : am_support_required_for_latest_inbound?
      sms = account_manager_answer_needed_reply if requires_am_support && !am_support_reply_sendable?(sms)
      return { "error" => "local draft model returned empty SMS", "provider" => "ollama/local", "model" => body["model"].presence || model } if sms.blank?

      {
        "body" => sms,
        "provider" => "ollama/local",
        "model" => body["model"].presence || model,
        "writer_model" => model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => requires_am_support ? "rewritten" : "passed",
        "draft_source" => requires_am_support ? "thumper_guardrail" : "thumper",
        "reason" => parsed["reason"].to_s.squish.presence || rewrite_reason,
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence
      }.merge(am_support_required_metadata(requires_am_support)).compact_blank
    rescue StandardError => error
      {
        "provider" => "ollama/local",
        "model" => writer_model,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "error" => "#{error.class}: #{error.message}"
      }
    end

    def writer_model
      @writer_model
    end

    def rag_profile
      @rag_profile
    end

    def support_rag_profile?
      rag_profile.to_h["kind"].to_s == "support"
    end

    def local_ollama_read_timeout
      ENV.fetch("WIZWIKI_COMMS_DRAFT_READ_TIMEOUT", "180").to_i.clamp(30, 240)
    end

    def cloud_writer?
      WizwikiSettings.sms_writer_cloud_provider(writer_model).present?
    end

    def cloud_draft
      return openai_cloud_draft if WizwikiSettings.sms_writer_cloud_provider(writer_model) == "openai"
      return nvidia_cloud_draft if WizwikiSettings.sms_writer_cloud_provider(writer_model) == "nvidia"

      { "error" => "Unsupported cloud SMS writer #{writer_model}" }
    end

    def cloud_draft_with_repair
      draft = cloud_draft
      return draft if acceptable_draft?(draft)

      reason = draft.to_h["error"].presence || sms_quality_rejection_reason(draft.to_h["body"]).presence
      return draft if reason.blank? || draft.to_h["body"].to_s.squish.blank?
      return draft unless guardrail_retryable_rejection?(reason)

      repaired = cloud_self_repair_draft(reason, draft.to_h["body"])
      acceptable_draft?(repaired) ? repaired : draft
    end

    def cloud_self_repair_draft(reason, rejected_body)
      previous_instruction = @guardrail_retry_instruction
      feedback = guardrail_retry_quality_feedback(reason)
      @guardrail_retry_instruction = [
        "The prior draft failed the pre-send gate for #{reason}.",
        numbered_open_customer_requirements_instruction,
        feedback,
        "Rewrite from scratch in Thumper's practical marketing-consultant voice.",
        "Answer the active customer question in sentence one, use current facts only, and ask at most one useful next question.",
        "Treat the prior draft as a negative example and do not reuse its opening or closing: #{rejected_body.to_s.squish.first(180)}"
      ].compact_blank.join(" ")
      repaired = cloud_draft
      repaired.to_h.merge(
        "self_repaired" => true,
        "self_repair_reason" => reason.to_s,
        "rejected_body_sha1" => Digest::SHA1.hexdigest(rejected_body.to_s),
        "sms_generation_pipeline" => "single_writer_guardrailed_self_repair",
        "sms_quality_gate" => "self_repaired"
      ).compact_blank
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] cloud self-repair failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      nil
    ensure
      @guardrail_retry_instruction = previous_instruction
    end

    def numbered_open_customer_requirements_instruction
      requirements = open_customer_reply_requirements_payload.select { |requirement| requirement[:answer_required] }.last(8)
      lines = requirements.map do |requirement|
        customer_text = requirement[:body].to_s.squish.first(180)
        answer_hint = requirement[:answer_hint].to_s.squish.first(360)
        [
          "Requirement #{requirement[:position]}: answer '#{customer_text}'.",
          answer_hint.present? ? "Verified guidance: #{answer_hint}" : nil
        ].compact.join(" ")
      end
      return if lines.blank?

      [
        "Before asking a follow-up, satisfy every numbered requirement below in the same SMS.",
        lines.join(" ")
      ].join(" ")
    end

    def local_cloud_fallback_draft(error)
      return unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_CLOUD_SMS_LOCAL_FALLBACK_ENABLED", "1"))

      fallback_model = local_cloud_fallback_model
      return if fallback_model.blank?

      local_writer = self.class.new(
        stage: @stage.reload,
        user: @user || @stage.user,
        operator_prompt: @operator_prompt,
        wait_seconds: @wait_seconds,
        writer_model: fallback_model,
        copilot: @copilot,
        guardrail_retry_instruction: @guardrail_retry_instruction
      )
      result = local_writer.send(:ollama_draft)
      unless local_writer.send(:acceptable_draft?, result)
        reason = result.to_h["error"].presence || local_writer.send(:sms_quality_rejection_reason, result.to_h["body"]).presence || "local_cloud_fallback_rejected"
        result = local_writer.send(:stack_recovery_guardrail_draft, reason) || local_writer.send(:fallback_draft, reason)
      end

      body = safe_persisted_sms_body(result.to_h["body"])
      return if body.blank?
      return unless local_writer.send(:acceptable_sms_body?, body, include_drafts: false) || local_writer.send(:fallback_sms_sendable?, body)

      result.to_h.merge(
        "body" => body,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "cloud_fallback" => true,
        "cloud_failure_reason" => error.to_s.squish.presence,
        "primary_writer_model" => writer_model,
        "primary_writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "fallback_writer_model" => fallback_model,
        "fallback_writer_model_label" => WizwikiSettings.sms_writer_model_label(fallback_model),
        "reason" => [
          result.to_h["reason"].to_s.squish.presence,
          "Primary cloud SMS writer failed; local Qwen generated a validated fallback draft."
        ].compact.join(" ")
      ).compact_blank
    rescue StandardError => fallback_error
      Rails.logger.warn("[CommsDraftWriter] local cloud SMS fallback failed stage=#{@stage&.id} #{fallback_error.class}: #{fallback_error.message}")
      nil
    end

    def local_cloud_fallback_model
      candidates = [
        ENV["WIZWIKI_COMMS_CLOUD_SMS_FALLBACK_MODEL"].presence,
        WizwikiSettings.default_sms_writer_model,
        "qwen3:30b"
      ].compact

      candidates.each do |candidate|
        normalized = WizwikiSettings.normalize_sms_writer_model(candidate)
        return normalized if normalized.present? && WizwikiSettings.sms_writer_cloud_provider(normalized).blank?
      end

      nil
    end

    def openai_cloud_draft
      raise "OpenAI SMS writer is not configured" unless WizwikiSettings.sms_writer_cloud_configured?(writer_model)

      payload = Autos::OpenaiClient.call(instructions: alice_prompt(json_output: true), input_text: cloud_sms_context_prompt)
      parsed = parse_model_response(Autos::OpenaiClient.extract_text(payload))
      sms = sanitize_sms(parsed["body"].presence || parsed["sms"].presence || Autos::OpenaiClient.extract_text(payload))
      requires_am_support = support_rag_profile? ? false : am_support_required_for_latest_inbound?
      sms = account_manager_answer_needed_reply if requires_am_support && !am_support_reply_sendable?(sms)
      return { "error" => "OpenAI SMS writer returned empty SMS", "provider" => "openai", "model" => payload["model"].presence || WizwikiSettings.sms_writer_cloud_model(writer_model) } if sms.blank?

      {
        "body" => sms,
        "provider" => "openai",
        "model" => payload["model"].presence || WizwikiSettings.sms_writer_cloud_model(writer_model),
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => requires_am_support ? "rewritten" : "passed",
        "draft_source" => requires_am_support ? "thumper_guardrail" : "thumper",
        "reason" => parsed["reason"].to_s.squish.presence || rewrite_reason,
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence
      }.merge(am_support_required_metadata(requires_am_support)).compact_blank
    rescue StandardError => error
      {
        "provider" => "openai",
        "model" => WizwikiSettings.sms_writer_cloud_model(writer_model),
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "error" => "#{error.class}: #{error.message}"
      }.compact_blank
    end

    def nvidia_cloud_draft
      api_key = nvidia_sms_api_key
      raise "#{background_writer_label} SMS writer is not configured" if api_key.blank?

      base = URI.parse(nvidia_sms_base_url)
      uri = URI.join(base.to_s.chomp("/") + "/", "chat/completions")
      model = WizwikiSettings.sms_writer_cloud_model(writer_model)
      compact_dojo_prompt = recursive_dojo_compact_cloud_prompt?
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      payload = {
        model: model,
        temperature: manual_regeneration_prompt? ? 0.72 : (@operator_prompt.present? ? 0.62 : 0.55),
        top_p: 0.9,
        max_tokens: compact_dojo_prompt ? 260 : 360,
        messages: [
          { role: "system", content: compact_dojo_prompt ? recursive_dojo_compact_alice_prompt : alice_prompt(json_output: true) },
          { role: "user", content: compact_dojo_prompt ? recursive_dojo_compact_prompt : cloud_sms_context_prompt }
        ]
      }
      if model.to_s.include?("nemotron")
        payload[:chat_template_kwargs] = { enable_thinking: false }
        payload[:reasoning_budget] = 0
      end
      request.body = JSON.generate(payload)

      read_timeout = nvidia_sms_read_timeout_seconds
      open_timeout = nvidia_sms_open_timeout_seconds
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: open_timeout, read_timeout: read_timeout) do |http|
        http.request(request)
      end
      body = JSON.parse(response.body.presence || "{}")
      raise(body.dig("error", "message").presence || "NVIDIA SMS writer returned HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      raw = body.dig("choices", 0, "message", "content").to_s
      parsed = parse_model_response(raw)
      sms = sanitize_sms(parsed["body"].presence || parsed["sms"].presence || raw)
      requires_am_support = support_rag_profile? ? false : am_support_required_for_latest_inbound?
      sms = account_manager_answer_needed_reply if requires_am_support && !am_support_reply_sendable?(sms)
      return { "error" => "NVIDIA SMS writer returned empty SMS", "provider" => "nvidia", "model" => body["model"].presence || model } if sms.blank?

      {
        "body" => sms,
        "provider" => "nvidia",
        "model" => body["model"].presence || model,
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => requires_am_support ? "rewritten" : "passed",
        "draft_source" => requires_am_support ? "thumper_guardrail" : "thumper",
        "reason" => parsed["reason"].to_s.squish.presence || rewrite_reason,
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence
      }.merge(am_support_required_metadata(requires_am_support)).compact_blank
    rescue StandardError => error
      {
        "provider" => "nvidia",
        "model" => WizwikiSettings.sms_writer_cloud_model(writer_model),
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "error" => "#{error.class}: #{error.message}"
      }.compact_blank
    end

    def nvidia_sms_api_key
      if writer_model.to_s == "nvidia:warp"
        ENV["WIZWIKI_WARP_GPU_API_KEY"].presence ||
          ENV["WIZWIKI_WARP_NVIDIA_API_KEY"].presence ||
          ENV["NVIDIA_API_KEY"].presence ||
          ENV["WIZWIKI_NVIDIA_API_KEY"].presence
      else
        ENV["NVIDIA_API_KEY"].presence || ENV["WIZWIKI_NVIDIA_API_KEY"].presence
      end
    end

    def nvidia_sms_base_url
      if writer_model.to_s == "nvidia:warp"
        WizwikiSettings.warp_gpu_base_url.presence || raise("WARP rented GPU base URL is not configured")
      else
        ENV["WIZWIKI_NEMOTRON_SMS_BASE_URL"].presence ||
          ENV["WIZWIKI_COMMS_NEMOTRON_BASE_URL"].presence ||
          ENV["WIZWIKI_COMMS_NVIDIA_BASE_URL"].presence ||
          ENV["NVIDIA_BASE_URL"].presence ||
          "https://integrate.api.nvidia.com/v1"
      end
    end

    def nvidia_sms_read_timeout_seconds
      if writer_model.to_s == "nvidia:warp"
        ENV.fetch("WIZWIKI_WARP_GPU_READ_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_READ_TIMEOUT_SECONDS", "35")).to_i.clamp(8, 120)
      else
        ENV.fetch("WIZWIKI_NEMOTRON_SMS_READ_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_READ_TIMEOUT_SECONDS", "75")).to_i.clamp(8, 120)
      end
    end

    def nvidia_sms_open_timeout_seconds
      if writer_model.to_s == "nvidia:warp"
        ENV.fetch("WIZWIKI_WARP_GPU_OPEN_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_OPEN_TIMEOUT_SECONDS", "8")).to_i.clamp(2, 30)
      else
        ENV.fetch("WIZWIKI_NEMOTRON_SMS_OPEN_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_OPEN_TIMEOUT_SECONDS", "8")).to_i.clamp(2, 30)
      end
    end

    def parse_model_response(value)
      text = strip_thinking_markup(value)
      text = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      JSON.parse(text)
    rescue JSON::ParserError
      { "body" => text }
    end

    def draft_validator
      @draft_validator ||= ::Comms::DraftValidator.new(context: self, max_sms_chars: MAX_SMS_CHARS)
    end

    def acceptable_draft?(draft)
      body = draft.to_h["body"].to_s.squish
      return support_sms_quality_rejection_reason(body).blank? if support_rag_profile?

      sms_quality_rejection_reason(body).blank?
    end

    def acceptable_sms_body?(body, include_drafts: true)
      return support_sms_quality_rejection_reason(body).blank? if support_rag_profile?

      sms_quality_rejection_reason(body, include_drafts: include_drafts).blank?
    end

    def support_draft_acceptable?(draft)
      support_sms_quality_rejection_reason(draft.to_h["body"]).blank?
    end

    def support_sms_quality_rejection_reason(body)
      text = body.to_s.squish
      return "support_sms_blank" if text.blank?
      return "support_sms_too_long" if text.length > MAX_SMS_CHARS
      return "support_sms_internal_leak" if analysis_leak?(text) || internal_context_fragment?(text)
      if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)
        return "support_sms_internal_leak"
      end
      if text.match?(/\b(?:i|we)\s+(?:sent|transferred|claimed|entered|placed|paid|refunded|changed)\b.{0,45}\b(?:coin|airdrop|wager|bet|transaction|payment|refund|order|account|transfer)\b/i)
        return "support_sms_unsafe_transaction_claim"
      end

      nil
    end

    def sms_quality_rejection_reason(body, include_drafts: true)
      return "mailbox_product_choice_missing_postcards" if mailbox_product_choice_missing_postcards?(body)
      return "direct_mail_strategy_reply_missing_handoff" if direct_mail_strategy_reply_missing_handoff?(body)
      return "marketing_channel_recommendation_missing" if marketing_channel_recommendation_missing?(body)
      return "broad_direct_mail_checkout_before_ready" if broad_direct_mail_checkout_before_ready?(body)
      return "stacked_yard_sign_price_process_missing" if stacked_yard_sign_price_process_missing?(body)
      return "turnaround_answer_missing" if latest_rush_or_turnaround_question? && !turnaround_answer_for_inbound?(body, latest_inbound_sms)
      return "print_products_answer_missing" if latest_print_products_question? && !print_products_answer_for_inbound?(body, latest_inbound_sms)
      return "asks_for_known_fit_field" if asks_for_known_fit_field?(body)
      return "missing_requested_product_context" if bundle_artwork_answer_wrong_for_current_lane?(body)
      return nil if stacked_business_card_link_package_answer?(body)
      return nil if open_customer_stack_link_answer_sendable?(body)
      return nil if latest_direct_process_answer_sendable?(body) && !misses_open_customer_messages?(body)
      return "misses_open_customer_messages" if misses_open_customer_messages?(body)
      return "signs_only_reply_against_mail_or_both_intent" if signs_only_reply_against_mail_or_both_intent?(body)
      return "missing_requested_product_context" if missing_requested_product_context?(body, latest_inbound_sms)
      return "price_only_question_with_checkout_url" if price_only_question_with_checkout_url?(body, latest_inbound_sms)
      return "unsolicited_yard_sign_quantity_checkout_url" if unsolicited_yard_sign_quantity_checkout_url?(body, latest_inbound_sms)
      return nil if price_only_pricing_answer_without_checkout_url?(body, latest_inbound_sms)
      return nil if yard_sign_quantity_acknowledgement_sendable?(body, latest_inbound_sms)
      return nil if route_link_answer_has_required_fit?(body)
      return nil if scenario_direct_answer_sendable?(body)

      draft_validator.rejection_reason(body, include_drafts: include_drafts)
    end

    def mailbox_product_choice_missing_postcards?(body)
      text = body.to_s.squish
      return false unless text.match?(/\bmailboxes?\b/i)
      return false if text.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail)\b/i)

      text.match?(/\b(?:yard\s+)?signs?\b/i) &&
        (text.include?("?") || text.match?(/\b(?:both|either|or|which|lean)\b/i))
    end

    def scenario_direct_answer_sendable?(body)
      text = body.to_s.squish
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || internal_context_fragment?(text)
      return false if repeated_recent_outbound?(text) || repetitive_thread_response?(text)
      return false if stale_latest_pivot_reply?(text) || wrong_route_shopify_link?(text)
      return false if bundle_artwork_answer_wrong_for_current_lane?(text)
      return false if premature_closing_reply?(text)
      return false if latest_rush_or_turnaround_question? && !turnaround_answer_for_inbound?(text, latest_inbound_sms)
      return false if latest_print_products_question? && !print_products_answer_for_inbound?(text, latest_inbound_sms)

      pricing_answer_for_inbound?(text, latest_inbound_sms) ||
        yard_sign_quantity_reply_sendable?(text) ||
        multi_product_link_reply_sendable?(text) ||
        direct_checkout_link_reply_sendable?(text) ||
        design_process_reply_sendable?(text) ||
        proof_handoff_reply_sendable?(text) ||
        eddm_neighborhood_blitz_reply_sendable?(text) ||
        clarification_reply_sendable?(text) ||
        print_products_reply_sendable?(text) ||
        consultant_handoff_reply_sendable?(text) ||
        (turnaround_question?(latest_inbound_sms) && turnaround_answer_for_inbound?(text, latest_inbound_sms)) ||
        ((design_process_question?(latest_inbound_sms) || artwork_creation_followup_request?(latest_inbound_sms)) && artwork_creation_help_answer?(text))
    end

    def latest_direct_process_answer_sendable?(body)
      text = body.to_s.squish
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || internal_context_fragment?(text)
      return false if repeated_recent_outbound?(text) || repetitive_thread_response?(text)
      return false if stale_latest_pivot_reply?(text) || wrong_route_shopify_link?(text)
      return false if bundle_artwork_answer_wrong_for_current_lane?(text)
      return false if premature_closing_reply?(text)
      return false if stacked_yard_sign_price_process_missing?(text)
      return false if latest_rush_or_turnaround_question? && !turnaround_answer_for_inbound?(text, latest_inbound_sms)
      return false if latest_print_products_question? && !print_products_answer_for_inbound?(text, latest_inbound_sms)

      design_process_reply_sendable?(text) ||
        proof_handoff_reply_sendable?(text) ||
        clarification_reply_sendable?(text) ||
        print_products_reply_sendable?(text) ||
        consultant_handoff_reply_sendable?(text) ||
        (turnaround_question?(latest_inbound_sms) && turnaround_answer_for_inbound?(text, latest_inbound_sms)) ||
        ((design_process_question?(latest_inbound_sms) || artwork_creation_followup_request?(latest_inbound_sms)) && artwork_creation_help_answer?(text))
    end

    def repeated_draft?(body)
      draft_validator.repeated_draft?(body)
    end

    def checkout_before_ready?(body)
      return true if price_only_question_with_checkout_url?(body, latest_inbound_sms)
      return true if unsolicited_yard_sign_quantity_checkout_url?(body, latest_inbound_sms)
      return true if broad_direct_mail_checkout_before_ready?(body)
      return true if latest_rush_or_turnaround_question? && body.to_s.match?(%r{https?://})
      return false if route_link_answer_has_required_fit?(body)

      draft_validator.checkout_before_ready?(body)
    end

    def link_ready_without_link?(body)
      draft_validator.link_ready_without_link?(body)
    end

    def route_link_answer_has_required_fit?(body)
      text = body.to_s.squish
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || premature_closing_reply?(text)
      return false if wrong_route_shopify_link?(text)
      return false if price_only_question_with_checkout_url?(text, latest_inbound_sms)
      return false if unsolicited_yard_sign_quantity_checkout_url?(text, latest_inbound_sms)

      route = checkout_request_route(latest_inbound_sms).presence || current_route_code.presence || inferred_product_route_from_fit
      route = route.to_s
      return false if route.blank?

      link = route_specific_shopify_link(route).to_s
      return false if link.blank? || fallback_shopify_link?(route, link)
      return false unless text.include?(link)
      return false if starter_pack_over_limit?(route)
      return true if direct_checkout_link_request?(latest_inbound_sms) && checkout_request_route(latest_inbound_sms).to_s == route.to_s

      fit = campaign_fit_payload
      return false if low_budget_signal?(fit[:budget])
      return true if usable_budget_signal?(fit[:budget])
      return true if buyer_accepts_recent_recommendation?(route)

      case route
      when "LAWN_SIGNS"
        fit[:quantity_count].present?
      when "EDDM", "NEIGHBORHOOD_BLITZ"
        fit[:household_count].present?
      when "PRO_PACK", "STARTER_PACK"
        fit[:household_count].present? || fit[:quantity_count].present?
      else
        fit[:household_count].present? || fit[:quantity_count].present?
      end
    end

    def normalize_draft_text(text)
      draft_validator.normalize_draft_text(text)
    end

    def support_fallback_draft(error = nil)
      body = if latest_inbound_sms.to_s.squish.present?
        "I couldn't verify that from the selected knowledge base. I can have an operator confirm it."
      else
        "What would you like help with? I'll use the selected knowledge base and route anything unverified to an operator."
      end

      {
        "body" => body,
        "provider" => "local/support_fallback",
        "model" => "support_rag_safe_fallback",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "rag_profile" => rag_profile.fetch("key"),
        "rag_profile_label" => rag_profile.fetch("label"),
        "rag_scope" => rag_profile.fetch("scope"),
        "sms_generation_pipeline" => "selected_rag_guardrailed",
        "sms_quality_gate" => "safe_fallback",
        "draft_source" => "rag_support_fallback",
        "reason" => "The selected knowledge profile could not produce a verified answer, so the safe operator-handoff fallback was used.",
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.squish.presence
      }.compact_blank
    end

    def fallback_draft(error)
      return support_fallback_draft(error) if support_rag_profile?

      contact_name = selected_contact["name"].to_s.squish.presence
      company = company_name
      inbound = latest_inbound_sms
      must_answer = must_answer_reply_for(inbound)
      body = if must_answer.present? && @operator_prompt.blank?
        must_answer
      elsif @operator_prompt.present? && !webhook_auto_prompt?
        fallback_operator_rewrite(inbound)
      elsif proof_handoff_request?(inbound)
        fallback_reply_to_inbound(inbound)
      elsif inbound.present? && latest_sms_event.to_h["direction"].to_s == "inbound"
        fallback_reply_to_inbound(inbound)
      elsif unanswered_outbound_question?
        unanswered_question_follow_up
      elsif inbound.present?
        fallback_reply_to_inbound(inbound)
      elsif @operator_prompt.present?
        Thumper::VoiceGuide.starter_sms(contact_name.presence || company, product_lane: opening_offer_product_lane)
      else
        opening_offer
      end

      sanitized_body = sanitize_sms(body)
      sanitized_body = fallback_recovery_body(sanitized_body) unless fallback_sms_sendable?(sanitized_body)
      proof_handoff = proof_handoff_request?(inbound)
      requires_am_support = proof_handoff || am_support_required_for_latest_inbound?
      numeric_context_guardrail = deterministic_numeric_context_guardrail_body?(sanitized_body, inbound)
      route_guardrail = numeric_context_guardrail || deterministic_route_guardrail_body?(sanitized_body) || marketing_channel_comparison_answer?(sanitized_body) || requires_am_support
      unless route_guardrail || soft_deterministic_fallbacks_enabled?
        return no_soft_fallback_draft(error)
      end

      reason = if requires_am_support
        proof_handoff ? "Thumper guardrail routed the proof/design handoff to AM support." : "Thumper guardrail routed a true support request to AM support."
      elsif numeric_context_guardrail
        "Thumper numeric context guardrail used the customer's count and advanced the known product lane after the writer fallback."
      elsif route_guardrail
        "Thumper deterministic guardrail used the current route and SMS thread after the writer fallback."
      else
        rewrite_reason
      end

      {
        "body" => sanitized_body,
        "provider" => route_guardrail ? "local/guardrail" : "local/fallback",
        "model" => route_guardrail ? "deterministic_route_guardrail" : "deterministic",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => route_guardrail ? "rewritten" : "fallback",
        "draft_source" => route_guardrail ? "thumper_guardrail" : "fallback",
        "reason" => reason,
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.presence
      }.merge(
        am_support_required_metadata(
          requires_am_support,
          reason: proof_handoff ? "proof_design_handoff" : nil,
          source: proof_handoff ? "proof_design_guardrail" : nil
        )
      ).compact_blank
    end

    def soft_deterministic_fallbacks_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["WIZWIKI_COMMS_SOFT_FALLBACKS_ENABLED"])
    end

    def no_soft_fallback_draft(error)
      {
        "body" => nil,
        "provider" => "local/guardrail",
        "model" => "writer_required_no_soft_fallback",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "rejected",
        "draft_source" => "writer_required",
        "reason" => "The configured writer did not produce a safe SMS draft, and soft deterministic fallbacks are disabled.",
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.presence
      }.compact_blank
    end

    def rejected_worker_recovery_draft(error)
      body = rejected_worker_recovery_body
      return fallback_draft(error) if body.blank?

      {
        "body" => sanitize_sms(body),
        "provider" => "local/guardrail",
        "model" => "deterministic_rejected_worker_recovery",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "rewritten",
        "draft_source" => "thumper_guardrail",
        "reason" => "Worker answer rejected; fast route guardrail used persisted route, fit, and checkout link.",
        "conversation_state" => @metadata["comms_bot_state"],
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.presence
      }.compact_blank
    end

    def rejected_worker_recovery_body
      metadata = @stage.reload.metadata.to_h
      state = metadata["comms_bot_state"].to_h
      route = metadata["product_interest_code"].presence || state["route_code"].presence
      label = metadata["product_interest_label"].presence || state["route_label"].presence || route.to_s.titleize.presence
      link = metadata["shopify_link"].to_s.squish.presence
      fit = state["campaign_fit"].to_h
      household_count = fit["household_count"].to_s.squish.presence
      quantity_count = fit["quantity_count"].to_s.squish.presence

      case route.to_s
      when "NEIGHBORHOOD_BLITZ"
        count_phrase = household_count.present? ? "For #{household_count}, " : ""
        parts = [
          "#{count_phrase}the Neighborhood Blitz package is the clearest fit for postcards plus local visibility.",
          "It keeps the campaign focused on the area you want to reach.",
          link.present? ? "Use this link when you are ready: #{link}" : "Do you already have artwork, or should WIZWIKI help create it?"
        ]
        parts.join(" ").squish
      when "LAWN_SIGNS"
        count_phrase = quantity_count.present? ? "For #{quantity_count}, " : ""
        [ "#{count_phrase}yard signs are the right signs-only path.", link.present? ? "Use this link when you are ready: #{link}" : "What quantity were you thinking?" ].join(" ").squish
      when "EDDM"
        count_phrase = household_count.present? ? "For #{household_count}, " : ""
        [ "#{count_phrase}EDDM is the clean mail-only postcard path.", link.present? ? "Use this link when you are ready: #{link}" : "Do you already know the neighborhood or carrier route?" ].join(" ").squish
      when "STARTER_PACK", "PRO_PACK"
        [ "#{label} is the better package fit from what you shared.", link.present? ? "Use this link when you are ready: #{link}" : "Do you already have artwork, or should WIZWIKI help create it?" ].join(" ").squish
      else
        return if link.blank?

        "#{label.presence || 'This package'} is the best fit from what you shared. Use this link when you are ready: #{link}".squish
      end
    end

    def fallback_sms_sendable?(body)
      return false if direct_mail_strategy_reply_missing_handoff?(body)
      return false if broad_direct_mail_checkout_before_ready?(body)
      return false if latest_rush_or_turnaround_question? && !turnaround_answer_for_inbound?(body, latest_inbound_sms)
      return false if latest_print_products_question? && !print_products_answer_for_inbound?(body, latest_inbound_sms)
      return false if price_only_question_with_checkout_url?(body, latest_inbound_sms)
      return true if pricing_answer_for_inbound?(body, latest_inbound_sms)
      return false if stale_latest_pivot_reply?(body)
      return false if repetitive_thread_response?(body)
      return false if yard_sign_price_conflict_for_guardrail?(body)
      return false if sold_out_shopify_link_in_text?(body)
      return false if prompt_style_preface?(body)
      return true if yard_sign_quantity_reply_sendable?(body)
      return false if yard_sign_quantity_reply_missing_price?(body)
      return true if multi_product_link_reply_sendable?(body)
      return true if direct_checkout_link_reply_sendable?(body)
      return true if design_process_reply_sendable?(body)
      return true if proof_handoff_reply_sendable?(body)
      return true if eddm_neighborhood_blitz_reply_sendable?(body)
      return true if clarification_reply_sendable?(body)
      return true if print_products_reply_sendable?(body)
      return true if stacked_business_card_link_package_answer?(body)
      return true if open_customer_stack_link_answer_sendable?(body)
      return true if mixed_postcards_signs_reply_sendable?(body)
      return true if consultant_handoff_reply_sendable?(body)

      acceptable_sms_body?(body, include_drafts: false)
    end

      def direct_checkout_link_reply_sendable?(body)
        text = body.to_s.squish
        return false unless direct_checkout_link_request?(latest_inbound_sms)
        return false if text.blank? || text.length > MAX_SMS_CHARS
        return false if analysis_leak?(text) || premature_closing_reply?(text) || repeated_recent_outbound?(text)
        return multi_product_link_reply_sendable?(text) if multi_product_link_request?(latest_inbound_sms)

        route = checkout_request_route(latest_inbound_sms)
        link = route_specific_shopify_link(route).to_s
        return false if route.blank? || link.blank?
        return false unless text.include?(link)
        return false if wrong_route_shopify_link?(text)
        confirmed_quantity = checkout_link_quantity_for(route, latest_inbound_sms)
        return false if route.to_s == "LAWN_SIGNS" && confirmed_quantity.present? && !text.match?(/\b#{Regexp.escape(confirmed_quantity.to_s)}\b/)

        true
      end

def design_process_reply_sendable?(body)
  text = body.to_s.squish
  return false unless design_process_question?(latest_inbound_sms)
  return false if text.blank? || text.length > MAX_SMS_CHARS
  return false if analysis_leak?(text) || repeated_recent_outbound?(text)
  return true if simple_proof_approval_question?(latest_inbound_sms) && proof_approval_answer?(text)
  if image_handling_process_question?(latest_inbound_sms)
    return false unless image_handling_process_answer?(text)
  end

  design_process_answer?(text)
    end

    def proof_handoff_reply_sendable?(body)
      text = body.to_s.squish
      return false unless proof_handoff_request?(latest_inbound_sms)
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || repeated_recent_outbound?(text)

      text.match?(/\bproofs?\b/i) &&
        text.match?(/\b(account manager|help with|contact|follow-up|follow up)\b/i) &&
        text.match?(/\b(email|text|call)\b/i)
    end

    def eddm_neighborhood_blitz_reply_sendable?(body)
      text = body.to_s.squish
      return false unless eddm_neighborhood_blitz_question?(latest_inbound_sms)
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || repeated_recent_outbound?(text)

      eddm_neighborhood_blitz_answer?(text)
    end

    def clarification_reply_sendable?(body)
      text = body.to_s.squish
      return false unless clarification_request?(latest_inbound_sms)
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || repeated_recent_outbound?(text)

      clarification_answer_for_inbound?(text, latest_inbound_sms)
    end

    def am_support_required_metadata(required = false, reason: nil, source: nil)
      return {} unless required

      {
        "requires_am_support" => true,
        "am_support_reason" => reason.presence || "support_requested_or_unanswerable_sms",
        "am_support_source" => source.presence || "thumper_support_guardrail"
      }
    end

    def safe_sms_body_for_autopilot?(body)
      fallback_sms_sendable?(body)
    end

    def yard_sign_quantity_reply_sendable?(body)
      return false unless current_route_code.to_s == "LAWN_SIGNS"
      return false unless yard_sign_quantity_context_present?

      text = body.to_s.squish
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || repeated_recent_outbound?(text)
      return false if premature_closing_reply?(text)
      return false unless text.match?(/\b(?:yard signs?|lawn signs?|signs?)\b/i)
      return true if conversational_quantity_follow_up?(text)

      text.match?(/\$\s?\d|closest|listed quantities|checkout tier|tier/i)
    end

    def yard_sign_quantity_acknowledgement_sendable?(body, inbound = latest_inbound_sms)
      text = body.to_s.squish
      inbound_body = inbound.to_s.squish
      return false if text.blank? || inbound_body.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || internal_context_fragment?(text)
      return false if repeated_recent_outbound?(text) || repetitive_thread_response?(text)
      return false if stale_latest_pivot_reply?(text) || wrong_route_shopify_link?(text)
      return false if premature_closing_reply?(text)
      return false if text.match?(%r{https?://|shop\.wizwikimarketing\.com}i) && !direct_checkout_link_request?(inbound_body)
      return false unless sign_interest?(inbound_body) || current_route_code.to_s == "LAWN_SIGNS" || pricing_route(inbound_body).to_s == "LAWN_SIGNS"

      quantity = exact_yard_sign_quantity_from_text(inbound_body)
      quantity ||= requested_quantities(inbound_body).then { |quantities| quantities.one? ? quantities.first : nil }
      return false if quantity.blank?
      return false unless text.match?(/\b#{Regexp.escape(quantity.to_s)}\b/)
      return false unless text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i)

      yard_sign_pricing_answer_for_inbound?(text, inbound_body)
    end

    def yard_sign_quantity_reply_missing_price?(body)
      return false unless current_route_code.to_s == "LAWN_SIGNS"
      return false unless yard_sign_quantity_context_present?

        text = body.to_s.squish
        return false if text.blank?
        return false if yard_sign_quantity_reply_sendable?(text)
        return false if direct_checkout_link_reply_sendable?(text)
        return false if conversational_quantity_follow_up?(text)

        text.match?(/\b(?:signs?|yard signs?|lawn signs?|covered|proceed|company)\b/i)
      end

    def yard_sign_quantity_context_present?
      inbound = latest_inbound_sms.to_s.squish
      return true if inbound.match?(/\A\d{1,6}\z/)
      return true if campaign_fit_payload[:quantity_count].present?

      exact_yard_sign_quantity_from_text(inbound).present?
    end

    def conversational_quantity_follow_up?(body)
      inbound = latest_inbound_sms.to_s.squish
      text = body.to_s.squish
      return false unless current_route_code.to_s == "LAWN_SIGNS"
      return false if text.blank? || text.length > MAX_SMS_CHARS
      return false if analysis_leak?(text) || repeated_recent_outbound?(text)
      return false if text.match?(/\b(?:checkout|link|tier|price|cost|\$\s?\d|listed quantities)\b/i)

      unless inbound.match?(/\A\d{1,6}\z/)
        return conversational_quantity_company_follow_up?(text)
      end

      return false unless text.match?(/\b(?:#{Regexp.escape(inbound)}|signs?|yard signs?|lawn signs?)\b/i)

      text.match?(/\b(?:first name|your name|company|business|campaign|what kind|save this conversation)\b/i)
    end

    def conversational_quantity_company_follow_up?(text)
      quantity = current_yard_sign_quantity_value
      return false unless quantity.positive?
      return false unless latest_inbound_looks_like_company_after_quantity?
      return false unless previous_outbound_asked_company_for_quantity?
      return false unless text.match?(/\b(?:#{Regexp.escape(quantity.to_s)}|signs?|yard signs?|lawn signs?)\b/i)

      text.match?(/\b(?:first name|your name|what'?s your name|what is your name)\b/i)
    end

    def latest_inbound_looks_like_company_after_quantity?
      inbound = latest_inbound_sms.to_s.squish
      return false if inbound.blank? || inbound.length > 90
      return false if inbound.match?(/[?@]/)
      return false if inbound.match?(/\b(?:yard\s+signs?|lawn\s+signs?|post\s*cards?|postcards?|bundle|price|cost|how much|checkout|link|proof|design|artwork|yes|no|maybe|both)\b/i)

      current_yard_sign_quantity_value.positive?
    end

    def previous_outbound_asked_company_for_quantity?
      sms_thread_events.reverse_each.first(6).any? do |event|
        body = event.to_h["body"].to_s.downcase.squish
        event.to_h["direction"].to_s == "outbound" &&
          body.match?(/\b(?:what company|company should i connect|company name|business name|connect this to|save this conversation)\b/)
      end
    end

    def current_yard_sign_quantity_value
      latest_quantity = exact_yard_sign_quantity_from_text(latest_inbound_sms).to_i
      return latest_quantity if latest_quantity.positive?

      quantity_text = campaign_fit_payload[:quantity_count].to_s
      quantity = quantity_text.scan(/\b\d{1,6}\b/).map(&:to_i).max.to_i
      return quantity if quantity.positive?

      sms_thread_events.reverse_each.first(8).filter_map do |event|
        next unless event.to_h["direction"].to_s == "inbound"

        body = event.to_h["body"].to_s
        next if body.match?(/[?@]/)

        body.scan(/\b\d{1,6}\b/).map(&:to_i).max
      end.compact.max.to_i
    end

    def fallback_recovery_body(original_body = nil)
      candidates = []
      inbound = latest_inbound_sms
      route = current_route_code
      artwork_followup = artwork_creation_followup_request?(inbound)
      candidates << stacked_open_messages_reply
      candidates << rush_checkout_boundary_guardrail_body(original_body)
      candidates << must_answer_reply_for(inbound)
      candidates << artwork_creation_help_reply(artwork_creation_route_for_inbound(inbound)) if artwork_followup
      candidates << original_body unless artwork_followup
      candidates << direct_checkout_link_reply(inbound) if direct_checkout_link_request?(inbound)
      candidates << multi_product_link_reply(inbound) if multi_product_link_request?(inbound)
      candidates << checkout_confusion_reply(route) if checkout_confusion_question?(inbound)
      candidates << neighborhood_blitz_best_deal_reply if neighborhood_blitz_best_deal_request?(inbound)
      candidates << bundle_composition_reply(inbound) if bundle_composition_question?(inbound)
      candidates << zip_code_follow_up_reply(inbound) if standalone_zip_code?(inbound)
      candidates << design_process_reply(route) if design_process_question?(inbound) && !proof_handoff_request?(inbound)
      candidates << proof_handoff_reply if proof_handoff_request?(inbound)
      candidates << eddm_neighborhood_blitz_reply if eddm_neighborhood_blitz_question?(inbound)
      candidates << neighborhood_blitz_contents_reply if neighborhood_blitz_contents_question?(inbound)
      candidates << clarification_reply_for_context(inbound) if clarification_request?(inbound)
      candidates << numeric_answer_follow_up if standalone_numeric_answer?(inbound) && route.present?
      candidates << quantity_company_follow_up(route) if route.present?
      candidates << identity_collection_reply if identity_payload[:missing].present?
      if route.present?
        candidates << business_context_question(route)
        candidates << next_route_fit_question(route)
        candidates << route_next_question(route)
      end
      candidates << product_direction_question
      candidates << unknown_reply

      candidates.compact_blank.each do |candidate|
        body = prepare_deterministic_fallback_body(candidate)
        return body if fallback_sms_sendable?(body)
      end

      prepare_deterministic_fallback_body(original_body)
    end

    def must_answer_reply_for(inbound)
      text = inbound.to_s.squish
      return if text.blank?

      stacked = stacked_open_messages_reply
      return stacked if stacked.present?

      return price_then_handoff_reply(text) if human_request?(text) && pricing_question?(text)
      return human_handoff_stack_reply if human_request?(text) || support_handoff_confirmation_request?(text)
      return turnaround_reply(text) if turnaround_question?(text) || rush_checkout_boundary_question?(text)
      if direct_checkout_link_request?(text)
        reply = direct_checkout_link_reply(text)
        return reply if reply.present?
      end

      return marketing_channel_comparison_reply if marketing_channel_comparison_question?(text)
      return direct_mail_strategy_handoff_reply if direct_mail_strategy_handoff_question?(text)
      return messy_print_consultant_reply if messy_print_consultant_question?(text)
      return standalone_print_product_quantity_reply(text) if standalone_print_product_quantity_followup?(text)
      return print_products_reply(text) if print_products_question?(text)
      return yard_sign_art_cost_reply if yard_sign_art_cost_question?(text)
      return yard_sign_included_items_reply(text) if yard_sign_included_items_question?(text) && pricing_question?(text)
      return yard_sign_pricing_reply(text) if signs_only_options_question?(text) || yard_sign_pricing_request?(text) || signs_only_pricing_question?(text)
      return pricing_reply(text) if pricing_question?(text)
      return yard_sign_included_items_reply(text) if yard_sign_included_items_question?(text)
      return yard_sign_cheapest_entry_reply(text) if yard_sign_cheapest_package_question?(text)
      return cheapest_overall_pricing_reply(text) if cheapest_overall_pricing_question?(text)
      return unit_pricing_reply(text) if unit_pricing_request?(text)
      return postcard_minimum_path_reply if postcard_minimum_path_question?(text)
      return standard_lane_compare_reply if standard_lane_compare_question?(text)
      return yard_sign_route_context_reply(text) if yard_sign_route_context_message?(text)

      return design_process_reply(current_route_code) if design_process_priority_question?(text) || (design_process_question?(text) && !proof_handoff_request?(text))
      return turnaround_reply(text) if turnaround_question?(text)
      return postcard_special_quantity_followup_reply(text) if postcard_special_quantity_followup?(text)
      return current_specials_reply(text) if current_specials_question?(text)
      return eddm_neighborhood_blitz_reply if eddm_neighborhood_blitz_question?(text)
      return bundle_compare_pricing_reply if starter_pro_compare_question?(text) || bundle_price_question?(text)
      return standard_options_pricing_reply if full_options_pricing_question?(text)
      return bundle_composition_reply(text) if bundle_composition_question?(text)
      return bundle_signs_only_fit_reply(signs_only_bundle_context_route) if signs_only_bundle_fit_question?(text)

      nil
    end

    def prepare_deterministic_fallback_body(value)
      text = value.to_s.squish
      return "" if text.blank? || analysis_leak?(text)

      text = remove_latest_inbound_echo(text)
      text = strip_url_trailing_punctuation(text)
      text = remove_prompt_style_preface(text)
      text = DealReports::CommsStager.apply_sender_profile(text, sender_name, nil) if defined?(DealReports::CommsStager)
      text.gsub!(/\[(?:your name|sender name|name|your phone|sender phone|phone number|callback number)\]/i, "")
      text = remove_sender_phone(text)
      text = text.sub(/\A[\s,;:\-]+/, "")
      text = customerize_sms_language(text)
      text = enforce_single_question(text)
      enforce_sms_length(text)
    end

    def deterministic_route_guardrail_body?(body)
      route = current_route_code.to_s
      return false if route.blank?
      return false unless link_fit_ready?(route)

      link = route_specific_shopify_link(route).to_s
      return false if link.blank?

      body.to_s.include?(link)
    end

    def repeated_rejection?(draft)
      draft.to_h["reject_reason"].to_s == "rejected_repeated_answer" ||
        draft.to_h["error"].to_s.match?(/\brejected_repeated_answer\b/)
    end

    def repeated_answer_guardrail_draft(error)
      name = customer_first_name.presence || selected_contact["name"].to_s.squish.split(/\s+/).first
      name_prefix = name.present? ? "#{name}, " : ""
      inbound = latest_inbound_sms
      route_numeric_body = numeric_route_guardrail_reply(nil, inbound)
      body = if route_numeric_body.present?
        route_numeric_body
      elsif inbound.present? && standalone_print_product_quantity_followup?(inbound)
        standalone_print_product_quantity_reply(inbound)
      elsif inbound.present? && print_products_question?(inbound)
        print_products_reply(inbound)
      elsif inbound.present?
        fallback_variant([
          fallback_reply_to_inbound(inbound),
          manual_regeneration_fallback(inbound),
          "#{name_prefix}I can keep this moving. What matters most for this campaign right now: postcard reach, yard signs in the ground, or a simple checkout link?"
        ])
      else
        fallback_variant([
          "#{name_prefix}quick question so I point you to the right WIZWIKI option: are you looking for direct-mail postcards, yard signs, or a full neighborhood push?",
          "#{name_prefix}let's pick the right WIZWIKI checkout path. Are you trying to reach mailboxes with postcards, get yard signs in the ground, or combine both?",
          "#{name_prefix}Thumper from WIZWIKI Marketing here. What are you trying to get moving first: postcards, yard signs, or a bigger local campaign?"
        ])
      end

      requires_am_support = am_support_required_for_latest_inbound?
      {
        "body" => sanitize_sms(body),
        "provider" => "local/guardrail",
        "model" => "non_repeating_sms_guardrail",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "sms_generation_pipeline" => "single_writer_guardrailed",
        "sms_quality_gate" => "rewritten",
        "draft_source" => "thumper_guardrail",
        "reason" => "Alice repeated a recent draft, so WIZWIKI saved a fresh non-repeating Thumper guardrail draft.",
        "conversation_state" => conversation_state,
        "operator_prompt" => @operator_prompt.presence,
        "error" => error.to_s.presence
      }.merge(am_support_required_metadata(requires_am_support)).compact_blank
    end

    def fallback_reply_to_inbound(inbound)
      text = inbound.to_s.squish
      stacked = stacked_open_messages_reply
      if stacked.present?
        stacked
      elsif email_decline_response?(text)
        email_decline_reply
      elsif negative_answer_to_recent_expansion_question?(text)
        negative_scope_confirmation_reply
      elsif stop_intent?(text)
        "I will stop texting here. Thanks for your time."
      elsif contact_context_question?(text)
        contact_context_reply
      elsif turnaround_question?(text) || rush_checkout_boundary_question?(text)
        turnaround_reply(text)
      elsif human_request?(text) && pricing_question?(text)
        price_then_handoff_reply(text)
      elsif support_handoff_confirmation_request?(text)
        human_handoff_reply
      elsif direct_mail_strategy_handoff_question?(text)
        direct_mail_strategy_handoff_reply
      elsif messy_print_consultant_question?(text)
        messy_print_consultant_reply
      elsif mixed_postcards_signs_question?(text)
        mixed_postcards_signs_reply
      elsif mixed_postcards_signs_cards_question?(text)
        mixed_postcards_signs_cards_reply
      elsif standalone_print_product_quantity_followup?(text)
        standalone_print_product_quantity_reply(text)
      elsif print_products_question?(text)
        print_products_reply(text)
      elsif human_request?(text)
        human_handoff_reply
      elsif yard_sign_included_items_question?(text) && pricing_question?(text)
        yard_sign_included_items_reply(text)
      elsif signs_only_pricing_question?(text)
        yard_sign_pricing_reply(text)
      elsif pricing_question?(text)
        pricing_reply(text)
      elsif yard_sign_included_items_question?(text)
        yard_sign_included_items_reply(text)
      elsif yard_sign_cheapest_package_question?(text)
        yard_sign_cheapest_entry_reply(text)
      elsif starter_pack_over_limit?
        starter_pack_over_limit_handoff_reply
      elsif standalone_numeric_answer?(text) && current_route_code.present?
        numeric_answer_follow_up
      elsif veteran_discount_question?(text)
        veteran_discount_reply
      elsif unit_pricing_request?(text)
        unit_pricing_reply(text)
      elsif postcard_minimum_path_question?(text)
        postcard_minimum_path_reply
      elsif postcard_special_below_minimum_followup?(text)
        postcard_special_below_minimum_reply
      elsif postcard_special_quantity_followup?(text)
        postcard_special_quantity_followup_reply(text)
      elsif standard_lane_compare_question?(text)
        standard_lane_compare_reply
      elsif yard_sign_route_context_message?(text)
        yard_sign_route_context_reply(text)
      elsif current_specials_question?(text)
        current_specials_reply(text)
      elsif own_art_discount_question?(text)
        own_art_discount_reply
      elsif yard_sign_art_cost_question?(text)
        yard_sign_art_cost_reply
      elsif multiple_bundle_same_art_question?(text)
        multiple_bundle_same_art_reply
      elsif ai_art_builder_question?(text)
        ai_art_builder_onboarding_reply
      elsif artwork_creation_followup_request?(text)
        artwork_creation_help_reply
      elsif cheapest_overall_pricing_question?(text)
        cheapest_overall_pricing_reply(text)
      elsif eddm_neighborhood_blitz_question?(text)
        eddm_neighborhood_blitz_reply
      elsif starter_pro_compare_question?(text)
        bundle_compare_pricing_reply
      elsif full_options_pricing_question?(text)
        standard_options_pricing_reply
      elsif direct_mail_strategy_handoff_question?(text)
        direct_mail_strategy_handoff_reply
      elsif messy_print_consultant_question?(text)
        messy_print_consultant_reply
      elsif mixed_postcards_signs_question?(text)
        mixed_postcards_signs_reply
      elsif mixed_postcards_signs_cards_question?(text)
        mixed_postcards_signs_cards_reply
      elsif print_products_question?(text)
        print_products_reply(text)
      elsif signs_only_bundle_fit_question?(text)
        bundle_signs_only_fit_reply(signs_only_bundle_context_route)
      elsif signs_only_bundle_compare_question?(text)
        signs_only_and_bundle_options_reply
      elsif multi_product_link_request?(text)
        multi_product_link_reply(text)
      elsif direct_checkout_link_request?(text)
        direct_link = direct_checkout_link_reply(text)
        if direct_link.present?
          direct_link
        elsif current_route_code.present? && link_fit_ready?(current_route_code)
          handoff_reply(current_route_code)
        elsif current_route_code.present?
          business_context_question(current_route_code) || route_next_question(current_route_code) || options_link_fit_question
        else
          options_link_fit_question
        end
      elsif checkout_confusion_question?(text)
        checkout_confusion_reply(current_route_code)
      elsif neighborhood_blitz_best_deal_request?(text)
        neighborhood_blitz_best_deal_reply
      elsif large_volume_request?(text) || outside_deal_quantity_pressure?(text)
        large_volume_standard_options_reply
      elsif standalone_zip_code?(text)
        zip_code_follow_up_reply(text)
      elsif design_process_question?(text) && !proof_handoff_request?(text)
        design_process_reply(current_route_code)
      elsif proof_handoff_request?(text)
        proof_handoff_reply
      elsif eddm_route_process_question?(text)
        eddm_route_process_reply
      elsif clarification_request?(text)
        clarification_reply_for_context(text)
      elsif logo_question?(text)
        route = design_support_route(text)
        logo_reply(route)
      elsif design_help_question?(text)
        route = design_support_route(text)
        design_reply(route)
      elsif bundle_price_question?(text)
        bundle_compare_pricing_reply
      elsif account_manager_answer_needed?(text)
        account_manager_answer_needed_reply
      elsif bundle_composition_question?(text)
        bundle_composition_reply(text)
      elsif turnaround_question?(text)
        turnaround_reply(text)
      elsif neighborhood_blitz_contents_question?(text)
        neighborhood_blitz_contents_reply
      elsif brand_explanation_question?(text) || product_offer_question?(text)
        brand_explanation_reply
      elsif product_contents_question?(text)
        product_contents_reply
      elsif completion_ready? && !completion_message_sent?
        completion_reply
      elsif identity_collection_needed?(text)
        identity_collection_reply
      elsif off_topic?(text)
        "That one is outside what I can answer well here. I am useful for WIZWIKI print, postcards, yard signs, EDDM, and local blitz campaigns. Which of those are you looking at?"
      elsif text.match?(/\b(pro pack|pro bundle|bigger bundle)\b/i) || text.match?(/\b100 yard signs?\b/i) && text.match?(/\b(?:1000|1,000) business cards?\b/i) && text.match?(/\b(?:1000|1,000) door hangers?\b/i)
        route_reply("PRO_PACK", "The Pro Pack is the bigger bundle with yard signs, business cards, and door hangers together.", "Roughly how many homes or doors are you trying to reach?")
      elsif text.match?(/\b(starter pack|starter bundle|small bundle)\b/i) || text.match?(/\b20 yard signs?\b/i) && text.match?(/\b500 business cards?\b/i) && text.match?(/\b500 door hangers?\b/i)
        route_reply("STARTER_PACK", "The Starter Pack is the smaller bundle with signs, cards, and door hangers.", "Do you want signs included, or mostly postcards/direct mail?")
      elsif door_hanger_only_intent?(text)
        print_products_reply(text)
      elsif sign_interest?(text)
        route_reply("LAWN_SIGNS", "Yep, we can help with yard signs.", "What quantity were you thinking?")
      elsif text.match?(/\b(eddm|post\s*cards?|postcards?|mail|mailer|direct mail)\b/i)
        route_reply("EDDM", "EDDM is postcard mailing by USPS route, so you can reach local homes without buying a list.", "About how many homes do you want to reach?")
      elsif text.match?(/\b(blitz|neighborhood)\b/i)
        route_reply("NEIGHBORHOOD_BLITZ", "A blitz usually pairs postcards with door hangers, yard signs, and a simple follow-up offer.", "Do you want postcards plus signs, door hangers, or all three?")
      elsif text.match?(/\b(art|artwork|design|creative|logo)\b/i)
        design_reply(design_support_route(text))
      elsif brand_explanation_question?(text) || product_offer_question?(text)
        brand_explanation_reply
      elsif product_contents_question?(text)
        product_contents_reply
      elsif text.match?(/\b(yes|sure|ok|okay|interested|send|tell me|more)\b/i)
        yes_reply
      elsif decline_without_product_fit?(text)
        "All good. If print, EDDM, signs, or a neighborhood push comes up later, send it here and I can help."
      else
        unknown_reply
      end
    end

    def standalone_numeric_answer?(text)
      text.to_s.squish.match?(/\A\$?\s*[\d,]{1,6}\s*\z/)
    end

    def standalone_zip_code?(text)
      text.to_s.squish.match?(/\A\d{5}(?:-\d{4})?\z/)
    end

    def zip_code_follow_up_reply(text)
      zip = text.to_s.squish[/\A\d{5}(?:-\d{4})?\z/]
      zip_text = zip.present? ? "#{zip} " : ""
      route = current_route_code.to_s

      if route == "EDDM" || recent_sms_context.match?(/\b(?:postcards?|eddm|direct mail|mailers?|homes?|doors?)\b/i)
        return "#{zip_text.presence || 'That ZIP '}gives us the target area. About how many homes or doors do you want to reach there?".squish
      end

      if route == "LAWN_SIGNS"
        return "#{zip_text.presence || 'That ZIP '}gives us the target area. How many Yard Signs package signs do you want to start with?".squish
      end

      "#{zip_text.presence || 'That ZIP '}gives us the target area. Are you thinking postcards, yard signs, or both there?".squish
    end

    def zip_code_answer?(text, inbound = latest_inbound_sms)
      zip = inbound.to_s.squish[/\A\d{5}(?:-\d{4})?\z/]
      body = text.to_s.downcase.squish
      return false if zip.blank? || body.blank?
      return false if body.match?(/\b(?:#{Regexp.escape(zip)},?\s+homes?|#{Regexp.escape(zip)},?\s+doors?|#{Regexp.escape(zip)},?\s+signs?|budget|dollars?|bucks?)\b/)

      body.include?(zip) &&
        body.match?(/\b(?:zip|target area|area|location|there|neighborhood)\b/)
    end

    def numeric_answer_follow_up
      route = current_route_code
      return unknown_reply if route.blank?
      quantity_pricing = yard_sign_quantity_follow_up_reply(route)
      return quantity_pricing if quantity_pricing.present?
      company_question = quantity_company_follow_up(route)
      return company_question if company_question.present?
      return starter_pack_over_limit_handoff_reply if starter_pack_over_limit?(route)
      return handoff_reply(route) if link_fit_ready?(route)

      context_question = business_context_question(route)
      return context_question if context_question.present?

      fit_question = next_route_fit_question(route)
      return fit_question if fit_question.present?

      return identity_collection_reply if identity_payload[:missing].present?

      route_next_question(route)
    end

    def numeric_route_guardrail_reply(candidate_text = nil, inbound = latest_inbound_sms)
      inbound_text = inbound.to_s.squish
      return unless standalone_numeric_answer?(inbound_text) && current_route_code.present?

      reply = numeric_answer_follow_up
      return if reply.blank?

      candidate = candidate_text.to_s.squish
      return reply if candidate.blank?
      return reply if asks_for_known_fit_field?(candidate)
      return reply if asks_for_known_discovery_field?(candidate)
      return reply if product_lane_selection_question?(candidate)
      return reply if stale_route_question?(current_route_code, candidate)
      return reply if repeated_draft?(candidate)

      nil
    end

    def deterministic_numeric_context_guardrail_body?(body, inbound = latest_inbound_sms)
      inbound_text = inbound.to_s.squish
      text = body.to_s.squish
      return false unless standalone_numeric_answer?(inbound_text) && current_route_code.present?
      return false if text.blank?

      acceptable_sms_body?(text, include_drafts: false)
    end

    def yard_sign_quantity_follow_up_reply(route = current_route_code)
      return unless route.to_s == "LAWN_SIGNS"

      quantity = campaign_fit_payload[:quantity_count].to_s.squish.presence
      return if quantity.blank?

      pricing = compact_yard_sign_quantity_reply(quantity)
      return pricing if pricing.present?

      yard_sign_pricing_reply("#{quantity} signs")
    end

    def compact_yard_sign_quantity_reply(quantity_value)
      quantity = numeric_quantity_value(quantity_value)
      return if quantity.blank?

      table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
      return if table.blank?

      options = price_options_for_quantity(table, quantity)
      inclusion = "Stakes, shipping, and design are included."
      if options.present?
        price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
        return if price.blank?

        return "#{quantity} Yard Signs are #{display_yard_sign_price(price)} double-sided. #{inclusion} Do you want to use that Yard Signs package option?"
      end

      available = table.keys.map(&:to_i).sort
      lower = available.select { |candidate| candidate < quantity }.max
      higher = available.select { |candidate| candidate > quantity }.min
      closest = [lower, higher].compact.map do |candidate|
        price = price_options_for_quantity(table, candidate)["double_sided_included"].presence ||
          price_options_for_quantity(table, candidate)["double_sided"].presence ||
          price_options_for_quantity(table, candidate)["price"].presence
        price.present? ? "#{candidate} at #{display_yard_sign_price(price)}" : nil
      end.compact
      return if closest.blank?

      "I do not see an exact #{quantity}-sign package option listed. Closest Yard Signs package options are #{closest.to_sentence}. #{inclusion} Do you want one of those, or do you want the exact #{quantity}-sign quantity checked?"
    end

    def display_yard_sign_price(price)
      amount = numeric_budget_value(price)
      amount.present? ? format_budget_amount(amount) : price.to_s
    end

    def quantity_company_follow_up(route = current_route_code)
      return unless route.to_s == "LAWN_SIGNS"

      quantity = campaign_fit_payload[:quantity_count].to_s.squish.presence
      return if quantity.blank?
      return unless identity_payload[:missing].include?("company_name") || !business_context_ready?

      "#{quantity} signs gives us the quantity. What business name should I save this under?"
    end

    def fallback_operator_rewrite(inbound)
      prompt = @operator_prompt.downcase
      return manual_regeneration_fallback(inbound) if manual_regeneration_prompt?
      return reset_conversation_opening_fallback if reset_conversation_prompt? && first_outbound_thread?

      if operator_prompt_logo_guidance? || logo_question?([inbound, @operator_prompt].join(" "))
        route = design_support_route([inbound, @operator_prompt].join(" "))
        return logo_reply(route)
      end

      if pricing_question?([inbound, @operator_prompt].join(" "))
        return pricing_reply([inbound, @operator_prompt].join(" "))
      end

      if turnaround_question?([inbound, @operator_prompt].join(" "))
        return turnaround_reply([inbound, @operator_prompt].join(" "))
      end

      if bundle_composition_question?([inbound, @operator_prompt].join(" "))
        return bundle_composition_reply([inbound, @operator_prompt].join(" "))
      end

      if operator_prompt_design_guidance? || design_help_question?([inbound, @operator_prompt].join(" "))
        route = design_support_route([inbound, @operator_prompt].join(" "))
        return design_reply(route)
      end

      if prompt.match?(/\b(question|ask|need|help|qualify|discover)\b/)
        direct = fallback_reply_to_inbound(inbound) if inbound.present?
        return direct if direct.present? && !similar_thread_response?(direct)
        if Thumper::VoiceGuide.yard_sign_lane?(opening_offer_product_lane)
          return Thumper::VoiceGuide.starter_sms(selected_contact["name"].to_s.squish.presence || company_name, product_lane: opening_offer_product_lane)
        end

        return fallback_variant([
          "Let's narrow it down. Are you thinking postcards, yard signs, or both?",
          "Let me point you toward the right option. Is this mostly a mailer, signs, or a full neighborhood push?",
          "Let's make this simple. Are you trying to reach homes with postcards, get seen with signs, or do both together?"
        ])
      end

      if inbound.present?
        fallback_reply_to_inbound(inbound)
      elsif Thumper::VoiceGuide.yard_sign_lane?(opening_offer_product_lane)
        Thumper::VoiceGuide.starter_sms(selected_contact["name"].to_s.squish.presence || company_name, product_lane: opening_offer_product_lane)
      else
        fallback_variant([
          Thumper::VoiceGuide.starter_sms(selected_contact["name"].to_s.squish.presence || company_name, product_lane: opening_offer_product_lane),
          "Hi #{selected_contact["name"].to_s.squish.presence || company_name}, Thumper from WIZWIKI Marketing here. Are you trying to reach mailboxes with postcards, get yard signs in the ground, or do both?",
          "Hi #{selected_contact["name"].to_s.squish.presence || company_name}, the useful first question is simple. Are you looking at postcards, yard signs, or a bigger local push?"
        ])
      end
    end

    def manual_regeneration_fallback(inbound)
      inbound_text = inbound.to_s.squish
      route = current_route_code.to_s.presence

      if inbound_text.present?
        direct = fallback_reply_to_inbound(inbound_text)
        return direct if direct.present? && !similar_thread_response?(direct)
      end

      if route.present?
        return handoff_reply(route) if link_fit_ready?(route)

        question = next_route_fit_question(route)
        return question if question.present?
        return identity_collection_reply if identity_payload[:missing].present?
        return options_link_fit_question if options_link_fit_question_needed?(route)
        return post_link_follow_up_reply(inbound_text) if shopify_link_already_sent?(route)

        return fallback_variant([
          route_next_question(route),
          product_direction_question,
          "Let's compare the options. Are you leaning toward a smaller starter run or a bigger neighborhood push?"
        ])
      end

      fallback_variant([
        product_direction_question,
        "Let's narrow this down. Are you mostly thinking postcards, yard signs, or both?",
        "To point you to the right WIZWIKI option, are you trying to reach homes by mail, get visibility with signs, or do both together?"
      ])
    end

    def fallback_variant(options)
      candidates = Array(options).map { |option| option.to_s.squish }.compact_blank
      fresh = candidates.reject { |option| repeated_draft?(option) || repetitive_thread_response?(option) }
      pool = fresh.presence || candidates
      return "" if pool.blank?

      seed = Digest::SHA1.hexdigest([
        @stage&.id || @metadata.to_h["stage_id"] || "stage",
        latest_inbound_sms,
        Array(@metadata["sms_thread"]).length,
        Array(@metadata["sms_draft_history"]).length,
        Time.current.to_i / 300
      ].join(":")).to_i(16)
      pool[seed % pool.length]
    end

    def prompt
      <<~PROMPT
        You are Thumper, the Thumper von AUTOS, writing the next outbound SMS for a human operator.
        Your customer-facing bot name is Thumper from WIZWIKI Marketing.
        Return JSON only: {"body":"...", "reason":"..."}.

        PARAMOUNT Thumper VOICE:
        #{Thumper::VoiceGuide.sms_prompt}

        RETRIEVAL HIERARCHY:
        - For voice, the Thumper Thumper Voice Canon, WIZWIKI Copy Playbook, and THUMPER VIBE resources outrank older examples and autogenerated memory.
        - For facts, current product catalog, pricing, links, specials, and the live SMS thread outrank every wording example.
        - Procedural skills are on-demand playbooks. Curated examples teach conversation shape. Guardrail memory teaches what to correct, not wording to imitate.
        - Never imitate judge calibration, rejected drafts, opt-out transcripts, simulator residue, or quarantined conversation memory.

        #{guardrail_retry_prompt_section}

        HARD RULES:
STATE RULES:
- First read CONTEXT JSON -> conversation_state -> known, missing_fields, next_missing_field, and product_interest.
- The known map is authoritative. Never ask for a field that is already known or already has a value.
- Do not start the SMS with a stale generic acknowledgement. Use a natural opener tied to the customer's message, or answer directly with no filler.
        - Ask for exactly one useful next item per SMS. Product fit comes before a checkout link, but one useful fit signal is enough to move: sign quantity OR homes/reach. Product interest alone is not enough. Do not ask budget unless the customer brings up budget, price, cost, spend, or a custom quote.
- Ask for missing discovery fields in this order when needed: product_interest, contact_name, company_name.
- Before sending a checkout link, collect one lightweight business/campaign context signal if it is missing: company name, trade/industry, or what they are promoting. Ask it conversationally, not like a form.
- Do not ask for ZIP, location, email, contact preference, days, or times unless the customer is being handed to AM support for a real escalation.
- If the latest customer message is only a 5-digit number and the prior bot question asked for ZIP, service area, location, specific area, neighborhood, route area, or mailing area, treat it as a ZIP code. Do not turn it into a home count, sign quantity, or budget.
        - If next_missing_field is present, answer the customer's latest question first, then ask only for that one field unless a product-fit question is more useful for recommending the right package. Product-fit questions should be concrete: sign quantity, how many homes/doors, postcards vs signs vs both, or artwork status. Budget is optional context only when the customer raises it.
        - If the latest customer message includes something unexpected, joking, off-menu, or outside the product data, respond like a relaxed human first. A small spontaneous joke is okay, then steer back to the useful product answer, link, or one next discovery step. Do not invent that WIZWIKI sells an unrelated item.
        - If no discovery fields are missing, keep helping with product fit, comparisons, pricing, design/proof process, or the checkout path. Do not use "anything else I can get you?" as a conversation closer.
        - Use good judgment for account-manager handoff. Hand off when the customer asks for a person, is frustrated, keeps pressing for an exception after explanation, has a complex/unusual order, or asks a question the product data cannot safely answer. Do not hand off lazily when product context can answer.
        - Large quantities, bulk curiosity, and numbers outside the listed deals are not automatic AM support. Answer what can be answered first: compare standard checkout packages/bundles, say when exact off-menu pricing is not safe to invent, and offer account-manager help only as an option unless the customer asks for support or becomes frustrated.
        - If the customer asks whether having their own art, logo, design, or files creates a discount, answer directly: no automatic discount from the listed checkout price unless PRODUCT CONTEXT says one exists. Their art helps the intake/proof path and can be reused across the run, but do not approve a discount.

	        - Write exactly one SMS body.
	        - Stay under #{MAX_SMS_CHARS} characters.
        - A single SMS may answer a full customer request, compare options, include prices, and provide relevant links when the customer asked for that. Keep it concise and ask at most one follow-up question.
        - If CONTEXT JSON has open_customer_messages, those are the unanswered active customer texts since Thumper last replied. Answer every active open customer question before asking a follow-up; if there are two or three active questions, cover them in the same SMS. If open_customer_reply_requirements is present, treat it as the required fact checklist for the SMS. If a later open text says actually, nevermind, scratch that, instead, rather, or prefer and clearly changes lanes, honor the latest decision instead of chasing the superseded older request.
	        - Do not say goodbye, "nice to meet you," "thank you for choosing," or "let me know if you need anything else" unless the customer has clearly ended the conversation.
	        - No markdown, bullets, labels, emojis, fake stats, discounts, guarantees, specials approvals, HubSpot IDs, internal notes, or bracket placeholders.
        - Sound like a real sales operator, not an automated blast.
        - Keep the tone friendly but never patronizing, scolding, dismissive, annoyed, or fake-cheery. Do not make the customer feel small for their budget, quantity, wording, spelling, or question. Plain encouragement is fine when it is specific and quickly moves to the next useful step.
        - Be thoughtful and thorough without sounding demanding. Do the useful work in the reply instead of describing what you are able to do. Prefer a clean answer or comparison over meta phrases like "I can compare" or commandy closers like "tell me."
        - If customer_first_name is known, use the first name naturally when it improves the message. Do not force it into every text.
        - Use FINE TRAINING CONTEXT and CALL SCENARIO CONTEXT for voice, sales scenario examples, objections, buying signals, and successful next-step patterns. These are training examples, not scripts. Create a fresh message for this exact lead and thread. Convert Sample Owner-style examples into Thumper's voice. Never write Sample Owner as the sender.
        - Use PRODUCT DECISION GUIDE, PRODUCT OFFERINGS DOCUMENT, SHOPIFY PRODUCT DETAILS, and PRODUCT TIMING DETAILS to decide which Shopify link fits. The training docs and Shopify link details may include product descriptions, quantities, sizes, included items, shipping notes, turnaround windows, and prices. Use those details to answer cost and timing questions and recommend a package size or sign size when the fit is clear.
        - Use UNIT PRICING GUIDE only as support math. Default customer quotes should use package totals. Mention price-per-unit only when the customer asks "each," "per unit," "per sign," "what is one worth," or is bantering about one or two pieces. Never imply WIZWIKI sells one or two units when the listed package minimum is higher.
        - Treat $, dollars, bucks, dolla, and phrases like "what can I get for 100" as budget/pricing language. If the customer is asking about a roughly $100 yard-sign budget, answer directly that about $100 gets about 10 yard signs, then ask only one useful follow-up.
        - If the customer asks what a bundle includes, what they get for $299 vs $599, whether cards/hangers are included, or how much "they" cost after discussing signs/cards/hangers, give the full Starter Pack and Pro Pack comparison before any follow-up question.
        - If the customer asks whether Pro Pack or Starter Pack is better when they only need yard signs, answer directly: Yard Signs is the cleaner signs-only package; Pro/Starter bundles add business cards and door hangers and only fit better if they want those extras.
        - If the customer asks what other print products WIZWIKI offers, answer with the broader print products first: business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials when relevant. Do not default straight into Starter/Pro unless the bundle is directly requested or clearly fits.
        - If a print request is messy, custom, or missing sizes/quantities/product mix, offer a marketing consultant to go over the details instead of forcing checkout.
        - For targeting, routes, lists, or what may work best, respond like a practical marketing consultant: give one grounded high-level recommendation from known context and explain the tradeoff. Offer a human marketing consultant for account-specific route selection, list strategy, software setup, forecasts, or details the supplied evidence cannot support.
        - If the customer compares postcards/direct mail with signs and asks what to start with, choose a starting move and explain why. Do not answer only that both are available; position the second channel as reinforcement when it fits.
        - If the first outbound, lead source, current product, or latest customer intent is Yard Signs, start in yard signs. Do not open with "postcards, yard signs, or both" unless the lane is genuinely unknown.
        - For yard-sign options/pricing, use customer-facing language like "For 18x24 yard signs, the options are..." Never write "the yard sign ladder I see," "the options I see," "from product data," or any phrase that sounds like the system is reading a table.
        - #{current_specials_prompt_instruction || "No promotional special is active. Never describe an expired offer as current or active."}
        - If the customer compares EDDM and Neighborhood Blitz, answer both lanes before discovery: EDDM is mail-only postcards by route; Neighborhood Blitz is the fuller mail-plus-visibility push with pieces like signs, door hangers, rack cards, or job-area materials.
        - If the customer asks for all options/packages/deals with prices, answer with a compact price comparison first. Do not close with a thank-you/link-only response.
        - Treat normal design, proofing, logo upload, artwork, and payment-before-artwork questions as buyer-confidence moments, not default human handoffs. Answer directly from CONTEXT JSON design_process.
        - For design-process questions explain the path naturally: the customer places the order first; after checkout the design team sends an intake form to the checkout email; the customer uploads images, logo, wording, colors, layout notes, and any existing artwork there; PDF/vector files are best when available; the team creates or reviews the proof; the customer can request changes; nothing prints until proof approval; payment starts the order/design queue and does not mean WIZWIKI prints blindly.
        - If the customer asks if they need their own design, artwork, logo, image, file, or finished design file, answer directly: they do not need a finished design. The customer completes checkout first; after checkout, WIZWIKI collects images/artwork/logo files through the intake/proof process. If they have art, WIZWIKI can use it or clean it up. If they do not, WIZWIKI has an easy-to-use AI postcard/art builder, AI design support, and in-house designers who can create the design work.
        - Do not use "creative" as a standalone noun in customer SMS. Say "design help," "artwork," "logo," "design files," or "help designing the postcard/sign artwork" so the customer understands exactly what you mean.
        - If a link was already sent and the customer asks where to design, where to upload a logo, why payment comes first, or whether they can see proof before print, do not just repeat the link or route away. Acknowledge the confusion, explain the process, reassure them that proof approval happens before print, then guide them back to checkout as the next step.
        - Do not offer a human as the default ending after a design-process explanation. Hand off only when the customer explicitly asks for a person, is still confused after the process was explained, has a complex/unusual design or order situation, has a larger consultative order, keeps asking for an exception such as a proof before payment, or seems uncomfortable after the explanation.
        - If handoff is needed, frame it as help understanding the order path. Do not imply the teammate will create a proof before payment, bypass checkout, or do unpaid design work. Never promise specific delivery dates, invented pricing, discounts, options, or collect payment info in chat.
        - Do not answer from generic fallback copy when product descriptions/prices are present.
        - If this is a first outbound or fresh opener, use opening_offer only as context for identity and intent. Write a fresh, natural first SMS for this lead. Keep the customer's first name if known, but do not copy the opener verbatim unless it is truly the best message: "#{opening_offer}"
        - Do not ask for ZIP, location, email, or contact preference in this flow unless exact pricing is missing or the customer has a real AM-support escalation. A single business-context question is allowed before checkout so the customer feels understood.
        - The goal is to take care of the client by understanding their campaign interest, campaign goal, and practical size/quantity fit. Do not oversell.
        - Answer pricing only from supplied pricing/product context. If exact pricing is missing, say exact pricing varies by quantity/setup, compare any listed standard options you can stand behind, and ask whether they want standard bundle guidance or custom pricing help. Do not immediately collect contact preference unless this is a true AM-support escalation.
        - If the customer asks what WIZWIKI does, answer from COMPANY PROFILE and mention Pro Pack, Starter Pack, Yard Signs, EDDM, neighborhood blitz, and design/artwork support only when relevant.
        - If the customer asks about lawn signs, be concrete: custom yard signs, jobsite signs, directional signs, stakes, and campaign artwork.
        - If the customer asks about EDDM, explain route-based postcard mailings in plain language.
        - If the customer asks about a neighborhood blitz, explain postcards plus signs/door hangers/follow-up in plain language.
        - If the latest customer message is off-topic, answer with a short boundary and steer back to WIZWIKI marketing. Do not pretend off-topic subjects are marketing requests.
        - Never start by repeating or quoting the customer's latest SMS. Answer or redirect directly.
        - Your conversation goal is to discover what the customer wants to accomplish with the campaign, not just force a menu choice. Primary deal choices are Pro Pack, Starter Pack, and Yard Signs. Supporting campaign routes are EDDM and neighborhood blitz. Treat artwork, logo, proof, and design needs as support context for the chosen print product, not as the primary product discovery path. Finding product interest does not end the chat; use one practical fit question to move toward the best link.
        - Your data goal is to capture product interest, first name, company name, and optionally the trade/industry or what kind of business this is for. Industry/business context is helpful but should not block a checkout link when product fit is already clear. If IDENTITY CAPTURE says any core fields are missing, ask naturally for one missing item after any direct answer.
	      - If product interest is known but quantity and homes/reach are both missing, do discovery mode: ask one concrete quantity or reach question before any checkout link. If product interest and one practical fit signal are known, recommend the best-fit Shopify link when supplied without making the conversation sound finished. Do not say a person will contact them unless they asked for a human/assistant or they are stuck in checkout.
	        - If product interest and quantity are known but business/campaign context is missing, ask only what kind of business or campaign this is for. Do not thank, close, or send a checkout link in that same SMS.
	        - If a product interest is already chosen and one practical fit signal is known, include the best-fit Shopify link if supplied and not already sent. Keep the door open by offering to compare or explain the next decision, not by closing the conversation.
        - Use assigned teammate first names only in customer SMS. Never write last names or email addresses to the customer as the handoff name.
        - If the customer asks for a person, human, call, rep, salesperson, or account manager, say the assigned WIZWIKI teammate can help with the next step without making the conversation sound over.
        - Do not route normal art proof, design proof, proof approval, logo/artwork/file upload, or payment-before-artwork questions to AM support unless the handoff criteria above are met.
        - If the customer sounds finished, end politely and clearly. Do not abruptly stop after finding a processing lane.
        - If the customer has not chosen a lane, ask one short helpful question that forces a real product direction: postcards, yard signs, or both. Then use quantity, home count, artwork status, and any customer-volunteered budget to decide between Pro Pack, Starter Pack, Yard Signs, EDDM, or Neighborhood Blitz.
        - If AUTOPILOT is enabled, behave like a careful supervised bot: answer the customer's latest question first, then ask at most one short next-step question.
        - Complex questions can take more than one SMS. Do not force a final answer if the customer needs a sequence; answer the first useful part, ask one focused follow-up, and keep the thread active.
        - Keep conversation memory from RECENT SMS THREAD. Do not ask again for details already supplied in the thread.
        - Do not repeat RECENT OUTBOUND TEXTS. Advance the conversation from the latest customer reply.
        - Do not set or mention a processing code in the customer-facing SMS.
        - Use only supported details from the context. If a detail is missing, do not invent it.
        - Pick Shopify links from CONTEXT JSON company_profile.shopify_links, product_offerings_document, fine_training_context, and conversation_state.shopify_link. Choose the link that matches the customer's campaign goal and needed size, not a generic human handoff.
        - If the customer wants two product paths, such as postcards and yard signs, think dynamically: recommend the strongest combined path, then offer relevant standalone links too if they help the customer choose. It is okay to include more than one link when the customer asked for or clearly needs more than one option.
        - Before sending a link, include one short recommendation sentence: why this offer fits and which offer to order on the link page. If their size/quantity or customer-volunteered budget suggests a useful alternate, mention the alternate in one short sentence.
        - Do not add a canned thank-you before a URL. Give one useful fit, price, or process sentence, then the link. When sending one URL, the URL must be the final text in the SMS. When sending multiple URLs, label each option clearly and make the final character of the SMS the last raw URL.
        - Put any final URL at the end with no period, comma, colon, semicolon, exclamation mark, question mark, or closing parenthesis after it. SMS clients should see the raw clickable URL only.
        - The human can edit before sending. Do not claim the message was sent.
        - If OPERATOR PROMPT is blank, create a fresh alternate from context that is meaningfully different from CURRENT NEXT TEXT.
        - If OPERATOR PROMPT is present, treat it as the rewrite instruction.
        - Ask for only one missing discovery item per SMS. Business context is a relationship/fit question, not a long qualification form.
        - Before returning JSON, silently self-check the draft against the current customer stack, Thumper voice canon, fact authority, recent outbound wording, and one-question limit. Rewrite it if any check fails. Never narrate this check.

        OPERATOR PROMPT:
        #{@operator_prompt.presence || "(blank - generate a fresh alternate)"}

        CONTEXT JSON:
        #{JSON.pretty_generate(alice_context_payload)}
      PROMPT
    end

    def recursive_dojo_compact_cloud_prompt?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("ASK_RECURSIVE_DOJO_COMPACT_NEMOTRON_PROMPT", "1")) &&
        writer_model.to_s == "nvidia:nemotron" &&
        simulation_stage? &&
        @metadata.to_h["recursive_dojo_status"].present?
    end

    def recursive_dojo_compact_alice_prompt
      <<~PROMPT.squish
        Write exactly one customer-facing SMS body as Thumper from WIZWIKI Marketing.
        Return JSON only: {"body":"...", "reason":"..."}.
        No markdown, labels, bullets, emojis, analysis, internal notes, or wrappers.
        Stay under #{MAX_SMS_CHARS} characters. Answer the latest customer question first.
        Sound like Thumper: practical, candid, consultative, specific, and human. Give the answer, one useful reason or recommendation, then at most one next question.
        If there are multiple open customer messages, answer every active question in one concise SMS.
        Ask at most one useful next question. Use only supplied prices, quantities, links, and product details.
        Never invent discounts, timing, products, or checkout links. Final URL must be raw and last when a link is included.
      PROMPT
    end

    def recursive_dojo_compact_prompt
      <<~PROMPT
        OPERATOR PROMPT:
        #{@operator_prompt.presence || "(blank - generate a fresh alternate)"}

        RECURSIVE DOJO SMS RULES:
        - This is an internal simulator run. Write the same customer-facing English SMS Thumper would send in the real thread.
        - Use context_json as authority. Do not mention context_json, dojo, simulator, metadata, processing codes, or internal rules.
        - Answer direct pricing, included-items, artwork/proof, and link requests before discovery.
        - Yard signs: use exact product pricing from context; design, stakes, and shipping are included when supplied.
        - Product lane can pivot when the latest customer asks about another product.
        - For bundles, Starter Pack and Pro Pack are bundles; Yard Signs is signs-only.
        - For design/proof questions, explain checkout -> intake/proof -> upload logo/artwork/notes -> proof approval before print.
        - Do not hand off to a human unless the customer explicitly asks for one or the request is truly custom/off-menu.
        - Silently check directness, completeness, factual grounding, Thumper voice, non-repetition, and one-question maximum before returning.
        - Return one compact JSON object only.

        CONTEXT JSON:
        #{JSON.generate(recursive_dojo_compact_context_payload)}
      PROMPT
    end

    def recursive_dojo_compact_context_payload
      sms_thread = compact_sms_thread
      {
        company: company_name,
        operator_prompt: @operator_prompt.presence,
        style_variation: style_variation_payload,
        model_pipeline: model_pipeline_payload.merge(compact_dojo_prompt: true),
        company_profile: {
          name: COMPANY_PROFILE["name"],
          short_description: COMPANY_PROFILE["short_description"],
          shopify_links: sendable_shopify_links
        }.compact_blank,
        design_process: recursive_dojo_design_process_payload,
        product_decision_guide: sms_product_matrix_payload,
        product_offerings_document: sms_product_offerings_summary,
        current_specials: current_specials_payload,
        unit_pricing_guide: recursive_dojo_unit_pricing_context_payload,
        shopify_product_details: compact_shopify_product_details_payload,
        product_timing_details: recursive_dojo_timing_context_payload,
        campaign_fit: campaign_fit_payload,
        route_assignment: route_assignment_payload,
        conversation_state: conversation_state,
        identity_capture: identity_payload,
        current_next_text: current_sms_body_for_context,
        latest_sms_event: compact_sms_event(latest_sms_event),
        latest_inbound_event: compact_sms_event(latest_inbound_sms_event),
        open_customer_messages: open_customer_messages_payload,
        open_customer_reply_requirements: open_customer_reply_requirements_payload,
        unanswered_outbound_question: unanswered_outbound_question_payload,
        latest_inbound_sms: latest_inbound_sms,
        recent_outbound_texts: recent_outbound_texts.first(SMS_RECENT_OUTBOUND_LIMIT),
        recent_sms_thread: sms_thread.last(6),
        recent_unsent_drafts: recent_draft_texts.first(1),
        dojo: {
          compact_prompt: true,
          status: @metadata["recursive_dojo_status"],
          cycle: @metadata["recursive_dojo_current_cycle"],
          total_cycles: @metadata["recursive_dojo_total_cycles"],
          turn: @metadata["recursive_dojo_current_turn"],
          title: @metadata["recursive_dojo_current_title"]
        }.compact_blank
      }.compact_blank
    end

    def recursive_dojo_design_process_payload
      {
        no_finished_design_required: true,
        order_path: [
          "Customer checks out first.",
          "After checkout, intake/proof flow collects logo, images, wording, colors, layout notes, and files.",
          "WIZWIKI can use or clean up supplied artwork, or help create artwork.",
          "Nothing prints until customer approves the proof."
        ]
      }
    end

    def recursive_dojo_unit_pricing_context_payload
      return unit_pricing_guide_payload if unit_pricing_request?(latest_inbound_sms)

      nil
    end

    def recursive_dojo_timing_context_payload
      inbound = latest_inbound_sms.to_s
      return product_timing_details_payload if turnaround_question?(inbound)
      return product_timing_details_payload if inbound.match?(/\b(?:rush|rushed|fast|faster|quick|timeline|turnaround|ship|shipping|delivery|when)\b/i)

      nil
    end

    def design_process_payload
      DESIGN_PROCESS_PROFILE
    end

    def context_payload
      {
        company: company_name,
        operator_prompt: @operator_prompt.presence,
        style_variation: style_variation_payload,
        model_pipeline: model_pipeline_payload,
        customer_first_name: customer_first_name,
        first_outbound: first_outbound_thread?,
        opening_offer: opening_offer,
        company_profile: COMPANY_PROFILE.merge("shopify_links" => sendable_shopify_links),
        design_process: design_process_payload,
        product_decision_guide: product_decision_guide,
        product_offerings_document: product_offerings_document,
        sms_skills: sms_skills,
        sms_examples: sms_examples,
        current_specials: current_specials_payload,
        unit_pricing_guide: unit_pricing_guide_payload,
        shopify_product_details: shopify_product_details_payload,
        product_timing_details: product_timing_details_payload,
        campaign_fit: campaign_fit_payload,
        fine_training_context: fine_training_context,
        call_scenario_context: call_scenario_context,
        deal: @metadata["deal_name"],
        direction: @metadata["comm_kit_direction_label"].presence || @metadata["comm_kit_direction"],
        processing_code: @metadata["processing_code"],
        processing_label: @metadata["processing_label"],
        processing_summary: @metadata["processing_summary"],
        lane_monitor: lane_monitor_payload,
        industry: industry_value,
        route_assignment: route_assignment_payload,
        conversation_state: conversation_state,
        identity_capture: identity_payload,
        selected_contact: selected_contact,
        selected_phone: selected_phone,
        selected_email: selected_email,
        selected_address: selected_address,
        location_capture_url: location_capture_url,
        location_capture_status: @metadata["location_capture_status"],
        location_capture_last: @metadata["location_capture_last"],
        autopilot: autopilot_payload,
        sender: {
          name: sender_name,
          email: @metadata.dig("sender_profile", "email").presence || @user&.email_address
        }.compact_blank,
        recipient_selection_summary: @metadata["recipient_selection_summary"],
        contact_intelligence: @metadata["contact_intelligence"],
        current_next_text: current_sms_body_for_context,
        recent_unsent_drafts: recent_draft_texts,
        thread_authority: "Persisted sms_thread is authoritative for customer intent. Current product catalog is authoritative for facts. Thumper Voice Canon and WIZWIKI Copy Playbook are authoritative for tone. Skills and curated examples are supporting patterns only; never imitate judge, rejected, simulator, opt-out, or quarantined memory.",
        latest_sms_event: latest_sms_event,
        latest_inbound_event: latest_inbound_sms_event,
        open_customer_messages: open_customer_messages_payload,
        open_customer_reply_requirements: open_customer_reply_requirements_payload,
        unanswered_outbound_question: unanswered_outbound_question_payload,
        sms_options: Array(@metadata["sms_options"]).first(6),
        latest_inbound_sms: latest_inbound_sms,
        prior_thumper_messages: prior_thumper_thread_messages,
        recent_outbound_texts: recent_outbound_texts,
        full_sms_thread: compact_sms_thread,
        recent_sms_thread: compact_sms_thread.last(16),
        recent_email_thread: Array(@metadata["email_thread"]).last(4)
      }.compact_blank
    end

    def active_alice_draft_question(organization, request_key)
      return if organization.blank? || request_key.blank?

      organization.autos_questions
        .where(status: "queued", answer: [nil, ""])
        .where("metadata ->> 'surface' = ?", "comms_sms_draft")
        .where("metadata ->> 'comms_stage_id' = ?", @stage.id.to_s)
        .where("metadata ->> 'sms_draft_request_key' = ?", request_key)
        .where("created_at >= ?", 5.minutes.ago)
        .order(created_at: :desc)
        .first
    end

    def sms_draft_request_key
      return unless webhook_auto_prompt?

      inbound = latest_inbound_sms_event.to_h
      body = inbound["body"].to_s.squish.downcase
      sender = inbound["from"].to_s.squish
      return if body.blank? && sender.blank?

      Digest::SHA1.hexdigest([
        @stage.id,
        sender,
        body,
        @operator_prompt.to_s.squish,
        writer_model
      ].join(":"))
    end

    def alice_context_payload
      return support_alice_context_payload if support_rag_profile?

      sms_thread = compact_sms_thread
      recent_sms_thread = sms_thread.last(SMS_RECENT_THREAD_CONTEXT_LIMIT)
      thread_window = sms_thread.last(SMS_THREAD_CONTEXT_LIMIT)
      full_sms_thread = thread_window.first([thread_window.length - recent_sms_thread.length, 0].max)
      full_sms_thread = nil if full_sms_thread.blank?

      {
        company: company_name,
        operator_prompt: @operator_prompt.presence,
        style_variation: style_variation_payload,
        model_pipeline: model_pipeline_payload,
        customer_first_name: customer_first_name,
        first_outbound: first_outbound_thread?,
        opening_offer: opening_offer,
        company_profile: {
          name: COMPANY_PROFILE["name"],
          short_description: COMPANY_PROFILE["short_description"],
          shopify_links: sendable_shopify_links
        }.compact_blank,
        design_process: design_process_payload,
        product_decision_guide: sms_product_matrix_payload,
        product_offerings_document: sms_product_offerings_summary,
        sms_skills: sms_skills,
        sms_examples: sms_examples,
        current_specials: current_specials_payload,
        unit_pricing_guide: unit_pricing_guide_payload,
        shopify_product_details: compact_shopify_product_details_payload,
        product_timing_details: product_timing_details_payload,
        campaign_fit: campaign_fit_payload,
        fine_training_context: compact_fine_training_context,
        call_scenario_context: compact_call_scenario_context,
        route_assignment: route_assignment_payload,
        conversation_state: conversation_state,
        identity_capture: identity_payload,
        selected_contact: selected_contact,
        selected_phone: selected_phone,
        current_next_text: current_sms_body_for_context,
        recent_unsent_drafts: recent_draft_texts.first(SMS_RECENT_DRAFT_LIMIT),
        latest_sms_event: compact_sms_event(latest_sms_event),
        latest_inbound_event: compact_sms_event(latest_inbound_sms_event),
        open_customer_messages: open_customer_messages_payload,
        open_customer_reply_requirements: open_customer_reply_requirements_payload,
        unanswered_outbound_question: unanswered_outbound_question_payload,
        latest_inbound_sms: latest_inbound_sms,
        recent_outbound_texts: recent_outbound_texts.first(SMS_RECENT_OUTBOUND_LIMIT),
        full_sms_thread: full_sms_thread,
        recent_sms_thread: recent_sms_thread,
        sms_options: Array(@metadata["sms_options"]).first(6),
        worker_rule: [current_specials_prompt_instruction, "Return only the next SMS body. Do not introduce, label, describe, quote, or wrap the message. Any prefix like 'Here's the next SMS body:' or 'Suggested reply:' is invalid. Do not explain your reasoning. Use training examples as voice/product guidance, not scripts. Use style_variation to avoid repeated phrasing. If open_customer_messages is present, answer every open customer message before asking one follow-up. Use open_customer_reply_requirements as the required fact checklist when present. Use style_variation to avoid repeated phrasing. If first_outbound is true and opening_offer is present, create a fresh natural opener for this lead and keep the first name when known. If the current route or lead source is Yard Signs, start in yard signs and do not ask the broad postcards/signs/both opener. Use customer-facing pricing language; never write 'the yard sign ladder I see' or 'the options I see.' If language metadata says the customer prefers another language, still write this internal draft in English; the SMS language layer translates after the quality gate."].compact_blank.join(" ")
      }.compact_blank
    end

    def support_alice_context_payload
      sms_thread = compact_sms_thread
      organization = @stage.organization || @stage.crm_record&.organization
      retrieval = if defined?(Comms::RagContext)
        Comms::RagContext.call(
          organization: organization,
          profile: rag_profile.fetch("key"),
          query: rag_semantic_query,
          limit: 4
        )
      else
        { profile: rag_profile.fetch("key"), scope: rag_profile.fetch("scope"), selected_documents: [], reason: "RAG context service unavailable" }
      end

      {
        assistant: "Thumper von AUTOS",
        rag_profile: rag_profile,
        support_contract: {
          source_of_truth: "Only the selected profile documents in retrieved_support and the current SMS thread",
          profile_scope: rag_profile.fetch("scope"),
          unknown_answer: "Say the answer could not be verified and offer operator confirmation; never invent a fact.",
          external_actions: "Never claim an external action occurred unless the supplied context explicitly confirms it."
        },
        retrieved_support: retrieval,
        operator_prompt: @operator_prompt.presence,
        latest_inbound_sms: latest_inbound_sms,
        latest_inbound_event: compact_sms_event(latest_inbound_sms_event),
        recent_sms_thread: sms_thread.last(SMS_THREAD_CONTEXT_LIMIT),
        current_next_text: current_sms_body_for_context,
        worker_rule: "Return only one concise customer SMS. Use only the selected profile documents and current thread. Never mix in another profile, invent facts, or claim an external action occurred without explicit confirmation."
      }.compact_blank
    end

    def rag_semantic_query
      return fine_training_semantic_query unless support_rag_profile?

      [
        latest_inbound_sms,
        @operator_prompt,
        rag_profile["label"],
        rag_profile["description"]
      ].compact_blank.join(" ").squish.truncate(1_200)
    end

    def style_variation_payload
      count = Array(@metadata["sms_draft_history"]).length + Array(@metadata["sms_thread"]).length
      seed = Digest::SHA1.hexdigest([@stage.id, latest_inbound_sms, count, Time.current.to_i / 90].join(":")).to_i(16)
      openers = [
        "direct and calm",
        "warm and practical",
        "quick owner-operator",
        "helpful and specific",
        "plainspoken sales assist"
      ]
      question_styles = [
        "ask the next question as a natural follow-up, not a form field",
        "tie the question to the customer's last answer",
        "lead with the useful recommendation, then ask one fit question",
        "make the question shorter than the answer",
        "avoid starting with 'About' or 'Roughly' if recent drafts did"
      ]
      banned_openings = (recent_outbound_texts + recent_draft_texts).filter_map do |text|
        text.to_s.squish.split(/[.?!]/).first
      end.first(6)

      {
        seed: seed % 10_000,
        tone: openers[seed % openers.length],
        question_style: question_styles[(seed / 7) % question_styles.length],
        avoid_openings: banned_openings,
        avoid_words: %w[roughly about quick idea right option]
      }
    end

    def model_pipeline_payload
      {
        writer_model: writer_model,
        writer_model_label: WizwikiSettings.sms_writer_model_label(writer_model),
        pipeline: "single_writer_guardrailed_self_repair",
        rule: "Use the selected SMS writer for composition. Rails enforces product facts and Thumper consultant voice; a failed cloud draft gets one focused self-repair before fallback.",
        self_repair: "one focused retry on a failed fact, completeness, repetition, or consultant-voice gate"
      }
    end

    def compact_fine_training_context
      context = fine_training_context
      return if context.blank?

      context.to_h.merge(
        selected_documents: Array(context[:selected_documents] || context["selected_documents"]).first(FINE_TRAINING_COMPACT_DOCUMENT_LIMIT).map do |document|
          item = document.to_h
          item.merge(
            excerpt: (item[:excerpt].presence || item["excerpt"]).to_s.squish.truncate(FINE_TRAINING_DOCUMENT_EXCERPT_CHARS, omission: "...")
          ).slice(:title, :source_type, :source_class, :file_name, :updated_at, :score, :retrieval_role, :usage_rule, :excerpt)
        end,
        selected_chunks: Array(context[:selected_chunks] || context["selected_chunks"]).first(FINE_TRAINING_COMPACT_CHUNK_LIMIT).map do |chunk|
          item = chunk.to_h
          item.merge(
            excerpt: (item[:excerpt].presence || item["excerpt"]).to_s.squish.truncate(FINE_TRAINING_CHUNK_EXCERPT_CHARS, omission: "...")
          ).slice(:label, :source_type, :source_id, :score, :retrieval_role, :retrieval_channels, :retrieval_rank_score, :retrieval_position, :usage_rule, :excerpt)
        end
      ).slice(:total_documents, :embedded_chunks_available, :selected_count, :selected_chunk_count, :voice_authority_count, :fact_authority_count, :training_selection_reason, :coverage_rule, :retrieval_mode, :retrieval_embedding_model, :retrieval_embedding_dimensions, :retrieval_embedding_cached, :retrieval_evidence, :retrieval_debug, :selected_documents, :selected_chunks)
    end

    def rag_trace_payload(context_payload, fine_training_payload)
      current_context_text = context_payload.to_h[:current_next_text].to_s.squish
      raw_current_text = current_sms_body.to_s.squish
      {
        route: current_route_code,
        latest_inbound: latest_inbound_sms.to_s.squish.truncate(180, separator: " "),
        current_next_text: current_context_text.presence&.truncate(220, separator: " "),
        current_next_text_skipped: raw_current_text.present? && current_context_text.blank? ? "Skipped stale current-next-text because it conflicted with the latest customer lane." : nil,
        fine_training: "#{Array(fine_training_payload[:selected_documents] || fine_training_payload['selected_documents']).length} docs / #{Array(fine_training_payload[:selected_chunks] || fine_training_payload['selected_chunks']).length} chunks",
        retrieval: (fine_training_payload[:retrieval_mode] || fine_training_payload["retrieval_mode"] || "keyword").to_s,
        retrieval_embedding_model: fine_training_payload[:retrieval_embedding_model] || fine_training_payload["retrieval_embedding_model"],
        retrieval_embedding_dimensions: fine_training_payload[:retrieval_embedding_dimensions] || fine_training_payload["retrieval_embedding_dimensions"],
        retrieval_evidence: Array(fine_training_payload[:retrieval_evidence] || fine_training_payload["retrieval_evidence"]).first(5),
        retrieval_debug: fine_training_payload[:retrieval_debug] || fine_training_payload["retrieval_debug"],
        profile: rag_profile.fetch("key"),
        scope: rag_profile.fetch("scope"),
        query: rag_semantic_query.truncate(700, separator: " "),
        documents: Array(fine_training_payload[:selected_documents] || fine_training_payload["selected_documents"]).first(3).map { |item| rag_trace_item(item, :document) },
        chunks: Array(fine_training_payload[:selected_chunks] || fine_training_payload["selected_chunks"]).first(3).map { |item| rag_trace_item(item, :chunk) },
        guidance: @guardrail_retry_instruction.to_s.squish.presence&.truncate(260, separator: " ")
      }.compact_blank
    rescue StandardError => error
      Rails.logger.warn("[CommsDraftWriter] rag trace unavailable: #{error.class}: #{error.message}")
      nil
    end

    def rag_trace_item(item, kind)
      data = item.to_h
      label = data[:title].presence || data["title"].presence ||
        data[:label].presence || data["label"].presence ||
        data[:file_name].presence || data["file_name"].presence ||
        kind.to_s
      score = data[:score].presence || data["score"].presence
      excerpt = data[:excerpt].presence || data["excerpt"].presence
      {
        label: label.to_s.squish.truncate(90, separator: " "),
        score: score,
        retrieval_role: data[:retrieval_role].presence || data["retrieval_role"].presence,
        excerpt: excerpt.to_s.squish.truncate(180, separator: " ")
      }.compact_blank
    end

    def compact_call_scenario_context
      context = call_scenario_context
      return if context.blank?

      context.to_h.merge(
        selected_calls: Array(context[:selected_calls] || context["selected_calls"]).first(CALL_SCENARIO_COMPACT_LIMIT).map do |call|
          item = call.to_h
          item.merge(
            context: (item[:context].presence || item["context"]).to_s.squish.truncate(CALL_SCENARIO_CONTEXT_CHARS, omission: "...")
          ).slice(:source_class, :title, :recorded_at, :occurred_at, :context)
        end
      ).slice(:source, :usage_rule, :selected_count, :selected_calls)
    end

    def compact_shopify_product_details_payload
      selected_routes = sms_shopify_detail_routes
      details = Array(shopify_product_details_payload)
      details = details.select { |detail| selected_routes.include?(detail.to_h[:code].to_s.presence || detail.to_h["code"].to_s) } if selected_routes.present?
      details.first(sms_all_product_details_needed? ? SHOPIFY_PRODUCT_DETAIL_LIMIT : SMS_SHOPIFY_PRODUCT_DETAIL_LIMIT).map do |detail|
          detail.to_h.merge(
            availability: product_availability_status(detail),
            price_table: Array(detail.to_h[:price_table] || detail.to_h["price_table"]).first(sms_all_product_details_needed? ? SHOPIFY_PRICE_ROW_LIMIT : SMS_SHOPIFY_PRICE_ROW_LIMIT),
            variants: Array(detail.to_h[:variants] || detail.to_h["variants"]).first(sms_all_product_details_needed? ? SHOPIFY_VARIANT_LIMIT : SMS_SHOPIFY_VARIANT_LIMIT)
          ).slice(:code, :label, :title, :url, :availability, :included, :shipping_note, :price_table, :variants)
        end
      end

    def sms_all_product_details_needed?
      text = [latest_inbound_sms, @operator_prompt].compact.join(" ")
      full_options_pricing_question?(text) ||
        text.to_s.match?(/\b(?:all|every|full|complete)\b.{0,40}\b(?:links?|options?|packages?|deals?|products?|prices?|pricing|costs?)\b/i)
    end

    def sms_shopify_detail_routes
      text = [latest_inbound_sms, @operator_prompt].compact.join(" ")
      explicit_print_routes = explicit_standalone_print_routes(text)
      return explicit_print_routes if explicit_print_routes.present?
      return %w[LAWN_SIGNS] if signs_only_context?
      return %w[PRO_PACK STARTER_PACK BUSINESS_CARDS DOOR_HANGERS FLYERS EDDM NEIGHBORHOOD_BLITZ LAWN_SIGNS] if sms_all_product_details_needed?

      fit = campaign_fit_payload
      candidates = []
      candidates << current_route_code
      candidates << latest_inbound_route_code
      candidates << inferred_product_route_from_fit
      candidates << recent_bundle_route_from_thread

      if fit[:wants_both] || multi_product_link_request?(text)
        candidates.concat(%w[NEIGHBORHOOD_BLITZ EDDM LAWN_SIGNS])
      elsif fit[:wants_bundle] || bundle_family_interest?(text)
        candidates.concat(%w[PRO_PACK STARTER_PACK])
      elsif fit[:wants_signs] || sign_interest?(text)
        candidates.concat(%w[LAWN_SIGNS STARTER_PACK PRO_PACK])
      elsif business_card_interest?(text)
        candidates.concat(%w[BUSINESS_CARDS STARTER_PACK PRO_PACK])
      elsif door_hanger_interest?(text)
        candidates.concat(%w[DOOR_HANGERS STARTER_PACK PRO_PACK])
      elsif flyer_interest?(text)
        candidates.concat(%w[FLYERS])
      elsif fit[:wants_postcards] || postcard_interest?(text)
        candidates.concat(%w[EDDM NEIGHBORHOOD_BLITZ])
      end

      case candidates.compact_blank.first.to_s
      when "PRO_PACK"
        candidates.concat(%w[STARTER_PACK LAWN_SIGNS])
      when "STARTER_PACK"
        candidates.concat(%w[PRO_PACK LAWN_SIGNS])
      when "BUSINESS_CARDS"
        candidates.concat(%w[STARTER_PACK PRO_PACK])
      when "DOOR_HANGERS"
        candidates.concat(%w[STARTER_PACK PRO_PACK])
      when "FLYERS"
        candidates.concat(%w[STORE])
      when "EDDM"
        candidates.concat(%w[NEIGHBORHOOD_BLITZ LAWN_SIGNS])
      when "NEIGHBORHOOD_BLITZ"
        candidates.concat(%w[EDDM LAWN_SIGNS])
      when "LAWN_SIGNS"
        candidates.concat(%w[STARTER_PACK PRO_PACK])
      end

      available = sendable_shopify_links.keys
      candidates.compact_blank.map(&:to_s).uniq.select { |route| available.include?(route) }.first(SMS_SHOPIFY_PRODUCT_DETAIL_LIMIT).presence ||
        %w[PRO_PACK STARTER_PACK BUSINESS_CARDS DOOR_HANGERS FLYERS LAWN_SIGNS]
    end

def explicit_standalone_print_routes(text)
  body = text.to_s.downcase.squish
  return [] if body.blank?

  routes = []
  routes << "BUSINESS_CARDS" if business_card_only_intent?(body)
  routes << "DOOR_HANGERS" if door_hanger_only_intent?(body)
  routes << "FLYERS" if flyer_only_intent?(body)
  routes.uniq
end

def campaign_fit_payload
  events = sms_thread_events
  thread_text = events.filter_map do |event|
    next unless event["direction"].to_s == "inbound"

    event["body"].to_s.squish.presence
  end.join("\n")
  explicit_lane_route = latest_explicit_lane_route_from_thread(events)
  budget = extract_budget_signal(thread_text) || contextual_numeric_signal(events, :budget)
  household_count = extract_household_count_signal(thread_text) || contextual_numeric_signal(events, :household_count)
  quantity_count = extract_quantity_signal(thread_text) || contextual_numeric_signal(events, :quantity)
  artwork_status = artwork_status_signal(thread_text)
  wants_signs = sign_interest?(thread_text)
  wants_postcards = postcard_interest?(thread_text)
  wants_bundle = bundle_family_interest?(thread_text)
  wants_both = thread_text.match?(/\b(both|combo|combined?|combination|bundle|pack|pro pack|starter pack|blitz|signs?\s*(?:and|\+)\s*(?:post\s*cards?|postcards?)|(?:post\s*cards?|postcards?)\s*(?:and|\+)\s*signs?)\b/i) ||
    (wants_signs && wants_postcards)
  case explicit_lane_route
  when "EDDM"
    wants_signs = false
    wants_postcards = true
    wants_bundle = false
    wants_both = false
  when "LAWN_SIGNS"
    wants_signs = true
    wants_postcards = false
    wants_bundle = false
    wants_both = false
  when "NEIGHBORHOOD_BLITZ"
    wants_signs = true
    wants_postcards = true
    wants_both = true
  end
  needs_household_signal = wants_postcards || wants_both
  {
    budget: budget,
    household_count: household_count,
    quantity_count: quantity_count,
    wants_signs: wants_signs,
    wants_postcards: wants_postcards,
    wants_bundle: wants_bundle,
    wants_both: wants_both,
    artwork_status: artwork_status,
    missing_fit_signals: [
      (wants_signs && quantity_count.blank? ? "sign_quantity" : nil),
      (needs_household_signal && household_count.blank? ? "homes_or_households_to_reach" : nil),
      (wants_signs || wants_postcards || wants_both ? nil : "postcards_signs_or_both"),
      (artwork_status.blank? ? "artwork_status" : nil)
    ].compact
  }.compact_blank
end

def latest_explicit_lane_route_from_thread(events = sms_thread_events)
  Comms::SmsLaneResolver.latest_explicit_lane_route(events)
end

def latest_explicit_product_route_from_thread(events = sms_thread_events)
  Array(events).reverse_each do |event|
    event = event.to_h
    next unless event["direction"].to_s == "inbound"

    standalone_route = explicit_standalone_print_routes(event["body"]).first
    return standalone_route if standalone_route.present?

    lane_route = explicit_lane_route_for_text(event["body"])
    return lane_route if lane_route.present?
  end

  nil
end

def explicit_lane_route_for_text(text)
  Comms::SmsLaneResolver.explicit_lane_route(text)
end

def sms_thread_events
  thread = @metadata["recursive_dojo_isolated_thread"].presence || @metadata["sms_thread"]
  events = Array(thread).map(&:to_h).select { |event| sms_event_after_reset?(event) }
  if @metadata["recursive_dojo_isolated_thread"].present? ||
      ActiveModel::Type::Boolean.new.cast(@metadata["ask_autopilot_test"]) ||
      ActiveModel::Type::Boolean.new.cast(@metadata["comms_simulation_mode"])
    return events
  end

  events.each_with_index.sort_by do |event, index|
    [sms_event_time(event) || Time.zone.at(0), index]
  end.map(&:first)
end

def sms_conversation_reset_time
  value = @metadata["sms_conversation_reset_at"].to_s
  return if value.blank?

  Time.zone.parse(value)
rescue ArgumentError, TypeError
  nil
end

def discovery_reset_active?
  ActiveModel::Type::Boolean.new.cast(@metadata["sms_discovery_reset"]) && sms_conversation_reset_time.present?
end

def sms_event_after_reset?(event)
  reset_at = sms_conversation_reset_time
  return true if reset_at.blank?

  event_time = sms_event_time(event)
  event_time.present? && event_time >= reset_at
end

def sms_event_time(event)
  value = event["created_at"].presence || event["at"].presence || event["timestamp"].presence || event["date_created"].presence
  return if value.blank?

  Time.zone.parse(value.to_s)
rescue ArgumentError, TypeError
  nil
end

def sms_thread_body_for_context(event)
  event = event.to_h
  body = event["body"].to_s.squish
  if event["direction"].to_s == "outbound" &&
      !ActiveModel::Type::Boolean.new.cast(event["language_preference_notice"]) &&
      event["english_body"].to_s.squish.present?
    body = event["english_body"].to_s.squish
  end
  return body if body.blank?
  return body unless event["direction"].to_s == "outbound"
  return body unless defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(body)

  "[prior outbound internal draft blocked from Thumper context]"
end

def compact_sms_thread
  sms_thread_events.filter_map do |event|
    body = sms_thread_body_for_context(event)
    next if body.blank?

    {
      at: event["created_at"],
      direction: event["direction"],
      status: event["status"],
      route: event["processing_code"],
      label: event["processing_label"],
      body: body
    }.compact_blank
  end
end

def compact_sms_event(event)
  item = event.to_h
  body = sms_thread_body_for_context(item)
  return if body.blank?

  {
    at: item["created_at"].presence || item["at"].presence || item["timestamp"].presence,
    direction: item["direction"],
    status: item["status"],
    route: item["processing_code"],
    label: item["processing_label"],
    body: body
  }.compact_blank
end

def latest_sms_event
  sms_thread_events.reverse.find do |event|
    channel = event["channel"].to_s
    (channel.blank? || channel == "sms") && event["body"].to_s.squish.present?
  end
end

def unanswered_outbound_question?
  event = latest_sms_event
  return false unless event.present?
  return false unless event["direction"].to_s == "outbound"

  event["body"].to_s.include?("?")
end

def unanswered_outbound_question_payload
  return unless unanswered_outbound_question?

  event = latest_sms_event
  {
    body: event["body"].to_s.squish,
    sent_at: event["created_at"],
    route_code: current_route_code,
    next_discovery_question: next_unanswered_discovery_question
  }.compact_blank
end

def unanswered_question_follow_up
  question = next_unanswered_discovery_question
  return unknown_reply if question.blank?

  prefix = fallback_variant([
    "No rush.",
    "When you get a second,",
    "One quick thing that would help:"
  ])
  [prefix, question].join(" ").squish
end

def next_unanswered_discovery_question
  route = current_route_code
  return handoff_reply(route) if link_fit_ready?(route)
  return next_route_fit_question(route) || identity_collection_reply if route.present?

  fit = campaign_fit_payload
  return "About how many signs do you want to start with?" if route.to_s == "LAWN_SIGNS" && fit[:quantity_count].blank? && !recently_asked?("About how many signs do you want to start with?")
  return "About how many homes do you want to reach?" if fit[:household_count].blank? && !recently_asked?("About how many homes do you want to reach?")
  return options_link_fit_question if options_link_fit_question_needed?(route)
  return "Do you already have artwork or a logo, or should WIZWIKI help build the design?" if fit[:artwork_status].blank? && !recently_asked?("Do you already have artwork or a logo, or should WIZWIKI help build the design?")

  case next_missing_identity_field
  when "contact_name"
    "What name should I put on this conversation?"
  when "company_name"
    "What company should I connect this to?"
  else
    "Are you leaning toward postcards, yard signs, or both?"
  end
end

def extract_budget_signal(text)
  return nil if text.blank?

  return "open budget" if open_budget_signal?(text)
  if (amount = explicit_budget_value(text))
    return format_budget_amount(amount)
  end

  if (match = text.match(/\$\s?[\d,.]+(?:\.\d+)?\s*[km]\b(?:\s*(?:-|to)\s*\$?\s*[\d,.]+(?:\.\d+)?\s*[km]?\b)?/i))
    return match[0].squish
  end
  if (match = text.match(/\b[\d,.]+(?:\.\d+)?\s*[km]\b(?!\s*(?:homes?|houses?|households?|doors?|addresses?|mailboxes?|signs?))/i))
    return match[0].squish
  end
  if (match = text.match(/\$\s?[\d,]+(?:\s?(?:-|to)\s?\$?\s?[\d,]+)?/))
    return match[0].squish
  end
    if (match = text.match(/\b(?:budget|spend|around|under|up to|about)\s+\$?([\d,.]+(?:\.\d+)?\s*[km]?)\b/i))
      return match[0].squish unless budget_match_has_quantity_unit?(text, match)
    end
    nil
  end

def explicit_budget_value(text)
  body = text.to_s.downcase.squish
  return nil if body.blank?
  return 100 if body.match?(/\b(?:a\s+|one\s+)?hundred\s+(?:dollars?|dolla(?:rs?)?|bucks?)\b/)

  if (match = body.match(/\$\s*([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?/i))
    return explicit_budget_match_value(match)
  end
  if (match = body.match(/\b([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?\s*(?:dollars?|dolla(?:rs?)?|bucks?)\b/i))
    return explicit_budget_match_value(match)
  end
  if (match = body.match(/\b(?:budget|spend|around|under|up to|about|for|with)\s+\$?\s*([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?/i))
    return explicit_budget_match_value(match) unless budget_match_has_quantity_unit?(body, match)
  end
  nil
end

def explicit_budget_match_value(match)
  base = match[1].to_s.delete(",").to_f
  return nil unless base.positive?

  suffix = match[2].to_s.downcase
  base *= 1_000 if suffix == "k"
  base *= 1_000_000 if suffix == "m"
  base == base.round ? base.round : base
end

def format_budget_amount(value)
  amount = value.to_f
  return "$#{format_quantity_count(amount.round)}" if amount == amount.round

  dollars, cents = format("%.2f", amount).split(".")
  "$#{format_quantity_count(dollars.to_i)}.#{cents}"
end

def budget_match_has_quantity_unit?(text, match)
  tail = text.to_s[match.end(0), 48].to_s
  tail.match?(/\A\s*(?:yard\s+signs?|lawn\s+signs?|signs?|post\s*cards?|postcards?|cards?|door\s+hangers?|hangers?|homes?|houses?|households?|doors?|addresses?|mailboxes?|pieces?|units?)\b/i)
end

def open_budget_signal?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(no budget|open budget|budget(?:'s| is)? open|budget(?:'s| is)? flexible|flexible budget|no cap|no limit|whatever it takes|spend what it takes)\b/)
end

def decline_without_product_fit?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || open_budget_signal?(body)

  body.match?(/\b(no thanks|not interested|not now|maybe later|later)\b/) || body.match?(/\A(?:no|nope|nah)\z/)
end

def business_context_ready?
  business_context_value.present?
end

def business_context_value
  company = conversation_company_name
  return company if company.present?

  industry = industry_value
  return industry if industry.present?

  business_context_from_thread
end

def business_context_from_thread
  text = inbound_sms_thread_text
  return if text.blank?

  inferred = infer_industry_from_company_name(text)
  return inferred if inferred.present?

  if (match = text.match(/\b(?:promot(?:e|ing)|campaign for|using (?:these|this) for|this is for|we are|we're|i own|i run|my company|my business)\s+([^.!?\n]{3,80})/i))
    return match[1].to_s.squish
  end

  nil
end

    def inbound_sms_thread_text
      sms_thread_events.filter_map do |event|
        next unless event.to_h["direction"].to_s == "inbound"

        event.to_h["body"].to_s.squish.presence
      end.join("\n")
    end

    def inferred_industry_from_thread
      infer_industry_from_company_name(inbound_sms_thread_text)
    end

def business_context_question(route = current_route_code)
  return if business_context_ready?

  already_asked = recent_outbound_texts.any? do |body|
    body.match?(/\b(what kind of business|business are we helping|what are we promoting|what offer are we promoting|company or offer)\b/i)
  end
  return if already_asked

  case route.to_s
  when "LAWN_SIGNS"
    "I can point you to the right sign option. What kind of business are these signs for?"
  when "BUSINESS_CARDS"
    "I can point you to the right business-card option. What kind of business are these for?"
  when "DOOR_HANGERS"
    "I can point you to the right door-hanger option. What kind of business are these for?"
  when "FLYERS"
    "I can point you to the right flyer option. What kind of business or event are these for?"
  when "EDDM"
    "I can point you to the right postcard option. What kind of business or offer are we promoting?"
  when "PRO_PACK", "STARTER_PACK", "NEIGHBORHOOD_BLITZ"
    "I can point you to the right bundle. What kind of business are we helping promote?"
  else
    "I can point you to the right option. What kind of business or offer are we promoting?"
  end
end

  def contextual_numeric_signal(events, kind)
    Array(events).each_with_index.reverse_each do |event, index|
      next unless event.to_h["direction"].to_s == "inbound"

      body = event.to_h["body"].to_s.squish
      previous = previous_outbound_body(events, index)
      if kind == :quantity
        confirmation_quantity = checkout_confirmation_quantity(body)
        if confirmation_quantity.present? &&
            previous.match?(/\b(quantity|qty|signs?|yard signs?|lawn signs?|jobsite signs?|tier|checkout option|listed quantities)\b/i) &&
            !previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach|mail|target)\b/i)
          return "#{confirmation_quantity} signs"
        end
      end

      if (contextual_value = contextual_embedded_numeric_signal(body, previous, kind))
        return contextual_value
      end

      match = body.match(/\A\$?\s*([\d,]{2,6})\s*\z/)
      next unless match

      number = match[1].tr(",", "")
      if kind == :budget
        next unless explicit_budget_value(body).present? || (previous.match?(/\b(budget|spend|price|cost|dollars?|dolla(?:rs?)?|bucks?)\b/i) && !previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach)\b/i))

      return "$#{number}"
      end

    if kind == :quantity
      next unless previous.match?(/\b(quantity|qty|signs?|yard signs?|lawn signs?|jobsite signs?)\b/i)
      next if previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach|mail|target)\b/i)

      return "#{number} signs"
    end

    next if kind == :household_count && zip_like_reply_after_location_question?(body, previous)
    next unless previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach|mail|target)\b/i)

    return "#{number} homes"
    end
    nil
  end

def contextual_embedded_numeric_signal(body, previous, kind)
  body = body.to_s.squish
  previous = previous.to_s.squish
  return if body.blank? || previous.blank?

  match = body.match(/\b([\d,]{2,6})\b/)
  return if match.blank?

  number = match[1].tr(",", "")
  return if number.blank?

  case kind
  when :household_count
    return if zip_like_reply_after_location_question?(body, previous)
    return unless previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach|mail|target)\b/i)
    return if body.match?(/\b(?:\$|budget|spend|cost|price|dollars?|dolla(?:rs?)?|bucks?)\b/i)

    "#{number} homes"
  when :quantity
    return unless previous.match?(/\b(quantity|qty|signs?|yard signs?|lawn signs?|jobsite signs?)\b/i)
    return if previous.match?(/\b(home count|homes?|households?|doors?|addresses?|mailboxes?|reach|mail|target)\b/i)

    "#{number} signs"
  end
end

def zip_like_reply_after_location_question?(body, previous)
  return false unless body.to_s.squish.match?(/\A\d{5}(?:-\d{4})?\z/)

  previous.to_s.match?(/\b(zip|postal|service area|location|where|specific area|neighbou?rhood|route area|mailing area|area)\b/i)
end

def previous_outbound_body(events, index)
  Array(events)[0...index].to_a.reverse_each do |event|
    event = event.to_h
    next unless event["direction"].to_s == "outbound"

    body = event["body"].to_s.squish
    return body if body.present?
  end
  ""
end

def extract_household_count_signal(text)
  return nil if text.blank?

  if (match = text.match(/\b(?:reach|mail|send|target)?\s*([\d,]{2,6})\s*(homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/i))
    return match[0].squish
  end
  nil
end

def extract_quantity_signal(text)
  return nil if text.blank?

  if (match = text.match(/\b([\d,]{1,6})\s*(yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i))
    return match[0].squish
  end
  nil
end

def artwork_status_signal(text)
  body = text.to_s.downcase
  return "needs_wizwiki_help" if body.match?(/\b(need|needs|want|wants|help)\b.*\b(art|artwork|design|creative|layout)\b/) || body.match?(/\b(no|don't have|do not have|without)\b.*\b(art|artwork|design|creative|file)\b/)
  return "has_artwork" if body.match?(/\b(have|has|ready|already)\b.*\b(art|artwork|design|creative|logo|file)\b/)

  nil
end

def inferred_product_route_from_fit
  fit = campaign_fit_payload
  links = sendable_shopify_links
  budget = numeric_budget_value(fit[:budget])
  households = numeric_household_value(fit[:household_count])

  if fit[:wants_both]
    return "NEIGHBORHOOD_BLITZ" if links["NEIGHBORHOOD_BLITZ"].present?
    return "PRO_PACK" if links["PRO_PACK"].present? && open_budget_signal?(fit[:budget])
    return "PRO_PACK" if links["PRO_PACK"].present? && ((budget.present? && budget >= 1_000) || (households.present? && households >= 1_000))
    return "EDDM" if links["EDDM"].present?
    return "LAWN_SIGNS" if links["LAWN_SIGNS"].present?
    return "STARTER_PACK" if links["STARTER_PACK"].present?
    return "NEIGHBORHOOD_BLITZ"
  end

  if fit[:wants_bundle]
    return "PRO_PACK" if links["PRO_PACK"].present? && open_budget_signal?(fit[:budget])
    return "PRO_PACK" if links["PRO_PACK"].present? && ((budget.present? && budget >= 1_000) || (households.present? && households >= 1_000))
    return "STARTER_PACK" if links["STARTER_PACK"].present?
    return "PRO_PACK" if links["PRO_PACK"].present?
    return "STARTER_PACK"
  end

  return "LAWN_SIGNS" if fit[:wants_signs] && !fit[:wants_postcards]
  return "EDDM" if fit[:wants_postcards] && !fit[:wants_signs]

  nil
end

def numeric_budget_value(value)
  numeric_shorthand_value(value)
end

def numeric_household_value(value)
  numeric_shorthand_value(value)
end

def numeric_quantity_value(value)
  numeric_shorthand_value(value)
end

def format_quantity_count(value)
  value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
end

def numeric_shorthand_value(value)
  text = value.to_s
  return nil if text.blank?

  if (match = text.match(/([\d,]+(?:\.\d+)?)\s*([km])\b/i))
    base = match[1].delete(",").to_f
    multiplier = match[2].downcase == "m" ? 1_000_000 : 1_000
    return (base * multiplier).round
  end

  text[/\d[\d,]*/].to_s.tr(",", "").presence&.to_i
end

def usable_budget_signal?(value)
  return true if open_budget_signal?(value)

  budget = numeric_budget_value(value)
  budget.present? && budget >= MIN_SELF_CHECKOUT_BUDGET
end

def low_budget_signal?(value)
  budget = numeric_budget_value(value)
  budget.present? && budget.positive? && budget < MIN_SELF_CHECKOUT_BUDGET
end

def budget_adjusted_route(route)
  route = route.to_s.presence
  return route if route.blank?

  fit = campaign_fit_payload
  budget = numeric_budget_value(fit[:budget])
  households = numeric_household_value(fit[:household_count])
  quantity = numeric_quantity_value(fit[:quantity_count])

  links = sendable_shopify_links
  if route.in?(%w[STARTER_PACK EDDM NEIGHBORHOOD_BLITZ]) && links["PRO_PACK"].present? && open_budget_signal?(fit[:budget])
    return "PRO_PACK" if fit[:wants_both] || fit[:wants_postcards] || households.present? || quantity.present?
  end

  if route == "STARTER_PACK" && links["PRO_PACK"].present? && budget.present? && budget >= PRO_PACK_BUDGET_FLOOR
    return "PRO_PACK" if fit[:wants_both] || (households.present? && households >= 1_000) || (quantity.present? && quantity >= 50) || budget >= LARGE_CAMPAIGN_BUDGET
  end

  route
end

    def autopilot_payload
      objective = @metadata["sms_autopilot_objective"].presence
      objective = nil if stale_handoff_objective?(objective)
      {
        enabled: ActiveModel::Type::Boolean.new.cast(@metadata["sms_autopilot_enabled"]),
        objective: objective || default_sms_autopilot_objective,
        turn_limit: @metadata["sms_autopilot_turn_limit"],
        sent_count: @metadata["sms_autopilot_sent_count"],
        last_sent_at: @metadata["sms_autopilot_last_sent_at"],
        disabled_reason: @metadata["sms_autopilot_disabled_reason"]
      }.compact_blank
    end

    def stale_handoff_objective?(value)
      value.to_s.match?(/route\s+to\s+contact_owner\s+only\s+when\s+the\s+customer\s+explicitly\s+asks\s+for\s+a\s+human/i)
    end

    def default_sms_autopilot_objective
      Thumper::VoiceGuide.autopilot_objective
    end

    def route_assignment_payload
      {
        routed: @metadata["comms_route_claimed_at"].present?,
        owner_name: handoff_owner_name,
        owner_email: @metadata["comms_routed_to_user_email"].presence,
        owner_id: @metadata["comms_routed_to_user_id"].presence
      }.compact_blank
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

    def selected_address
      @metadata["aircall_selected_address"].to_h.presence || option_by_id("address_options", "selected_address_id")
    end

    def option_by_id(options_key, selected_key)
      selected_id = @metadata[selected_key].to_s
      options = Array(@metadata[options_key])
      match = options.find { |option| option.to_h["id"].to_s == selected_id }
      (match || options.first).to_h
    end

    def current_sms_body
      @metadata["comms_command_sms_draft_body"].presence ||
        @metadata["aircall_composed_sms_body"].presence ||
        @metadata["composed_sms_body"].presence ||
        option_by_id("sms_options", "selected_sms_id")["body"].to_s
    end

    def current_sms_body_for_context
      body = current_sms_body.to_s.squish
      return if body.blank?
      return if stale_current_sms_body_for_latest_lane?(body)

      body
    end

    def stale_current_sms_body_for_latest_lane?(body)
      latest = latest_inbound_sms.to_s.squish
      return false if latest.blank? || body.blank?

      latest_wants_signs = sign_interest?(latest)
      latest_wants_mail = postcard_interest?(latest) || latest.match?(/\b(?:eddm|direct mail|mailers?|mailboxes?|homes?|households?|doors?)\b/i)
      body_talks_signs = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i)
      body_talks_mail = body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mailboxes?|homes?|households?|doors?|4th\s+of\s+july|block sale)\b/i)

      return true if latest_wants_signs && body_talks_mail && !body_talks_signs
      return true if latest_wants_mail && body_talks_signs && !body_talks_mail

      false
    end

    def recent_draft_texts
      history = Array(@metadata["sms_draft_history"]).filter_map do |entry|
        entry.to_h["body"].to_s.squish.presence
      end
      ([current_sms_body_for_context.to_s.squish.presence] + history).compact_blank.reverse.uniq.first(8)
    end

    def manual_regeneration_prompt?
      @operator_prompt.match?(/Manual rewrite id|recent unsent drafts|materially different next SMS/i)
    end

    def reset_conversation_prompt?
      @operator_prompt.match?(/\bCONVERSATION RESET MODE\b/i)
    end

    def reset_conversation_opening_fallback
      first = customer_first_name
      greeting = first.present? ? "Hi #{first}, I'm Thumper from WIZWIKI Marketing." : "Hi, I'm Thumper from WIZWIKI Marketing."
      fallback_variant([
        "#{greeting} I'm here to answer as many questions as I can and help you feel good about the next step with WIZWIKI. Are you thinking postcards, yard signs, or both?",
        "#{greeting} let's sort through the options and keep this simple. Are you looking for postcards, yard signs, or both?",
        "#{greeting} Ask me anything you need, and I'll help point you toward the right WIZWIKI option. Are you trying to reach mailboxes with postcards, get yard signs in the ground, or do both?",
        "#{greeting} we can make the next step clear and choose the right WIZWIKI path. Do you need postcards, yard signs, or both?"
      ])
    end

    def operator_prompt_design_guidance?
      @operator_prompt.match?(/\b(?:artwork|design|designer|ai designer|bring (?:their|your|own)|own art|own artwork|logo|creative|finished design)\b/i)
    end

    def operator_prompt_logo_guidance?
      @operator_prompt.match?(/\b(?:logo|brand mark|use their logo|use your logo|bring their logo|bring your logo)\b/i)
    end

    def latest_inbound_sms
      latest_inbound_sms_event&.dig("body").to_s.presence
    end

    def latest_inbound_sms_event
      sms_thread_events.reverse.find do |event|
        channel = event["channel"].to_s
        (channel.blank? || channel == "sms") &&
          event["direction"].to_s == "inbound" &&
          event["body"].to_s.squish.present?
      end
    end

    def open_customer_messages_payload
      current_open_customer_message_bodies.filter_map do |body|
        event = active_open_inbound_sms_events.find { |candidate| candidate.to_h["body"].to_s.squish == body }
        payload = event.present? ? compact_sms_event(event) : { body: body }
        payload.to_h.merge(body: body).compact_blank
      end
    end

    def open_customer_reply_requirements_payload
      current_open_customer_message_bodies.each_with_index.filter_map do |message, index|
        required = open_customer_message_answer_required?(message)
        hint = open_customer_answer_hint(message)
        next if !required && hint.blank?

        {
          position: index + 1,
          body: message,
          answer_required: required,
          answer_hint: hint
        }.compact_blank
      end
    end

    def open_customer_answer_hint(message)
      body = message.to_s.squish
      return if body.blank?

      hints = []
      if current_specials_question?(body) || postcard_special_all_tiers_request?(body) || postcard_special_quantity_followup?(body)
        hints << current_specials_reply(body)
      end

      if pricing_intent?(body)
        pricing = pricing_reply(body)
        hints << pricing if pricing.present?
      end

      if design_process_question?(body) || design_process_priority_question?(body) || proof_handoff_request?(body)
        hints << "Answer proof/design directly: the customer reviews and approves a proof before anything prints; after checkout, the intake form collects logo, artwork, wording, and notes."
      end

      if yard_sign_included_items_question?(body)
        hints << "For Yard Signs, design help, stakes, and shipping are included in the listed price; different front/back designs add $125."
      end

      if turnaround_question?(body) || rush_checkout_boundary_question?(body)
        hints << "Answer timing/rush directly. Rush is handled through a marketing consultant before normal checkout; rush starts after proof approval, moves production ahead, and shipping is still usually UPS/FedEx ground."
      end

      if print_products_question?(body)
        hints << print_products_reply(body)
      end

      if messy_print_consultant_question?(body)
        hints << messy_print_consultant_reply
      end

      if direct_mail_strategy_handoff_question?(body)
        hints << direct_mail_strategy_handoff_reply
      end

      hints.compact_blank.join(" ").squish.truncate(700, separator: " ").presence
    end

    def open_inbound_sms_events
      events = sms_thread_events
      last_outbound_index = events.rindex do |event|
        channel = event["channel"].to_s
        (channel.blank? || channel == "sms") &&
          event["direction"].to_s == "outbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled blocked skipped])
      end
      candidates = last_outbound_index ? events[(last_outbound_index + 1)..] : events
      Array(candidates).select do |event|
        channel = event["channel"].to_s
        (channel.blank? || channel == "sms") &&
          event["direction"].to_s == "inbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled blocked skipped])
      end
    end

    def active_open_inbound_sms_events
      events = open_inbound_sms_events
      return events if events.length < 2

      latest = events.last.to_h["body"].to_s
      return events unless superseding_customer_pivot_message?(latest)

      events.reject.with_index do |event, index|
        next false if index == events.length - 1

        open_message_superseded_by_later_pivot?(event.to_h["body"].to_s, latest)
      end
    end

      def recent_outbound_texts
        sms_thread_events.reverse_each.filter_map do |event|
          channel = event["channel"].to_s
          next unless channel.blank? || channel == "sms"
          next unless event["direction"].to_s == "outbound"

          event["body"].to_s.squish.presence
        end
      end

      def recent_outbound_texts_before_latest_inbound
        found_latest_inbound = false
        sms_thread_events.reverse_each.filter_map do |event|
          channel = event["channel"].to_s
          next unless channel.blank? || channel == "sms"

          if !found_latest_inbound
            if event["direction"].to_s == "inbound" && event["body"].to_s.squish.present?
              found_latest_inbound = true
            end
            next
          end

          next unless event["direction"].to_s == "outbound"

          event["body"].to_s.squish.presence
        end
      end

    def prior_thumper_thread_messages
      recent_outbound_texts.reverse
    end

    def webhook_auto_prompt?
      @operator_prompt.match?(/\ACustomer replied from .+ Draft the best next short SMS reply/i)
    end

    def company_name
      explicit = @metadata["company_name"].presence
      return explicit if explicit.present?

      record_name = @stage&.crm_record&.name.to_s.squish.presence
      contact_name = @metadata["captured_contact_name"].presence || selected_contact["name"].to_s.squish.presence
      return nil if record_name.present? && contact_name.present? && record_name.casecmp(contact_name).zero?

      record_name || @stage&.title
    end

def identity_payload
  missing = missing_discovery_fields

  {
    missing: missing,
    known: {
      product_interest: current_route_code.present?,
      contact_name: conversation_contact_name.present?,
      company_name: conversation_company_name.present?,
      industry: industry_value.present?
    },
    next_missing_field: next_missing_discovery_field,
    captured_contact_name: @metadata["captured_contact_name"],
    captured_company_name: @metadata["captured_company_name"],
    captured_industry: @metadata["captured_industry"],
    prompt_if_missing: "Ask for exactly one missing discovery field naturally so WIZWIKI can save the conversation correctly."
  }.compact
end

def product_offerings_document
  if defined?(Autos::ContextCache)
    Autos::ContextCache.comms_product_offerings(PRODUCT_OFFERINGS_PATH)
  else
    PRODUCT_OFFERINGS_PATH.exist? ? PRODUCT_OFFERINGS_PATH.read.first(12_000) : nil
  end
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] product offerings document unavailable: #{error.class}: #{error.message}")
  nil
end

def sms_examples
  return unless SMS_EXAMPLES_PATH.exist?

  selected_sms_examples(SMS_EXAMPLES_PATH.read).first(SMS_EXAMPLES_CHARS)
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] Thumper SMS RAG examples unavailable: #{error.class}: #{error.message}")
  nil
end

def sms_skills
  return unless SMS_SKILLS_PATH.exist?

  selected_sms_skills(SMS_SKILLS_PATH.read).first(SMS_SKILLS_CHARS)
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] Thumper SMS skills unavailable: #{error.class}: #{error.message}")
  nil
end

def selected_sms_skills(raw)
  sections = raw.to_s.split(/(?=^## Skill:)/)
  intro = sections.shift.to_s.strip
  return intro if sections.blank?

  open_messages = current_open_customer_message_bodies
  latest_inbound = latest_inbound_sms.to_s.downcase.squish
  context = [latest_inbound, open_messages, recent_sms_context, current_route_code].flatten.compact.join(" ").downcase
  core = sections.select { |section| section.match?(/^## Skill: (?:Latest-Message First|Consultant Voice And Self-Correction)/i) }
  ranked = sections.map do |section|
    score = sms_skill_score(section, context) + sms_skill_intent_bonus(section, latest_inbound, open_messages)
    [score, section]
  end
    .select { |score, _section| score.positive? }
    .sort_by { |score, section| [-score, section[/^## Skill:\s*(.+)$/, 1].to_s] }
    .map(&:last)
  selected = (core + ranked).uniq.first(SMS_SKILLS_SECTION_LIMIT)
  selected = (core + sections.first(SMS_SKILLS_SECTION_LIMIT)).uniq.first(SMS_SKILLS_SECTION_LIMIT) if selected.blank?

  ([intro] + selected).join("\n\n").strip
end

def sms_skill_score(section, context)
  body = section.to_s.downcase
  pairs = [
    [%r{\b(?:yard|lawn|jobsite|directional)?\s*signs?\b}, %r{\b(?:yard|lawn|jobsite|directional)?\s*signs?\b}, 9],
    [%r{\b(?:postcards?|eddm|direct mail|mailers?|routes?|homes?|mailboxes?)\b}, %r{\b(?:postcards?|eddm|direct mail|mailers?|routes?|homes?|mailboxes?)\b}, 9],
    [%r{\b(?:price|pricing|cost|how much|quote|deal|special)\b}, %r{\b(?:price|pricing|cost|how much|quote|deal|special)\b}, 7],
    [%r{\b(?:link|checkout|order|buy|ready)\b}, %r{\b(?:link|checkout|order|buy|ready)\b}, 6],
    [%r{\b(?:design|logo|art|artwork|proof|upload|intake)\b}, %r{\b(?:design|logo|art|artwork|proof|upload|intake)\b}, 6],
    [%r{\b(?:rush|timeline|turnaround|shipping|deadline|fast)\b}, %r{\b(?:rush|timeline|turnaround|shipping|deadline|fast)\b}, 6],
    [%r{\b(?:business cards?|door hangers?|flyers?|rack cards?|print)\b}, %r{\b(?:business cards?|door hangers?|flyers?|rack cards?|print)\b}, 6],
    [%r{\b(?:person|human|consultant|reach out|call me|handoff)\b}, %r{\b(?:person|human|consultant|reach out|call me|handoff)\b}, 5],
    [%r{\b(?:starter|pro pack|bundle|cards|hangers)\b}, %r{\b(?:starter|pro pack|bundle|cards|hangers)\b}, 5]
  ]
  pairs.sum { |context_pattern, section_pattern, weight| context.match?(context_pattern) && body.match?(section_pattern) ? weight : 0 }
end

def sms_skill_intent_bonus(section, latest_inbound, open_messages)
  heading = section.to_s[/^## Skill:\s*(.+)$/, 1].to_s
  open_context = Array(open_messages).join(" ").downcase

  case heading
  when /\ATurnaround And Rush\z/i
    latest_inbound.match?(/\b(?:rush|rushed|asap|expedite|turnaround|timeline|shipping|deadline|fast)\b/) ? 60 : 0
  when /\ALive SMS Stack Reader\z/i
    Array(open_messages).length >= 2 ? 55 : 0
  when /\AOther Print Product Menu\z/i
    open_context.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b/) ? 40 : 0
  else
    0
  end
end

def selected_sms_examples(raw)
  sections = raw.to_s.split(/(?=^## Example \d+)/)
  intro = sections.shift.to_s.strip
  return intro if sections.blank?

  context = [latest_inbound_sms, recent_sms_context, current_route_code].compact.join(" ").downcase
  ranked = sections.filter_map do |section|
    score = sms_example_score(section, context)
    [score, section] if score.positive?
  end

  selected = ranked.sort_by { |score, section| [-score, sms_example_order(section)] }
    .map(&:last)
    .first(SMS_EXAMPLES_SECTION_LIMIT)
  selected = sections.first(SMS_EXAMPLES_SECTION_LIMIT) if selected.blank?

  ([intro] + selected).join("\n\n").strip
end

def sms_example_order(section)
  label = section.to_s[/^## Example ([\dA-Z.]+)/, 1].to_s
  number = label[/\d+(?:\.\d+)?/].to_f
  suffix = label[/[A-Z]+/].to_s
  number + (suffix.bytes.sum.to_f / 10_000)
end

def sms_example_score(section, context)
  body = section.to_s.downcase
  score = 0
  score += 8 if context.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|mailing|route|homes?|doors?)\b/) && body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|route|homes?)\b/)
  score += 8 if context.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) && body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
  score += 7 if context.match?(/\b(?:special|deal|discount|4th|july|veteran)\b/) && body.match?(/\b(?:special|deal|discount|4th|july|veteran)\b/)
  score += 6 if context.match?(/\b(?:how much|cost|price|pricing|each|per|one|single|unit)\b/) && body.match?(/\b(?:how much|cost|price|pricing|each|per|one|unit)\b/)
  score += 6 if context.match?(/\b(?:cheapest|lowest|budget|less|under|smaller|fewer)\b/) && body.match?(/\b(?:cheapest|lowest|budget|less|under|smaller|fewer)\b/)
  score += 7 if context.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?|print products?|print pieces?)\b/) && body.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?|print products?|print pieces?)\b/)
  score += 5 if context.match?(/\b(?:starter|pro pack|bundle|business cards?|door hangers?)\b/) && body.match?(/\b(?:starter|pro pack|bundle|business cards?|door hangers?)\b/)
  score += 5 if context.match?(/\b(?:link|checkout|order|buy)\b/) && body.match?(/\b(?:link|checkout|order|buy)\b/)
  score += 5 if context.match?(/\b(?:design|logo|art|artwork|proof|upload)\b/) && body.match?(/\b(?:design|logo|art|artwork|proof|upload)\b/)
  score += 5 if context.match?(/\b(?:turnaround|timeline|how long|rush|faster|production|shipping|ship|deadline|date)\b/) && body.match?(/\b(?:turnaround|timeline|rush|production|shipping|ship|deadline|date)\b/)
  score += 5 if context.match?(/\b(?:approve|approval|proof|intake|upload|logo|artwork|notes?)\b/) && body.match?(/\b(?:approve|approval|proof|intake|upload|logo|artwork|notes?)\b/)
  score += 4 if context.match?(/\b(?:follow up|follow-up|reach out|connect|person|someone|consultant|teammate)\b/) && body.match?(/\b(?:follow up|follow-up|reach out|connect|person|someone|consultant|teammate)\b/)
  score += 4 if context.match?(/\b(?:stop|unsubscribe|no\b|not\b|instead|rather)\b/) && body.match?(/\b(?:stop|unsubscribe|negative answer|instead|rather)\b/)
  score
end

def product_decision_guide
  links = sendable_shopify_links
  items = [
    {
      code: "PRO_PACK",
      label: "Pro Pack",
      fit: "Use when they want a bigger ready-to-buy campaign bundle, want signs plus business cards plus door hangers, ask for the pro/bigger bundle, or need enough material for a serious local push.",
      ask_if_unclear: "Are you looking for the bigger bundle with signs, business cards, and door hangers?",
      link: links["PRO_PACK"]
    },
    {
      code: "STARTER_PACK",
      label: "Starter Pack",
      fit: "Use when they want a smaller entry package, are testing WIZWIKI, ask for the starter/smaller bundle, or need signs plus cards and door hangers without the larger Pro Pack quantity.",
      ask_if_unclear: "Are you looking for a starter bundle with signs, cards, and door hangers?",
      link: links["STARTER_PACK"]
    },
    {
      code: "BUSINESS_CARDS",
      label: "Business Cards",
      fit: "Use when they specifically want business cards only, ask for business-card pricing, or ask for the business-card checkout path. Do not force Starter Pack, Pro Pack, or Yard Signs unless they ask for a bundle.",
      ask_if_unclear: "About how many business cards are you thinking about?",
      link: links["BUSINESS_CARDS"]
    },
    {
      code: "DOOR_HANGERS",
      label: "Door Hangers",
      fit: "Use when they specifically want door hangers only, ask for door-hanger pricing, or ask for the door-hanger checkout path. Do not push this from yard-sign or postcard threads unless the customer brings up door hangers.",
      ask_if_unclear: "About how many door hangers are you thinking about?",
      link: links["DOOR_HANGERS"]
    },
    {
      code: "FLYERS",
      label: "Flyers",
      fit: "Use when they specifically want flyers or handouts only, ask for flyer pricing, or ask for the flyer checkout path. Ask size or quantity if the exact order is unclear.",
      ask_if_unclear: "What flyer size and quantity are you thinking about?",
      link: links["FLYERS"]
    },
    {
      code: "EDDM",
      label: "EDDM postcards",
      fit: "Use when they mention direct mail, postcards, mailers, every door, routes, broad local reach, or getting into homes. Mention the easy-to-use AI postcard/art builder when creative help matters.",
      ask_if_unclear: "Are you trying to reach homes or businesses with postcards?",
      link: links["EDDM"]
    },
    {
      code: "NEIGHBORHOOD_BLITZ",
      label: "Neighborhood Blitz",
      fit: "Use when they want a bigger local push with repeated visibility, postcards plus signs, door hangers, canvassing, or a service-area launch. This is the primary combined path for customers who ask for both postcards and yard signs.",
      ask_if_unclear: "Do you want one mail drop, or a fuller neighborhood push with signs or door hangers too?",
      link: links["NEIGHBORHOOD_BLITZ"]
    },
    {
      code: "LAWN_SIGNS",
      label: "Yard Signs",
      fit: "Use when they only need yard signs/lawn signs/jobsite signs/directional signs/stakes, or they are asking specifically about signs instead of a bundle.",
      ask_if_unclear: "What quantity should I price for the signs?",
      link: links["LAWN_SIGNS"]
    }
  ]
  explicit_routes = explicit_standalone_print_routes([latest_inbound_sms, @operator_prompt].compact.join(" "))
  if explicit_routes.present?
    items = items.select { |item| explicit_routes.include?(item[:code].to_s) }
  elsif signs_only_context?
    items = items.select { |item| item[:code] == "LAWN_SIGNS" }
  end
  items.map(&:compact_blank)
end

def sms_product_matrix_payload
  entries = [
    sms_product_matrix_entry(
      "PRO_PACK",
      "bigger bundle: 100 signs, 1,000 business cards, 1,000 door hangers",
      "larger ready-to-buy bundle, signs plus cards plus door hangers",
      "Is this the bigger bundle you want to order?"
    ),
    sms_product_matrix_entry(
      "STARTER_PACK",
      "starter bundle: 20 yard signs, 500 business cards, 500 door hangers",
      "smaller entry package or test run",
      "Would the 20-sign starter run cover it?"
    ),
    sms_product_matrix_entry(
      "BUSINESS_CARDS",
      "business-card-only path with 16pt premium matte cards",
      "customer specifically asks for business cards, card pricing, or the business-card link",
      "About how many business cards are you thinking about?"
    ),
    sms_product_matrix_entry(
      "LAWN_SIGNS",
      "signs-only path with yard/jobsite/directional signs",
      "customer only wants signs or asks for sign quantity/budget",
      "How many signs do you want to start with?"
    ),
    sms_product_matrix_entry(
      "DOOR_HANGERS",
      "door-hanger-only path with 4.25x11 door hangers",
      "customer specifically asks for door hangers, hanger pricing, or the hanger link",
      "About how many door hangers are you thinking about?"
    ),
    sms_product_matrix_entry(
      "FLYERS",
      "flyer-only path with size and quantity options",
      "customer specifically asks for flyers, handouts, flyer pricing, or the flyer link",
      "What flyer size and quantity are you thinking about?"
    ),
    sms_product_matrix_entry(
      "EDDM",
      "postcard mailing path by route/area",
      "postcards, direct mail, EDDM, homes, mailboxes",
      "About how many homes do you want to reach?"
    ),
    sms_product_matrix_entry(
      "NEIGHBORHOOD_BLITZ",
      "combined local push; use for postcards plus signs/field visibility",
      "customer wants both postcards and signs or a bigger neighborhood push",
      "Do you want the combined blitz, or signs-only?"
    )
  ].compact
  explicit_routes = explicit_standalone_print_routes([latest_inbound_sms, @operator_prompt].compact.join(" "))
  if explicit_routes.present?
    entries = entries.select { |entry| explicit_routes.include?(entry.to_h[:code].to_s.presence || entry.to_h["code"].to_s) }
  elsif signs_only_context?
    entries = entries.select { |entry| entry.to_h[:code].to_s == "LAWN_SIGNS" || entry.to_h["code"].to_s == "LAWN_SIGNS" }
  end

  {
    rule: "Use deterministic guardrails for exact pricing/link danger zones; use this compact matrix for product fit and next question.",
    current_route: current_route_code,
    likely_routes: sms_shopify_detail_routes,
    options: entries
  }.compact_blank
end

def sms_product_matrix_entry(code, includes, use_when, ask)
  price = bundle_price_text(code).presence
  {
    code: code,
    label: product_catalog_label(code).presence || ROUTE_LABELS[code].presence || code.to_s.tr("_", " ").titleize,
    includes: includes,
    use_when: use_when,
    price: price,
    link: route_specific_shopify_link(code),
    ask_if_unclear: ask
  }.compact_blank
end

def product_catalog_label(route)
  return unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.label(route)
rescue StandardError
  nil
end

def sms_product_offerings_summary
  [
    product_catalog_sms_summary,
    "SMS product rules: answer direct questions first; ask one useful next question max.",
    "Use Starter/Pro for signs+cards+hangers bundles; use Yard/Lawn Signs for signs-only; use EDDM for postcard mailing; use Neighborhood Blitz for postcards plus signs/field visibility. Treat artwork/proof/logo questions as design support for the chosen print product, not as a primary discovery product.",
    current_specials_prompt_instruction,
    "Do not invent off-menu prices. For larger custom volume, explain standard options first and offer AM/custom pricing help only as an option."
  ].compact_blank.join(" ")
end

def product_catalog_sms_summary
  return unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.sms_summary
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] product catalog summary unavailable: #{error.class}: #{error.message}")
  nil
end

def current_specials_payload
  return unless defined?(Comms::CurrentSpecials)

  Comms::CurrentSpecials.context_payload
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] current specials payload unavailable: #{error.class}: #{error.message}")
  nil
end

def current_specials_prompt_instruction
  return unless defined?(Comms::CurrentSpecials)

  Comms::CurrentSpecials.prompt_instruction
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] current specials prompt unavailable: #{error.class}: #{error.message}")
  nil
end

def fine_training_context
  organization = @stage.organization || @stage.crm_record&.organization
  return if organization.blank? || !defined?(TrainingDocument)

  hybrid_retrieval = fine_training_hybrid_retrieval(organization)
  retrieved_chunks_by_id = Array(hybrid_retrieval[:results]).each_with_index.each_with_object({}) do |(item, index), memo|
    data = item.to_h.symbolize_keys
    memo[data[:id].to_i] = data.merge(retrieval_position: index + 1) if data[:id].present?
  end
  source_pack = fine_training_source_pack(organization)
  total = source_pack.to_h[:total].to_i
  return if total.zero?

  keywords = fine_training_keywords
  documents = Array(source_pack.to_h[:documents]).select { |document| fine_training_composition_eligible?(document) }
  document_index = documents.index_by { |document| [document.class.name, document.id] }
  scored_documents = documents.map do |document|
    role = fine_training_retrieval_role(document)
    score = fine_training_score(fine_training_document_haystack(document), keywords, updated_at: document.updated_at) + fine_training_role_boost(role)
    [document, score, role]
  end
  ranked_documents = scored_documents.select { |_document, score, _role| score.positive? }
    .sort_by { |document, score, _role| [-score, document.updated_at || Time.zone.at(0)] }
  voice_documents = ranked_documents.select { |_document, _score, role| role == "voice_authority" }.first(2)
  fact_documents = ranked_documents.select { |_document, _score, role| role == "fact_authority" }.first(2)
  adaptive_documents = ranked_documents.select { |_document, _score, role| role == "positive_example" }.first(ADAPTIVE_TRAINING_CHUNK_LIMIT)
  other_documents = ranked_documents.reject { |_document, _score, role| role == "positive_example" }
  selected_documents = (voice_documents + fact_documents + adaptive_documents + other_documents)
    .uniq { |document, _score, _role| [document.class.name, document.id] }
    .first(FINE_TRAINING_DOCUMENT_LIMIT)

  adaptive_chunk_ids = Array(hybrid_retrieval[:adaptive_results]).filter_map { |item| item.to_h[:id] || item.to_h["id"] }
  chunks = fine_training_embedding_chunks(organization, adaptive_chunk_ids: adaptive_chunk_ids).select do |chunk|
    fine_training_chunk_composition_eligible?(chunk, document_index)
  end
  scored_chunks = chunks.map do |chunk|
    role = fine_training_chunk_role(chunk, document_index)
    score = fine_training_score([chunk.label, chunk.metadata.to_h.values, chunk.content].flatten.compact.join(" "), keywords, updated_at: chunk.updated_at) + fine_training_role_boost(role)
    retrieved = retrieved_chunks_by_id[chunk.id.to_i]
    if retrieved.present?
      score += 1_000
      score += ((FINE_TRAINING_CHUNK_LIMIT - retrieved[:retrieval_position].to_i) * 10)
      score += (retrieved[:rank_score].to_f * 100).round
    end
    [chunk, score, role, retrieved]
  end
  ranked_chunks = scored_chunks.select { |_chunk, score, _role, _retrieved| score.positive? }
    .sort_by { |chunk, score, _role, _retrieved| [-score, chunk.updated_at || Time.zone.at(0)] }
  voice_chunks = ranked_chunks.select { |_chunk, _score, role, _retrieved| role == "voice_authority" }.first(1)
  fact_chunks = ranked_chunks.select { |_chunk, _score, role, _retrieved| role == "fact_authority" }.first(2)
  adaptive_chunks = ranked_chunks.select { |_chunk, _score, role, _retrieved| role == "positive_example" }.first(ADAPTIVE_TRAINING_CHUNK_LIMIT)
  other_chunks = ranked_chunks.reject { |_chunk, _score, role, _retrieved| role == "positive_example" }
  selected_chunks = (voice_chunks + fact_chunks + adaptive_chunks + other_chunks)
    .uniq { |chunk, _score, _role, _retrieved| chunk.id }
    .first(FINE_TRAINING_CHUNK_LIMIT)

  {
    total_documents: total,
    documents_scanned: documents.length,
    chunks_scanned: chunks.length,
    embedded_chunks_available: chunks.length,
    selected_count: selected_documents.length,
    selected_chunk_count: selected_chunks.length,
    retrieval_mode: hybrid_retrieval.dig(:retrieval_debug, :mode),
    retrieval_embedding_model: hybrid_retrieval[:embedding_model],
    retrieval_embedding_dimensions: hybrid_retrieval[:embedding_dimensions],
    retrieval_embedding_cached: hybrid_retrieval[:embedding_cached],
    retrieval_evidence: hybrid_retrieval[:evidence],
    retrieval_debug: hybrid_retrieval[:retrieval_debug],
    voice_authority_count: selected_documents.count { |_document, _score, role| role == "voice_authority" },
    fact_authority_count: selected_documents.count { |_document, _score, role| role == "fact_authority" },
    training_selection_reason: "Always load the Thumper/WIZWIKI voice authorities, then add current fact authorities and the highest-signal procedural or conversational memory for this exact thread.",
    coverage_rule: "Voice canon controls tone. Current product and thread context control facts. Skills control procedure. Curated examples teach shape. Guardrails are correction checklists. Judge, simulator, opt-out, rejected, and quarantined memory are not composition examples.",
    document_inventory: documents.sort_by { |document| document.title.to_s.downcase }.first(FINE_TRAINING_INVENTORY_LIMIT).map do |document|
      {
        title: document.title,
        source_type: document.source_type,
        source_class: document.class.name,
        retrieval_role: fine_training_retrieval_role(document),
        file_name: fine_training_file_name(document),
        updated_at: document.updated_at&.to_date&.iso8601
      }.compact_blank
    end,
    selected_documents: selected_documents.map do |document, score, role|
      {
        title: document.title,
        source_type: document.source_type,
        source_class: document.class.name,
        file_name: fine_training_file_name(document),
        updated_at: document.updated_at&.to_date&.iso8601,
        score: score,
        retrieval_role: role,
        usage_rule: fine_training_usage_rule(document),
        excerpt: document.body.to_s.squish.truncate(1_800, omission: "...")
      }.compact_blank
    end,
    selected_chunks: selected_chunks.map do |chunk, score, role, retrieved|
      {
        label: chunk.label,
        source_type: chunk.source_type,
        source_id: chunk.source_id,
        score: score,
        retrieval_role: role,
        retrieval_channels: Array(retrieved.to_h[:retrieval_channels]).presence,
        retrieval_rank_score: retrieved.to_h[:rank_score],
        retrieval_position: retrieved.to_h[:retrieval_position],
        usage_rule: fine_training_chunk_usage_rule(chunk, document_index),
        excerpt: chunk.content.to_s.squish.truncate(1_400, omission: "...")
      }.compact_blank
    end
  }
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] fine training context unavailable: #{error.class}: #{error.message}")
  nil
end

def fine_training_hybrid_retrieval(organization)
  return @fine_training_hybrid_retrieval if defined?(@fine_training_hybrid_retrieval)
  return @fine_training_hybrid_retrieval = {} unless defined?(Autos::Retriever)

  retrieval_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  query = fine_training_semantic_query
  embedding_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  embedding_result = if defined?(Autos::QueryEmbedder)
    Autos::QueryEmbedder.call(query: query, model: Autos::WorkerQueue.embedder_model)
  else
    { ok: false, embedding: [], model: Autos::WorkerQueue.embedder_model, error: "query embedder unavailable" }
  end
  embedding_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - embedding_started) * 1_000).round
  primary_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  primary_retrieval = Autos::Retriever.call(
    organization: organization,
    query: query,
    embedding: embedding_result.to_h[:embedding],
    embedding_model: embedding_result.to_h[:model].presence || Autos::WorkerQueue.embedder_model,
    scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
    surface: "comms_sms_draft",
    limit: FINE_TRAINING_CHUNK_LIMIT,
    candidate_limit: 40,
    source_types: ["TrainingDocument", "TrainingVaultDocument"]
  )
  primary_retrieval_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - primary_started) * 1_000).round
  adaptive_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  adaptive_retrieval = Autos::Retriever.call(
    organization: organization,
    query: query,
    embedding: embedding_result.to_h[:embedding],
    embedding_model: embedding_result.to_h[:model].presence || Autos::WorkerQueue.embedder_model,
    scope: Comms::AdaptiveLearningReview::EMBEDDING_SCOPE,
    surface: "comms_sms_draft",
    limit: ADAPTIVE_TRAINING_CHUNK_LIMIT,
    candidate_limit: 12,
    source_types: ["TrainingDocument"]
  )
  adaptive_retrieval_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - adaptive_started) * 1_000).round
  primary = primary_retrieval.to_h.symbolize_keys
  adaptive = adaptive_retrieval.to_h.symbolize_keys
  adaptive_results = Array(adaptive[:results]).first(ADAPTIVE_TRAINING_CHUNK_LIMIT)
  @fine_training_hybrid_retrieval = primary.merge(
    results: Array(primary[:results]) + adaptive_results,
    adaptive_results: adaptive_results,
    evidence: Array(primary[:evidence]) + Array(adaptive[:evidence]).first(ADAPTIVE_TRAINING_CHUNK_LIMIT),
    retrieval_debug: primary[:retrieval_debug].to_h.merge(
      adaptive_scope: Comms::AdaptiveLearningReview::EMBEDDING_SCOPE,
      adaptive_mode: adaptive.dig(:retrieval_debug, :mode),
      adaptive_returned: adaptive_results.length,
      adaptive_limit: ADAPTIVE_TRAINING_CHUNK_LIMIT,
      query_chars: query.length,
      query_embedding_ms: embedding_ms,
      primary_retrieval_ms: primary_retrieval_ms,
      adaptive_retrieval_ms: adaptive_retrieval_ms,
      total_retrieval_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - retrieval_started) * 1_000).round
    ),
    embedding_dimensions: embedding_result.to_h[:dimensions].to_i,
    embedding_cached: ActiveModel::Type::Boolean.new.cast(embedding_result.to_h[:cached]),
    embedding_error: embedding_result.to_h[:error].presence
  )
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] hybrid fine-training retrieval unavailable: #{error.class}: #{error.message}")
  @fine_training_hybrid_retrieval = {
    embedding_model: Autos::WorkerQueue.embedder_model,
    results: [],
    evidence: [],
    retrieval_debug: { mode: "keyword_fallback", error: "#{error.class}: #{error.message}" }
  }
end

def fine_training_embedding_chunks(organization, adaptive_chunk_ids: [])
  return [] unless defined?(AutosEmbeddingChunk) && defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
  primary_chunks = if defined?(Autos::ContextCache)
    Autos::ContextCache.comms_fine_training_embedding_chunks(organization)
  else
    AutosEmbeddingChunk
      .embedded
      .where(
        organization: organization,
        source_type: ["TrainingDocument", "TrainingVaultDocument"],
        embedding_model: Autos::WorkerQueue.embedder_model,
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE
      )
      .where("COALESCE(metadata ->> 'composition_eligible', 'true') <> 'false'")
      .select(:id, :source_type, :source_id, :label, :content, :metadata, :updated_at)
      .to_a
  end

  adaptive_ids = Array(adaptive_chunk_ids).map(&:to_i).select(&:positive?).uniq.first(ADAPTIVE_TRAINING_CHUNK_LIMIT)
  return primary_chunks if adaptive_ids.blank?

  adaptive_chunks = AutosEmbeddingChunk
    .embedded
    .where(
      id: adaptive_ids,
      organization: organization,
      source_type: "TrainingDocument",
      embedding_model: Autos::WorkerQueue.embedder_model,
      scope: Comms::AdaptiveLearningReview::EMBEDDING_SCOPE
    )
    .select(:id, :source_type, :source_id, :label, :content, :metadata, :updated_at)
    .to_a
  (primary_chunks + adaptive_chunks).uniq(&:id)
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] fine training chunk load unavailable: #{error.class}: #{error.message}")
  []
end

def fine_training_source_pack(organization)
  if defined?(Autos::ContextCache)
    Autos::ContextCache.comms_fine_training_source_pack(
      organization,
      inventory_limit: FINE_TRAINING_INVENTORY_LIMIT
    )
  else
    training_scope = organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"])
    vault_scope = if defined?(TrainingVaultDocument) && organization.respond_to?(:training_vault_documents)
      organization.training_vault_documents.where(status: %w[approved indexed])
    else
      TrainingDocument.none
    end
    priority_documents = training_scope
      .where("metadata ->> 'retrieval_priority' = 'paramount' OR metadata ->> 'training_priority' = 'paramount' OR metadata ->> 'training_kind' IN ('thumper_voice_canon', 'copywriter_voice')")
      .order(updated_at: :desc)
      .limit(24)
      .to_a
    recent_documents = training_scope.order(updated_at: :desc).limit(FINE_TRAINING_INVENTORY_LIMIT).to_a
    vault_documents = vault_scope.order(updated_at: :desc).limit(FINE_TRAINING_INVENTORY_LIMIT).to_a
    {
      total: training_scope.count + vault_scope.count,
      documents: (priority_documents + recent_documents + vault_documents).uniq { |document| [document.class.name, document.id] }
    }
  end
end

def fine_training_retrieval_role(document)
  return Comms::TrainingMemoryPolicy.role_for(document) if defined?(Comms::TrainingMemoryPolicy)

  document.metadata.to_h["retrieval_role"].to_s.presence || "training_reference"
end

def fine_training_composition_eligible?(document)
  return Comms::TrainingMemoryPolicy.composition_eligible?(document) if defined?(Comms::TrainingMemoryPolicy)

  document.status.to_s != "archived" && document.metadata.to_h["composition_eligible"].to_s != "false"
end

def fine_training_usage_rule(document)
  return Comms::TrainingMemoryPolicy.usage_rule(document) if defined?(Comms::TrainingMemoryPolicy)

  "Use only when relevant and subordinate it to current thread and product facts."
end

def fine_training_chunk_source(chunk, document_index)
  document_index[[chunk.source_type.to_s, chunk.source_id]]
end

def fine_training_chunk_role(chunk, document_index)
  source = fine_training_chunk_source(chunk, document_index)
  return fine_training_retrieval_role(source) if source.present?

  chunk.metadata.to_h["retrieval_role"].to_s.presence || "training_reference"
end

def fine_training_chunk_composition_eligible?(chunk, document_index)
  source = fine_training_chunk_source(chunk, document_index)
  return fine_training_composition_eligible?(source) if source.present?

  metadata = chunk.metadata.to_h
  if metadata["training_kind"].to_s == "comms_playbook_memory"
    return false unless metadata["learning_status"].to_s == "approved_positive"
    return false unless ActiveModel::Type::Boolean.new.cast(metadata["human_reviewed"])
  end
  metadata["composition_eligible"].to_s != "false" &&
    !%w[judge_calibration quarantined_memory negative_example].include?(metadata["retrieval_role"].to_s)
end

def fine_training_chunk_usage_rule(chunk, document_index)
  source = fine_training_chunk_source(chunk, document_index)
  return fine_training_usage_rule(source) if source.present?

  chunk.metadata.to_h["usage_rule"].to_s.presence || "Use only when relevant and subordinate it to current thread and product facts."
end

def fine_training_role_boost(role)
  return 0 unless defined?(Comms::TrainingMemoryPolicy::ROLE_BOOSTS)

  Comms::TrainingMemoryPolicy::ROLE_BOOSTS.fetch(role.to_s, 0)
end

def fine_training_keywords
  route_terms = [
    current_route_code,
    @metadata["product_interest_label"],
    @metadata["processing_label"]
  ].compact_blank.map { |term| term.to_s.tr("_", " ").downcase }

  base_terms = %w[
    fine training voice tone sms text comms sales scenario scenarios objection objections
    stale follow followup follow-up no response unanswered dormant reengage re-engage
    product offering offer shopify link links wizwiki thumper sample_owner copywriter copywriting
    price pricing cost budget quantity quantities sizes shipping turnaround rush proof approval intake upload production
    eddm postcard postcards mailer mailers neighborhood blitz lawn signs yard signs artwork logo design
    business cards door hangers flyers rack cards magnets brochures print products print pieces
  ]
  dynamic_terms = fine_training_dynamic_terms
  (base_terms + route_terms + dynamic_terms).compact_blank.map(&:downcase).uniq
end

def fine_training_dynamic_terms
  text = [
    @operator_prompt,
    latest_inbound_sms,
    latest_sms_event.to_h["body"],
    current_sms_body_for_context,
    campaign_fit_payload.to_json,
    compact_sms_thread.last(10).map { |event| event.to_h[:body] || event.to_h["body"] }
  ].flatten.compact.join(" ").downcase

  stopwords = %w[
    the and for you your with that this from have what when where how can could would should
    about into they them there here just need want wants looking does dont don't get got will
    text sms thumper wizwiki marketing thanks thank okay ok yes no
  ]
  text.scan(/[a-z0-9][a-z0-9\-]{2,}/).uniq.reject { |term| stopwords.include?(term) }.first(60)
end

def fine_training_semantic_query
  current_next_text = current_sms_body_for_context
  [
    "Latest inbound: #{latest_inbound_sms}",
    (current_open_customer_message_bodies.present? ? "Open customer messages to answer: #{current_open_customer_message_bodies.join(" | ")}" : nil),
    (open_customer_reply_requirements_payload.present? ? "Open answer requirements: #{open_customer_reply_requirements_payload.map { |item| item[:answer_hint] }.compact_blank.join(" | ")}" : nil),
    "Route: #{current_route_code}",
    "Operator prompt: #{@operator_prompt}",
    (current_next_text.present? ? "Current next text: #{current_next_text}" : nil),
    "Campaign fit: #{campaign_fit_payload.to_json}",
    "Thumper SMS comms fine-training retrieval",
    "Goal: answer the latest customer message, continue discovery when product fit is incomplete, and choose the right WIZWIKI product link when quantity or homes/reach is known. Budget is optional only if the customer brings it up.",
    "Processing label: #{@metadata["processing_label"]}",
    "Recent thread:",
    compact_sms_thread.last(10).map { |event| "#{event[:direction] || event["direction"]}: #{event[:body] || event["body"]}" }
  ].flatten.compact.join("\n").squish.truncate(4_000, omission: "...")
end

def fine_training_document_haystack(document)
  [
    document.title,
    document.source_type,
    fine_training_file_name(document),
    document.respond_to?(:folder_path) ? document.folder_path : nil,
    document.metadata.to_h.values_at("folder_path", "upload_source", "training_kind", "category", "training_priority", "priority", "retrieval_priority"),
    document.body.to_s.first(24_000)
  ].flatten.compact.join(" ")
end

def fine_training_score(text, keywords, updated_at: nil)
  haystack = text.to_s.downcase
  score = keywords.sum { |keyword| haystack.include?(keyword.to_s.downcase) ? 1 : 0 }
  score += 60 if haystack.match?(/\b(paramount|canonical|highest priority|primary voice|authoritative voice)\b/)
  score += 8 if haystack.match?(/\b(sms|text|comms)\b/)
  score += 5 if haystack.match?(/\b(fine training|voice|tone|scenario|sales)\b/)
  score += 5 if haystack.match?(/\b(price|pricing|cost|budget|quantity|shipping|turnaround|proof|production)\b/)
  score += 5 if haystack.match?(/\b(stale|follow-?up|no response|unanswered|dormant|re-?engage)\b/)
  score += 5 if haystack.match?(/\b(pro pack|starter pack|eddm|postcards?|neighborhood blitz|lawn signs?|yard signs?|design support|artwork support|shopify)\b/)
  score += 2 if updated_at.present? && updated_at > 7.days.ago
  score
end

def fine_training_file_name(document)
  return document.file_name if document.respond_to?(:file_name)

  document.metadata.to_h["file_name"].presence || document.metadata.to_h["original_filename"].presence
end

def call_scenario_context
  organization = @stage.organization || @stage.crm_record&.organization
  return if organization.blank?
  if defined?(Autos::ContextCache)
    return Autos::ContextCache.comms_call_scenario_context(organization: organization, crm_record: @stage.crm_record)
  end

  calls = []
  if organization.respond_to?(:fathom_calls)
    calls += organization.fathom_calls.active.recent.limit(8).to_a
  end
  if organization.respond_to?(:playbook_calls)
    graph_calls = if @stage.crm_record.present?
      PlaybookCall.for_crm_record_graph(@stage.crm_record).limit(8).to_a
    else
      []
    end
    recent_calls = organization.playbook_calls.active.recent.limit(8).to_a
    calls += (graph_calls + recent_calls)
  end

  calls = calls.uniq { |call| [call.class.name, call.id] }.first(12)
  return if calls.blank?

  {
    source: "recent_fathom_and_playbook_calls",
    usage_rule: "Use these as real sales-call scenario memory: objections, buying signals, useful wording, package-fit patterns, and next-step strategy. Do not quote private call details to the customer unless the current thread already includes them.",
    selected_count: calls.length,
    selected_calls: calls.map do |call|
      {
        source_class: call.class.name,
        title: call.respond_to?(:title) ? call.title : nil,
        recorded_at: (call.respond_to?(:recording_start_time) ? call.recording_start_time : nil)&.iso8601,
        occurred_at: (call.respond_to?(:occurred_at) ? call.occurred_at : nil)&.iso8601,
        context: call.respond_to?(:compact_context) ? call.compact_context(max_chars: 1_200) : nil
      }.compact_blank
    end
  }
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] call scenario context unavailable: #{error.class}: #{error.message}")
  nil
end

def shopify_links
  @shopify_links ||= begin
    catalog_links = route_valid_shopify_links(product_catalog_shopify_links)
    training_links = route_valid_shopify_links(training_shopify_links)
    configured_links = {
      "PRO_PACK" => ENV["WIZWIKI_SHOPIFY_PRO_PACK_URL"].presence || ENV["SHOPIFY_PRO_PACK_URL"].presence,
      "STARTER_PACK" => ENV["WIZWIKI_SHOPIFY_STARTER_PACK_URL"].presence || ENV["SHOPIFY_STARTER_PACK_URL"].presence,
      "BUSINESS_CARDS" => ENV["WIZWIKI_SHOPIFY_BUSINESS_CARDS_URL"].presence || ENV["SHOPIFY_BUSINESS_CARDS_URL"].presence,
      "DOOR_HANGERS" => ENV["WIZWIKI_SHOPIFY_DOOR_HANGERS_URL"].presence || ENV["SHOPIFY_DOOR_HANGERS_URL"].presence,
      "FLYERS" => ENV["WIZWIKI_SHOPIFY_FLYERS_URL"].presence || ENV["SHOPIFY_FLYERS_URL"].presence,
      "EDDM" => ENV["WIZWIKI_SHOPIFY_EDDM_URL"].presence || ENV["SHOPIFY_EDDM_URL"].presence,
      "NEIGHBORHOOD_BLITZ" => ENV["WIZWIKI_SHOPIFY_NEIGHBORHOOD_BLITZ_URL"].presence || ENV["SHOPIFY_NEIGHBORHOOD_BLITZ_URL"].presence,
      "LAWN_SIGNS" => ENV["WIZWIKI_SHOPIFY_LAWN_SIGNS_URL"].presence || ENV["SHOPIFY_LAWN_SIGNS_URL"].presence,
      "STORE" => ENV["WIZWIKI_SHOPIFY_STORE_URL"].presence || ENV["SHOPIFY_STORE_URL"].presence
      }.compact_blank.then { |links| route_valid_shopify_links(links) }
      shopify_catalog_links.merge(training_links).merge(catalog_links).merge(configured_links).tap do |links|
        store_link = configured_links["STORE"].presence || catalog_links["STORE"].presence || training_links["STORE"].presence || "https://shop.example.invalid/collections/origin"
        links["STORE"] ||= store_link if store_link.present? && !disallowed_shopify_link?(store_link)
      end
    end
  end

def product_catalog_shopify_links
  return {} unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.shopify_links
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] product catalog links unavailable: #{error.class}: #{error.message}")
  {}
end

def sendable_shopify_links
  @sendable_shopify_links ||= shopify_links.each_with_object({}) do |(route, url), links|
    route = route.to_s
    next if url.blank?
    next if route != "STORE" && shopify_product_sold_out?(route)

    links[route] = url
  end
end

def shopify_catalog_links
  products = Rails.cache.fetch("wizwiki/comms/shopify_catalog_products/v2", expires_in: SHOPIFY_CATALOG_CACHE_TTL) do
    uri = URI.parse(SHOPIFY_CATALOG_PRODUCTS_URL)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 8) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "Thumper-Comms/1.0"
      http.request(request)
    end
    raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    Array(JSON.parse(response.body)["products"])
  end

  %w[PRO_PACK STARTER_PACK BUSINESS_CARDS DOOR_HANGERS FLYERS EDDM NEIGHBORHOOD_BLITZ LAWN_SIGNS].each_with_object({}) do |route, links|
    product = best_shopify_catalog_product(products, route)
    handle = product.to_h["handle"].to_s.squish
    next if handle.blank?

    url = "https://shop.example.invalid/products/#{handle}"
    next if disallowed_shopify_link?(url)

    links[route] = url
  end.compact_blank
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] Shopify catalog links unavailable: #{error.class}: #{error.message}")
  {}
end

def best_shopify_catalog_product(products, route)
  Array(products).filter_map do |product|
    next if disallowed_shopify_product?(product)

    score = shopify_catalog_product_score(route, product)
    next if score.to_i <= 0

    [score, product]
  end.max_by { |score, product| [score.to_i, generic_shopify_product_score(product), -product.to_h["handle"].to_s.length] }&.last
end

def generic_shopify_product_score(product)
  handle = product.to_h["handle"].to_s.downcase
  title = product.to_h["title"].to_s.downcase
  score = 0
  score += 120 if handle.match?(/(?:\A|-)sample_owner\z/) || title.match?(/\|\s*sample_owner\b/i)
  score += 60 unless handle.match?(/-(adam|sample_owner|charlie|dane|ian|kristina|maddy|patrick|peyton|riley)\z/)
  score += 30 unless title.match?(/\|\s*(adam|sample_owner|charlie|dane|ian|kristina|maddy|patrick|peyton|riley)\b/i)
  score
end

def shopify_catalog_product_score(route, product)
  route = route.to_s
  handle = product.to_h["handle"].to_s.downcase
  title = product.to_h["title"].to_s.downcase
  text = "#{title} #{handle}"
  context = shopify_catalog_context_text
  explicit_eddm = context.match?(/\b(eddm|every\s+door|route(?:s|d)?|usps)\b/i)
  home_service_postcards = context.match?(/\b(roof|roofing|roofer|restoration|storm|older homes?|aged homes?|homeowners?)\b/i)
  large_postcard_reach = numeric_household_value(campaign_fit_payload[:household_count]).to_i >= 3_000

  case route
  when "PRO_PACK"
    return 1_000 if handle == "pro-pack"
    return 850 if handle.match?(/\Apro-pack(?:-|$)/) || text.match?(/\bpro pack\b/)
  when "STARTER_PACK"
    return 1_000 if handle == "starter-pack"
    return 850 if handle.match?(/\Astarter-pack(?:-|$)/) || text.match?(/\bstarter pack\b/)
  when "BUSINESS_CARDS"
    return 1_050 if handle == "business-cards"
    return 820 if handle.match?(/\Abusiness-cards(?:-|$)/) || text.match?(/\bbusiness cards?\b/)
  when "DOOR_HANGERS"
    return 1_050 if handle == "door-hangers"
    return 820 if handle.match?(/\Adoor-hangers(?:-|$)/) || text.match?(/\bdoor hangers?\b/)
  when "FLYERS"
    return 1_050 if handle == "flyers-canvasser"
    return 820 if handle.match?(/\Aflyers(?:-|$)/) || text.match?(/\bflyers?\b/)
  when "LAWN_SIGNS"
    return 1_000 if handle == "wizwiki-deal-18x24-yard-signs"
    return 900 if handle == "24x18-yard-signs-sample_owner"
    return 760 if text.match?(/\b(24x18|18x24).*(yard|lawn).*signs?\b/)
    return 620 if text.match?(/\byard signs?\b/)
  when "EDDM"
    return 1_320 if context.match?(/\b(?:july\s*4|4th\s+of\s+july|postcard\s+specials?|specials?|promos?|discounts?)\b/i) && handle == "postcard-block-sale-0704"
    return 1_280 if context.match?(/\b(?:older homes?|aged homes?)\b/i) && handle == "targeted-postcards-for-older-homes-sample_owner"
    return 1_280 if context.match?(/\b(?:new home buyers?|new homeowners?)\b/i) && handle == "targeted-postcards-for-new-home-buyers-sample_owner"
    return 1_250 if large_postcard_reach && handle.match?(/\Ago-big-postcard-blocks(?:-sample_owner)?\z/)
    return 1_200 if home_service_postcards && handle.match?(/\A(?:postcards-olderhomes|targeted-postcards-for-older-homes-sample_owner)\z/) && !explicit_eddm
    return 1_120 if !explicit_eddm && handle == "targeted-postcard-package"
    return 1_080 if explicit_eddm && handle == "eddm-postcards"
    return 980 if handle == "eddm-postcards"
    return 900 if handle.match?(/\Aeddm-postcards/)
    return 820 if handle.match?(/\Atargeted-postcard-package/)
    return 760 if text.match?(/\b(postcard|postcards|direct mail|eddm)\b/)
  when "NEIGHBORHOOD_BLITZ"
    return 1_160 if handle == "main-course-bundle-eddm-postcards-1-deluxe-a-frames-500-rack-cards-sample_owner"
    return 1_100 if handle.match?(/\Amain-course.*sample_owner\z/) || title.match?(/\bmain course\b.*\|\s*sample_owner\b/)
    return 1_000 if handle == "main-course-bundle"
    return 860 if text.match?(/\b(main course|eddm postcards.*a-frames|postcards.*rack cards)\b/)
  end

  0
end

def shopify_catalog_context_text
  @shopify_catalog_context_text ||= [
    @metadata["captured_industry"],
    @metadata["industry"],
    @metadata["company_name"],
    @metadata["captured_company_name"],
    @metadata["processing_label"],
    @metadata["product_interest"],
    @metadata["product_interest_code"],
    Array(@metadata["sms_thread"]).last(18).map { |event| sms_thread_body_for_context(event) }
  ].flatten.compact.join("\n")
end

def training_shopify_links
  organization = @stage.organization || @stage.crm_record&.organization
  return {} if organization.blank?

  documents = []
  documents += organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"]).order(updated_at: :desc).limit(300).to_a if defined?(TrainingDocument)
  documents += organization.training_vault_documents.where(status: %w[approved indexed]).order(updated_at: :desc).limit(300).to_a if defined?(TrainingVaultDocument)

  documents.each_with_object({}) do |document, links|
    text = [
      document.title,
      document.respond_to?(:file_name) ? document.file_name : nil,
      document.respond_to?(:folder_path) ? document.folder_path : nil,
      document.body
    ].compact.join("\n")
    urls = text.scan(%r{https?://[^\s<>"')\]]+}).map { |url| url.delete_suffix(".").delete_suffix(",") }.uniq
    next if urls.blank?

    code = classify_product_link_document(text)
    if code.present?
      matching_url = urls.find { |url| shopify_link_matches_route?(code, url) }
      links[code] ||= matching_url if matching_url.present?
    end
    if code.blank? && text.match?(/\b(shopify|checkout|store|buy|order)\b/i)
      links["STORE"] ||= urls.first
    end
  end.compact_blank
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] training Shopify links unavailable: #{error.class}: #{error.message}")
  {}
end

def shopify_product_details_payload
  codes = [
    current_route_code,
    "BUSINESS_CARDS",
    "DOOR_HANGERS",
    "FLYERS",
    "LAWN_SIGNS",
    "STARTER_PACK",
    "PRO_PACK",
    "EDDM",
    "NEIGHBORHOOD_BLITZ"
  ].compact_blank.uniq

  codes.filter_map do |code|
    detail = product_details_for_route(code)
    next if detail.blank?

    {
      code: code,
        label: ROUTE_LABELS[code.to_s].presence || code.to_s.tr("_", " ").titleize,
        title: detail[:title],
        url: detail[:url],
        availability: product_availability_status(detail),
        included: detail[:included],
        shipping_note: detail[:shipping_note],
        price_table: detail[:price_table],
      variants: Array(detail[:variants]).first(36)
      }.compact_blank
    end
  end

def product_availability_status(detail)
  variants = Array(detail.to_h[:variants] || detail.to_h["variants"])
  known = variants.select { |variant| [true, false].include?(variant_available_value(variant)) }
  return "unknown" if known.blank?

  known.any? { |variant| variant_available_value(variant) == true } ? "available" : "sold_out"
end

def variant_available_value(variant)
  value = variant.to_h
  return value[:available] if value.key?(:available)
  return value["available"] if value.key?("available")

  nil
end

def product_details_for_route(route)
  route = route.to_s
  return if route.blank?
  @product_details_for_route ||= {}
  return @product_details_for_route[route] if @product_details_for_route.key?(route)

  live = shopify_product_details(route)
  training = training_product_details(route)
  catalog = product_catalog_details(route)
  return @product_details_for_route[route] = nil if live.blank? && training.blank? && catalog.blank?

  merged = (live || {}).merge(training || {}).merge(catalog || {})
  merged[:price_table] = merge_price_tables(live&.dig(:price_table), training&.dig(:price_table), catalog&.dig(:price_table))
  merged[:included] = Array(catalog&.dig(:included)) | Array(training&.dig(:included)) | Array(live&.dig(:included))
  merged[:shipping_note] = catalog&.dig(:shipping_note).presence || live&.dig(:shipping_note).presence || training&.dig(:shipping_note).presence
  @product_details_for_route[route] = merged
end

def product_catalog_details(route)
  return {} unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.product_details(route)
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] product catalog details unavailable route=#{route} #{error.class}: #{error.message}")
  {}
end

def shopify_product_details(route)
  link = shopify_links[route.to_s].presence
  return if link.blank?
  return unless link.match?(%r{\Ahttps?://}i)
  return unless URI.parse(link).host.to_s.match?(/shop\.wizwikimarketing\.com\z/i)

  json_url = link.sub(/\?.*\z/, "").sub(%r{/\z}, "")
  json_url = "#{json_url}.js" unless json_url.end_with?(".js")
  cache_key = "wizwiki/comms/shopify_product/#{Digest::SHA256.hexdigest(json_url)}"

  Rails.cache.fetch(cache_key, expires_in: SHOPIFY_DETAIL_CACHE_TTL) do
    uri = URI.parse(json_url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "Thumper-Comms/1.0"
      http.request(request)
    end
    raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    product = JSON.parse(response.body)
    variants = Array(product["variants"]).map { |variant| normalize_shopify_variant(variant) }.compact
    description = strip_html(product["description"].to_s)
    {
      source: "shopify_product_json",
      title: product["title"].to_s.squish.presence,
      url: link,
      included: included_items_from_text(description),
      shipping_note: shipping_note_from_text(description),
      price_table: price_table_from_variants(variants),
      variants: variants
    }.compact_blank
  rescue StandardError => error
    Rails.logger.warn("[CommsDraftWriter] Shopify product details unavailable route=#{route} url=#{json_url} #{error.class}: #{error.message}")
    nil
  end
rescue URI::InvalidURIError
  nil
end

def normalize_shopify_variant(variant)
  title = variant.to_h["title"].to_s.squish
  price = variant.to_h["price"]
  quantity = extract_variant_quantity(title)
  {
    id: variant.to_h["id"],
    title: title,
    quantity: quantity,
    side: variant_side(title),
    stakes: variant_stakes(title),
    price: dollars_from_cents(price),
    price_cents: price.to_i,
    available: variant.to_h["available"]
  }.compact
end

def extract_variant_quantity(title)
  title.to_s[/\A\s*(\d{1,5})\b/, 1]&.to_i
end

def variant_side(title)
  text = title.to_s.downcase
  return "different_front_back" if text.include?("different front") || text.include?("different back")
  return "double_sided" if text.include?("double sided") || text.include?("double-sided")
  return "single_sided" if text.include?("single sided") || text.include?("single-sided")

  nil
end

def variant_stakes(title)
  text = title.to_s.downcase
  return "included" if text.include?("with free stakes") || text.include?("stakes included")
  return "none" if text.include?("no stakes")

  nil
end

def price_table_from_variants(variants)
  Array(variants).each_with_object({}) do |variant, table|
    next if variant_available_value(variant) == false

    quantity = variant[:quantity]
    next if quantity.blank?

    table[quantity] ||= {}
    key = variant[:side].presence || "price"
    if variant[:stakes].present? && key != "price"
      table[quantity]["#{key}_#{variant[:stakes]}"] ||= variant[:price]
    end
    table[quantity][key] ||= variant[:price]
  end
end

def training_product_details(route)
  text = product_training_text(route)
  return if text.blank?

  {
    source: "training_documents",
    title: product_training_title(route),
    url: shopify_links[route.to_s].presence,
    included: included_items_from_text(text),
    shipping_note: shipping_note_from_text(text),
    price_table: training_price_table(text)
  }.compact_blank
end

def product_training_title(route)
  document = product_training_document(route)
  document&.title.to_s.squish.presence
end

def product_training_text(route)
  document = product_training_document(route)
  document&.body.to_s
end

def product_training_document(route)
  @product_training_documents ||= {}
  return @product_training_documents[route.to_s] if @product_training_documents.key?(route.to_s)

  organization = @stage.organization || @stage.crm_record&.organization
  return @product_training_documents[route.to_s] = nil if organization.blank?

  documents = []
  documents += organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"]).order(updated_at: :desc).limit(400).to_a if defined?(TrainingDocument)
  documents += organization.training_vault_documents.where(status: %w[approved indexed]).order(updated_at: :desc).limit(400).to_a if defined?(TrainingVaultDocument)

  matching = documents.find do |document|
    text = [
      document.title,
      document.respond_to?(:file_name) ? document.file_name : nil,
      document.body.to_s.first(12_000)
    ].compact.join("\n")
    classify_product_link_document(text) == route.to_s
  end
  @product_training_documents[route.to_s] = matching
rescue StandardError => error
  Rails.logger.warn("[CommsDraftWriter] product training document unavailable route=#{route} #{error.class}: #{error.message}")
  @product_training_documents[route.to_s] = nil
end

def training_price_table(text)
  table = {}
  text.to_s.scan(/\b(\d{1,5})\s*(?:pcs?|pieces?|yard\s+signs?|signs?)?\s*(?:[-:|]|for)?\s*\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
    table[quantity.to_i] ||= {}
    table[quantity.to_i]["double_sided"] ||= "$#{price.delete(',')}"
  end
  text.to_s.scan(/\$([\d,]+(?:\.\d{2})?)\s*(?:for)?\s*(\d{1,5})\s*(?:pcs?|pieces?|yard\s+signs?|signs?)/i) do |price, quantity|
    table[quantity.to_i] ||= {}
    table[quantity.to_i]["double_sided"] ||= "$#{price.delete(',')}"
  end
  table
end

def merge_price_tables(*tables)
  tables.compact.each_with_object({}) do |table, merged|
    table.to_h.each do |quantity, values|
      key = quantity.to_i
      merged[key] ||= {}
      merged[key].merge!(values.to_h.compact_blank)
    end
  end
end

def included_items_from_text(text)
  body = text.to_s.downcase
  items = []
  items << "stakes included" if body.match?(/\b(free stakes|stakes included|stakes are free|stakes and shipping included)\b/)
  items << "shipping included" if body.match?(/\b(free shipping|shipping included|shipping all in|out[- ]the[- ]door|actual total|no surprise charges)\b/)
  items << "design included" if body.match?(/\b(free design|design included|design is included|we handle the design)\b/)
  items << "double sided" if body.match?(/\b(double sided|double-sided|both sides)\b/)
  items << "full color" if body.match?(/\b(full color|full-color)\b/)
  items << "UV printed/coated" if body.match?(/\b(uv printed|uv coated|uv coating)\b/)
  items.uniq
end

def shipping_note_from_text(text)
  body = text.to_s.squish
  return "Yard sign deal pricing includes shipping at no added cost." if body.match?(/\byard signs?.{0,120}(shipping included|free shipping)|shipping included.{0,120}yard signs?/i)
  return "Shipping is included at no added cost." if body.match?(/\b(free shipping|shipping included|shipping all in|actual total|no surprise charges)\b/i)
  return "Shipping is added on top of the base bundle price." if body.match?(/\bbundle packs?: shipping added|shipping added on top of the base bundle price/i)

  nil
end

def strip_html(value)
  value.to_s.gsub(/<script.*?<\/script>/mi, " ")
    .gsub(/<style.*?<\/style>/mi, " ")
    .gsub(/<[^>]+>/, " ")
    .gsub(/&nbsp;/i, " ")
    .gsub(/&amp;/i, "&")
    .squish
end

def dollars_from_cents(cents)
  amount = cents.to_i / 100.0
  amount == amount.to_i ? "$#{amount.to_i}" : format("$%.2f", amount)
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

def route_valid_shopify_links(links)
  links.to_h.each_with_object({}) do |(route, url), valid|
    next if url.blank?
    next if disallowed_shopify_link?(url)
    next unless route.to_s == "STORE" || shopify_link_matches_route?(route, url)

    valid[route.to_s] = url
  end
end

def shopify_link_matches_route?(route, url)
  text = url.to_s.downcase
  return false if text.blank?
  return false if disallowed_shopify_link?(text)
  return true if route.to_s == "STORE"

  case route.to_s
  when "PRO_PACK"
    text.match?(%r{/products/[^?#]*(?:pro-pack|pro[_-]?pack|100-ys|100-yard-signs)})
  when "STARTER_PACK"
    text.match?(%r{/products/[^?#]*(?:starter-pack|starter[_-]?pack|20-yard-signs)})
  when "BUSINESS_CARDS"
    text.match?(%r{/products/[^?#]*(?:business-cards?|business[_-]?cards?)})
  when "DOOR_HANGERS"
    text.match?(%r{/products/[^?#]*(?:door-hangers?|doorhanger|hangers?)})
  when "FLYERS"
    text.match?(%r{/products/[^?#]*(?:flyers?|flyers-canvasser|handouts?)})
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

def wrong_route_shopify_link?(body)
  text = body.to_s.squish
  urls = text.scan(%r{https?://\S+}).map { |url| strip_url_trailing_punctuation(url) }.uniq
  return false if urls.blank?
  return true if urls.any? { |url| sold_out_shopify_url?(url) }
  return false if urls.length > 1 && text.match?(/\b(compare|links|options|standalone|also)\b/i)

  route = route_hint_from_reply(text).presence || current_route_code.to_s.presence
  return false if route.blank?

  urls.any? do |url|
    next false unless url.match?(%r{shop\.wizwikimarketing\.com/products/}i)

    !shopify_link_matches_route?(route, url)
  end
end

def route_hint_from_reply(text)
  body = text.to_s.downcase.squish
  return "LAWN_SIGNS" if body.match?(/\byard signs? package\b|\bsigns?-only\b|\byard signs?.{0,80}(?:best fit|right order|order|checkout|link)/)
  return "NEIGHBORHOOD_BLITZ" if body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bmain course\b/)
  return "STARTER_PACK" if body.match?(/\bstarter\s*pack\b/)
  return "PRO_PACK" if body.match?(/\bpro\s*pack\b/)
  return "BUSINESS_CARDS" if business_card_interest?(body)
  return "DOOR_HANGERS" if door_hanger_interest?(body)
  return "FLYERS" if flyer_interest?(body)
  return "EDDM" if body.match?(/\beddm\b|\bpostcards?\b|\bdirect mail\b/)

  nil
end

def disallowed_shopify_product?(product)
  handle = product.to_h["handle"].to_s
  title = product.to_h["title"].to_s
  disallowed_shopify_link?("https://shop.example.invalid/products/#{handle}") ||
    title.match?(/\|\s*dane\b/i)
end

def disallowed_shopify_link?(url)
  text = url.to_s
  text.match?(%r{/products/[^?#\s]*\bdane\b}i) ||
    stale_shopify_product_link?(text) ||
    non_owner_shopify_link?(text)
end

def stale_shopify_product_link?(url)
  text = url.to_s.downcase
  STALE_SHOPIFY_PRODUCT_HANDLES.any? do |handle|
    text.match?(%r{/products/#{Regexp.escape(handle)}(?=[/?#;.,)\]\s]|\z)})
  end
end

def non_owner_shopify_link?(url)
  return false unless require_owner_shopify_links?

  text = url.to_s.downcase
  text.include?("shop.example.invalid/") && !owner_shopify_link?(text)
end

def owner_shopify_link?(url)
  text = url.to_s.downcase
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/postcard-block-sale-0704\b})
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/business-cards\b})
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/door-hangers\b})
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/flyers-canvasser\b})
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/eddm-postcards\b})
  return true if text.match?(%r{shop\.wizwikimarketing\.com/products/starter-pack\b})

  text.match?(%r{shop\.wizwikimarketing\.com/[^?#\s]*sample_owner\b})
end

def require_owner_shopify_links?
  !ENV.fetch("WIZWIKI_REQUIRE_OWNER_SHOPIFY_LINKS", "true").to_s.match?(/\A(?:0|false|no|off)\z/i)
end

def shopify_product_sold_out?(route)
  route = route.to_s
  return false if route.blank? || route == "STORE"

  details = product_details_for_route(route).to_h
  variants = Array(details[:variants])
  known_variants = variants.select { |variant| [true, false].include?(variant_available_value(variant)) }
  known_variants.present? && known_variants.none? { |variant| variant_available_value(variant) == true }
end

def sold_out_shopify_url?(url)
  route = sold_out_shopify_route_for_url(url)
  route.present? && shopify_product_sold_out?(route)
end

def sold_out_shopify_route_for_url(url)
  cleaned = strip_url_trailing_punctuation(url.to_s)
  return if cleaned.blank?

  shopify_links.find { |_code, link| strip_url_trailing_punctuation(link.to_s) == cleaned }&.first
end

def sold_out_shopify_route_in_text(text)
  text.to_s.scan(%r{https?://\S+}).filter_map do |url|
    route = sold_out_shopify_route_for_url(url)
    route if route.present? && shopify_product_sold_out?(route)
  end.first
end

def sold_out_shopify_link_in_text?(text)
  text.to_s.scan(%r{https?://\S+}).any? { |url| sold_out_shopify_url?(url) }
end

def sold_out_checkout_reply(route)
  label = ROUTE_LABELS[route.to_s].presence || route.to_s.tr("_", " ").titleize.presence || "that option"
  "The #{label} checkout link looks sold out right now, so it is better not to send that link. The safer next step is the closest available option, or a WIZWIKI teammate can check that deal manually."
end

def missing_identity_fields
  fields = []
  fields << "contact_name" if conversation_contact_name.blank?
  fields << "company_name" if conversation_company_name.blank?
  fields
end

def missing_discovery_fields
  fields = missing_identity_fields
  fields.unshift("product_interest") if current_route_code.blank?
  DISCOVERY_FIELD_ORDER.select { |field| fields.include?(field) }
end

def next_missing_identity_field
  DISCOVERY_FIELD_ORDER.find { |field| missing_identity_fields.include?(field) }
end

def next_missing_discovery_field
  missing_discovery_fields.first
end

def conversation_contact_name
  identity_display_value(@metadata["captured_contact_name"].presence || selected_contact["name"])
end

def customer_first_name
  text = conversation_contact_name.to_s.squish
  return if text.blank? || text.match?(/@/)

  first = text.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
  return if first.blank? || first.length < 2

  first
end

def first_outbound_thread?
  compact_sms_thread.blank?
end

def opening_offer
  first = customer_first_name
  Thumper::VoiceGuide.starter_sms(first, product_lane: opening_offer_product_lane)
end

def opening_offer_product_lane
  [
    current_route_code,
    @metadata["product_interest_code"],
    @metadata["product_interest_label"],
    @metadata["product_interest"],
    @metadata["sms_captured_product_interest"],
    @metadata.dig("comms_bot_state", "route_code"),
    @metadata.dig("comms_bot_state", "product_interest_code"),
    @metadata.dig("comms_bot_state", "product_interest")
  ].compact_blank.first
rescue StandardError
  nil
end

def conversation_company_name
  explicit_company = @metadata["captured_company_name"].presence || @metadata["company_name"].presence
  contact = conversation_contact_name
  if explicit_company.present?
    explicit = identity_display_value(explicit_company)
    return explicit if explicit.present? && !same_identity_value?(explicit, contact)
  end

  thread_company = company_name_from_recent_business_answer
  return thread_company if thread_company.present? && !same_identity_value?(thread_company, contact)

  fallback = company_name
  return if same_identity_value?(fallback, contact)

  identity_display_value(fallback)
end

def company_name_from_recent_business_answer
  events = sms_thread_events
  events.each_with_index.reverse_each do |event, index|
    event = event.to_h
    channel = event["channel"].to_s
    next unless (channel.blank? || channel == "sms") && event["direction"].to_s == "inbound"

    previous = previous_outbound_body(events, index)
    next unless previous.match?(/\b(what company|company should|connect this to|company name|business name|what business|what kind of business)\b/i)

    candidate = clean_company_name_candidate(event["body"])
    return candidate if candidate.present?
  end

  nil
end

def clean_company_name_candidate(value)
  text = value.to_s.squish
  return if text.blank?
  return unless company_like_business_context_response?(text)

  text.gsub(/\b(?:thanks|thank you|please|yes|yeah|sure|ok|okay)\b/i, "")
    .squish
    .split
    .map { |part| part.match?(/\A[A-Z0-9&.'-]+\z/) ? part : part.capitalize }
    .join(" ")
end

def company_like_business_context_response?(text)
  cleaned = text.to_s.squish
  return false if generic_identity_value?(cleaned)
  return false unless cleaned.match?(/\A[a-z0-9&.' -]{2,80}\z/i)
  return true if company_legal_suffix?(cleaned)
  return false if cleaned.match?(/\b(hi|hello|hey|yes|yeah|yep|sure|ok|okay|no|stop|thanks|thank you|great|got it|interested|send|tell me|more|what|kind|eddm|mail|sign|signs|blitz|art|artwork|help|test|zip)\b/i)

  cleaned.split(/\s+/).length >= 2 && cleaned.match?(/\b(roofing|roofers?|plumbing|hvac|heating|cooling|electrical|landscap|construction|contractor|painting|flooring|restoration|pest|solar|concrete|masonry|remodel)\b/i)
end

def company_legal_suffix?(text)
  text.to_s.match?(/\b(?:l\.?\s*l\.?\s*c\.?|llc|inc(?:orporated)?|corp(?:oration)?|co\.?|company|llp|pllc|group|partners|enterprises)\b/i)
end

def same_identity_value?(left, right)
  left_text = left.to_s.squish.downcase
  right_text = right.to_s.squish.downcase
  left_text.present? && left_text == right_text
end

def email_value
  selected = selected_email
  @metadata["captured_email"].presence ||
    @metadata["recipient_email"].presence ||
    selected["email"].presence ||
    selected["value"].presence ||
    selected["address"].presence
end

def email_opt_in_value
  value = @metadata["email_opt_in"].to_s.downcase
  return "yes" if value.in?(%w[yes true 1 y])
  return "no" if value.in?(%w[no false 0 n])
  return "yes" if email_value.present?

  nil
end

def email_opt_in_known?
  email_opt_in_value.present?
end

def contact_preference_value
  @metadata["contact_preference"].to_s.squish.presence
end

def preferred_contact_window_value
  @metadata["preferred_contact_window"].to_s.squish.presence ||
    @metadata["preferred_contact_days"].to_s.squish.presence ||
    @metadata["preferred_contact_times"].to_s.squish.presence
end

def contact_preference_requires_window?
  contact_preference_value.to_s.match?(/\b(sms|text|phone|call)\b/i)
end

def next_missing_prompt(field)
  case field.to_s
  when "product_interest"
    "Ask whether they need postcards, yard signs, or both so WIZWIKI can choose the right product link."
  when "contact_name"
    "Ask for the customer's first name only."
  when "company_name"
    "Ask for the company or business name only."
  end
end

def generic_identity_value?(value)
      text = value.to_s.squish.downcase
      text.blank? || GENERIC_IDENTITY_VALUES.include?(text) || text.match?(/\A(?:wizwiki\s*)?comms\b/) || text.match?(/\Asample\b/)
    end

    def identity_collection_needed?(text)
      return false if text.match?(/\b(what|offer|do|service|services|eddm|mail|sign|art|artwork|blitz|zip|location|where|ship|shipping|area|route)\b/i)
      return false if recently_asked_identity? && !text.match?(/\b(my name is|i am|i'm|this is|company is|business is|we are|we're|i own|i run|from|with|at)\b/i)
      return false if current_route_code.present? && next_route_fit_question(current_route_code).present?

      identity_payload[:missing].present? && text.match?(/\b(hi|hello|hey|yes|sure|ok|okay|interested|send|tell me|more|test)\b/i)
    end

def identity_collection_reply
  if shopify_link_already_sent?
    return post_link_follow_up_reply(latest_inbound_sms)
  end
  if current_route_code.present? && link_fit_ready?(current_route_code)
    return handoff_reply(current_route_code)
  end
  if current_route_code.present? && next_route_fit_question(current_route_code).present?
    return route_next_question(current_route_code)
  end

  reply = case next_missing_discovery_field
  when "product_interest"
    product_direction_question
  when "contact_name"
    fallback_variant([
      "Absolutely. What name should I save this under?",
      "What first name should I keep with this conversation?",
      "Who should I put this under?"
    ])
  when "company_name"
    fallback_variant([
      "What business name should I save this under?",
      "What business name should I attach this to?",
      "Which company is this campaign for?"
    ])
  else
    fallback_variant([
      "What are you trying to promote next?",
      "What are we helping you get in front of people?",
      "What kind of campaign are you trying to move?"
    ])
  end

  reply
end

def product_direction_question
  fit = campaign_fit_payload
  return LOW_BUDGET_CLARIFICATION if low_budget_signal?(fit[:budget]) && !recently_asked?(LOW_BUDGET_CLARIFICATION)
  if usable_budget_signal?(fit[:budget]) || fit[:household_count].present?
    return fallback_variant([
      "Are you leaning toward postcards, yard signs, or both?",
      "That gives me a starting point. Should this lean toward postcards for mailboxes, yard signs, or both?",
      "Should the first push be built around postcards, signs, or both together?"
    ])
  end

  fallback_variant([
    "Are you leaning toward postcards, yard signs, or both?",
    "Are you trying to reach mailboxes with postcards, get yard signs in the ground, or do both?",
    "Which option feels closest: postcards, yard signs, or a combo?"
  ])
end

def email_decline_reply
  return "We can skip email. Do you prefer SMS, a phone call, or no preference?" if contact_preference_value.blank?
  return "We can skip email. For SMS or phone follow-up, are there any days or times that work best?" if contact_preference_requires_window? && preferred_contact_window_value.blank?

  identity_collection_reply
end

      def yes_reply
        latest_route = accepted_recent_recommendation_route.to_s.presence || current_route_code.to_s
        if location_permission_recently_requested? && !zip_present?
          return identity_collection_reply
        end

        return handoff_reply(latest_route) if link_fit_ready?(latest_route)
        return handoff_reply(latest_route) if buyer_accepts_recent_recommendation?(latest_route)
        return route_next_question(latest_route, prefix: "Sounds good.") if latest_route.present? && next_route_fit_question(latest_route).present?
        return identity_collection_reply if identity_payload[:missing].present?
        return handoff_reply(latest_route) if ready_for_handoff?(latest_route)
      return route_next_question(latest_route, prefix: "Sounds good.") if latest_route.present?

      ["Sounds good.", product_direction_question].join(" ").squish
    end

    def unknown_reply
      route = current_route_code
      return post_link_follow_up_reply(latest_inbound_sms) if shopify_link_already_sent?(route)
      return handoff_reply(route) if link_fit_ready?(route)
      return route_next_question(route) if route.present? && next_route_fit_question(route).present?
      return identity_collection_reply if route.present? && identity_payload[:missing].present?
      return handoff_reply(route) if ready_for_handoff?(route)
      return route_next_question(route) if route.present?

      ["Let's narrow this down.", product_direction_question].join(" ").squish
    end

    def route_reply(route, answer, question)
      return handoff_reply(route, prefix: answer) if link_fit_ready?(route)

      fit_question = next_route_fit_question(route)
      return [answer, fit_question].join(" ").squish if fit_question.present?
      return [answer, question].join(" ").squish if route_question_still_useful?(route, question)
      return [answer, identity_collection_reply].join(" ").squish if identity_payload[:missing].present?
      return handoff_reply(route, prefix: answer) if ready_for_handoff?(route)

      answer
    end

def route_question_still_useful?(route, question)
  fit = campaign_fit_payload
  body = question.to_s.downcase

  return true if route.to_s.in?(%w[EDDM NEIGHBORHOOD_BLITZ]) && fit[:household_count].blank? && body.match?(/\b(homes?|households?|reach|routes?|mail)\b/)
  return true if route.to_s == "LAWN_SIGNS" && fit[:quantity_count].blank? && body.match?(/\b(signs?|quantity|how many)\b/)

  false
end

def route_next_question(route, prefix: nil)
  questions = ROUTE_NEXT_QUESTIONS.fetch(route, [])
  fit = campaign_fit_payload
  if zip_present?
    questions = questions.reject { |candidate| candidate.match?(/\b(zip|city|neighborhood|service area|route|area)\b/i) }
  end
  questions = questions.reject { |candidate| stale_route_question?(route, candidate, fit) }
  question = next_route_fit_question(route) || questions.find { |candidate| !recently_asked?(candidate) } || questions.first
  label = @metadata["processing_label"].presence || route.to_s.tr("_", " ").titleize
  body = case route
  when "PRO_PACK"
    "The Pro Pack is the stronger fit when you want signs, cards, and door hangers working together."
  when "STARTER_PACK"
    "The Starter Pack is a good fit when you want a smaller first run before scaling."
  when "EDDM"
    "EDDM is a strong fit for local route-based postcard reach."
  when "NEIGHBORHOOD_BLITZ"
    "A neighborhood blitz is a good fit when you want repeated local visibility."
  when "LAWN_SIGNS"
    "The Yard Signs package is a good fit for quick local visibility."
  else
    "#{label} sounds like the right option."
  end
  [prefix, body, question].compact.join(" ").squish
end

def stale_route_question?(route, question, fit = campaign_fit_payload)
  route = route.to_s
  body = question.to_s.downcase
  return true if fit[:artwork_status].present? && body.match?(/\b(artwork|design|logo)\b/)

  if route == "LAWN_SIGNS"
    return true if fit[:quantity_count].present? && body.match?(/\b(how many|quantity|signs are you thinking|sign count)\b/)
    return true if !fit[:wants_postcards] && !fit[:wants_both] && body.match?(/\b(homes?|households?|reach|postcards?|direct mail|mail)\b/)
    return true if fit[:wants_signs] && !fit[:wants_postcards] && !fit[:wants_both] && body.match?(/\b(bundle|cards?|door hangers?|postcards?)\b/)
  end

  false
end

def next_route_fit_question(route)
  fit = campaign_fit_payload
  return nil if link_fit_ready?(route)

  if low_budget_signal?(fit[:budget]) && !recently_asked?(LOW_BUDGET_CLARIFICATION)
    return LOW_BUDGET_CLARIFICATION
  end

  if route.to_s == "LAWN_SIGNS" && fit[:quantity_count].blank? && !recently_asked?("About how many signs do you want to start with?")
    return fallback_variant([
      "About how many signs do you want to start with?",
      "How many yard signs are you thinking for the first run?",
      "Are you picturing a small batch of signs or a bigger push?"
    ])
  end

  if route.to_s != "LAWN_SIGNS" && fit[:household_count].blank? && !recently_asked?("About how many homes do you want to reach?")
    return fallback_variant([
      "About how many homes do you want to reach?",
      "How many homes or doors are you trying to get in front of?",
      "Is this a small neighborhood test or a larger reach campaign?"
    ])
  end

  context_question = business_context_question(route)
  return context_question if context_question.present?

  return options_link_fit_question if options_link_fit_question_needed?(route)

  if fit[:artwork_status].blank? && !recently_asked?("Do you already have artwork, or should WIZWIKI help shape it?")
    return fallback_variant([
      "Do you already have artwork, or should WIZWIKI help shape it?",
      "Do you have a logo or design ready, or should WIZWIKI help build the creative?",
      "Should we use artwork you already have, or help create the design from scratch?"
    ])
  end

  nil
end

def options_link_fit_question
  "I can send you a link that shows a few options. Roughly what quantity or reach should I use to point you to the right one?"
end

def options_link_fit_question_needed?(route)
  route = route.to_s
  return false if route.blank?
  return false if recently_asked?(options_link_fit_question)
  return false if shopify_link_already_sent?(route)
  return false if link_fit_ready?(route)

  fit = campaign_fit_payload
  quantity_missing = route == "LAWN_SIGNS" ? fit[:quantity_count].blank? : fit[:household_count].blank?
  return false unless quantity_missing

  quantity_was_asked = if route == "LAWN_SIGNS"
    recently_asked?("About how many signs do you want to start with?")
  else
    recently_asked?("About how many homes do you want to reach?")
  end
  quantity_was_asked
end

def ready_for_handoff?(route)
  return true if starter_pack_over_limit?(route)

  route.to_s.present? && link_fit_ready?(route)
    end

def link_fit_ready?(route = current_route_code)
  route = route.to_s
  return false if route.blank?
  return false if shopify_sentence(route).blank?
  return false if shopify_link_already_sent?(route)
  return true if buyer_accepts_recent_recommendation?(route)
  return true if direct_checkout_link_request?(latest_inbound_sms) && checkout_request_route(latest_inbound_sms).to_s == route
  return false unless business_context_ready?
  return false if starter_pack_over_limit?(route)

  fit = campaign_fit_payload
  return false if low_budget_signal?(fit[:budget])
  return true if usable_budget_signal?(fit[:budget])

  case route
  when "LAWN_SIGNS"
    fit[:quantity_count].present?
  when "EDDM", "NEIGHBORHOOD_BLITZ"
    fit[:household_count].present?
  when "PRO_PACK", "STARTER_PACK"
    fit[:household_count].present? || fit[:quantity_count].present?
  else
    fit[:household_count].present? || fit[:quantity_count].present?
  end
end

    def handoff_reply(route, prefix: nil)
      return starter_pack_over_limit_handoff_reply(prefix: prefix) if starter_pack_over_limit?(route)

      checkout = checkout_sentence(route)
      support = checkout.present? ? nil : sms_customer_support_close
      [prefix, compact_product_checkout_summary(route), postcard_generator_sentence(route), support, checkout].compact_blank.join(" ").squish
    end

def starter_pack_over_limit?(route = current_route_code)
  return false unless route.to_s == "STARTER_PACK"

  fit = campaign_fit_payload
  households = numeric_household_value(fit[:household_count])
  quantity = numeric_quantity_value(fit[:quantity_count])

  (households.present? && households > STARTER_PACK_REACH_LIMIT) ||
    (quantity.present? && quantity > STARTER_PACK_SIGN_LIMIT)
end

def starter_pack_over_limit_handoff_reply(prefix: nil)
  base = fallback_variant([
    "A few Starter Pack bundles can be a great deal for that size, and the Pro Pack may fit better if you want a bigger ready-to-buy push. The standard options are worth comparing first so you are not forced into the wrong checkout link.",
    "That is bigger than one Starter Pack, so I would compare the standard bundles first instead of inventing a custom price. Starter bundles can stack well, and Pro Pack is the bigger ready-to-buy bundle.",
    "For that size, the standard path is either stacking Starter Pack bundles or stepping up to Pro Pack where it fits. Larger-volume custom specials need a custom check so pricing stays accurate."
  ])
  [prefix, base].compact_blank.join(" ").squish
end

    def completion_ready?
      ready_for_handoff?(current_route_code)
    end

    def completion_message_sent?
      @metadata["sms_autopilot_completion_sent_at"].present? || @metadata["sms_autopilot_completed_at"].present?
    end

    def completion_reply
      [compact_product_checkout_summary(current_route_code), postcard_generator_sentence(current_route_code), checkout_sentence(current_route_code)].compact_blank.join(" ").squish
    end

def customer_support_close
  "I can keep helping compare the options from here."
end

def sms_customer_support_close
  "I can keep helping compare the options from here."
end

def price_then_handoff_reply(text)
  pricing = pricing_reply(text)
  pricing = strip_handoff_pricing_follow_up(pricing)
  handoff = human_handoff_reply
  return handoff if pricing.blank?

  [pricing, handoff].compact_blank.join(" ").squish
end

def strip_handoff_pricing_follow_up(text)
  body = text.to_s.sub(/\s+[^.!?]*\?\z/, "").squish
  body
    .sub(/\s+I can point you to the right sign option\.?\z/i, "")
    .sub(/\s+I can narrow this down quickly\.?\z/i, "")
    .sub(/\s+The checkout link is the next step\.?\z/i, "")
    .squish
end

def human_handoff_reply
  contact_reply = handoff_contact_collection_reply
  return contact_reply if contact_reply.present?

  owner = handoff_owner_name
  context = handoff_price_context_reply(latest_inbound_sms)
  if owner.present?
    reply = fallback_variant([
      "I will get this in front of #{owner} for follow-up. I can still answer the basics here while that happens.",
      "I will pass this to #{owner} so they can help with the next step. If you have a quick product question in the meantime, send it here.",
      "#{owner} will be the right person to pick this up from here, and I will get it in front of them for follow-up."
    ])
  else
    reply = fallback_variant([
      "I will get this in front of a WIZWIKI teammate for follow-up. I can still answer the basics here while that happens.",
      "I will pass this to the WIZWIKI team so someone can help with the next step. If you have a quick product question in the meantime, send it here.",
      "I will get this in front of the team for follow-up so a person can pick it up from here."
    ])
  end
  [context, reply].compact_blank.join(" ").squish
end

def human_handoff_stack_reply
  contact_reply = handoff_contact_collection_reply
  return contact_reply if contact_reply.present?

  context = [
    current_open_customer_message_bodies.join(" "),
    recent_customer_sms_context,
    latest_inbound_sms
  ].compact.join(" ").squish
  owner = handoff_owner_name
  parts = []
  parts << if owner.present?
    "Yes, I will get this in front of #{owner} for follow up."
  else
    "Yes, I will get this in front of a WIZWIKI teammate for follow up."
  end

  if turnaround_question?(context) || rush_checkout_boundary_question?(context)
    details = turnaround_details
    parts << "For rush, a marketing consultant needs to confirm availability and pricing; rush starts after proof approval, moves production ahead in the queue, and shipping is still usually #{details[:shipping]}."
  end

  if design_process_question?(context) || artwork_creation_followup_request?(context)
    parts << "You do not need finished artwork ready; the intake/proof step collects your logo, artwork, wording, and notes after checkout, not by text, and nothing prints until you approve the proof."
  end

  parts << "I can still answer basics here while that happens." if parts.length == 1
  enforce_sms_length(parts.compact_blank.join(" ").squish)
end

def handoff_contact_collection_reply
  if handoff_contact_posted? && handoff_contact_ready?
    owner = handoff_owner_name.presence || "One of our marketing consultants"
    preference = handoff_contact_preference_label
    return "Perfect. #{owner} will be contacting you#{preference.present? ? " #{preference}" : ""}. I let them know your contact preferences."
  end
  return if handoff_contact_posted? && !handoff_contact_ready?
  return if !handoff_contact_collection_response_turn? && !human_request?(latest_inbound_sms) && !support_handoff_confirmation_request?(latest_inbound_sms) && !recent_handoff_offer_accepted?

  unless handoff_contact_permission?
    return "I can get this in front of a marketing consultant to help with the next step. Would it be helpful for them to reach out?"
  end

  case handoff_contact_preference
  when "email"
    return "Perfect. What email should our marketing consultant use?" if handoff_contact_email.blank?
  when "call", "phone"
    missing = []
    missing << "the best number" if handoff_contact_phone.blank?
    missing << "a good time to call or text" if handoff_contact_time.blank?
    return "Perfect. What is #{missing.to_sentence}?" if missing.present?
  when "text", "sms"
    missing = []
    missing << "the best number" if handoff_contact_phone.blank?
    missing << "a good time to text" if handoff_contact_time.blank?
    return "Perfect. What is #{missing.to_sentence}?" if missing.present?
  else
    return "Perfect. What is the best way for them to reach you: email, call, or text? #{known_handoff_contact_hint}".squish
  end

  "Perfect. I am getting that to the right marketing consultant now."
end

def handoff_contact_collection_active?
  ActiveModel::Type::Boolean.new.cast(@metadata["sms_autopilot_handoff_contact_pending"]) &&
    @metadata["sms_autopilot_handoff_contact_posted_at"].blank?
end

def handoff_contact_collection_response_turn?
  return false unless defined?(Comms::InboundSmsHandoff)

  Comms::InboundSmsHandoff.contact_collection_response?(@stage, latest_inbound_sms)
rescue StandardError
  false
end

def handoff_contact_ready?
  return false unless handoff_contact_permission?

  case handoff_contact_preference
  when "email"
    handoff_contact_email.present?
  when "call", "phone"
    handoff_contact_phone.present? && handoff_contact_time.present?
  when "text", "sms"
    handoff_contact_phone.present? && handoff_contact_time.present?
  else
    false
  end
end

def handoff_contact_posted?
  @metadata["sms_autopilot_handoff_contact_posted_at"].present? ||
    @metadata["sms_autopilot_slack_human_requested_at"].present? ||
    @metadata["sms_autopilot_slack_handoff_at"].present?
end

def handoff_contact_permission?
  ActiveModel::Type::Boolean.new.cast(@metadata["sms_autopilot_handoff_contact_permission"]) ||
    human_request?(latest_inbound_sms) ||
    support_handoff_confirmation_request?(latest_inbound_sms) ||
    (handoff_contact_collection_active? && handoff_contact_affirmative_reply?(latest_inbound_sms)) ||
    recent_handoff_offer_accepted?
end

def handoff_contact_preference
  value = normalize_handoff_contact_preference(@metadata["sms_autopilot_handoff_contact_preference"])
  value ||= "email" if handoff_contact_permission? && handoff_contact_email.present? && handoff_contact_phone.blank?
  value
end

def handoff_contact_email
  @metadata["sms_autopilot_handoff_contact_email"].to_s.squish.presence
end

def handoff_contact_phone
  @metadata["sms_autopilot_handoff_contact_phone"].to_s.squish.presence
end

def handoff_contact_time
  @metadata["sms_autopilot_handoff_contact_time"].to_s.squish.presence
end

def handoff_contact_time_from(value)
  body = value.to_s.squish
  return if body.blank? || body.include?("?")
  return body[/\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b[^.!?]{0,80}/i]&.squish if body.match?(/\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i)
  return body[/\b(?:morning|afternoon|evening|after lunch|before lunch|anytime|any time|after \d{1,2}|before \d{1,2})\b[^.!?]{0,60}/i]&.squish if body.match?(/\b(?:morning|afternoon|evening|after lunch|before lunch|anytime|any time|after \d{1,2}|before \d{1,2})\b/i)
  return body[/\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b[^.!?]{0,40}/i]&.squish if body.match?(/\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b/i)

  nil
end

def handoff_contact_affirmative_reply?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || body.include?("?")

  body.match?(/\A(?:yes|yesd|yep|yeah|sure|ok|okay|please|absolutely|that works|sounds good|do that|go ahead|please do)[\s.!]*\z/) ||
    body.match?(/\b(?:yes|yesd|yep|yeah|sure|ok|okay|please|absolutely|that works|sounds good|go ahead|please do|let'?s do|lets do|do this|this number|same number|use this number|use that number|text only)\b/)
end

def recent_handoff_offer_accepted?
  handoff_contact_affirmative_reply?(latest_inbound_sms) && recent_outbound_consultant_offer?
end

def recent_outbound_consultant_offer?
  Array(@metadata["sms_thread"]).map(&:to_h).reverse.first(12).any? do |event|
    event["direction"].to_s == "outbound" &&
      event["body"].to_s.squish.present? &&
      !event["status"].to_s.in?(%w[failed canceled undelivered blocked skipped]) &&
      consultant_handoff_offer_text?(event["body"])
  end
end

def consultant_handoff_offer_text?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:marketing consultant|consultant|wizwiki teammate|teammate|person|someone)\b/)
  return false unless body.match?(/\b(?:want me|would it be helpful|can i|should i|check this|reach out|go over|connect|best way for (?:them|someone|a consultant|our consultant) to reach|what(?:'s| is) the best way)\b/)
  return false if body.match?(/\b(?:will be contacting|i let them know|getting that to|got this to)\b/)

  true
end

def normalize_handoff_contact_preference(value)
  body = value.to_s.downcase.squish
  return "email" if body.match?(/\b(?:email|e-mail)\b/)
  return "text" if body.match?(/\b(?:text|sms)\b/)
  return "call" if body.match?(/\b(?:call|phone|ring)\b/)

  nil
end

def known_handoff_contact_hint
  nil
end

def handoff_contact_preference_label
  case handoff_contact_preference
  when "email"
    "by email"
  when "call", "phone"
    "by phone"
  when "text", "sms"
    "by text"
  end
end

def handoff_price_context_reply(text)
  body = [text, recent_sms_context].compact.join(" ").downcase.squish
  return if body.blank?
  return unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)

  quantity = body.scan(/\b(\d{1,6})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i).flatten.map(&:to_i).max
  return if quantity.blank?

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  options = price_options_for_quantity(table, quantity)
  price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
  return if price.blank?

  "For #{format_quantity_count(quantity)} yard signs, you are at #{display_yard_sign_price(price)} with design help, stakes, and shipping included."
end

def support_handoff_confirmation_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if turnaround_question?(body) || rush_checkout_boundary_question?(body)
  return false if pricing_question?(body) && body.match?(/\b(?:but first|first|before|what\s+do|what\s+would|how\s+much|cost|price|pricing|quote)\b/)
  return false if body.match?(/\b(?:artwork|art work|design|logo|creative|file|files|image|images|proof|screenshot)\b/) &&
    !body.match?(/\b(?:person|someone|consultant|rep|representative|call|follow\s*up|reach out|connect)\b/)
  return false unless explicit_support_handoff_request?(body)
  return true if body.match?(/\b(?:yes|yep|yeah|sure|ok|okay|please|too|also)\b/)
  return true if body.match?(/\b(?:have|get|connect|pass)\b.{0,80}\b(?:person|someone|consultant|team|teammate|human)\b/)
  return true if body.match?(/\b(?:call)\b.{0,80}\b(?:me|us|back)\b/)

  recent_sms_context.match?(/\b(?:real person|someone|consultant|human|call me)\b.{0,120}\b(?:cost|price|quote|500|yard signs?)\b/i)
end

def proof_handoff_reply
  fallback_variant([
    "Checkout starts the order and gets you into the design queue. After that, the intake form collects your logo, images, wording, colors, and notes, not text message attachments; then you review a proof and nothing prints until you approve it.",
    "You do not need a finished design before checkout. The order starts the design queue, the intake form gathers your files and notes after checkout, and nothing goes to print until you approve the proof.",
    "The proof process starts after checkout: upload what you have through the intake form, add the design notes, review the proof, and request changes if needed before print."
  ])
end

def account_manager_answer_needed_reply
  if handoff_contact_confirmation_due? || handoff_contact_collection_response_turn? || human_request?(latest_inbound_sms) || support_handoff_confirmation_request?(latest_inbound_sms)
    human_handoff_stack_reply
  elsif proof_handoff_request?(latest_inbound_sms)
    proof_handoff_reply
  elsif bundle_change_custom_request?(latest_inbound_sms)
    custom_bundle_handoff_reply
  elsif frustrated_or_support_pressure?(latest_inbound_sms)
    human_handoff_reply
  elsif yard_sign_pricing_request?(latest_inbound_sms)
    yard_sign_pricing_reply(latest_inbound_sms).presence || outside_deal_quantity_handoff_reply
  elsif outside_deal_quantity_pressure?(latest_inbound_sms)
    outside_deal_quantity_handoff_reply
  elsif product_option_mismatch?(latest_inbound_sms)
    fallback_variant([
      "Good catch. I would compare the listed options first instead of guessing at a custom setup. Starter Pack and Pro Pack are fixed bundles, and Yard Signs is the signs-only path. What quantity or mix are you trying to price?",
      "That may be outside the fixed checkout setup. The standard packs are the clean first comparison, and custom specials only make sense after that. What quantity or mix are you considering?",
      "If the listed checkout option does not match the mix you need, start by comparing Yard Signs, Starter Pack, and Pro Pack. What quantity or mix should we compare?"
    ])
  else
    fallback_variant([
      "I want to get that right instead of guessing. I will pass this to a WIZWIKI teammate, and I can keep answering the product basics here.",
      "That one needs a person so we do not answer it loosely. I will pass it to the WIZWIKI team for the right next step.",
      "That needs an exact answer from the team. A WIZWIKI teammate can pick this up from here."
    ])
  end
end

def am_support_required_for_latest_inbound?
  inbound = latest_inbound_sms.to_s
  return false if inbound.blank?
  return true if handoff_contact_confirmation_due?
  return true if handoff_contact_collection_response_turn?
  return true if recent_handoff_offer_accepted?
  return true if messy_print_consultant_question?(inbound)
  return true if direct_mail_strategy_handoff_question?(inbound)
  return true if human_request?(inbound)
  return true if checkout_handoff_needed?(inbound)
  return true if frustrated_or_support_pressure?(inbound) && explicit_support_handoff_request?(inbound)

  false
end

def handoff_contact_confirmation_due?
  handoff_contact_posted? && handoff_contact_ready? && !handoff_confirmation_already_sent?
end

def handoff_confirmation_already_sent?
  posted_at = sms_event_time("created_at" => @metadata["sms_autopilot_handoff_contact_posted_at"].presence || @metadata["sms_autopilot_slack_handoff_at"])
  return false if posted_at.blank?

  sms_thread_events.any? do |event|
    event = event.to_h
    next false unless event["direction"].to_s == "outbound"
    next false unless sms_event_time(event).to_i >= posted_at.to_i

    event["body"].to_s.match?(/\b(?:assigned to follow up|will be contacting|getting that to the right marketing consultant|contact preferences)\b/i)
  end
end

def checkout_handoff_needed?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  checkout_context = body.match?(/\b(?:checkout|check out|cart|payment|pay|paid|order|link|url|website|site|shopify)\b/)
  blocked = body.match?(/\b(?:can'?t|cannot|couldn'?t|won'?t|will not|error|failed|fails|failure|not working|doesn'?t work|isn'?t working|stuck|broken|declined|decline|missing|issue|problem|trouble|won'?t load|will not load)\b/)
  checkout_context && blocked
end

def explicit_support_handoff_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  human_request?(body) ||
    body.match?(/\b(?:support person|human support|account manager|assistant|sales rep|representative|someone call|call me|email me|text me)\b/) ||
    body.match?(/\b(?:have|get|connect|pass|send)\b.{0,80}\b(?:person|someone|consultant|team|teammate|human|rep|representative)\b/) ||
    body.match?(/\b(?:person|someone|consultant|team|teammate|human|rep|representative)\b.{0,80}\b(?:follow\s*up|reach out|call|connect|pick this up)\b/)
end

def am_support_reply_sendable?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(account manager|marketing consultant|consultant|wizwiki teammate|teammate|person|human|rep|representative)\b/) &&
    body.match?(/\b(contact|follow[-\s]?up|reach out|call|text|email)\b/) &&
    !analysis_leak?(body)
end

def pricing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  return true if cheapest_overall_pricing_question?(body)
  return true if full_options_pricing_question?(body)
  return true if signs_only_bundle_compare_question?(body)
  return true if signs_only_pricing_question?(body)
  return true if yard_sign_pricing_request?(body)
  return true if route_quantity_option_question?(body)
  return true if budget_value_question?(body)
  return true if current_specials_question?(body)
  return true if deal_or_special_pricing_question?(body)
  pricing_intent?(body) ||
    body.match?(/\b(?:shipping|stakes included|free shipping|what.*included)\b/) ||
    (body.match?(/\b\d{1,6}\s*(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/) && body.match?(/\b(?:how|what|cost|price|pricing|total|quote|rate|charge)\b/)) ||
    (product_option_mismatch?(body) && (sign_interest?(body) || requested_quantities(body).present?))
end

def deal_or_special_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if current_specials_question?(body)
  explicit_promo_query = body.match?(/\bpromos?\b/) &&
    body.match?(/\b(?:any|current|active|running|available|got|have|show|list|give|send|tell|deal|special|discount|coupon)\b/)
  return false unless body.match?(/\b(?:cheap(?:er|est)?|expensive|less expensive|lowest|lower|affordable|specials?|coupon|discounts?|price break|deal|deals)\b/) ||
    explicit_promo_query

  sign_interest?(body) ||
    postcard_interest?(body) ||
    current_route_code.present? ||
    inferred_product_route_from_fit.present? ||
    requested_quantities(body).present?
end

def pricing_intent?(text)
  text.to_s.match?(PRICING_INTENT_PATTERN)
end

def pricing_reply(text)
  if unit_pricing_request?(text)
    reply = unit_pricing_reply(text)
    return reply if reply.present?
  end

  route = pricing_route(text)
  return if route.blank?

  case route
  when "VETERAN_DISCOUNT"
    veteran_discount_reply
  when "CHEAPEST_OVERALL"
    cheapest_overall_pricing_reply(text)
  when "CURRENT_SPECIALS"
    current_specials_reply(text)
  when "SIGNS_AND_BUNDLE_OPTIONS"
    signs_only_and_bundle_options_reply
  when "ALL_STANDARD_OPTIONS"
    standard_options_pricing_reply
  when "BUNDLE_PACKS"
    bundle_compare_pricing_reply
  when "LAWN_SIGNS"
    yard_sign_pricing_reply(text)
  when "STARTER_PACK", "PRO_PACK"
    bundle_pricing_reply(route, text)
  else
    generic_product_pricing_reply(route)
  end
end

def pricing_route(text)
  body = text.to_s.downcase
  return "VETERAN_DISCOUNT" if veteran_discount_question?(body)
  return "CURRENT_SPECIALS" if current_specials_question?(body)
  return "CHEAPEST_OVERALL" if cheapest_overall_pricing_question?(body)
  return "BUNDLE_PACKS" if bundle_price_question?(body)
  return "SIGNS_AND_BUNDLE_OPTIONS" if signs_only_bundle_compare_question?(body)
  return "LAWN_SIGNS" if signs_only_pricing_question?(body)
  return "ALL_STANDARD_OPTIONS" if full_options_pricing_question?(body) && (multi_product_pricing_question?(body) || !body.match?(SIGN_INTEREST_PATTERN))
  return "LAWN_SIGNS" if signs_only_options_question?(body)
  return "ALL_STANDARD_OPTIONS" if full_options_pricing_question?(body)
  return "LAWN_SIGNS" if yard_sign_pricing_request?(body)
  return "STARTER_PACK" if body.match?(/\bstarter\s*pack\b/)
  return "PRO_PACK" if body.match?(/\bpro\s*pack\b/)
  return "BUSINESS_CARDS" if business_card_interest?(body)
  return "DOOR_HANGERS" if door_hanger_interest?(body)
  return "FLYERS" if flyer_interest?(body)
  return "LAWN_SIGNS" if yard_sign_budget_question?(body)
  return "LAWN_SIGNS" if sign_interest?(body) || body.match?(/\b\d{1,5}\s*(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
  return "EDDM" if postcard_interest?(body) || body.match?(/\b\d{1,6}\s*(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/)
  if current_route_code.present? && pricing_intent?(body)
    return current_route_code
  end
  return "ALL_STANDARD_OPTIONS" if pricing_intent?(body)

  current_route_code.presence || inferred_product_route_from_fit
end

def current_specials_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if veteran_discount_question?(body)
  return true if postcard_special_quantity_followup?(body)
  return true if postcard_best_deal_special_question?(body)
  return false if product_deal_question?(body)
  explicit_promo_query = body.match?(/\bpromos?\b/) &&
    body.match?(/\b(?:any|current|active|running|available|got|have|show|list|give|send|tell|deal|special|discount|coupon)\b/)
  return false unless body.match?(/\b(?:specials?|coupon|coupons|discounts?|july\s*4|4th\s+of\s+july)\b/) ||
    explicit_promo_query ||
    body.match?(/\bdeals?\b/) && body.match?(/\b(?:any|current|active|running|available|specials?|promos?|discounts?|got|have|show|list|give|send|tell)\b/)
  return false if sign_interest?(body) && !postcard_interest?(body) && !body.match?(/\b(?:july\s*4|4th\s+of\s+july|postcard\s+specials?)\b/)

  body.match?(/\b(?:what|which|any|have|got|active|current|right now|today|running|available|show|list|give|send|tell|july\s*4|4th\s+of\s+july)\b/) ||
    postcard_interest?(body)
end

def postcard_best_deal_special_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if sign_interest?(body) && !postcard_interest?(body)
  return false unless postcard_interest?(body) || current_route_code.to_s == "EDDM" || recent_sms_context.match?(POSTCARD_INTEREST_PATTERN)
  return false unless body.match?(/\bdeals?\b/)

  body.match?(/\b(?:best|better|strongest|good|great|current|active|available|cheapest|lowest|value)\b/)
end

def product_deal_question?(text)
  body = text.to_s.downcase.squish
  body.match?(/\b(?:combo|bundle|bundles|pack|packs|starter\s*pack|pro\s*pack|signs?\s*only|yard\s+signs?|lawn\s+signs?)\b/) &&
    !body.match?(/\b(?:specials?|coupon|coupons|discounts?|july\s*4|4th\s+of\s+july)\b/)
end

def current_specials_reply(text = nil)
  body = text.to_s.downcase.squish
  return inactive_postcard_specials_reply(body) unless current_postcard_special_active?

  line = Comms::CurrentSpecials.full_sms_line.to_s.squish.presence || Comms::CurrentSpecials.sms_line.to_s.squish.presence
  return missing_pricing_handoff_reply if line.blank?

  link = Comms::CurrentSpecials.respond_to?(:checkout_url) ? Comms::CurrentSpecials.checkout_url.to_s.presence : nil
  wants_link = body.match?(/\b(?:link|checkout|order|buy|purchase|ready|send|where)\b/)
  return "#{line} Use this reviewed checkout link when you are ready: #{link}".squish if wants_link && link.present?

  "#{line} Would you like an operator to confirm whether it fits your request?".squish
end

def inactive_postcard_specials_reply(text = nil)
  "I do not have a reviewed active special or standard price configured for that request. I can have an operator confirm current options before anything is quoted."
end

def yard_sign_specials_pricing_context_sentence
  details = product_details_for_route("LAWN_SIGNS").to_h
  table = details[:price_table].to_h
  quantity = yard_sign_pricing_quantity_for(latest_inbound_sms)
  sentence = quantity.present? && table.present? ? yard_sign_quantity_sentence(quantity, table) : nil
  inclusion = yard_sign_inclusion_sentence(details)
  return [sentence, inclusion].compact_blank.join(" ").squish if sentence.present?

  compact_yard_sign_pricing_sentence.presence || "I do not have reviewed pricing configured for that product."
end

def yard_sign_specials_follow_up
  if numeric_quantity_value(campaign_fit_payload[:quantity_count]).present?
    "Want to stay with the signs, or look at postcards too?"
  else
    "How many signs are you thinking?"
  end
end

def current_postcard_special_active?
  defined?(Comms::CurrentSpecials) && Comms::CurrentSpecials.active?
rescue StandardError
  false
end

def postcard_special_confirmation_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:right pricing|that pricing|that size|at that size|is .*special|special .*right)\b/)
  return false unless postcard_interest?(body) || recent_sms_context.match?(POSTCARD_INTEREST_PATTERN)

  body.match?(/\b(?:1,?000|1000|1k)\b/) ||
    recent_sms_context.match?(/\b(?:1,?000|1000|1k)\b.{0,80}\b(?:post\s*cards?|postcards?|homes?|houses?)\b/i)
end

def current_specials_price_line(line)
  line.to_s
    .sub(/\A4th\s+of\s+july\s+specials?\s+are\s+live\s*:\s*/i, "")
    .sub(/[.]\z/, "")
    .squish
end

def postcard_special_all_tiers_request?(text)
  body = text.to_s.downcase.squish
  body.match?(/\b(?:all|every|full|complete|entire)\b.{0,30}\b(?:tiers?|prices?|pricing|options?|table|list)\b/) ||
    body.match?(/\b(?:tiers?|price table|price list|full pricing|all pricing|all prices)\b/)
end

def postcard_minimum_path_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if direct_checkout_link_request?(body)
  return false if sign_interest?(body) && !postcard_interest?(body)
  return false unless postcard_interest?(body) || current_route_code.to_s == "EDDM" || recent_sms_context.match?(POSTCARD_INTEREST_PATTERN)

  postcard_minimum_path_question_shape?(body)
end

def postcard_minimum_path_question_shape?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:smallest|minimum|lowest|starter|starting|entry|real)\b.{0,50}\b(?:path|order|option|route|postcards?|mail)\b/) ||
    body.match?(/\b(?:what|which)\b.{0,40}\b(?:smallest|minimum|lowest|starter|starting|entry)\b.{0,40}\b(?:postcards?|mail|order|path|route)\b/)
end

def postcard_minimum_path_reply
  starting_price = Comms::ProductCatalog.starting_price_line("EDDM") || Comms::ProductCatalog.fixed_price("EDDM")
  return missing_pricing_handoff_reply if starting_price.blank?

  "The reviewed catalog starts at #{starting_price}. About how many recipients are you trying to reach?"
end

def postcard_special_anchor_quantity(text)
  anchor = postcard_special_quantity_from_text(text)
  return anchor if anchor.present?

  sms_thread_events.reverse_each do |event|
    next unless event.to_h["direction"].to_s == "inbound"

    anchor = postcard_special_quantity_from_text(event.to_h["body"])
    return anchor if anchor.present?
  end

  postcard_special_quantity_from_text(recent_sms_context)
end

def postcard_special_quantity_from_text(text)
  context = text.to_s.downcase
  [
    [25_000, /\b(?:25,?000|25000|25k)\b/],
    [10_000, /\b(?:10,?000|10000|10k)\b/],
    [5_000, /\b(?:5,?000|5000|5k)\b/],
    [2_500, /\b(?:2,?500|2500|2\.5k)\b/],
    [1_000, /\b(?:1,?000|1000|1k)\b/]
  ].find { |_quantity, pattern| context.match?(pattern) }&.first
end

def postcard_special_price_for_quantity(quantity)
  Comms::ProductCatalog.special_price_for_quantity(quantity)
end

def postcard_special_below_minimum_followup?(text)
  return false unless current_postcard_special_active?

  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:less|fewer|smaller|lower|below|under|not\s+that\s+many|too\s+many|maybe\s+less|closer\s+to\s+less|less\s+than)\b/)
  return false unless recent_postcard_special_mentioned?

  current_route_code.to_s == "EDDM" || recent_sms_context.match?(POSTCARD_INTEREST_PATTERN)
end

def recent_postcard_special_mentioned?
  full_recent_sms_context.match?(/\b(?:active|current|reviewed|seasonal)\s+(?:offer|special|promotion)\b/i)
end

def postcard_special_below_minimum_reply
  "That quantity is outside the reviewed special tiers I have. I can have an operator confirm the correct standard option."
end

def postcard_special_quantity_followup?(text)
  return false unless current_postcard_special_active?

  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if sign_interest?(body) && !postcard_interest?(body)
  return false if explicit_postcard_checkout_request?(body)
  quantity = postcard_special_quantity_from_text(body)
  return false unless quantity.present? && quantity >= 1_000
  has_postcard_quantity_unit = body.match?(/\b(?:mail|mailing|homes?|households?|mailboxes?|doors?|nearby|reach|post\s*cards?|postcards?)\b/)
  quantity_only_followup = postcard_special_quantity_only_followup?(body)
  return false unless has_postcard_quantity_unit || quantity_only_followup

  postcard_interest?(body) ||
    current_route_code.to_s == "EDDM" ||
    recent_sms_context.match?(POSTCARD_INTEREST_PATTERN) ||
    recent_postcard_special_mentioned?
end

def postcard_special_quantity_only_followup?(body)
  return false unless body.to_s.match?(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+|approx(?:imately)?\s+)?(?:1,?000|1000|1k|2,?500|2500|2\.5k|5,?000|5000|5k|10,?000|10000|10k|25,?000|25000|25k)\s*(?:homes?|households?|mailboxes?|doors?|post\s*cards?|postcards?)?\z/i)

  current_route_code.to_s == "EDDM" ||
    recent_sms_context.match?(POSTCARD_INTEREST_PATTERN) ||
    recent_sms_context.match?(/\b(?:how many|about how many|roughly how many).{0,60}\b(?:homes?|households?|mailboxes?|doors?|post\s*cards?|postcards?|reach)\b/i) ||
    recent_postcard_special_mentioned?
end

def postcard_large_quantity_followup_reply(text)
  quantity = postcard_special_quantity_from_text(text).presence ||
    requested_quantities(text).select { |value| value >= 1_000 }.min ||
    1_000
  label = format_quantity_count(quantity)

  "Got it, around #{label} homes is a larger postcard run. Standard EDDM starts at $399 for one mail-only route, but #{label} homes should be priced as a larger postcard block so routing and postage stay accurate. Want me to have a marketing consultant confirm the best setup?"
end

def explicit_postcard_checkout_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:send|text|share|give me|need|want|checkout|link|order|buy|purchase)\b/)

  body.match?(/\b(?:post\s*cards?|postcards?|postcard\s+block\s+sale|block\s+sale|postcard\s+special|4th\s+of\s+july|july\s*4)\b/) ||
    (body.match?(/\b(?:1,?000|1000|1k|2,?500|2500|2\.5k|5,?000|5000|5k|10,?000|10000|10k|25,?000|25000|25k)\b/) && recent_sms_context.match?(POSTCARD_INTEREST_PATTERN))
end

def postcard_special_quantity_followup_reply(text)
  quantity = postcard_special_quantity_from_text(text).presence || 1_000
  price = product_catalog_postcard_special_price_for_quantity(quantity).presence || postcard_special_price_for_quantity(quantity)
  label = format_quantity_count(quantity)

  "For mailing around #{label} homes, the 4th of July postcard Block Sale is #{label} postcards for #{price}. That is the closest postcard special tier; want me to send that checkout link?"
end

def product_catalog_postcard_special_price_for_quantity(quantity)
  return unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.special_price_for_quantity(quantity)
rescue StandardError
  nil
end

def postcard_below_minimum_quantity_followup?(text)
  quantity = postcard_below_minimum_quantity_value(text)
  return false unless quantity.present? && quantity < 1_000
  return false unless recent_postcard_special_mentioned?

  current_route_code.to_s == "EDDM" ||
    full_recent_sms_context.match?(POSTCARD_INTEREST_PATTERN) ||
    full_recent_sms_context.match?(/\b(?:homes?|households?|mailboxes?|doors?|reach|route)\b/i)
end

def postcard_below_minimum_quantity_value(text)
  body = text.to_s.downcase.squish
  return if body.blank?

  match = body.match(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+)?([\d,]{1,6})\s*(?:homes?|households?|mailboxes?|doors?|post\s*cards?|postcards?)?\z/i)
  return if match.blank?

  match[1].to_s.delete(",").to_i
end

def postcard_below_minimum_quantity_reply(text)
  quantity = postcard_below_minimum_quantity_value(text)
  count = quantity.present? ? "#{format_quantity_count(quantity)} homes" : "that count"
  price = bundle_price_text("EDDM").presence || "$399"

  if current_postcard_special_active?
    "For #{count}, I would not use the 4th of July block sale. The standard postcard path starts at #{price}; EDDM route mail usually reaches about 500-700 homes. Want the #{price} postcard link?"
  else
    "For #{count}, the standard postcard path starts at #{price}; EDDM route mail usually reaches about 500-700 homes. Want the #{price} postcard link?"
  end
end

def postcard_below_minimum_quantity_answer?(text, inbound)
  quantity = postcard_below_minimum_quantity_value(inbound)
  body = text.to_s.downcase.squish
  return false if quantity.blank? || body.blank?
  return false if body.match?(/\bpostcard\s+block\s+sale\b.*\$\s?790|\$\s?790\b.*\b(?:proceed|link|checkout|order|use)\b/)

  body.match?(/\b#{Regexp.escape(format_quantity_count(quantity).downcase)}\b|\b#{quantity}\b/) &&
    body.match?(/\b(?:standard\s+postcard|eddm|route)\b/) &&
    body.match?(/\$399\b/) &&
    body.match?(/\b(?:not\s+use|starts?\s+at|under|below|less\s+than|instead)\b/)
end

def postcard_special_below_minimum_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:4th\s+of\s+july|july\s*4|postcard\s+special)\b/) &&
    body.match?(/\b(?:starts\s+at|minimum|1,?000|1k)\b/) &&
    body.match?(/\beddm\b/) &&
    body.match?(/\$399\b/)
end

def budget_value_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if explicit_budget_value(body).blank?
  return true if body.match?(/\b(?:what|what's|whats|how many|can|could|would|will|do|does|get|buy|afford|cover|fit|enough|budget|spend)\b/)

  current_route_code.to_s == "LAWN_SIGNS" || sign_interest?(body)
end

def yard_sign_budget_question?(text)
  body = text.to_s.downcase.squish
  return false unless budget_value_question?(body)

  sign_interest?(body) ||
    current_route_code.to_s == "LAWN_SIGNS" ||
    recent_sms_context.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs in the ground|signs-only|yard signs package)\b/i)
end

def full_options_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if starter_pro_compare_question?(body)
  return false if cheapest_overall_pricing_question?(body)

  body.match?(/\b(?:all|every|full|whole|complete)\b.{0,50}\b(?:options?|packages?|packs?|deals?|prices?|pricing|costs?|rates?)\b/) ||
    body.match?(/\b(?:options?|packages?|packs?|deals?)\b.{0,40}\b(?:with|and|plus|including|include)\b.{0,30}\b(?:prices?|pricing|costs?|rates?)\b/) ||
    body.match?(/\b(?:prices?|pricing|costs?|rates?)\b.{0,40}\b(?:for|on|of)\b.{0,30}\b(?:all|every|options?|packages?|packs?|deals?)\b/) ||
    body.match?(/\b(?:tell|show|give|send|list)\b.{0,35}\b(?:options?|packages?|packs?|deals?)\b.{0,60}\b(?:prices?|pricing|costs?|rates?)\b/) ||
    body.match?(/\b(?:all|every|standard|main)\b.{0,35}\b(?:prices?|pricing|costs?|rates?)\b/) ||
    broad_product_options_question?(body) ||
    multi_product_pricing_question?(body)
end

def broad_product_options_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if current_specials_question?(body)
  return false if signs_only_options_question?(body)

  product_specific = body.match?(SIGN_INTEREST_PATTERN) ||
    body.match?(POSTCARD_INTEREST_PATTERN) ||
    body.match?(/\b(?:business\s+cards?|door\s+hangers?)\b/)
  return false if product_specific && !body.match?(/\b(?:all|every|everything|standard|main|whole|complete)\b/)

  body.match?(/\b(?:what|which)\b.{0,35}\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b/) ||
    body.match?(/\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b.{0,35}\b(?:what|which|available|do you have|can you do)\b/) ||
    body.match?(/\b(?:show|list|give|send|tell)\b.{0,35}\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b/) ||
    body.match?(/\bwhat\s+(?:do|can)\s+you\s+(?:offer|sell|do|have)\b/) ||
    body.match?(/\bwhat(?:'s| is)\s+(?:available|on the menu)\b/)
end

def cheapest_overall_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if current_specials_question?(body)
  return false if postcard_interest?(body) && !sign_interest?(body)
  return false if signs_only_bundle_compare_question?(body)
  return false if body.match?(/\b(?:all|every|full|whole|complete)\b.{0,50}\b(?:options?|packages?|packs?|deals?|prices?|pricing|costs?|rates?)\b/)

  value_language = body.match?(/\b(?:cheap(?:er|est)?|least expensive|lowest(?:\s+(?:cost|price))?|low\s*price|entry(?:\s*point)?|starter\s+(?:option|path)|smallest\s+(?:option|package)|budget\s+(?:option|path)|affordable)\b/)
  return false unless value_language

  body.match?(/\b(?:option|options|choice|path|way|package|pack|product|service|thing|route|deal|price|pricing|cost|quote)\b/) ||
    body.match?(/\bwhat(?:'s| is)\s+(?:the\s+)?(?:cheap(?:er|est)?|least expensive|lowest)\b/)
end

def yard_sign_cheapest_package_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless sign_interest?(body)
  return false unless body.match?(/\b(?:cheap(?:er|est)?|least expensive|lowest(?:\s+(?:cost|price|total))?|entry(?:\s*point)?|smallest|budget)\b/)

  body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) &&
    body.match?(/\b(?:package|pack|option|deal|path|price|pricing|cost|total)\b/)
end

def yard_sign_cheapest_entry_reply(_text = nil)
  rows = yard_sign_unit_price_rows
  entry = rows.find { |row| row[:quantity].to_i == 10 } || rows.first
  quantity = entry.to_h[:quantity].presence || 10
  total = entry.to_h[:total].presence || "$99"

  [
    "The cheapest total Yard Signs option is #{format_quantity_count(quantity)} signs for #{total}.",
    "The best per-sign price improves with volume, but that 10-sign package is the real entry point.",
    "Stakes, shipping, and design are included.",
    "Want me to send the 10-sign checkout link?"
  ].join(" ")
end

def multi_product_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false unless pricing_intent?(body)

  lanes = [
    body.match?(SIGN_INTEREST_PATTERN),
    body.match?(/\b(?:business\s+cards?|cards?)\b/),
    body.match?(POSTCARD_INTEREST_PATTERN),
    body.match?(/\b(?:door\s+hangers?|hangers?)\b/)
  ]
  lanes.count(true) >= 2
end

def signs_only_options_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless signs_only_context?
  return false if explicit_bundle_family_interest?(body)
  return false if postcard_interest?(body)

  body.match?(/\b(?:what|which|other|more|list|show|give|send)\b.{0,45}\b(?:options?|choices?|quantit(?:y|ies)|tiers?|packages?|prices?|pricing|costs?)\b/) ||
    body.match?(/\b(?:what are my options?|other options?|more options?|sign options?|sign quantities|quantity options?|price tiers?)\b/)
end

def signs_only_intent?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:signs?\s*[- ]?only|only\s+(?:yard\s+|lawn\s+)?signs?|yard\s+signs?\s*[- ]?only|lawn\s+signs?\s*[- ]?only)\b/) ||
    body.match?(/\bonly\b.{0,40}\b(?:care|need|want|looking)\b.{0,25}\b(?:yard\s+|lawn\s+)?signs?\b/) ||
    body.match?(SIGN_INTEREST_PATTERN) && body.match?(/\bonly\b/)
end

def signs_only_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false unless signs_only_intent?(body)
  return false if signs_only_bundle_compare_question?(body)

  pricing_intent?(body) || body.match?(/\b(?:options?|tiers?|packages?)\b/)
end

def yard_sign_pricing_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if signs_only_pricing_question?(body)
  return true if signs_only_options_question?(body)
  return true if yard_sign_budget_question?(body)

  has_sign_context = sign_interest?(body) ||
    body.match?(/\b\d{1,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
  return false unless has_sign_context
  return true if direct_pricing_question?(body)
  return true if yard_sign_quantity_outside_deals?(body)

  requested_quantities(body).present? &&
    body.match?(/\b(?:options?|tiers?|packages?|available|listed|checkout|order|deal|special|bulk|custom|exact)\b/)
end

def signs_only_bundle_compare_question?(text)
  body = text.to_s.downcase.squish
  return false unless signs_only_intent?(body)

  body.match?(/\b(?:combo|bundle|bundles|pack|packs|starter\s*pack|pro\s*pack|both|compare|comparison|vs\.?|versus|or)\b/)
end

def starter_pro_compare_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\bstarter\s*pack\b/) && body.match?(/\bpro\s*pack\b/)

  body.match?(/\b(?:compare|comparison|versus|vs\.?|difference|what.*come|what.*include|cards?|business\s+cards?|door\s+hangers?)\b/)
end

def standard_options_pricing_reply
  starter_price = bundle_price_text("STARTER_PACK").presence || "$299"
  pro_price = bundle_price_text("PRO_PACK").presence || "$599"
  parts = [
    "Starter Pack #{starter_price} (20 yard signs, 500 business cards, 500 door hangers).",
    "Pro Pack #{pro_price} (100 signs, 1k cards, 1k door hangers).",
    compact_standard_yard_sign_pricing_sentence,
    compact_route_price_sentence("EDDM"),
    compact_route_price_sentence("NEIGHBORHOOD_BLITZ")
  ].compact_blank

  body = "Standard options: #{parts.join(' ')} Lowest total is Yard Signs at 10 for $99."
  if body.length > MAX_SMS_CHARS
    parts[2] = compact_standard_yard_sign_pricing_sentence(quantities: [10, 20, 50, 100])
    body = "Standard options: #{parts.compact_blank.join(' ')} Lowest total is Yard Signs at 10 for $99."
  end
  body
end

def signs_only_and_bundle_options_reply
  [
    compact_yard_sign_pricing_sentence,
    "The signs-only option includes stakes, shipping, and design.",
    "Combo options add cards and door hangers:",
    bundle_compare_sentence("STARTER_PACK"),
    bundle_compare_sentence("PRO_PACK"),
    "Which option feels closer?"
  ].compact_blank.join(" ").squish
end

def compact_yard_sign_pricing_sentence
  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  parts = [10, 20, 50, 100, 250, 500, 1000].filter_map do |quantity|
    options = price_options_for_quantity(table, quantity)
    price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
    price.present? ? "#{format_quantity_count(quantity)} for #{display_yard_sign_price(price)}" : nil
  end
  return if parts.blank?

  "Yard Signs package: #{parts.to_sentence}."
end

def compact_standard_yard_sign_pricing_sentence(quantities: [10, 20, 50, 100, 250, 500, 1000])
  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  parts = quantities.filter_map do |quantity|
    options = price_options_for_quantity(table, quantity)
    price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
    price.present? ? "#{format_quantity_count(quantity)} for #{display_yard_sign_price(price)}" : nil
  end
  return if parts.blank?

  "Yard Signs: #{parts.join(', ')}."
end

def compact_route_price_sentence(route)
  price = bundle_price_text(route)
  return if price.blank?

  case route.to_s
  when "EDDM"
    return "EDDM postcards: #{price} for one mail-only route, usually about 500-700 homes."
  when "NEIGHBORHOOD_BLITZ"
    return "Neighborhood Blitz: #{price} for one 500-home mail-plus-visibility push."
  end

  label = product_catalog_label(route).presence || ROUTE_LABELS[route].presence || route.to_s.tr("_", " ").titleize
  "#{label}: #{price}."
end

def bundle_price_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if signs_only_pricing_question?(body)
  return false if signs_only_context? && !explicit_bundle_family_interest?(body)
  return false unless bundle_family_interest?(body) || recent_bundle_price_context?(body)

  pricing_intent?(body) ||
    body.match?(/\b(?:tell me|real simple|simple version|break down|what comes with it|what comes in it|cost extra|included|include|business cards? with them|cards? with them)\b/) ||
    body.match?(/\bwhat\s+(?:exactly\s+)?(?:do|does|is|are|comes?|included|get|getting)\b/) ||
    body.match?(/\$\s*\d[\d,]*(?:\s*(?:vs\.?|versus|or|and|\/)\s*\$?\s*\d[\d,]*)/)
end

def general_bundle_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:neighborhood|neighbourhood|blitz|eddm|direct mail|post\s*cards?|postcards?|mailers?|mailboxes?)\b/)

  body.match?(/\b(?:any|do you have|have|what|which|show|list|offer|offers|options?)\b.{0,40}\b(?:bundles?|packs?)\b/) ||
    body.match?(/\b(?:bundles?|packs?)\b.{0,40}\b(?:any|do you have|have|what|which|show|list|offer|offers|options?)\b/) ||
    body.match?(/\A(?:any\s+)?(?:bundles?|packs?)\??\z/)
end

def general_bundle_reply
  "Yes. The fixed bundles are Starter Pack for $299 with 20 yard signs, 500 business cards, and 500 door hangers, or Pro Pack for $599 with 100 signs, 1,000 business cards, and 1,000 door hangers. Which bundle feels closer?"
end

def recent_bundle_price_context?(text)
  body = text.to_s.downcase.squish
  return false unless body.match?(/\b(they|them|those|these|both|other option|options?|pack|packs|bundle|bundles|with them|same price|included|include|cost extra)\b/) ||
    pricing_intent?(body) ||
    body.match?(/\b(?:what comes?|what do i get)\b/)
  return false if signs_only_context? && !explicit_bundle_family_interest?(body)

  recent_text = recent_sms_context
  bundle_family_interest?(recent_text) || recent_bundle_route_from_thread.present?
end

def bundle_family_interest?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if explicit_bundle_family_interest?(body)

  wants_signs = sign_interest?(body)
  wants_cards = body.match?(/\b(?:business\s+cards?|cards?)\b/)
  wants_hangers = body.match?(/\b(?:door\s+hangers?|hangers?)\b/)
  wants_signs && (wants_cards || wants_hangers) || (wants_cards && wants_hangers)
end

def explicit_bundle_family_interest?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(starter\s*pack|pro\s*pack|starter[-\s]?pack|pro[-\s]?pack|business\s+cards?|door\s+hangers?|hangers?)\b/) ||
    body.match?(/\b(?:bundle|bundles|pack|packs)\b/) && !body.match?(/\b(?:yard\s+sign|lawn\s+sign|sign)\b.{0,25}\b(?:bundle|pack)\b|\b(?:bundle|pack)\b.{0,25}\b(?:yard\s+sign|lawn\s+sign|sign)\b/)
end

def signs_only_context?
  return false if current_route_code.to_s != "LAWN_SIGNS"

  fit = campaign_fit_payload
  return false if fit[:wants_postcards] || fit[:wants_both]

  true
end

def signs_only_bundle_push?(text)
  return false unless signs_only_context?

  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:starter\s*pack|pro\s*pack|business\s+cards?|door\s+hangers?|hangers?)\b/) &&
    !body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,80}\b(?:signs only|signs-only|cleaner|separate|not.*cards|not.*hangers)\b/)
end

  def requested_quantities(text)
    body = text.to_s.downcase.squish
    numeric_body = body.gsub(/\b\d{1,3}\s*x\s*\d{1,3}\b/i, " ")
    quantities = body.scan(/\b(\d{1,6})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b/i).flatten
    if sign_interest?(body) || pricing_intent?(body) || body.match?(/\boption\b/) || route_quantity_option_question?(body)
      quantities += numeric_body.scan(/\b\d{1,5}\b/)
    end
    quantities << checkout_confirmation_quantity(body) if current_route_code.to_s == "LAWN_SIGNS"
    quantities.map { |quantity| quantity.to_i }.select { |quantity| quantity.positive? }.uniq.sort
  end

  def checkout_confirmation_quantity(text)
    body = text.to_s.downcase.squish
    return if body.blank?
    return if body.match?(/\b\d{5}(?:-\d{4})?\b/)

    patterns = [
      /\b(?:i(?:'|’)?ll|i\s+will|i\s+would|we(?:'|’)?ll|we\s+will|we\s+would)\s+(?:take|get|order|do|use|choose|go\s+with|proceed\s+with)\s+(?:the\s+)?([\d,]{2,6})(?:\s*(?:yard\s+signs?|lawn\s+signs?|signs?))?\b/i,
      /\b(?:take|get|order|do|use|choose|go\s+with|proceed\s+with)\s+(?:the\s+)?([\d,]{2,6})(?:\s*(?:yard\s+signs?|lawn\s+signs?|signs?))?\b/i,
      /\b([\d,]{2,6})(?:\s*(?:yard\s+signs?|lawn\s+signs?|signs?))?\s+(?:works|is\s+fine|sounds\s+good|please|tier)\b/i
    ]
    match = patterns.lazy.filter_map { |pattern| body.match(pattern) }.first
    return if match.blank?

    quantity = match[1].to_s.delete(",").to_i
    quantity.positive? ? quantity : nil
  end

def route_quantity_option_question?(text)
  body = text.to_s.downcase.squish
  return false unless current_route_code.to_s == "LAWN_SIGNS"
  return false unless body.match?(/\b\d{2,6}\b/)

  body.match?(/\b(?:can|could|do|does|have to|need to|order|get|choose|available|listed|option|quantity|qty|count|minimum)\b/) ||
    body.match?(/\b\d{2,6}\s*(?:or|vs\.?|versus|instead of|rather than|to)\s*\d{2,6}\b/)
end

def postcard_interest?(text)
  body = text.to_s
  (body.match?(POSTCARD_INTEREST_PATTERN) || direct_mail_household_interest?(body)) && !postcard_rejection?(body)
end

def direct_mail_household_interest?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  sign_only = body.match?(/\b(?:yard|lawn|jobsite|directional)\s+signs?\b/) &&
    !body.match?(/\b(?:mail|mailers?|mailing|post\s*cards?|postcards?|eddm|direct mail)\b/)
  return false if sign_only

  body.match?(/\b(?:mail|send|hit|reach|target|cover)\b.{0,50}\b(?:\d[\d,]*\s*)?(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b/) ||
    body.match?(/\b(?:\d[\d,]*\s*)?(?:homes?|houses?|households?|doors?|addresses?|mailboxes?)\b.{0,50}\b(?:mail|mailers?|post\s*cards?|postcards?|reach|target)\b/)
end

def postcard_rejection?(text)
  text.to_s.match?(POSTCARD_REJECTION_PATTERN)
end

def product_offer_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(what|which|kind|kinds|type|types)\b.*\b(products?|services?|offers?|options?|packages?)\b/) ||
    body.match?(/\b(products?|services?|offers?|options?|packages?)\b.*\b(what|which|kind|kinds|type|types|available)\b/) ||
    body.match?(/\bwhat do you (?:offer|sell|do)\b/)
end

def contact_context_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:who are you|who is this|who am i texting|what is this|why are you (?:texting|contacting|messaging)|why did you (?:text|contact|message)|where did you get (?:my|this) (?:number|info)|how did you get (?:my|this) (?:number|info)|i (?:forgot|forget) (?:signing|signing up|about this)|did i sign up|i don'?t remember (?:signing|this))\b/)
end

def contact_context_reply
  source = contact_context_source_sentence
  [
    "Fair question. I'm Thumper with WIZWIKI Marketing.",
    "WIZWIKI helps local businesses get attention with postcards, yard signs, door hangers, business cards, and neighborhood campaigns.",
    source,
    "You can check us out at https://example.invalid.",
    "Want the quick version of what WIZWIKI does, or should I leave it there?"
  ].compact_blank.join(" ").squish
end

def contact_context_source_sentence
  source = [
    @metadata["lead_source"],
    @metadata["source"],
    @metadata.dig("conversation_state", "source")
  ].find { |value| public_contact_source?(value) }

  if source.present?
    "This looks like a WIZWIKI local-marketing follow-up from #{source.to_s.squish}."
  else
    "I do not see the exact signup note in this thread, so I do not want to guess."
  end
end

def public_contact_source?(value)
  text = value.to_s.squish
  return false if text.blank?

  !text.match?(/\b(?:ask simulator|simulator|staged|test|internal|manual|autos|codex|dojo)\b/i)
end

def brand_explanation_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:sales pitch|not a sales pitch|no sales pitch|explain like a real person|real person|plain english|plain language)\b/) ||
    body.match?(/\bwhat\s+(?:does|do)\s+wizwiki\s+(?:do|help|help me do)\b/) ||
    body.match?(/\bhow\s+can\s+wizwiki\s+help\b/) ||
    body.match?(/\bexplain\b.*\bwizwiki\b.*\bhelp/i)
end

def brand_explanation_reply
  "WIZWIKI helps local businesses get attention in the neighborhoods they want to win with practical print campaigns: postcards, yard signs, door hangers, business cards, and bundle deals like Starter Pack or Pro Pack. The job is to pick the simplest move that gets you seen. Are you trying to reach mailboxes with postcards, get yard signs in the ground, or do both?"
end

def brand_explanation_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:account manager|contact preference|text, call, or email|sales pitch|solutions?|leverage|utilize|seamless|elevate|unlock|empower|robust)\b/)

  body.match?(/\b(?:local|neighborhood|customers|attention|get seen|get noticed)\b/) &&
    body.match?(/\b(?:postcards?|yard signs?|signs?|door hangers?|business cards?|starter pack|pro pack|print campaigns?)\b/)
end

def direct_checkout_link_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if rush_checkout_boundary_question?(body)
  return false if postcard_minimum_path_question_shape?(body)
  return false if yard_sign_cheapest_package_question?(body)
  return false if cheapest_overall_pricing_question?(body)
  return false if unit_pricing_request?(body)
  return false if signs_only_options_question?(body)
  explicit_link_request = body.match?(/\b(?:do you have|can i get|can you send|send|share|text|give me|get me|let me get|lemme(?:\s+get)?|need|want|where'?s|where is)\b.*\b(?:links?|checkout|order|buy|purchase|product page)\b/) ||
    body.match?(/\b(?:checkout|order|buy|purchase)\s+links?\b/) ||
    body.match?(/\blinks?\s+(?:for me|to order|to buy|to checkout|to check out)\b/)
  return false if body.match?(/\b(?:proof|artwork|design|logo|images?|pictures?|photos?|files?|upload|attach|send)\b/) &&
    body.match?(/\b(?:order|checkout|pay|payment|first|before|after|intake)\b/) &&
    !explicit_link_request
  return false if explicit_support_handoff_request?(body) && !explicit_link_request

  selected_yard_sign_option_request = body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:10|20|50|100|250|500|1,?000)\b.{0,35}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,35}\b(?:option|package|checkout)\b/) ||
    body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,35}\b(?:10|20|50|100|250|500|1,?000)\b.{0,35}\b(?:option|package|checkout)\b/)
  return true if selected_yard_sign_option_request
  return true if selected_bundle_checkout_request?(body)

  return true if buyer_close_signal?(body) && accepted_recent_recommendation_route.present? && !price_only_pricing_question?(body)
  return true if checkout_confirmation_quantity(body).present? && !price_only_pricing_question?(body)

  explicit_link_request ||
    body.match?(/\b(?:how|where)\s+(?:do|can|should)\s+i\s+(?:order|buy|checkout|check out|purchase)\b/) ||
    body.match?(/\bready\s+to\s+(?:order|buy|checkout|check out|purchase)\b/) ||
    (buyer_close_signal?(body) && latest_outbound_checkout_prompt_route.present?)
end

def selected_bundle_checkout_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:starter|pro)\s*(?:pack|bundle)\b/)
  return false if body.match?(/\b(?:what|how much|compare|difference|different|included|includes|comes with|options?|price|pricing|cost)\b/) &&
    !body.match?(/\b(?:send|share|text|give me|get me|let me get|i(?:'|’)?ll do|i will do|we(?:'|’)?ll do|we will do|let(?:'|’)?s do|lets do|go with|move forward|ready|checkout|order|buy|purchase)\b/)

  strong_close = body.match?(/\b(?:send|share|text|give me|get me|let me get|i(?:'|’)?ll do|i will do|we(?:'|’)?ll do|we will do|let(?:'|’)?s do|lets do|go with|use|take|choose|start|move forward with|ready for|ready to order|checkout|order|buy|purchase)\b/)
  return true if strong_close

  body.match?(/\A(?:the\s+)?(?:starter|pro)\s*(?:pack|bundle)\.?\z/) &&
    recent_sms_context.match?(/\b(?:starter\s*pack|pro\s*pack|\$299|\$599|bundle)\b/i)
end

def checkout_confusion_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.match?(/\bwhat\s+exactly\s+am\s+i\s+buying\b/)
  return false unless body.match?(/\b(?:checkout|links?|order|buying|purchase|cart|product\s+page)\b/)

  body.match?(/\b(?:confused|confusing|understand|not\s+sure|what\s+exactly|what\s+am\s+i\s+buying|what\s+is\s+this|what\s+does\s+this\s+include|why\s+this\s+link)\b/)
end

def checkout_confusion_reply(route = current_route_code)
  route = route.to_s.presence || checkout_request_route(latest_inbound_sms).presence || current_route_code.presence
  summary = route.present? ? compact_product_checkout_summary(route) : "That link is for the WIZWIKI checkout option we have been discussing."
  [
    "That link should show exactly what you are buying before you pay.",
    summary,
    "Check the package, quantity, and price on the page before you finish the order.",
    "After checkout, the artwork/proof intake goes to the checkout email, and nothing prints until you approve the proof.",
    "If the link does not match what you want, send me the package name you see."
  ].compact_blank.join(" ").squish
end

def checkout_confusion_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:checkout|link|order)\b/) &&
    body.match?(/\b(?:package|option|deal|quantity|price|what you are buying|shows?)\b/) &&
    body.match?(/\b(?:proof|intake|approve|approval|nothing prints|does not match|doesn't match|package name)\b/)
end

def direct_checkout_link_reply(text)
  return multi_product_link_reply(text) if multi_product_link_request?(text)

  route = checkout_request_route(text)
  return if route.blank?
  return sold_out_checkout_reply(route) if shopify_product_sold_out?(route)

  link = route_specific_shopify_link(route)
  return if link.blank?

  if route.to_s == "NEIGHBORHOOD_BLITZ"
    quantity = checkout_confirmation_quantity(text).presence || neighborhood_blitz_checkout_household_quantity(text) || accepted_recent_recommendation_quantity(route)
    link_label = quantity.present? ? "Here is the Neighborhood Blitz checkout link for the #{quantity}-home campaign:" : "Here is the Neighborhood Blitz checkout link:"
    [
      link_label,
      link,
      "After checkout, the intake/proof form goes to the checkout email and nothing prints until approval."
    ].compact_blank.join(" ").squish
  elsif route.to_s == "EDDM" && current_postcard_special_active? && (quantity = postcard_special_quantity_from_text(text)).present?
    price = postcard_special_price_for_quantity(quantity)
    [
      "Yes. For #{format_quantity_count(quantity)} postcards, the 4th of July postcard Block Sale is #{price}.",
      "Here is the checkout link:",
      link
    ].compact_blank.join(" ").squish
  else
    quantity = checkout_link_quantity_for(route, text)
    [
      direct_checkout_link_intro(route, quantity: quantity),
      "Here is the checkout link:",
      link
    ].compact_blank.join(" ").squish
  end
end

def checkout_request_route(text)
  body = text.to_s.downcase.squish
  return if body.blank?
  return "NEIGHBORHOOD_BLITZ" if body.match?(/\bneighbou?rhood\s+blitz\b|\bblitz\b/)
  if buyer_close_signal?(body)
    prompt_route = latest_outbound_checkout_prompt_route
    return prompt_route if prompt_route.present?

    accepted_route = accepted_recent_recommendation_route
    return accepted_route if accepted_route.present?
  end
  return "NEIGHBORHOOD_BLITZ" if combined_postcard_sign_interest?(body)
  return "STARTER_PACK" if body.match?(/\bstarter\s*(?:pack|bundle)\b/)
  return "PRO_PACK" if body.match?(/\bpro\s*(?:pack|bundle)\b/)
  return "BUSINESS_CARDS" if business_card_interest?(body)
  return "DOOR_HANGERS" if door_hanger_interest?(body)
  return "FLYERS" if flyer_interest?(body)
  return "EDDM" if direct_mail_household_interest?(body)
  return "LAWN_SIGNS" if body.match?(/\byard\s+signs?\b|\blawn\s+signs?\b|\bsigns?\b/)
  return "EDDM" if body.match?(/\beddm\b|\bpost\s*cards?\b|\bpostcards?\b|\bdirect mail\b|\bmailers?\b/)
  return "NEIGHBORHOOD_BLITZ" if body.match?(/\bneighbou?rhood\s+blitz\b|\bblitz\b|\bcombo\b|\bboth\b/)

  latest_inbound_route_code.presence || current_route_code.presence || inferred_product_route_from_fit
end

def multi_product_link_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless direct_checkout_link_request?(body)

  multi_product_link_routes(body).length >= 2
end

def combined_postcard_sign_interest?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  postcard = postcard_interest?(body) || body.match?(/\b(?:post\s*card|postcard|post\s*cards|postcards|eddm|direct mail|mailers?|mailing|homes?)\b/)
  signs = sign_interest?(body) || body.match?(/\b(?:yard\s+sign|yard\s+signs|lawn\s+sign|lawn\s+signs|jobsite\s+sign|jobsite\s+signs|directional\s+sign|directional\s+signs|signs?)\b/)
  both_word = body.match?(/\b(?:both|combo|combined|together|plus|and)\b/)
  postcard && signs && both_word
end

def multi_product_link_reply(text = latest_inbound_sms)
  items = multi_product_link_routes(text).first(3).filter_map do |route|
    link = route_specific_shopify_link(route).to_s.squish.presence
    next if link.blank?

    "#{multi_product_link_label(route)}: #{link}"
  end
  return direct_checkout_link_reply_without_multi(text) if items.length < 2

  body = ["Here are the links.", *items].join(" ")
  enforce_sms_length(strip_url_trailing_punctuation(body))
end

def multi_product_link_routes(text = latest_inbound_sms)
  body = text.to_s.downcase.squish
  return [] if body.blank?

  routes = product_link_routes_in_text(body)
  routes.concat(%w[EDDM LAWN_SIGNS]) if combined_postcard_sign_interest?(body)

  if pronoun_multi_link_request?(body)
    routes.concat(recent_product_link_routes_before_latest_inbound)
  end

  routes.uniq.select { |route| route_specific_shopify_link(route).present? }.first(multi_product_link_route_limit(body))
end

def multi_product_link_route_limit(text)
  text.to_s.downcase.match?(/\b(?:both|two)\b/) ? 2 : 3
end

def pronoun_multi_link_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:both|two|all|those|these|them)\b.{0,50}\b(?:links?|checkouts?|product pages?|pages?|options?|paths?)\b/) ||
    body.match?(/\b(?:links?|checkouts?|product pages?|pages?|options?|paths?)\b.{0,50}\b(?:both|two|all|those|these|them)\b/)
end

def recent_product_link_routes_before_latest_inbound(limit: 8)
  events = sms_thread_events
  latest = latest_inbound_sms_event.to_h
  latest_id = latest["id"].to_s
  latest_body = latest["body"].to_s.squish
  latest_at = latest["created_at"].to_s
  latest_index = events.rindex do |event|
    event = event.to_h
    next false unless event["direction"].to_s == "inbound"
    next false unless event["body"].to_s.squish == latest_body

    latest_id.present? ? event["id"].to_s == latest_id : event["created_at"].to_s == latest_at
  end
  prior_events = latest_index.present? ? events.first(latest_index) : events
  routes = []

  prior_events.last(limit).reverse_each do |event|
    product_link_routes_in_text(event.to_h["body"]).each do |route|
      routes << route unless routes.include?(route)
    end
    break if routes.length >= 3
  end

  routes
end

def product_link_routes_in_text(text)
  body = text.to_s.downcase.squish
  return [] if body.blank?

  routes = []
  routes << "BUSINESS_CARDS" if business_card_interest?(body)
  routes << "DOOR_HANGERS" if door_hanger_interest?(body)
  routes << "FLYERS" if flyer_interest?(body)
  routes << "LAWN_SIGNS" if sign_interest?(body) || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?)\b/)
  routes << "EDDM" if direct_mail_household_interest?(body) || postcard_interest?(body) || body.match?(/\b(?:eddm|direct mail|mailers?)\b/)
  routes << "STARTER_PACK" if body.match?(/\bstarter\s*(?:pack|bundle)\b/)
  routes << "PRO_PACK" if body.match?(/\bpro\s*(?:pack|bundle)\b/)
  routes << "NEIGHBORHOOD_BLITZ" if body.match?(/\bneighbou?rhood\s+blitz\b|\bblitz\b/)
  routes.uniq
end

def multi_product_link_label(route)
  case route.to_s
  when "BUSINESS_CARDS" then "Business Cards"
  when "DOOR_HANGERS" then "Door Hangers"
  when "FLYERS" then "Flyers"
  when "LAWN_SIGNS" then "Yard Signs"
  when "EDDM" then "Postcards/EDDM"
  when "STARTER_PACK" then "Starter Pack"
  when "PRO_PACK" then "Pro Pack"
  when "NEIGHBORHOOD_BLITZ" then "Neighborhood Blitz"
  else route.to_s.tr("_", " ").titleize
  end
end

def direct_checkout_link_reply_without_multi(text)
  route = checkout_request_route(text)
  return if route.blank?
  return sold_out_checkout_reply(route) if shopify_product_sold_out?(route)

  link = route_specific_shopify_link(route)
  return if link.blank?

  if route.to_s == "NEIGHBORHOOD_BLITZ"
    quantity = checkout_confirmation_quantity(text).presence || neighborhood_blitz_checkout_household_quantity(text) || accepted_recent_recommendation_quantity(route)
    link_label = quantity.present? ? "Here is the Neighborhood Blitz checkout link for the #{quantity}-home campaign:" : "Here is the Neighborhood Blitz checkout link:"
    [
      link_label,
      link,
      "After checkout, the intake/proof form goes to the checkout email and nothing prints until approval."
    ].compact_blank.join(" ").squish
  elsif route.to_s == "EDDM" && current_postcard_special_active? && (quantity = postcard_special_quantity_from_text(text)).present?
    price = postcard_special_price_for_quantity(quantity)
    [
      "Yes. For #{format_quantity_count(quantity)} postcards, the 4th of July postcard Block Sale is #{price}.",
      "Here is the checkout link:",
      link
    ].compact_blank.join(" ").squish
  else
    quantity = checkout_link_quantity_for(route, text)
    [
      direct_checkout_link_intro(route, quantity: quantity),
      "Here is the checkout link:",
      link
    ].compact_blank.join(" ").squish
  end
end

def neighborhood_blitz_checkout_household_quantity(text)
  body = text.to_s.downcase.squish
  body[/\b(\d{2,6})\s*(?:homes?|households?|doors?)\b/i, 1]
end

def multi_product_link_reply_sendable?(body)
  return false unless multi_product_link_request?(latest_inbound_sms)

  text = body.to_s.squish
  return false if text.blank? || text.length > MAX_SMS_CHARS
  return false if analysis_leak?(text) || premature_closing_reply?(text) || repeated_recent_outbound?(text)

  expected_links = multi_product_link_routes(latest_inbound_sms).first(3).filter_map { |route| route_specific_shopify_link(route).to_s.squish.presence }
  return false if expected_links.length < 2

  expected_links.all? { |link| text.include?(link) }
end

def direct_checkout_link_intro(route, quantity: nil)
  case route.to_s
  when "STARTER_PACK"
    "Starter Pack is the smaller package: $299 for 20 yard signs, 500 business cards, and 500 door hangers."
  when "PRO_PACK"
    "Pro Pack is the bigger package: $599 for 100 signs, 1,000 business cards, and 1,000 door hangers."
  when "BUSINESS_CARDS"
    "Business Cards have a standalone checkout with premium matte quantity options."
  when "DOOR_HANGERS"
    "Door Hangers have a standalone 4.25x11 checkout with quantity and finish options."
  when "FLYERS"
    "Flyers have a standalone checkout with size and quantity options."
  when "LAWN_SIGNS"
    return yard_sign_checkout_intro(quantity) if quantity.present?

    "The Yard Signs package is the signs-only deal."
  when "EDDM"
    "EDDM is the postcard mailing path."
  when "NEIGHBORHOOD_BLITZ"
    "Neighborhood Blitz is the package for mail plus local visibility."
  else
    "Sounds good."
  end
end

def checkout_link_quantity_for(route, text)
  route = route.to_s
  return unless route.present?

  quantity = checkout_confirmation_quantity(text).presence || accepted_recent_recommendation_quantity(route)
  if quantity.blank? && route == "LAWN_SIGNS"
    quantity = numeric_quantity_value(campaign_fit_payload[:quantity_count])
  elsif quantity.blank? && %w[EDDM NEIGHBORHOOD_BLITZ].include?(route)
    quantity = numeric_household_value(campaign_fit_payload[:household_count])
  end
  quantity.to_s.presence
end

def yard_sign_checkout_intro(quantity)
  count = numeric_quantity_value(quantity)
  return "The Yard Signs package is the signs-only deal." if count.blank?

  details = product_details_for_route("LAWN_SIGNS").to_h
  table = details[:price_table].to_h
  options = price_options_for_quantity(table, count)
  price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
  inclusion = yard_sign_inclusion_sentence(details).presence || "Stakes, shipping, and design are included."
  if price.present?
    "For #{format_quantity_count(count)} signs, the price is #{display_yard_sign_price(price)}. #{inclusion}"
  else
    "For #{format_quantity_count(count)} signs, use the Yard Signs package link and choose the closest listed checkout option."
  end
end

def product_contents_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\bwhat(?:'s| is)?\s+(?:included|inside|in them|in those)\b/) ||
    body.match?(/\bwhat\s+comes?\s+with\s+(?:them|those|it|that|the\s+pack|the\s+bundle)\b/) ||
    body.match?(/\bhow many\s+(?:signs?|cards?|door hangers?|hangers?)\b/)
end

def product_contents_reply
  "Starter Pack includes 20 yard signs, 500 business cards, and 500 door hangers. Pro Pack includes 100 yard signs, 1,000 business cards, and 1,000 door hangers. If you only need signs, the Yard Signs package is separate. Which direction fits best?"
end

def eddm_route_process_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:mailing route|mail route|select(?:ing)? a route|pick(?:ing)? a route|choose a route|homes on the route|sent to the homes|postcards? are sent|around jobs?|around job sites?)\b/)

  body.match?(/\b(?:post\s*cards?|postcards?|mail|mailer|mailing|eddm|route|homes?|addresses?)\b/)
end

def eddm_neighborhood_blitz_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:same|different|difference|versus|vs\.?|compare|like|better|best|recommend|which|should i|right fit)\b/)
  return false unless body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b/)

  body.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/) ||
    recent_sms_context.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/i)
end

def eddm_neighborhood_blitz_reply
  first = customer_first_name
  opening = first.present? ? "#{first}, they overlap, but they are not exactly the same." : "They overlap, but they are not exactly the same."
  eddm_price = bundle_price_text("EDDM").presence || "$399"
  blitz_price = bundle_price_text("NEIGHBORHOOD_BLITZ").presence || "$699"
  [
    opening,
    "EDDM is the postcard mailing piece: #{eddm_price} for one mail-only route, usually about 500-700 homes.",
    "Neighborhood Blitz is the fuller local push with postcards plus extra visibility pieces like the Yard Signs package or job-area materials; the listed package is #{blitz_price}.",
    "If you only want mailboxes, EDDM is cleaner; if you want mail plus visibility, Neighborhood Blitz is stronger."
  ].join(" ").squish
end

def eddm_neighborhood_blitz_answer?(text)
  body = text.to_s.squish
  return false if body.blank?

  body.match?(/\beddm\b/i) &&
    body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b/i) &&
    body.match?(/\b(?:overlap|not exactly the same|not the same|different|mailing piece|fuller local push|fuller campaign)\b/i)
end

def neighborhood_blitz_contents_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b|\bmain course\b/)
  return true if body.match?(/\b(?:do|does|would|will|can|could|so)\b.*\b(?:get|include|come with|comes with|have|with)\b.*\b(?:yard signs?|lawn signs?|signs?|other products?|products?|door hangers?|cards?|postcards?)\b/)
  return true if body.match?(/\b(?:yard signs?|lawn signs?|signs?|other products?|products?|door hangers?|cards?|postcards?)\b.*\b(?:included|come with|comes with|part of|with it|in it)\b/)

  false
end

def neighborhood_blitz_contents_reply
  "Neighborhood Blitz is the broader combined push, not the signs-only path. It can include postcards plus field visibility pieces like the Yard Signs package, door hangers, rack cards, or job-area materials. If you only want signs, Yard Signs is cleaner; if you want mail plus visibility, Neighborhood Blitz fits better."
end

def neighborhood_blitz_best_deal_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if standard_lane_compare_question?(body)
  return false unless combined_postcard_sign_interest?(body)

  body.match?(/\b(?:best|right|good|better|recommend|deal|package|bundle|option|fit)\b/) ||
    body.match?(/\b(?:targeting|reach|mail|homes?|doors?|neighborhoods?)\b/)
end

def standard_lane_compare_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:compare|comparing|deciding|looking at|looking between|not sure)\b/)

  lanes = [
    body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/),
    body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/),
    body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle|business\s+cards?|door\s+hangers?)\b/)
  ]
  lanes.count(true) >= 2
end

def standard_lane_compare_reply
  "Those are different lanes. Yard Signs is the lowest entry point at 10 for $99, EDDM postcards start at $399 for one mail-only route, and Starter Pack is $299 with 20 signs, 500 business cards, and 500 door hangers. If you want everything side by side, I can list the full menu."
end

def yard_sign_route_context_message?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless current_route_code.to_s == "LAWN_SIGNS" || signs_only_context?
  return false if postcard_interest?(body)
  return false if print_product_terms_present?(body)
  return false if print_products_question?(body) || messy_print_consultant_question?(body)
  return false if full_options_pricing_question?(body) || standard_lane_compare_question?(body)
  return false if pricing_question?(body) || unit_pricing_request?(body)
  return false if direct_checkout_link_request?(body)

  body.match?(/\b(?:business|company|crew|shop|job|jobs|missed|busy|sorry|plumbing|roofing|hvac|landscap|tree|pest|service)\b/)
end

def yard_sign_route_context_reply(text = nil)
  business = text.to_s.match(/\b(plumbing|roofing|hvac|landscap(?:ing)?|tree service|pest control)\b/i)&.[](1).to_s.downcase
  opener = business.present? ? "For a #{business} business, yard signs around active jobs are a clean starting point." : "Yard signs are a clean starting point for local visibility."
  "No worries. #{opener} If you want the lowest entry point, Yard Signs start at 10 for $99. What quantity feels closest?"
end

def neighborhood_blitz_best_deal_reply
  price = bundle_price_text("NEIGHBORHOOD_BLITZ").presence
  price_text = price.present? ? " at #{price}" : ""
  [
    "For postcards plus yard signs, the Neighborhood Blitz package is the best-fit combined path#{price_text}.",
    "It is built for a local push with postcards plus field visibility pieces like signs, door hangers, rack cards, or job-area materials.",
    "Do you want the combined blitz, or signs-only?"
  ].join(" ").squish
end

def neighborhood_blitz_best_deal_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\bneighborhood blitz\b/) &&
    body.match?(/\b(?:combined|best-fit|best fit|package|path|local push)\b/) &&
    body.match?(/\b(?:postcards?|eddm|mail)\b/) &&
    body.match?(/\b(?:yard signs?|signs?|field visibility)\b/)
end

def neighborhood_blitz_contents_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || question_only_sms?(body)
  return false if body.length < 180

  body.match?(/\b(?:yes|combined|fuller|broader|campaign|push|neighborhood blitz)\b/) &&
    body.match?(/\b(?:yard signs?|yard signs package|signs?)\b/) &&
    body.match?(/\b(?:postcards?|door hangers?|rack cards?|products?|job-area|visibility)\b/) &&
    body.match?(/\b(?:signs-only|signs only|only want signs|yard signs is the signs-only|yard signs package is the signs-only)\b/)
end

def clarification_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:i\s+)?(?:don'?t|do not)\s+(?:understand|get it|get|follow|see)\b/) ||
    body.match?(/\b(?:i'?m|i am)\s+(?:confused|lost|not following)\b/) ||
    body.match?(/\b(?:confused|not following|lost me|you lost me)\b/) ||
    body.match?(/\b(?:what do you mean|what does that mean|what is that supposed to mean)\b/) ||
    body.match?(/\b(?:can you explain|could you explain|explain that|explain it|break that down|say that simpler|make that simpler)\b/) ||
    body.match?(/\b(?:what'?s|what is)\s+the\s+difference\b/) ||
    body.match?(/\b(?:same thing|same as|how is that different)\b/)
end

def clarification_answer_for_inbound?(text, inbound)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if question_only_sms?(body)
  context = [inbound, recent_sms_context].compact.join(" ").downcase
  if context.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b/) &&
      context.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/)
    return eddm_neighborhood_blitz_answer?(body)
  end
  return true if eddm_neighborhood_blitz_answer?(body)
  return true if design_process_answer?(body)
  return true if artwork_creation_help_answer?(body)

  body.match?(/\b(?:means|basically|plain terms|difference|different|not the same|works|process|includes?|comes with|mailing|carrier route|route|proof|approval|intake|checkout|yard signs?|starter pack|pro pack|eddm|postcards?|neighborhood blitz)\b/)
end

def question_only_sms?(text)
  body = text.to_s.squish
  return false if body.blank?

  sentences = body.split(/(?<=[.!?])\s+/).map(&:squish).reject(&:blank?)
  return false if sentences.blank?
  return true if sentences.all? { |sentence| sentence.end_with?("?") }

  body.match?(/\A(?:would|do|does|can|could|should|are|is|what|which|how|why|want)\b.*\?\z/i) &&
    !body.match?(/\b(?:means|basically|difference|different|works|includes?|comes with|mailing|proof|approval|intake|checkout)\b/i)
end

def clarification_reply_for_context(inbound)
  route = current_route_code
  context = [inbound, recent_sms_context, route].compact.join(" ").downcase

  return neighborhood_blitz_contents_reply if neighborhood_blitz_contents_question?(inbound)

  if eddm_neighborhood_blitz_question?(inbound) ||
      (context.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b/) &&
        context.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/))
    return eddm_neighborhood_blitz_reply
  end

  return design_process_reply(route) if design_process_question?(context) || artwork_creation_followup_request?(context)

  if product_contents_question?(context) || context.match?(/\b(?:starter\s*pack|pro\s*pack|pack|bundle)\b/)
    pricing = pricing_reply(context)
    return pricing if pricing.present? && pricing.length <= MAX_SMS_CHARS

    return "Starter Pack is the smaller fixed bundle: 20 yard signs, 500 business cards, and 500 door hangers. Pro Pack is the bigger fixed bundle: 100 signs, 1,000 cards, and 1,000 door hangers. Which one fits your first run better?"
  end

  return eddm_route_process_reply if context.match?(/\b(?:eddm|carrier route|mailing route|post\s*cards?|postcards?|mailers?|mailing)\b/)

  reply = case route.to_s
  when "LAWN_SIGNS"
    "The Yard Signs package is the signs-only deal. Starter Pack and Pro Pack are bundles that add business cards and door hangers too. If you only need signs, stay with Yard Signs; if you want the full local push, compare Starter or Pro Pack."
  when "STARTER_PACK"
    "Starter Pack is the smaller fixed bundle for a first local push: yard signs, business cards, and door hangers together. If you need more volume than that deal includes, Pro Pack or larger-volume help is the better path."
  when "PRO_PACK"
    "Pro Pack is the larger fixed bundle: more signs, business cards, and door hangers for a bigger push. A custom count outside that deal needs a custom check so pricing stays accurate."
  when "EDDM"
    "EDDM means postcards mailed by USPS route, so you choose an area and the mailers go to homes there. It is best when mailbox reach is the main goal."
  when "NEIGHBORHOOD_BLITZ"
    "Neighborhood Blitz is the fuller local push: postcards plus visibility pieces like the Yard Signs package or job-area materials. If you only want signs, the Yard Signs package is the signs-only path. EDDM is only the postcard mailing part."
  else
    "I moved too fast there. The main options are EDDM for postcard mailing, Yard Signs for signs only, and Starter/Pro Pack when you want signs, cards, and door hangers together. Which part should I explain first?"
  end

  trim_sms_at_boundary(reply)
end

def recent_sms_context
  sms_thread_events.last(8).filter_map { |event| event.to_h["body"].to_s.squish.presence }.join(" ")
end

def full_recent_sms_context
  events = sms_thread_events + Array(@stage&.metadata.to_h["sms_thread"]).map(&:to_h).select { |event| sms_event_after_reset?(event) }
  events
    .uniq { |event| event["id"].presence || [event["created_at"], event["direction"], event["body"]] }
    .sort_by.with_index { |event, index| [sms_event_time(event) || Time.zone.at(0), index] }
    .last(12)
    .filter_map { |event| event.to_h["body"].to_s.squish.presence }
    .join(" ")
end

def eddm_route_process_reply
  first = customer_first_name
  opener = if last_outbound_route_code_token?
    first.present? ? "#{first}, sorry, that last text was an internal label." : "Sorry, that last text was an internal label."
  else
    first.present? ? "#{first}, that is the idea." : "That is the idea."
  end
  [
    opener,
    "With EDDM, you choose the carrier route or area around the jobs you want to target, and postcards go to homes on that route.",
    "About how many homes would you want around each job?"
  ].join(" ").squish
end

def last_outbound_route_code_token?
  Array(@metadata["sms_thread"]).reverse_each do |event|
    next unless event.to_h["direction"].to_s == "outbound"

    return internal_route_code_token?(event.to_h["body"])
  end

  false
end

def internal_route_code_token?(text)
  body = text.to_s.squish.downcase
  body.match?(/\A(?:starter_pack|pro_pack|lawn_signs|eddm|neighborhood_blitz|custom_artwork)\z/) ||
    body.match?(/\A[a-z0-9]+(?:_[a-z0-9]+)+\z/)
end

def yard_sign_pricing_reply(text)
  details = product_details_for_route("LAWN_SIGNS").to_h
  table = details[:price_table].to_h
  return if table.blank?

  special_reply = yard_sign_specials_reply(text, details: details, table: table)
  return special_reply if special_reply.present?

  cheapest_reply = cheapest_yard_sign_option_reply(text, details: details, table: table)
  return cheapest_reply if cheapest_reply.present?

  budget_reply = yard_sign_budget_reply(text, details: details, table: table)
  return budget_reply if budget_reply.present?

  quantities = requested_quantities(text)
  current_quantity = numeric_quantity_value(campaign_fit_payload[:quantity_count])
  quantities << current_quantity if quantities.blank? && current_quantity.present?
  quantities = quantities.first(4)
  sentences = if quantities.present?
    quantities.map { |quantity| yard_sign_quantity_sentence(quantity, table) }.compact
  else
    default_yard_sign_price_sentences(table)
  end
  return if sentences.blank?

  body = sentences.join(" ")
  inclusion = yard_sign_inclusion_sentence(details)
  body = [body, inclusion].compact_blank.join(" ")
  body = [body, "Different front/back designs add $125."].compact_blank.join(" ") if yard_sign_front_back_addon?(table) && !body.include?("front/back")
  follow_up = yard_sign_pricing_follow_up(text)
  body = [body, follow_up].compact_blank.join(" ") if follow_up.present? && body.length + follow_up.length + 1 <= MAX_SMS_CHARS
  body
end

def yard_sign_pricing_follow_up(text)
  return if shopify_link_already_sent?("LAWN_SIGNS")

  if link_fit_ready?("LAWN_SIGNS")
    if requested_quantities(text).present? && !direct_checkout_link_request?(text)
      return "Want the checkout link for that Yard Signs option?"
    end

    return checkout_sentence("LAWN_SIGNS")
  end

  next_route_fit_question("LAWN_SIGNS") ||
    business_context_question("LAWN_SIGNS") ||
    (requested_quantities(text).present? ? "Want the checkout link for that Yard Signs option?" : "Which count feels closest?")
end

def direct_pricing_question?(text)
  pricing_intent?(text)
end

def yard_sign_specials_reply(text, details:, table:)
  body = text.to_s.downcase.squish
  return unless body.match?(/\b(?:specials?|coupon|discounts?|price break)\b/) ||
    body.match?(/\bpromos?\b/) && body.match?(/\b(?:any|current|active|running|available|got|have|show|list|give|send|tell|deal|special|discount|coupon)\b/)

  quantity = yard_sign_pricing_quantity_for(text)
  inclusion = yard_sign_inclusion_sentence(details)
  entry = lowest_yard_sign_deal_option(table)
  entry_sentence = entry.present? ? "The lowest listed Yard Signs deal is #{entry[:quantity]} signs for #{entry[:price]} #{entry[:label]}." : nil
  if quantity.present?
    options = price_options_for_quantity(table, quantity)
    if options.present?
      sentence = yard_sign_default_price_sentence(quantity, options)
      return ["I do not see a separate yard-sign special listed right now; the listed Yard Signs deal is the price I can stand behind.", entry_sentence, quantity == entry&.dig(:quantity) ? nil : sentence, inclusion, "Do you want the lowest entry point, or the #{quantity}-sign option?"].compact_blank.join(" ")
    end
  end

  price_sentence = default_yard_sign_price_sentences(table).first
  ["I do not see a separate yard-sign special listed right now; Yard Signs are priced by quantity.", entry_sentence || price_sentence, inclusion].compact_blank.join(" ")
end

def cheapest_yard_sign_option_reply(text, details:, table:)
  body = text.to_s.downcase.squish
  return unless body.match?(/\b(?:cheap(?:er|est)?|expensive|less expensive|lowest|lower|affordable)\b/)

  quantity = yard_sign_pricing_quantity_for(text)
  inclusion = yard_sign_inclusion_sentence(details)
  entry = lowest_yard_sign_deal_option(table)
  return if entry.blank?

  if quantity.present?
    options = price_options_for_quantity(table, quantity)
    if options.present?
      current = default_yard_sign_option_for_quantity(quantity, options)
      pieces = []
      pieces << "The best price per sign comes with volume, but the cheapest total Yard Signs option is #{entry[:quantity]} signs for #{entry[:price]} #{entry[:label]}."
      if quantity != entry[:quantity] && current.present?
        pieces << "If you still want #{quantity}, listed #{current[:label]} is #{current[:price]}."
      end
      pieces << inclusion
      pieces << (quantity == entry[:quantity] ? "Do you want to start there?" : "Want the $99 entry point, or are you still pricing #{quantity} signs?")
      return pieces.compact_blank.join(" ")
    end
  end

  ["The best price per sign comes with volume, but the cheapest total Yard Signs option is #{entry[:quantity]} signs for #{entry[:price]} #{entry[:label]}.", inclusion, "Do you want to start there?"].compact_blank.join(" ")
end

def cheapest_overall_pricing_reply(text = nil)
  details = product_details_for_route("LAWN_SIGNS").to_h
  table = details[:price_table].to_h
  entry = lowest_yard_sign_deal_option(table)
  return missing_pricing_handoff_reply if entry.blank?

  first = "Cheapest overall is the yard-sign entry point: #{entry[:quantity]} signs for #{entry[:price]}."
  inclusion = yard_sign_inclusion_sentence(details)
  industry_sentence = cheapest_overall_industry_sentence
  [first, inclusion, industry_sentence, "Want to start there?"].compact_blank.join(" ")
end

def cheapest_overall_industry_sentence
  context = [industry_value, latest_inbound_sms, recent_sms_context].compact.join(" ").downcase
  case context
  when /\bplumbing|plumber\b/
    "For plumbing, that is usually a simple first test around active job sites."
  when /\broof(?:ing|er|ers)?\b/
    "For roofing, that is usually a simple first test around completed jobs or active neighborhoods."
  when /\bhvac|heating|cooling|air conditioning\b/
    "For HVAC, that is usually a simple first test around service areas and active jobs."
  else
    "That is usually the simplest first test before jumping into mail."
  end
end

def yard_sign_pricing_quantity_for(text)
  quantities = requested_quantities(text)
  current_quantity = numeric_quantity_value(campaign_fit_payload[:quantity_count])
  quantities << current_quantity if quantities.blank? && current_quantity.present?
  quantities.compact.map(&:to_i).select(&:positive?).max
end

def lowest_yard_sign_option_for_quantity(options)
  candidates = {
    "single-sided" => options["single_sided_included"].presence || options["single_sided"].presence,
    "double-sided" => options["double_sided_included"].presence || options["double_sided"].presence,
    "different front/back" => options["different_front_back_included"].presence || options["different_front_back"].presence,
    "listed" => options["price"].presence
  }.filter_map do |label, price|
    amount = numeric_budget_value(price)
    next if amount.blank?

    { label: label, price: display_yard_sign_price(price), amount: amount }
  end

  candidates.min_by { |candidate| candidate[:amount] }
end

def default_yard_sign_option_for_quantity(quantity, options)
  price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
  amount = numeric_budget_value(price)
  return if amount.blank?

  { quantity: quantity.to_i, label: "double-sided", price: display_yard_sign_price(price), amount: amount }
end

def yard_sign_default_price_sentence(quantity, options)
  option = default_yard_sign_option_for_quantity(quantity, options)
  return if option.blank?

  "#{quantity} signs are #{option[:price]} #{option[:label]}."
end

def lowest_yard_sign_deal_option(table)
  table.to_h.filter_map do |quantity, options|
    option = default_yard_sign_option_for_quantity(quantity, options.to_h)
    next if option.blank?

    option
  end.select { |option| option[:quantity].positive? }.min_by { |option| [option[:amount], option[:quantity]] }
end

def lower_yard_sign_tier_sentence(quantity, table)
  lower = table.keys.map(&:to_i).select { |candidate| candidate.positive? && candidate < quantity.to_i }.max
  return if lower.blank?

  options = price_options_for_quantity(table, lower)
  low = lowest_yard_sign_option_for_quantity(options)
  return if low.blank?

  "A smaller listed tier is #{lower} signs at #{low[:price]} #{low[:label]}."
end

def yard_sign_budget_reply(text, details:, table:)
  budget = explicit_budget_value(text) || numeric_budget_value(extract_budget_signal(text))
  return if budget.blank?
  return if requested_quantities(text).present? && !text.to_s.match?(/\$|dollars?|dolla(?:rs?)?|bucks?|\bfor\s+\d/i)

  quantity = yard_sign_quantity_for_budget(budget, table)
  return if quantity.blank?

  budget_label = format_budget_amount(budget)
  price_options = price_options_for_quantity(table, quantity)
  price = price_options["double_sided_included"].presence || price_options["double_sided"].presence || price_options["price"].presence
  count_phrase = quantity == 10 && budget.to_i.between?(90, 125) ? "about 10 yard signs" : "#{quantity} yard signs"
  first = if count_phrase.start_with?("about ")
    "#{budget_label} gets you #{count_phrase}."
  elsif price.present? && budget.to_i >= numeric_budget_value(price).to_i
    "#{budget_label} can cover #{count_phrase}."
  else
    "#{budget_label} puts you around #{count_phrase}."
  end

  inclusion = yard_sign_inclusion_sentence(details)
  next_step = current_route_code.to_s == "LAWN_SIGNS" || sign_interest?(text) ? "Do you want to keep this signs-only?" : "Are signs the product you want to price first?"
  [first, "The Yard Signs package is the best fit at that entry point.", inclusion, next_step].compact_blank.join(" ")
end

def yard_sign_quantity_for_budget(budget, table)
  amount = budget.to_f
  return 10 if amount.between?(90, 125) && price_options_for_quantity(table, 10).present?

  priced_quantities = table.to_h.filter_map do |quantity, options|
    price = options.to_h["double_sided_included"].presence || options.to_h["double_sided"].presence || options.to_h["price"].presence
    numeric_price = numeric_budget_value(price)
    next if numeric_price.blank?

    [quantity.to_i, numeric_price]
  end.select { |quantity, price| quantity.positive? && price.positive? }

  affordable = priced_quantities.select { |_quantity, price| price <= amount * 1.05 }.max_by { |quantity, _price| quantity }
  return affordable.first if affordable.present?

  priced_quantities.min_by { |_quantity, price| (price - amount).abs }&.first
end

def yard_sign_quantity_sentence(quantity, table)
  options = price_options_for_quantity(table, quantity)
  if options.present?
    exact_yard_sign_price_sentence(quantity, options)
  else
    nearest_yard_sign_price_sentence(quantity, table)
  end
end

def exact_yard_sign_price_sentence(quantity, options)
  single = options["single_sided_included"].presence || options["single_sided"].presence
  double = options["double_sided_included"].presence || options["double_sided"].presence
  front_back = options["different_front_back_included"].presence || options["different_front_back"].presence
  default = options["price"].presence

  if double.present?
    "#{quantity} signs are #{display_yard_sign_price(double)} double-sided."
  elsif single.present?
    "#{quantity} signs are #{display_yard_sign_price(single)} single-sided."
  elsif default.present?
    "#{quantity} signs are #{display_yard_sign_price(default)}."
  elsif front_back.present?
    "#{quantity} signs with different front/back designs are #{display_yard_sign_price(front_back)}."
  end
end

def nearest_yard_sign_price_sentence(quantity, table)
  available = table.keys.map(&:to_i).sort
  return if available.blank?

  lower = available.select { |candidate| candidate < quantity }.max
  higher = available.select { |candidate| candidate > quantity }.min
  nearest = [lower, higher].compact
  return "I do not see a #{quantity}-sign checkout option listed." if nearest.blank?

  parts = nearest.map do |candidate|
    options = price_options_for_quantity(table, candidate)
    price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
    price.present? ? "#{candidate} at #{display_yard_sign_price(price)}" : nil
  end.compact
  return "I do not see a #{quantity}-sign checkout option listed." if parts.blank?

  "I do not see a #{quantity}-sign checkout option listed; closest listed quantities are #{parts.to_sentence}. If exactly #{quantity} is the right count, that needs a custom check so pricing stays accurate."
end

def price_options_for_quantity(table, quantity)
  table[quantity.to_i].presence || table[quantity.to_s].presence || {}
end

def unit_pricing_guide_payload
  {
    policy: [
      "Quote package totals by default.",
      "Use per-unit math only when the customer explicitly asks each/per unit/per sign or is bantering about one or two pieces.",
      "Do not imply one or two pieces are available when the listed package minimum is higher.",
      "For bundles, per-unit math is blended shorthand only; the fixed bundle includes multiple item types."
    ],
    lanes: {
      yard_signs: {
        unit: "sign",
        minimum_checkout_quantity: yard_sign_unit_price_rows.first&.dig(:quantity),
        tiers: yard_sign_unit_price_rows
      },
      starter_pack: fixed_bundle_unit_payload("STARTER_PACK"),
      pro_pack: fixed_bundle_unit_payload("PRO_PACK"),
      eddm: route_unit_payload("EDDM", unit: "home", planning_quantity: "500-700 homes"),
      neighborhood_blitz: route_unit_payload("NEIGHBORHOOD_BLITZ", unit: "home", planning_quantity: "500 homes")
    }.compact_blank
  }.compact_blank
end

def yard_sign_unit_price_rows
  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  [10, 20, 50, 100, 250, 500, 1000].filter_map do |quantity|
    option = default_yard_sign_option_for_quantity(quantity, price_options_for_quantity(table, quantity))
    next if option.blank?

    {
      quantity: quantity,
      total: option[:price],
      per_unit: unit_price_text(option[:amount], quantity),
      label: option[:label]
    }
  end
end

def fixed_bundle_unit_payload(route)
  price = bundle_price_text(route)
  amount = numeric_budget_value(price)
  contents = fixed_bundle_contents(route)
  sign_count = contents[:yard_signs].to_i
  label = ROUTE_LABELS[route.to_s].presence || route.to_s.tr("_", " ").titleize

  {
    label: label,
    total: price,
    contents: contents,
    blended_sign_reference: amount.present? && sign_count.positive? ? unit_price_text(amount, sign_count) : nil,
    customer_safe_note: "#{label} is a fixed bundle, so the sign-count math is only shorthand; the cards and door hangers are part of the value too."
  }.compact_blank
end

def fixed_bundle_contents(route)
  catalog_contents = product_catalog_contents(route)
  return catalog_contents if catalog_contents.present?

  case route.to_s
  when "STARTER_PACK"
    { yard_signs: 20, business_cards: 500, door_hangers: 500 }
  when "PRO_PACK"
    { yard_signs: 100, business_cards: 1000, door_hangers: 1000 }
  else
    {}
  end
end

def product_catalog_contents(route)
  return {} unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.contents(route)
rescue StandardError
  {}
end

def route_unit_payload(route, unit:, planning_quantity:)
  price = bundle_price_text(route)
  amount = numeric_budget_value(price)
  catalog_planning_quantity = product_catalog_planning_quantity(route)
  planning_quantity = catalog_planning_quantity if catalog_planning_quantity.present?
  quantities = planning_quantity.to_s.scan(/\d[\d,]*/).map { |value| value.delete(",").to_i }.select(&:positive?)
  label = product_catalog_label(route).presence || ROUTE_LABELS[route.to_s].presence || route.to_s.tr("_", " ").titleize

  {
    label: label,
    total: price,
    planning_quantity: planning_quantity,
    per_unit_reference: amount.present? && quantities.present? ? unit_price_range_text(amount, quantities) : nil,
    unit: unit
  }.compact_blank
end

def product_catalog_planning_quantity(route)
  return unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.planning_quantity(route)
rescue StandardError
  nil
end

def unit_price_range_text(total_amount, quantities)
  values = Array(quantities).map(&:to_i).select(&:positive?)
  return if values.blank?
  return unit_price_text(total_amount, values.first) if values.length == 1

  low = unit_price_text(total_amount, values.max)
  high = unit_price_text(total_amount, values.min)
  return low if low == high

  "#{low}-#{high}"
end

def unit_price_text(total_amount, quantity)
  amount = total_amount.to_f
  count = quantity.to_i
  return if amount <= 0 || count <= 0

  format_budget_amount((amount / count).round(2))
end

def unit_pricing_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless unit_pricing_allowed_language?(body) || one_or_two_unit_banter?(body)

  sign_interest?(body) ||
    bundle_pack_interest?(body) ||
    postcard_interest?(body) ||
    body.match?(/\b(?:eddm|neighborhood blitz|starter pack|pro pack|door hangers?|business cards?|cards?|hangers?)\b/) ||
    current_route_code.present?
end

def unit_pricing_allowed_language?(body)
  body.match?(/\b(?:each|apiece|a piece|per\s+(?:unit|piece|sign|card|hanger|home|house|door|postcard)|price\s+per|unit\s+price|what(?:'s| is)?\s+(?:one|each one)\s+worth|how much\s+(?:is|are)\s+(?:one|1|each|a|single))\b/i) ||
    body.match?(/\b(?:how\s+much\s+(?:(?:is|are|does|would|will)\s+)?(?:one|1|a|single)\s+(?:yard\s+|lawn\s+)?(?:sign|card|hanger|postcard|piece|unit)s?\s*(?:cost|run|work\s+out(?:\s+to)?)?|what(?:'s| is| does| would)?\s+(?:one|1|a|single)\s+(?:yard\s+|lawn\s+)?(?:sign|card|hanger|postcard|piece|unit)s?\s*(?:cost|run|work\s+out(?:\s+to)?)?)\b/i) ||
    body.match?(/\b(?:one|1|a|single)\s+(?:yard\s+|lawn\s+)?(?:sign|card|hanger|postcard|piece|unit)s?\b.{0,40}\b(?:work\s+out|cost|run|each|apiece|per)\b/i) ||
    body.match?(/\b(?:cost|price|pricing|rate|quote|charge)\s+(?:for|on|of)\s+(?:one|1|a|single)\s+(?:yard\s+|lawn\s+)?(?:sign|card|hanger|postcard|piece|unit)s?\b/i)
end

def postcard_unit_pricing_context?(body)
  text = body.to_s.downcase.squish
  return false if text.blank?
  return true if postcard_interest?(text)
  return false if sign_interest?(text)
  return false if text.match?(/\b(?:business\s+cards?|starter\s*pack|pro\s*pack|bundle|door\s+hangers?|hangers?)\b/)
  return false unless text.match?(/\b(?:cards?|pieces?|units?)\b/)

  current_route_code.to_s == "EDDM" || recent_sms_context.match?(POSTCARD_INTEREST_PATTERN)
end

def one_or_two_unit_banter?(body)
  body.match?(/\b(?:just|only)?\s*(?:1|one)\s*(?:or|\/|,|and)\s*(?:2|two)\s*(?:yard\s+signs?|lawn\s+signs?|signs?|business\s+cards?|cards?|door\s+hangers?|hangers?|postcards?|pieces?|units?)\b/i) ||
    body.match?(/\b(?:just|only)\s*(?:1|one|2|two)\s*(?:yard\s+signs?|lawn\s+signs?|signs?|business\s+cards?|cards?|door\s+hangers?|hangers?|postcards?|pieces?|units?)\b/i)
end

def bundle_pack_interest?(text)
  body = text.to_s.downcase.squish
  body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle|pack|cards?|door\s*hangers?|hangers?)\b/)
end

def unit_pricing_reply(text)
  body = text.to_s.downcase.squish
  if sign_interest?(body) || current_route_code.to_s == "LAWN_SIGNS" || body.match?(/\b(?:1|one|2|two)\s*(?:or|\/|and)?\s*(?:2|two)?\s*(?:signs?|yard signs?)\b/i)
    return yard_sign_unit_pricing_reply(body)
  end

  if postcard_unit_pricing_context?(body) || body.match?(/\b(?:eddm|mail|post\s*cards?|postcards?)\b/i)
    return route_unit_pricing_reply("EDDM")
  end

  if body.match?(/\bneighborhood\s+blitz\b/i)
    return route_unit_pricing_reply("NEIGHBORHOOD_BLITZ")
  end

  if body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle|pack|cards?|door\s*hangers?|hangers?)\b/)
    return bundle_unit_pricing_reply(body)
  end

  yard_sign_unit_pricing_reply(body)
end

def yard_sign_unit_pricing_reply(_text = nil)
  rows = yard_sign_unit_price_rows
  entry = rows.first
  return if entry.blank?

  pieces = [
    "The listed Yard Signs minimum is #{entry[:quantity]} signs for #{entry[:total]}, which works out to #{entry[:per_unit]} per sign.",
    "There is not a one-sign checkout; the order minimum starts at that 10-sign option, so that is the real entry point."
  ]
  next_row = rows.find { |row| row[:quantity].to_i == 20 }
  pieces << "For comparison, 20 signs are #{next_row[:total]} or #{next_row[:per_unit]} each." if next_row.present?
  pieces << "Do you want the lowest 10-sign entry point, or are you thinking bigger?"
  pieces.join(" ")
end

def bundle_unit_pricing_reply(text)
  route = text.match?(/\bpro\s*pack\b/i) ? "PRO_PACK" : (text.match?(/\bstarter\s*pack\b/i) ? "STARTER_PACK" : nil)
  if route.present?
    payload = fixed_bundle_unit_payload(route)
    return fixed_bundle_unit_sentence(payload) if payload.present?
  end

  starter = fixed_bundle_unit_sentence(fixed_bundle_unit_payload("STARTER_PACK"), compact: true)
  pro = fixed_bundle_unit_sentence(fixed_bundle_unit_payload("PRO_PACK"), compact: true)
  [starter, pro, "Those are bundle shorthand numbers, not separate item pricing, because cards and door hangers are included too."].compact_blank.join(" ")
end

def fixed_bundle_unit_sentence(payload, compact: false)
  label = payload.to_h[:label]
  total = payload.to_h[:total]
  contents = payload.to_h[:contents].to_h
  per_sign = payload.to_h[:blended_sign_reference]
  return if label.blank? || total.blank?

  included = "#{format_quantity_count(contents[:yard_signs].to_i)} signs, #{format_quantity_count(contents[:business_cards].to_i)} cards, and #{format_quantity_count(contents[:door_hangers].to_i)} door hangers"
  sentence = "#{label} is #{total} for #{included}."
  if per_sign.present?
    sentence = [sentence, "Using just the sign count, that is about #{per_sign} per included sign, but the cards and door hangers are part of the bundle value too."].join(" ")
  end
  compact ? sentence : [sentence, "Does that bundle math help, or are you trying to stay signs-only?"].join(" ")
end

def route_unit_pricing_reply(route)
  payload = route_unit_payload(route, unit: route.to_s == "EDDM" ? "home/postcard" : "home", planning_quantity: route.to_s == "NEIGHBORHOOD_BLITZ" ? "500 homes" : "500-700 homes")
  return if payload.blank?

  label = payload[:label]
  total = payload[:total]
  per_unit = payload[:per_unit_reference]
  planning_quantity = payload[:planning_quantity]
  return "#{label} is #{total}." if per_unit.blank?

  if route.to_s == "EDDM"
    return "#{label} is #{total}; using #{planning_quantity} as the planning range, that is about #{per_unit} per #{payload[:unit]}. There is not a one-postcard checkout; that route/block is the real starting point. Do you want to stay around that 500-700 home range, or look at larger postcard blocks?"
  end

  "#{label} is #{total}; using #{planning_quantity} as the planning range, that is about #{per_unit} per #{payload[:unit]}. Do you want mail-only reach, or the broader blitz?"
end

def default_yard_sign_price_sentences(table)
  [10, 20, 50, 100, 250, 500, 1000].filter_map do |quantity|
    options = price_options_for_quantity(table, quantity)
    price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
    price.present? ? "#{format_quantity_count(quantity)} for #{display_yard_sign_price(price)}" : nil
  end.then do |parts|
    parts.present? ? ["For 18x24 yard signs, the options are #{parts.to_sentence}."] : []
  end
end

def yard_sign_inclusion_sentence(details)
  included = Array(details[:included]).join(" ").downcase
  pieces = []
  pieces << "stakes" if included.include?("stakes")
  pieces << "shipping" if included.include?("shipping")
  pieces << "design" if included.include?("design")
  return if pieces.blank?

  "For the yard-sign deal, #{pieces.to_sentence} #{pieces.length == 1 ? 'is' : 'are'} included."
end

def yard_sign_front_back_addon?(table)
  table.to_h.values.any? do |options|
    options.to_h.key?("different_front_back") || options.to_h.key?("different_front_back_included")
  end
end

def bundle_pricing_reply(route, text)
  details = product_details_for_route(route).to_h
  body = [details[:title], product_training_text(route)].compact.join(" ")
  price = bundle_price_text(route, details: details, body: body)
  return generic_product_pricing_reply(route) if price.blank?

  label = ROUTE_LABELS[route].presence || route.to_s.tr("_", " ").titleize
  included = Array(details[:included]).presence
  shipping = details[:shipping_note].presence
  summary = "#{label} is #{price}."
  summary = [summary, "#{included.to_sentence.capitalize} are included."].join(" ") if included.present?
  summary = [summary, shipping].join(" ") if shipping.present?
  summary
end

def bundle_compare_pricing_reply(question: nil)
  prefix = bundle_compare_context_prefix
  starter = bundle_compare_sentence("STARTER_PACK")
  pro = bundle_compare_sentence("PRO_PACK")
  details = bundle_compare_detail_sentence
  question = bundle_pricing_followup_question(question).presence || bundle_compare_default_followup_question

  [prefix, starter, pro, details, question].compact_blank.join(" ").squish
end

def bundle_compare_context_prefix
  body = latest_inbound_sms.to_s.downcase.squish
  return "Here is the clean comparison." if body.match?(/\b(?:comparing|compare|vs\.?|versus|\$299|\$599)\b/)
  return "Cards and door hangers are included in the bundle pricing." if body.match?(/\b(?:cost extra|included|include|business cards?|door hangers?)\b/)
  return "Simple version: both bundles include signs, cards, and door hangers." if body.match?(/\b(?:simple|cheap|not useless|tell me the price|what comes with it)\b/)

  nil
end

def bundle_compare_sentence(route)
  details = product_details_for_route(route).to_h
  body = [details[:title], product_training_text(route)].compact.join(" ")
  price = bundle_price_text(route, details: details, body: body)
  label = ROUTE_LABELS[route].presence || route.to_s.tr("_", " ").titleize
  sentence_subject = route.to_s == "PRO_PACK" ? "The #{label}" : label
  included = bundle_compare_included_text(route)

  if price.present?
    fallback_variant([
      "#{sentence_subject} is #{price} for #{included}.",
      "#{label} runs #{price} and includes #{included}.",
      "#{price} gets you #{included} with #{label}.",
      "With #{label}, #{price} covers #{included}."
    ])
  else
    fallback_variant([
      "#{sentence_subject} includes #{included}.",
      "#{label} comes with #{included}.",
      "With #{label}, you get #{included}."
    ])
  end
end

def bundle_compare_included_text(route)
  case route.to_s
  when "PRO_PACK"
    "100 signs, 1,000 cards, and 1,000 door hangers"
  when "STARTER_PACK"
    "20 yard signs, 500 business cards, and 500 door hangers"
  else
    bundle_composition_sentence(route)
      .sub(/\AThe\s+#{Regexp.escape(ROUTE_LABELS[route.to_s].presence || route.to_s.tr('_', ' ').titleize)}\s+includes\s+/i, "")
      .sub(/\.\z/, "")
  end
end

def bundle_compare_detail_sentence
  labels = bundle_compare_detail_labels
  return if labels.blank?

  "Both include #{labels.to_sentence}."
end

def bundle_compare_detail_labels
  included = %w[STARTER_PACK PRO_PACK].map do |route|
    Array(product_details_for_route(route).to_h[:included]).map(&:to_s).map(&:downcase)
  end
  shared = included.reduce { |left, right| left & right } || []
  text = shared.join(" ")
  labels = []
  labels << "design" if text.match?(/\bdesign\b/)
  labels << "double-sided UV printing/coating" if text.match?(/\bdouble\s*sided\b/) && text.match?(/\buv\b/)
  labels << "double-sided printing" if labels.exclude?("double-sided UV printing/coating") && text.match?(/\bdouble\s*sided\b/)
  labels << "UV coating" if labels.exclude?("double-sided UV printing/coating") && text.match?(/\buv\b/)
  labels << "stakes" if text.match?(/\bstakes?\b/)
  labels << "shipping" if text.match?(/\bshipping\b/)
  labels
end

def bundle_pricing_answer_for_guardrail(text)
  body = text.to_s.squish
  reply = bundle_compare_pricing_reply(question: bundle_pricing_followup_question(body))
  return reply if reply.present?

  return enforce_sms_length(enforce_single_question(body)) if bundle_detail_pricing_answer?(body) && fallback_sms_sendable?(body)

  nil
end

def bundle_detail_pricing_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.include?("$") &&
    body.match?(/\bstarter\s*pack\b/) &&
    body.match?(/\bpro\s*pack\b/) &&
    body.match?(/\b(?:yard\s+signs?|signs?)\b/) &&
    body.match?(/\b(?:business\s+cards?|cards?)\b/)
end

def bundle_pricing_followup_question(text)
  question = text.to_s.squish.scan(/[^.!?]*\?/).last.to_s.squish
  return if question.blank?
  return if question.length > 140
  return if multi_discovery_ask?(question)
  return if stale_bundle_pricing_followup?(question)

  question
end

def stale_bundle_pricing_followup?(question)
  body = question.to_s.downcase.squish
  pricing_intent?(body) ||
    body.match?(/\b(?:compare|vs\.?|versus|starter\s*pack|pro\s*pack|what do i get|what comes? with|included|cards?|door hangers?)\b/) ||
    body.match?(/\b(?:what kind of business|which business|industry|budget|zip|where are you|location)\b/) ||
    body.match?(/\b(?:which one fits|which option fits|which package fits|would that cover|proceed with either|need help with anything else)\b/)
end

def bundle_compare_default_followup_question
  fallback_variant([
    "Are you leaning toward the smaller starter run or the bigger pro run?",
    "Would the 20-sign starter run cover it, or do you need the 100-sign pro push?",
    "Which bundle feels closer to what you want to launch with?",
    "Do you want to keep it lean with Starter, or go heavier with Pro?"
  ])
end

def bundle_price_text(route, details: nil, body: nil)
  fixed = fixed_bundle_price_text(route)
  return fixed if fixed.present?

  details ||= product_details_for_route(route).to_h
  body = [body, details[:title], product_training_text(route)].compact.join(" ")
  raw = body[/\bonly\s+\$([\d,]+(?:\.\d{2})?)/i, 1] ||
    body[/\b(?:price|pricing|deal)\D{0,40}\$([\d,]+(?:\.\d{2})?)/i, 1]
  return "$#{raw}" if raw.present?

  variant_price = Array(details[:variants]).filter_map { |variant| variant.to_h[:price].presence || variant.to_h["price"].presence }.first
  return variant_price if variant_price.present?

  table = details[:price_table].to_h
  first_quantity = table.keys.map(&:to_i).select(&:positive?).sort.first
  return if first_quantity.blank?

  price_options_for_quantity(table, first_quantity).values.first.presence
end

def fixed_bundle_price_text(route)
  catalog_price = product_catalog_fixed_price(route)
  return catalog_price if catalog_price.present?

  case route.to_s
  when "STARTER_PACK" then "$299"
  when "PRO_PACK" then "$599"
  when "EDDM" then "$399"
  when "NEIGHBORHOOD_BLITZ" then "$699"
  end
end

def product_catalog_fixed_price(route)
  return unless defined?(Comms::ProductCatalog)

  Comms::ProductCatalog.fixed_price(route)
rescue StandardError
  nil
end

def correct_fixed_bundle_price_mismatches(text)
  body = text.to_s.squish
  return body if body.blank?

  body.gsub(/\b(Pro Pack\b[^.?!]{0,140}?)\$299\b/i, "\\1$599")
end

def correct_yard_sign_price_mismatches(text)
  body = text.to_s.squish
  return body if body.blank?
  return body unless yard_sign_price_conflict_for_guardrail?(body)

  inbound = latest_inbound_sms.to_s.squish
  query = if inbound.present? && (signs_only_pricing_question?(inbound) || pricing_route(inbound).to_s == "LAWN_SIGNS" || sign_interest?(inbound))
    inbound
  else
    "yard signs pricing"
  end

  yard_sign_pricing_reply(query).presence || body
end

def yard_sign_price_conflict_for_guardrail?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || !body.include?("$")
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
  return false if bundled_package_price_context?(body) && !yard_signs_only_price_claim_context?(body)
  return true if latest_exact_yard_sign_quantity_conflict?(body)
  return true if stale_yard_sign_price_amount_for_guardrail?(body)

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  table.present? && yard_sign_price_claim_conflicts?(body, table)
end

def latest_exact_yard_sign_quantity_conflict?(body)
  quantity = exact_yard_sign_quantity_from_text(latest_inbound_sms)
  return false unless quantity.present?

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.blank?

  text = body.to_s.downcase.squish
  known_quantities = table.keys.map { |key| key.to_s.delete(",").to_i }.select(&:positive?).uniq
  other_quantity = known_quantities.any? do |candidate|
    next false if candidate == quantity

    text.match?(/\b#{candidate}\s*(?:-| )?\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|sign\s+option)\b/i)
  end
  return true if other_quantity

  amounts = dollar_amounts(text)
  return false if amounts.blank?

  amounts.any? { |amount| !valid_yard_sign_price_for_quantity?(table, quantity, amount) }
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

def stale_yard_sign_price_amount_for_guardrail?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || !body.include?("$")
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)

  dollar_amounts(body).any? { |amount| amount.to_f.round(2) == 749.0 }
end

def bundled_package_price_context?(body)
  body.to_s.match?(/\b(?:starter\s*pack|pro\s*pack|neighborhood blitz|bundle)\b/) &&
    body.to_s.match?(/\b(?:business\s+cards?|door\s+hangers?|postcards?|a-frames?|rack cards?)\b/)
end

def yard_signs_only_price_claim_context?(body)
  body.to_s.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\s+(?:start|starts|are|is|cost|costs|for|at)\b/) ||
    body.to_s.match?(/\b\$[\d,]+(?:\.\d{2})?[^.?!]{0,80}\bfor\s+\d{1,5}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
end

def generic_product_pricing_reply(route)
  return business_card_only_reply("business card pricing") if route.to_s == "BUSINESS_CARDS"
  return door_hanger_only_reply("door hanger pricing") if route.to_s == "DOOR_HANGERS"
  return flyer_only_reply("flyer pricing") if route.to_s == "FLYERS"

  details = product_details_for_route(route).to_h
  table = details[:price_table].to_h
  if table.present?
    first_quantity = table.keys.map(&:to_i).sort.first
    price = price_options_for_quantity(table, first_quantity).values.first
    return "#{ROUTE_LABELS[route].presence || route.to_s.tr('_', ' ').titleize} starts at #{price}." if first_quantity.present? && price.present?
  end

  missing_pricing_handoff_reply
end

def missing_pricing_handoff_reply
  "Outside the exact listed packages, the clean starting point is Starter Pack at $299, Pro Pack at $599, and Yard Signs priced by quantity. Larger-volume custom specials need an account-manager check so pricing stays accurate. Which path is closest: bundle, signs, or postcards?"
end

def missing_pricing_handoff_reply?(text)
  text.to_s == missing_pricing_handoff_reply
end

def product_timing_details_payload
  details = turnaround_details
  return if details.blank?

  details.merge(
    source: "Product_Knowledge.md",
    usage_rule: "Use this for customer-facing turnaround answers. Timing runs from proof approval for production, not simply from order placement."
  )
end

def turnaround_details
  return @turnaround_details if defined?(@turnaround_details)

  text = product_knowledge_text
  @turnaround_details = {
    proof_print_ready: "1-2 business days if the customer provides a print-ready editable PDF or vector file",
    proof_custom_design: "2-3 business days for custom design from scratch",
    yard_signs_production: "7-10 business days after proof approval",
    other_print_production: "7-10 business days after proof approval",
    shipping: "2-5 business days by UPS/FedEx Ground",
    rush_print_window: "about 2-3 business days after proof approval when rush is available",
    rush_boundaries: "Rush is not handled through normal Shopify checkout. A marketing consultant should confirm availability and pricing based on product, quantity, and timeline.",
    source_confirmed: text.match?(/\bTURNAROUND TIMES\b/i).present?
  }
end

def product_knowledge_text
  @product_knowledge_text ||= begin
    organization = @stage.organization || @stage.crm_record&.organization
    if organization.blank? || !defined?(TrainingDocument)
      ""
    else
      document = organization.training_documents
        .where(status: TrainingDocument::STATUSES - ["archived"])
        .where("lower(title) LIKE ?", "%product_knowledge%")
        .order(updated_at: :desc)
        .first
      document ||= organization.training_documents
        .where(status: TrainingDocument::STATUSES - ["archived"])
        .where("lower(title) LIKE ? OR lower(body) LIKE ?", "%product knowledge%", "%## turnaround times%")
        .order(updated_at: :desc)
        .first
      document&.body.to_s
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsDraftWriter] product knowledge timing unavailable: #{error.class}: #{error.message}")
    ""
  end
end

def turnaround_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if shipping_included_question?(body)
  return true if rush_checkout_boundary_question?(body)

  body.match?(/\b(turnaround|turn around|timeline|how long|how soon|when would|when will|need them by|need it by|asap|rush|rushed|expedite|production time|ship|shipping time|delivery time|arrive|get them|in a hurry|hurry|hurray|fast|next friday|deadline)\b/)
end

def rush_timing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:rush|rushed|asap|expedite|faster|fast|in a hurry|hurry|hurray|next\s+friday|need (?:them|it) by|deadline)\b/)
end

def shipping_included_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:shipping|ship)\b.{0,50}\b(?:included|include|comes with|part of|free)\b/) ||
    body.match?(/\b(?:included|include|comes with|part of|free)\b.{0,50}\b(?:shipping|ship)\b/)
end

def yard_sign_included_items_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if yard_sign_art_cost_question?(body)
  return false unless body.match?(/\b(?:include|included|comes with|come with|part of|free)\b/)
  return false unless body.match?(/\b(?:design|stakes?|shipping|ship)\b/)

  sign_interest?(body) ||
    current_route_code.to_s == "LAWN_SIGNS" ||
    recent_sms_context.match?(SIGN_INTEREST_PATTERN)
end

def yard_sign_art_cost_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:art|artwork|design|layout|logo)\b/)
  return false unless body.match?(/\b(?:charge|cost|extra|additional|add[-\s]?on|added|pay|fee|included|free)\b/)

  sign_interest?(body) ||
    current_route_code.to_s == "LAWN_SIGNS" ||
    recent_sms_context.match?(SIGN_INTEREST_PATTERN)
end

def yard_sign_art_cost_reply
  "No extra charge for standard yard-sign design help; design help, stakes, and shipping are included in the listed price. Different front/back designs add $125. After checkout, the intake form collects your logo/artwork and you approve a proof before print."
end

def yard_sign_included_items_reply(text = nil)
  return yard_sign_art_cost_reply if yard_sign_art_cost_question?(text)

  quantity = yard_sign_pricing_quantity_for(text.to_s).presence || current_yard_sign_quantity_value
  price = nil
  if quantity.to_i.positive?
    table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
    options = price_options_for_quantity(table, quantity)
    price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
  end

  if price.present?
    return "For #{format_quantity_count(quantity)} yard signs, you are at #{display_yard_sign_price(price)} with design help, stakes, and shipping included. Different front/back designs add $125.".squish
  end

  "Yes. For Yard Signs, design help, stakes, and shipping are included in the listed price. Different front/back designs add $125.".squish
end

def print_products_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/) && !body.match?(/\b(?:other|else|flyers?|print products?)\b/)
  return true if business_card_only_intent?(body)
  return true if door_hanger_only_intent?(body)
  return true if flyer_only_intent?(body)

  context = [body, recent_sms_context].join(" ").downcase.squish

  return true if body.match?(/\b(?:what other|what else|other print|print products?|what can you help with|what do you offer)\b/)
  return true if body.match?(/\b(?:flyers?|rack cards?|magnets?|brochures?)\b/)
  return true if body.match?(/\b(?:need|want|looking for|interested in|pricing|price|help with)\b.{0,80}\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b/)
  return true if body.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b.{0,80}\b(?:need|want|looking for|interested in|pricing|price|help with)\b/)
  return true if body.match?(/\bbusiness cards?\b/) && body.match?(/\bdoor hangers?\b/) && body.match?(/\b(?:include|offer|help|those|products?)\b/)
  return true if context.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b/) &&
    body.match?(/\b(?:those|these|that|all that|what can you help with|help me choose|real person|person|consultant|talk to someone)\b/)

  false
end

def print_products_reply(text = latest_inbound_sms)
  body = text.to_s.downcase.squish
  if business_card_only_intent?(body)
    return business_card_only_reply(body)
  elsif door_hanger_only_intent?(body)
    return door_hanger_only_reply(body)
  elsif flyer_only_intent?(body)
    return flyer_only_reply(body)
  end

  if broad_print_products_menu_question?(body)
    return "Besides yard signs, WIZWIKI prints business cards, door hangers, flyers, postcards, rack cards, and related campaign pieces. Which piece matters most for this campaign?"
  end

  if print_product_terms_present?(body)
    multi_reply = multi_print_products_reply(body)
    return multi_reply if multi_reply.present?

    pieces = []
    pieces << "business cards" if body.match?(/\bbusiness cards?\b/)
    pieces << "door hangers" if body.match?(/\bdoor hangers?\b/)
    pieces << "flyers" if body.match?(/\bflyers?\b/)
    pieces << "rack cards" if body.match?(/\brack cards?\b/)
    pieces << "vehicle magnets" if body.match?(/\bmagnets?\b/)
    pieces << "brochures" if body.match?(/\bbrochures?\b/)
    piece_text = natural_list(pieces.presence || ["business cards", "door hangers", "flyers"])
    if print_product_confirmation_question?(body)
      return "#{piece_text.to_s.sub(/\A([a-z])/) { Regexp.last_match(1).upcase }} can all be ordered on their own. Rough quantities will tell us whether standard checkout or a custom print mix makes more sense. Do you have a count for any of them?"
    end

    return "WIZWIKI can help with #{piece_text}. Starter Pack and Pro Pack are fixed bundles when signs, cards, and hangers fit together; for print-only pieces, custom sizes, or custom quantities, a marketing consultant can help map it out."
  end

  "WIZWIKI can help with business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials. Starter/Pro are fixed bundles; if the mix is custom, a marketing consultant can help dial it in."
end

def multi_print_products_reply(text)
  body = text.to_s.downcase.squish
  terms = requested_print_product_terms(body)
  return if terms.length < 2

  if direct_checkout_link_request?(body) || multi_product_link_request?(body)
    link_reply = multi_product_link_reply(body)
    return link_reply if link_reply.present?
  end

  parts = []
  parts << "business cards are 16pt premium matte: 250 for $70, 500 for $75, 1,000 for $80" if terms.include?(:business_cards)
  parts << "door hangers are 4.25x11: 500 from $270, 1,000 from $335" if terms.include?(:door_hangers)
  parts << "8.5x11 flyers start at 250 for $210 and 500 for $280" if terms.include?(:flyers)

  extra_terms = terms - %i[business_cards door_hangers flyers]
  if extra_terms.present?
    parts << "For #{natural_list(extra_terms.map { |term| print_product_term_label(term) })}, a marketing consultant can confirm sizes and quantities"
  end

  return if parts.blank?

  intro = terms.length >= 3 ? "Business cards, door hangers, and flyers all have standalone options. " : ""
  reply = "#{intro}#{parts.join('. ').sub(/\A([a-z])/) { Regexp.last_match(1).upcase }}. Which product and quantity should I price first?"
  return reply if reply.length <= MAX_SMS_CHARS

  compact_terms = natural_list(terms.map { |term| print_product_term_label(term) })
  "WIZWIKI can help with #{compact_terms}. Business cards and door hangers have standalone checkout paths; custom print mixes can go to a marketing consultant. Want the links?"
end

def print_product_term_label(term)
  case term
  when :business_cards then "business cards"
  when :door_hangers then "door hangers"
  when :flyers then "flyers"
  when :rack_cards then "rack cards"
  when :magnets then "vehicle magnets"
  when :brochures then "brochures"
  else term.to_s.tr("_", " ")
  end
end

def standalone_print_product_quantity_followup?(text)
  standalone_print_product_quantity_route(text).present? &&
    standalone_print_product_quantity_value(text).present?
end

def standalone_print_product_quantity_reply(text)
  body = text.to_s.downcase.squish
  route = standalone_print_product_quantity_route(body)
  quantity = standalone_print_product_quantity_value(body)
  return if route.blank? || quantity.blank?

  case route
  when "BUSINESS_CARDS"
    standalone_business_card_quantity_reply(quantity, body)
  when "DOOR_HANGERS"
    standalone_door_hanger_quantity_reply(quantity, body)
  when "FLYERS"
    standalone_flyer_quantity_reply(quantity, body)
  end
end

def standalone_print_product_quantity_route(text)
  body = text.to_s.downcase.squish
  return if body.blank?
  return "DOOR_HANGERS" if door_hanger_interest?(body)
  return "FLYERS" if flyer_interest?(body)
  return "BUSINESS_CARDS" if business_card_interest?(body)
  return "BUSINESS_CARDS" if body.match?(/\bcards?\b/) && recent_standalone_print_route.to_s == "BUSINESS_CARDS"

  if body.match?(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+|just\s+)?[\d,]{1,6}\s*[.!?]?\z/i)
    route = current_route_code.to_s.presence || recent_standalone_print_route.to_s.presence
    return route if %w[BUSINESS_CARDS DOOR_HANGERS FLYERS].include?(route)
  end

  nil
end

def standalone_print_product_quantity_value(text)
  body = text.to_s.downcase.squish
  return if body.blank?
  return if body.match?(/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/)

  values = body.scan(/\b[\d,]{1,6}\b/).map { |value| value.delete(",").to_i }.select(&:positive?)
  values.uniq!
  return unless values.one?

  values.first
end

def recent_standalone_print_route
  sms_thread_events.last(8).reverse_each do |event|
    body = event.to_h["body"].to_s.downcase.squish
    next if body.blank?

    return "BUSINESS_CARDS" if business_card_interest?(body)
    return "DOOR_HANGERS" if door_hanger_interest?(body)
    return "FLYERS" if flyer_interest?(body)
  end

  nil
end

def standalone_business_card_quantity_reply(quantity, body)
  tiers = {
    250 => "$70",
    500 => "$75",
    1_000 => "$80",
    2_500 => "$150",
    5_000 => "$195",
    10_000 => "$300"
  }
  link = route_specific_shopify_link("BUSINESS_CARDS").to_s.squish.presence
  if quantity < 250
    return [
      "Standalone business cards start at 250.",
      "The 250-count option is $70.",
      direct_checkout_link_request?(body) && link.present? ? "If 250 works, here is the Business Cards checkout link: #{link}" : "Would 250 work?"
    ].compact_blank.join(" ").squish
  end

  price = tiers[quantity]
  if price.present?
    reply = "For #{format_quantity_count(quantity)} business cards, the standalone 16pt premium matte option is #{price}."
    return [reply, "Here is the Business Cards checkout link: #{link}"].compact_blank.join(" ").squish if direct_checkout_link_request?(body) && link.present?

    return [reply, "Want me to send the Business Cards checkout link?"].compact_blank.join(" ").squish
  end

  "Business cards have listed standalone tiers at 250, 500, 1,000, 2,500, 5,000, and 10,000. #{format_quantity_count(quantity)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
end

def standalone_door_hanger_quantity_reply(quantity, body)
  tiers = {
    500 => "$270",
    1_000 => "$335",
    2_500 => "$600",
    5_000 => "$1,035",
    10_000 => "$1,985"
  }
  link = route_specific_shopify_link("DOOR_HANGERS").to_s.squish.presence
  if quantity < 500
    return [
      "Standalone door hangers start at 500, so #{format_quantity_count(quantity)} is below the listed checkout minimum.",
      "The 500-count option starts at $270.",
      direct_checkout_link_request?(body) && link.present? ? "If 500 works, here is the door-hanger checkout link: #{link}" : "Would 500 work?"
    ].compact_blank.join(" ").squish
  end

  price = tiers[quantity]
  if price.present?
    reply = "For #{format_quantity_count(quantity)} door hangers, the standalone 4.25x11 option starts at #{price}, depending on finish."
    return [reply, "Here is the door-hanger checkout link: #{link}"].compact_blank.join(" ").squish if direct_checkout_link_request?(body) && link.present?

    return [reply, "Want me to send the door-hanger checkout link?"].compact_blank.join(" ").squish
  end

  "Door hangers have listed standalone tiers at 500, 1,000, 2,500, 5,000, and 10,000. #{format_quantity_count(quantity)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
end

def standalone_flyer_quantity_reply(quantity, body)
  tiers = {
    250 => "$210",
    500 => "$280",
    1_000 => "$345",
    2_500 => "$570",
    5_000 => "$820",
    10_000 => "$1,550"
  }
  link = route_specific_shopify_link("FLYERS").to_s.squish.presence
  if quantity < 250
    return [
      "For 8.5x11 flyers, the listed standalone tiers start at 250.",
      "The 250-count option is $210.",
      direct_checkout_link_request?(body) && link.present? ? "If 250 works, here is the Flyers checkout link: #{link}" : "Would 250 work?"
    ].compact_blank.join(" ").squish
  end

  price = tiers[quantity]
  if price.present?
    reply = "For #{format_quantity_count(quantity)} 8.5x11 flyers, the standalone option is #{price}; smaller flyer sizes can be lower."
    return [reply, "Here is the Flyers checkout link: #{link}"].compact_blank.join(" ").squish if direct_checkout_link_request?(body) && link.present?

    return [reply, "Want me to send the Flyers checkout link?"].compact_blank.join(" ").squish
  end

  "Flyers have listed 8.5x11 tiers at 250, 500, 1,000, 2,500, 5,000, and 10,000. #{format_quantity_count(quantity)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
end

def business_card_only_intent?(text)
  body = text.to_s.downcase.squish
  business_card_context = business_card_interest?(body) ||
    body.match?(/\bcards?\b/) && recent_standalone_print_route.to_s == "BUSINESS_CARDS"
  return false unless business_card_context
  return false if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|post\s*cards?|postcards?|direct mail|eddm|door hangers?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?|starter\s*pack|pro\s*pack|bundle|neighbou?rhood\s+blitz|main course)\b/)

  true
end

def business_card_only_reply(text)
  quantity_reply = standalone_print_product_quantity_reply(text)
  return quantity_reply if quantity_reply.present?

  link = route_specific_shopify_link("BUSINESS_CARDS").to_s.squish.presence
  link_requested = direct_checkout_link_request?(text)
  base = "Business cards have a standalone 16pt premium matte option. Standard quantities are 250 for $70, 500 for $75, 1,000 for $80, 2,500 for $150, 5,000 for $195, and 10,000 for $300."
  if link_requested && link.present?
    "#{base} Here is the Business Cards checkout link: #{link}"
  elsif link.present?
    "#{base} Want me to send the Business Cards checkout link?"
  else
    "#{base} If you want that path, I can have a marketing consultant help confirm the best order setup."
  end
end

def door_hanger_only_intent?(text)
  body = text.to_s.downcase.squish
  return false unless door_hanger_interest?(body)
  return false if body.match?(/\b(?:business cards?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?|starter\s*pack|pro\s*pack|bundle|neighbou?rhood\s+blitz|main course)\b/)

  body.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/)
end

def door_hanger_only_reply(text)
  quantity_reply = standalone_print_product_quantity_reply(text)
  return quantity_reply if quantity_reply.present?

  link = route_specific_shopify_link("DOOR_HANGERS").to_s.squish.presence
  link_requested = direct_checkout_link_request?(text)
  base = "Door hangers have a standalone 4.25x11 option. Standard quantities start at 500 for $270, 1,000 from $335, 2,500 from $600, 5,000 from $1,035, and 10,000 from $1,985 depending on finish."
  if link_requested && link.present?
    "#{base} Here is the door-hanger checkout link: #{link}"
  elsif link.present?
    "#{base} Want me to send the door-hanger checkout link?"
  else
    "#{base} If you want that path, I can have a marketing consultant help confirm the best order setup."
  end
end

def flyer_only_intent?(text)
  body = text.to_s.downcase.squish
  return false unless flyer_interest?(body)
  return false if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|post\s*cards?|postcards?|direct mail|eddm|business cards?|door hangers?|rack cards?|magnets?|vehicle magnets?|brochures?|starter\s*pack|pro\s*pack|bundle|neighbou?rhood\s+blitz|main course)\b/)

  true
end

def flyer_only_reply(text)
  quantity_reply = standalone_print_product_quantity_reply(text)
  return quantity_reply if quantity_reply.present?

  link = route_specific_shopify_link("FLYERS").to_s.squish.presence
  link_requested = direct_checkout_link_request?(text)
  base = "Flyers have a standalone checkout with size and quantity options. For 8.5x11 flyers, pricing is 250 for $210, 500 for $280, 1,000 for $345, 2,500 for $570, 5,000 for $820, and 10,000 for $1,550; smaller flyer sizes can be lower."
  if link_requested && link.present?
    "#{base} Here is the Flyers checkout link: #{link}"
  elsif link.present?
    "#{base} Want me to send the Flyers checkout link?"
  else
    "#{base} If size or quantity is still fuzzy, a marketing consultant can help confirm the cleanest setup."
  end
end

def broad_print_products_menu_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?)\b/)

  body.match?(/\b(?:what other|what else|other print|print products?|what can you help with|what do you offer)\b/)
end

def print_product_confirmation_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:could|can|would|do|does|will)\b.{0,70}\b(?:include|include those|have|offer|help with)\b/) ||
    body.match?(/\b(?:those|these|that|all that)\b.{0,70}\b(?:include|included|available|possible|work|help)\b/) ||
    body.match?(/\b(?:yes|yep|yeah|ok|okay)\b.{0,40}\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b/)
end

def print_product_terms_present?(text)
  text.to_s.downcase.squish.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|vehicle magnets?|brochures?|print pieces?|print products?)\b/)
end

def natural_list(items)
  parts = Array(items).map(&:to_s).map(&:squish).reject(&:blank?).uniq
  return "" if parts.blank?
  return parts.first if parts.length == 1
  return parts.join(" and ") if parts.length == 2

  "#{parts[0...-1].join(', ')}, and #{parts.last}"
end

def messy_print_consultant_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  context = [body, recent_sms_context].join(" ").downcase.squish
  return false unless context.match?(/\b(?:print|flyers?|business cards?|door hangers?|rack cards?|brochures?|menus?|cards?)\b/)

  body.match?(/\b(?:messy|custom|not sure|don'?t know|do not know|sizes?|quantit(?:y|ies)|figure all that out|all that out|real person|person help|help me choose|talk to a person|consultant)\b/)
end

def messy_print_consultant_reply
  pieces = requested_print_product_terms(latest_inbound_sms).map do |term|
    case term
    when :business_cards then "business cards"
    when :door_hangers then "door hangers"
    when :flyers then "flyers"
    when :rack_cards then "rack cards"
    when :magnets then "vehicle magnets"
    when :brochures then "brochures"
    end
  end.compact
  piece_text = natural_list(pieces.presence || ["flyers", "business cards", "door hangers"])

  if print_handoff_choice_question?(latest_inbound_sms)
    return "A marketing consultant is the better fit for #{piece_text} when sizes and quantities are still open. They can map out the cleanest print mix and quote it accurately. What is the best way for them to reach you?"
  end

  "Totally fine. For #{piece_text}, sizes and quantities are exactly what a marketing consultant should help map out so we quote it cleanly. What is the best way for them to reach you?"
end

def print_handoff_choice_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  context = [body, recent_sms_context].join(" ").downcase.squish
  return false unless context.match?(/\b(?:print|flyers?|business cards?|door hangers?|rack cards?|brochures?|cards?)\b/)

  body.match?(/\b(?:should|can|could|would)\b.{0,90}\b(?:real person|person|consultant|someone|teammate)\b/) ||
    body.match?(/\b(?:real person|person|consultant|someone|teammate)\b.{0,90}\b(?:help me choose|figure|map|handle|take over)\b/) ||
    body.match?(/\bthumper\b.{0,80}\b(?:figure all that out|help me choose)\b/)
end

def marketing_channel_comparison_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:post\s*cards?|direct mail|eddm|mailers?)\b/)
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?)\b/)

  body.match?(/\b(?:should (?:i|we)|which (?:one|channel|option)|what(?:'s| is) better|better first|best first|start with|begin with|lead with|recommend|versus|vs\.?|or)\b/)
end

def marketing_channel_comparison_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  recommendation = body.match?(/\b(?:start with|begin with|lead with|recommend|i'd (?:start|begin|lead|go)|i would (?:start|begin|lead|go)|go with|best first move|better starting point|first move)\b/)
  practical_reason = body.match?(/\b(?:because|so (?:you|we)|for (?:broad|fast|local|neighborhood)|to (?:cover|reach|build|reinforce|blanket|stay visible)|coverage|visibility|local proof|job sites?|jobs? you win)\b/)
  recommendation && practical_reason
end

def marketing_channel_recommendation_missing?(text)
  marketing_channel_comparison_question?(latest_inbound_sms) && !marketing_channel_comparison_answer?(text)
end

def marketing_channel_comparison_reply
  inbound = latest_inbound_sms.to_s.downcase.squish
  if inbound.match?(/\b(?:roof|roofing|roofer|storm|hail|wind damage)\b/) || industry_value.to_s.casecmp?("Roofing")
    "Start with postcards so you can cover the storm-hit neighborhoods quickly, then place signs at the jobs you win to build local proof. What ZIP codes are you targeting?"
  else
    "Start with postcards for broad neighborhood reach, then use signs around active jobs or high-visibility spots to reinforce the campaign. What area are you targeting?"
  end
end

def direct_mail_strategy_handoff_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if marketing_channel_comparison_question?(body)
  return false unless body.match?(/\b(?:direct mail|eddm|postcards?|mailers?|mailboxes?|routes?|lists?|targeting|neighborhoods?)\b/)

  body.match?(/\b(?:strategy|targeting|routes?|lists?|software|account setup|best neighborhoods?|what would work|pick the best|plan|manage)\b/)
end

def direct_mail_strategy_handoff_reply
  business = industry_value.to_s.squish.presence
  opener = business.present? ? "For a #{business.downcase} campaign, EDDM is a clean starting point for broad neighborhood coverage without buying a list." : "EDDM is a clean starting point for broad neighborhood coverage without buying a list."
  "#{opener} The exact neighborhoods, routes, offer, and list strategy depend on the service area and campaign goal. Want me to connect you with a marketing consultant to map that out?"
end

def direct_mail_strategy_reply_missing_handoff?(text)
  return false unless direct_mail_strategy_handoff_question?(latest_inbound_sms)

  body = text.to_s.downcase.squish
  return true if body.blank?

  !(human_handoff_answer?(body) && body.match?(/\b(?:strategy|routes?|lists?|targeting|neighborhoods?|details|go over)\b/))
end

def broad_direct_mail_checkout_before_ready?(text)
  body = text.to_s.downcase.squish
  inbound = latest_inbound_sms.to_s.downcase.squish
  return false if body.blank? || inbound.blank?
  return false unless body.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i)
  return false unless inbound.match?(/\b(?:direct mail|eddm|post\s*cards?|postcards?|mailers?|mailing|mailboxes?)\b/)
  return false if direct_checkout_link_request?(inbound) || buyer_close_signal?(inbound)
  return false if requested_quantities(inbound).present? && (pricing_question?(inbound) || current_specials_question?(inbound) || postcard_special_quantity_followup?(inbound))

  inbound.match?(/\b(?:want|need|looking for|interested in|thinking about|considering|trying|start|starting)\b/) ||
    inbound.match?(/\A(?:direct mail|eddm|postcards?|mailers?)\b/)
end

def turnaround_reply(text)
  details = turnaround_details
  return if details.blank?

  body = text.to_s.downcase
  route = turnaround_route(body)
  if rush_handoff_confirmation_request?(body)
    return rush_handoff_confirmation_reply(route)
  end

  if rush_checkout_boundary_question?(body)
    return rush_checkout_boundary_reply(route)
  end

  if body.match?(/\b(rush|rushed|asap|expedite|this week|need them by|need it by|in a hurry|hurry|hurray|fast|next friday|deadline)\b/)
    return rush_turnaround_reply(route)
  end

  case route
  when "LAWN_SIGNS"
    production = details[:yard_signs_production].to_s.sub(/\s+after proof approval\z/i, "")
    "For yard signs, proof comes first. Once you approve it, standard production is usually #{production}, then shipping is #{details[:shipping]}. If you have a firm date, send it over and we can back into the timing."
  else
    "The timeline has two parts: proof first, then production after approval. Proof is #{details[:proof_print_ready]}, or #{details[:proof_custom_design]}; most print production is 7-10 business days after proof approval, then shipping is #{details[:shipping]}."
  end
end

def turnaround_route(text)
  return "LAWN_SIGNS" if sign_interest?(text)
  return "LAWN_SIGNS" if current_route_code.to_s == "LAWN_SIGNS"

  current_route_code.presence
end

def rush_checkout_boundary_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  checkout_context = body.match?(/\bcheckout\b|\bcheck\s+out\b/)
  rush_context = body.match?(/\b(?:rush|rushed|asap|expedite|faster|fast|in a hurry|hurry|hurray|next\s+friday|need (?:them|it) by|deadline)\b/) ||
    recent_sms_context.match?(/\b(?:rush|rushed|asap|expedite|faster|fast|in a hurry|hurry|hurray|next\s+friday|need (?:them|it) by|deadline)\b/i)
  boundary_context = body.match?(/\b(?:normal|standard|regular)\b.{0,30}\b(?:checkout|check\s+out)\b/) ||
    body.match?(/\b(?:checkout|check\s+out)\b.{0,80}\b(?:rush|rushed|asap|expedite|normal|standard|regular)\b/) ||
    body.match?(/\b(?:rush|rushed|asap|expedite)\b.{0,80}\b(?:checkout|check\s+out)\b/) ||
    body.match?(/\b(?:shouldn'?t|should\s+not|don'?t|do\s+not|avoid|instead)\b.{0,80}\b(?:checkout|check\s+out)\b/)

  checkout_context && rush_context && boundary_context
end

def rush_handoff_confirmation_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless explicit_support_handoff_request?(body)

  body.match?(/\b(?:rush|rushed|asap|expedite|faster|deadline)\b/) ||
    recent_sms_context.match?(/\b(?:rush|rushed|asap|expedite|faster|deadline)\b/i)
end

def rush_turnaround_reply(route)
  details = turnaround_details
  if route.to_s == "LAWN_SIGNS"
    "For yard signs, do not use the normal checkout for rush. A marketing consultant needs to confirm availability and pricing for the quantity and timeline; rush starts after proof approval, moves production ahead, and shipping is still usually #{details[:shipping]}. Want me to have a marketing consultant check this with you?"
  else
    "Rush should not go through the normal checkout path. It starts after design/proof approval, can move production to #{details[:rush_print_window]}, and shipping is still usually #{details[:shipping]}. Want me to have a marketing consultant check this with you?"
  end
end

def rush_checkout_boundary_reply(route)
  details = turnaround_details
  if route.to_s == "LAWN_SIGNS"
    "For a rush yard-sign order, do not use the normal checkout. A marketing consultant needs to confirm availability and pricing first; rush starts after proof approval, moves production ahead, and shipping is still usually #{details[:shipping]}. Want me to have a marketing consultant check this with you?"
  else
    "Rush should not go through the normal checkout path. A marketing consultant needs to confirm availability and pricing first; rush starts after design/proof approval, can move production to #{details[:rush_print_window]}, and shipping is still usually #{details[:shipping]}. Want me to have a marketing consultant check this with you?"
  end
end

def rush_handoff_confirmation_reply(route)
  details = turnaround_details
  if route.to_s == "LAWN_SIGNS"
    "Got it. I will get this in front of a marketing consultant for rush availability and pricing. Rush starts after proof approval, mainly moves print production ahead in the queue, and shipping is still usually #{details[:shipping]}."
  else
    "Got it. I will get this in front of a marketing consultant for rush availability and pricing. Rush starts after design/proof approval, can move production to #{details[:rush_print_window]}, and shipping is still usually #{details[:shipping]}."
  end
end

def design_process_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if multi_product_link_request?(body)

  process_terms = body.match?(/\b(upload|send|attach|image|images|photo|photos|logo|artwork|art|file|files|design|proof|proofing|approve|approval|print|prints|printing)\b/)
  question_shape = body.include?("?") || body.match?(/\b(where|how|when|why|what|can|could|do|does|will|would|is|are)\b/)
  payment_confusion = body.match?(/\b(pay|paying|paid|payment|checkout|order)\b.*\b(first|before|design|proof|artwork|logo|art|file|upload)\b/) ||
    body.match?(/\b(first|before)\b.*\b(pay|paying|paid|payment|checkout|order)\b.*\b(design|proof|artwork|logo|art|image|images|file|upload)\b/) ||
    body.match?(/\b(making me pay|pay first|paying first|checkout first|order first|why pay)\b/)
  proof_print_confidence = body.match?(/\b(proof|design)\b.*\b(before|print|prints|printing|approve|approval|changes|revision|revisions|like|dislike)\b/) ||
    body.match?(/\b(nothing|anything)\b.*\b(print|prints|printing)\b.*\b(approve|approval|proof)\b/)

  (question_shape && process_terms) || payment_confusion || proof_print_confidence
end

def yard_signs_package_proof_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless sign_interest?(body)

  body.match?(/\b(proof|design|artwork|mockup|print|prints|printing|approve|approval)\b/) &&
    (body.include?("?") || body.match?(/\b(before|until|see|review|get|when|how|do i|will i|can i)\b/))
end

def yard_signs_package_proof_reply
  quantity = requested_quantities(latest_inbound_sms).max
  quantity_text = quantity.present? && quantity.positive? ? " For #{quantity} signs, that package is the clean fit." : ""
  [
    "The Yard Signs package is the signs-only deal.",
    quantity_text,
    "You review and approve a proof before anything prints.",
    "Complete checkout first; the intake form goes to the checkout email for logo, artwork, wording, colors, and notes."
  ].compact_blank.join(" ").squish
end

def yard_signs_package_proof_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\byard\s+signs?\s+package\b|\bpackage\b|\bdeal\b|\bspecial\b/) &&
    body.match?(/\bproof\b/) &&
    body.match?(/\b(approve|approval|before|nothing prints|print)\b/)
end

def proof_before_payment_exception_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(proof|design|artwork|mockup)\b.*\b(before|first)\b.*\b(pay|paying|paid|payment|checkout|order)\b/) ||
    body.match?(/\b(before|first)\b.*\b(pay|paying|paid|payment|checkout|order)\b.*\b(proof|design|artwork|mockup)\b/) ||
    body.match?(/\b(?:not|won't|will not|dont|don't|do not)\b.*\b(pay|paying|checkout|order)\b.*\b(until|unless|before)\b.*\b(proof|design|artwork|mockup)\b/) ||
    (body.match?(/\b(?:see|get|review|approve)\b.*\b(?:proof|design|artwork|mockup)\b.*\bfirst\b/) && body.match?(/\b(pay|paying|paid|payment|checkout|order)\b|\bmaking me pay\b/))
end

def complex_design_order_situation?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(file setup|bleed|press[-\s]?ready|print[-\s]?ready|color match|pantone|vectorize|trademark|brand guidelines|multi[-\s]?location|several versions|variable data|material|substrate|installation|install|permit|contract|terms|legal)\b/)
end

def design_process_explained_recently?
  texts = (recent_outbound_texts.first(6) + recent_draft_texts.first(4)).compact_blank
  texts.any? do |message|
    body = message.to_s
    design_process_answer?(body) ||
      body.match?(/\b(intake form|nothing prints until|proof approval happens before print|checkout starts .{0,80}design queue|payment starts .{0,80}design queue)\b/i)
  end
end

def design_process_handoff_needed?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if human_request?(body)
  return true if complex_design_order_situation?(body)
  return true if proof_before_payment_exception_request?(body) && design_process_explained_recently?
  return true if design_process_explained_recently? && body.match?(/\b(still confused|confused|not comfortable|uncomfortable|worried|concerned|nervous|don't trust|do not trust|hesitant)\b/)

  false
end

def design_process_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if proof_approval_answer?(body)

  body.match?(/\b(checkout|order|payment|pay|paying|paid|ordering)\b/) &&
    body.match?(/\b(intake form|checkout email|upload|images?|pictures?|logo|artwork|files?|wording|colors|notes)\b/) &&
    body.match?(/\b(proof|approve|approval|nothing prints|print until|before print|before it prints)\b/)
end

def simple_proof_approval_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\bproof\b/) &&
    (
      body.match?(/\b(?:can|could|do|does|will|would|am i|are we)\b.{0,80}\b(?:approve|review|see|get|receive)\b/) ||
        body.match?(/\b(?:approve|review|see|get|receive)\b.{0,80}\bproof\b/) ||
        body.match?(/\bproof\b.{0,80}\b(?:before|prior to)\b.{0,40}\b(?:print|prints|printing)\b/)
    )
end

def proof_approval_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:yes|you can|you will|you'll|you review|you approve|we send|you receive|you get)\b/) &&
    body.match?(/\bproof\b/) &&
    body.match?(/\b(?:approve|approval|review)\b/) &&
    body.match?(/\b(?:before|until|nothing|goes to print|prints?|printing)\b/)
end

def image_handling_process_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(upload|send|attach|image|images|photo|photos|logo|artwork|art|file|files)\b/)
end

def image_handling_process_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(upload|send|intake form|checkout email|email)\b/) &&
    body.match?(/\b(image|images|photo|photos|logo|artwork|art|file|files|wording|colors|notes)\b/)
end

def design_process_priority_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.match?(/\b(pay|payment|checkout|order)\b.*\b(proof|artwork|design)\b/)
  return true if body.match?(/\b(proof|artwork|design)\b.*\b(pay|payment|checkout|order)\b/)
  return true if body.match?(/\bproof\b/) && body.match?(/\b(email|send|sent|receive|get|where|how)\b/)
  return false unless design_process_question?(body)

  body.match?(/\b(proof|approve|approval|pay|payment|checkout|order|email|send|sent|receive|get the art proof|why do i pay)\b/)
end

def design_process_reply(route = current_route_code, prefix: nil)
  inbound = latest_inbound_sms.to_s
  if stacked_yard_sign_price_process_context?
    reply = stacked_yard_sign_process_reply(stacked_yard_sign_price_process_context_text)
    return reply if reply.present?
  end

  if inbound.match?(/\b(?:keep it simple|simple|quick version|short version|brief)\b/i) &&
      inbound.match?(/\bproof|approve|approval|printing|print\b/i) &&
      inbound.match?(/\b(?:logo|rough|screenshot|clean\s*up|cleaned\s*up|artwork)\b/i)
    return "Yes. You approve a proof before anything prints, and the team can use or clean up a rough logo through the intake form after checkout, not by text.".squish
  end

  pool = if inbound.match?(/\bproof|approve|approval|printing|print\b/i) && inbound.match?(/\b(?:logo|rough|screenshot|clean\s*up|cleaned\s*up|artwork)\b/i)
    [
      "Yes. You approve a proof before anything prints, and the design team can use or clean up a rough logo after checkout through the intake form, not by text. A cleaner PDF/vector file helps if you have one, but it is not required.",
      "Yes. Nothing prints until you approve the proof. After checkout, the intake form collects the logo/artwork and notes; the design team can use what you have or clean up a rough logo enough for the proof."
    ]
  elsif proof_before_payment_exception_request?(inbound) || inbound.match?(/\b(pay|paying|paid|payment|checkout|making me pay|pay first)\b/i)
    [
      "The order comes first so the design queue can start, but checkout does not mean WIZWIKI prints blindly. After checkout, the design team emails the intake form for images/artwork, and WIZWIKI can use the AI postcard/art builder or in-house designers. They build the proof, and nothing prints until approval.",
      "Payment starts the order and design queue. After that, the design team collects your images/artwork through the checkout-email intake form. If you need design help, WIZWIKI can use the AI postcard/art builder or in-house designers, prepares the proof, and you can request changes before anything prints."
    ]
  elsif inbound.match?(/\bproof\b/i) && inbound.match?(/\b(email|send|sent|receive|get|where|how)\b/i)
    [
      "The proof comes after the order. Complete checkout, then the intake form goes to the checkout email so you can upload images, logo, wording, and notes. WIZWIKI can use the AI postcard/art builder or in-house designers, you can request changes, and nothing prints until approval.",
      "The proof path runs through the checkout email after the order is complete. The design team sends the intake form there, collects images/artwork/logo files, can use the AI postcard/art builder, creates the proof, and waits for your approval before print."
    ]
  elsif logo_question?(inbound)
    [
      "You can use your logo. Complete the order first; after checkout, the design team sends an intake form to the checkout email. Upload your logo, images, wording, colors, notes, and files there; WIZWIKI can use the AI postcard/art builder or in-house designers if you need help. Nothing prints until you approve the proof.",
      "Your logo can go into the artwork. Complete the order first; after checkout, the design team emails an intake form for logo, images, wording, colors, notes, and artwork. The AI postcard/art builder or in-house designers can help from there; you approve the proof before print."
    ]
  elsif design_help_question?(inbound)
    [
      "You do not need a finished design before ordering. Complete the order first, then the design team sends the intake form to collect images, logo, wording, colors, and notes. WIZWIKI can clean up what you have or create the design with the AI postcard/art builder and in-house designers. Nothing prints until proof approval.",
      "A finished design is not required. Complete the order first; after checkout, upload images/artwork/logo and notes through the intake form, not by text. The team can use the AI postcard/art builder or in-house designers, you review the proof, and nothing prints until approval."
    ]
  else
    [
      "Artwork happens after checkout. Once the order is placed, the design team sends an intake form to the checkout email; upload images, logo, wording, colors, notes, and files there instead of texting them. WIZWIKI can use the AI postcard/art builder or in-house designers, then you review and approve the proof before anything prints.",
      "Complete the order first, then the design team sends an intake form to the checkout email. That is where images, logo, wording, colors, layout notes, and artwork go. WIZWIKI can use the AI postcard/art builder or in-house designers, and nothing prints until approval."
    ]
  end
  body = fallback_variant(pool)
  step = if route.to_s.present? && (shopify_link_already_sent?(route) || link_fit_ready?(route))
    if that_makes_sense_contextual?
      "If that answers the concern, checkout is the next step."
    else
      "If that covers the design question, checkout is the next step."
    end
  end

  enforce_sms_length([prefix, body, step].compact_blank.join(" ").squish)
end

def design_help_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(need|needs|required|require|have to|must|should|do i|can i|without|don't have|do not have|no)\b.*\b(design|artwork|art|logo|file|creative|layout)\b/) ||
    body.match?(/\b(design|artwork|art|logo|file|creative|layout)\b.*\b(need|needs|required|require|have to|must|should|do i|can i|without|don't have|do not have|no)\b/)
end

def artwork_creation_followup_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if art_pricing_or_discount_question?(body)
  return false if multiple_bundle_same_art_question?(body)
  return true if postcard_design_help_request?(body)
  return true if design_help_question?(body)
  return false unless recent_design_or_artwork_question?

  body.match?(/\b(?:i|we)\s+(?:need|want|have)\s+to\s+(?:create|make|build|design)\s+(?:it|that|this|one)\b/) ||
    body.match?(/\b(?:i|we)?\s*(?:don'?t|do not|dont|no|none|not)\s+(?:have|got)\s+(?:any\s+of\s+)?(?:those|that|these|it|one)\b/) ||
    body.match?(/\b(?:create|make|build|design)\s+(?:it|that|this|one)\b.*\b(?:help|can you|could you|wizwiki)\b/) ||
    body.match?(/\b(?:can|could)\s+you\s+help\b/) ||
    body.match?(/\b(?:yes|yeah|yep|please|sure)\b.*\b(?:help|create|make|build|design)\b/)
end

def postcard_design_help_request?(text)
  body = text.to_s.downcase.squish
  return false unless postcard_interest?(body) || body.match?(/\bpost\s*cards?|postcards?|mailer|mailers|direct mail|eddm\b/)

  body.match?(/\b(?:design|artwork|creative|make|create|help|generator)\b/)
end

def art_pricing_or_discount_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:discount|discounts|price break|cheaper|less expensive|lower price|credit|coupon|promo|special|deal|cost|price|pricing)\b/) &&
    body.match?(/\b(?:art|artwork|design|logo|file|files|creative)\b/)
end

def own_art_discount_question?(text)
  body = text.to_s.downcase.squish
  return false unless art_pricing_or_discount_question?(body)

  body.match?(/\b(?:own|already have|have my|have our|have the|supplied|provide|send|upload|ready|finished)\b.{0,80}\b(?:art|artwork|design|logo|file|files|creative)\b/) ||
    body.match?(/\b(?:art|artwork|design|logo|file|files|creative)\b.{0,80}\b(?:discount|price break|cheaper|less expensive|lower price|credit)\b/)
end

def veteran_discount_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:discounts?|price break|promo|promos|specials?|deal|deals?|coupon|coupons?)\b/)

  body.match?(/\b(?:vet|vets|veteran|veterans|military|service\s+member|service\s+members|active\s+duty|first\s+responder|first\s+responders)\b/)
end

def veteran_discount_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

    body.match?(/\b(?:not|no|don'?t|do not|doesn'?t|does not|isn'?t|is not)\b.{0,80}\b(?:vet|veteran|military|service\s+member|active\s+duty|first\s+responder)\b.{0,80}\b(?:discount|discounts?|special|promo|deal)\b/) ||
    body.match?(/\bnot a (?:vet|veteran) discount specifically\b/)
end

def veteran_discount_reply
  if defined?(Comms::CurrentSpecials) && Comms::CurrentSpecials.active? && Comms::CurrentSpecials.sms_line.present?
    return "Not a veteran discount specifically. The 4th of July postcard special is postcard-only: 1,000 postcards for $790. Want me to price that 1,000-postcard tier or compare the bigger postcard blocks?"
  end

  "Not a veteran discount specifically. The listed prices are the ones I can stand behind here. What product and quantity are you considering?"
end

def multiple_bundle_same_art_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:same|reuse|re-use|one)\b.{0,50}\b(?:art|artwork|design|logo|file|files|creative)\b/) ||
    body.match?(/\b(?:art|artwork|design|logo|file|files|creative)\b.{0,50}\b(?:same|reuse|re-use|one)\b/)

  body.match?(/\b(?:order|buy|checkout|quantity|qty|add|four|4|multiple|several|more than one|bundles?|units?|those)\b/)
end

def multiple_bundle_same_art_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:same|reuse|re-use|approved art|same art|same artwork)\b/) &&
    body.match?(/\b(?:checkout|intake|proof|order|quantity|unit|units|target)\b/)
end

def multiple_bundle_same_art_reply
  "You can use the same approved art across the run. Neighborhood Blitz is listed as a 500-home unit; if the page lets you set quantity 4, use that and note the 2,000-home target in intake. If not, the clean listed path is the closest available checkout quantity plus that note in intake."
end

def own_art_discount_reply
  "No automatic discount just for supplying your own art; the listed checkout price is still the price unless a specific special is shown. Your art does help the process: upload it in the intake/proof step after checkout and the same approved art can be used across the run. Larger-volume specials need a custom check so pricing stays accurate."
end

def design_support_route(text = nil)
  return "LAWN_SIGNS" if sign_interest?(text)

  route = current_route_code.to_s.presence
  non_product_route_code?(route) ? nil : route
end

def recent_design_or_artwork_question?
  recent_outbound_texts.first(4).any? do |message|
    body = message.to_s.downcase
    body.match?(/\b(?:artwork|art|design|logo|creative|file|files|intake|upload|images|colors|layout|proof|creating it|create it)\b/)
  end
end

def artwork_creation_help_reply(route = artwork_creation_route_for_inbound(latest_inbound_sms))
  if postcard_interest?(latest_inbound_sms) || route.to_s == "EDDM"
    return "WIZWIKI can create the postcard design with the AI postcard/art builder or in-house designers. Complete the order first; after checkout, the design team sends an intake form so you can upload images, wording, logo, and notes. You approve the proof before print."
  end

  case route.to_s
  when "PRO_PACK"
    "The Pro Pack includes design support. Complete the order first, then the design team sends the intake form so you can upload images, logo, and notes. WIZWIKI can use the AI postcard/art builder or in-house designers, you review the proof, and nothing prints until approval."
  when "STARTER_PACK"
    "The Starter Pack is the $299 bundle with 20 yard signs, 500 business cards, and 500 door hangers. It includes design support too: after checkout, the intake form collects your logo, images, and notes before proof approval."
  when "LAWN_SIGNS"
    "You don't need a finished design. Complete the order first, then the intake form collects your images/artwork. If you have artwork, we can use it or clean it up; if not, our AI postcard/art builder and in-house designers can create it. What quantity should I price for the signs?"
  else
    "Complete the order first, then the design team sends the intake form so you can upload images, logo, wording, and notes. WIZWIKI can use the AI postcard/art builder or in-house designers to create or clean up the artwork, you review the proof, and nothing prints until approval."
  end
end

def artwork_creation_route_for_inbound(text)
  body = text.to_s.downcase.squish
  return "PRO_PACK" if body.match?(/\bpro\s*pack\b/)
  return "STARTER_PACK" if body.match?(/\bstarter\s*(?:pack|bundle)\b/)
  return "EDDM" if postcard_interest?(body)
  return "LAWN_SIGNS" if sign_interest?(body)

  current_route_code.presence || recent_bundle_route_from_thread
end

def logo_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(logo|brand mark|wordmark)\b/)

  body.match?(/\b(can|could|do|does|will|would|need|use|send|upload|have|bring|include|put|place|file|format|png|pdf|svg|eps|ai)\b/) ||
    body.include?("?")
end

def logo_help_answer(route = current_route_code)
  if route.to_s == "LAWN_SIGNS"
    return "You can use your logo on the signs. Complete the order first; after checkout, the design team sends an intake form to the checkout email. Upload your logo, images, wording, colors, and sign notes there. PDF/vector is best if you have it. Nothing prints until proof approval."
  end

  "You can use your logo. Complete the order first; after checkout, the design team sends an intake form to the checkout email. Upload your logo, images, wording, colors, layout notes, and artwork there. A clean PNG, PDF, SVG, EPS, or AI file helps, but it is not a blocker. Nothing prints until proof approval."
end

def design_help_answer(route = current_route_code)
  if route.to_s == "LAWN_SIGNS"
    return "You don't need a finished design. Complete the order first, then the intake form collects your images/artwork. If you have artwork, we can use it or clean it up; if not, our AI postcard/art builder and in-house designers can create it. What quantity should I price for the signs?"
  end

  "You do not need a finished design before ordering. Complete the order first; after checkout, the intake form goes to the checkout email for images, logo, wording, colors, notes, and files. WIZWIKI has an easy-to-use AI postcard/art builder and design support, and nothing prints until proof approval."
end

def design_reply(route)
  return design_process_reply(route) if design_process_question?(latest_inbound_sms)

  answer = design_help_answer(route)
  return answer if route.to_s == "LAWN_SIGNS" && answer.include?("?")

  fit_question = next_route_fit_question(route)
  return [answer, fit_question].join(" ").squish if fit_question.present?
  return [answer, identity_collection_reply].join(" ").squish if identity_payload[:missing].present?
  return [answer, "If that answers the concern, checkout is the next step."].join(" ").squish if ready_for_handoff?(route)

  return answer if route.to_s == "LAWN_SIGNS" && campaign_fit_payload[:quantity_count].present?

  question = route.to_s == "LAWN_SIGNS" ? "How many signs are you thinking about for the first run?" : "Is the design for signs, postcards, door hangers, or a full campaign?"
  [answer, question].join(" ").squish
end

def logo_reply(route)
  return design_process_reply(route) if design_process_question?(latest_inbound_sms)

  answer = logo_help_answer(route)
  fit_question = next_route_fit_question(route)
  return [answer, fit_question].join(" ").squish if fit_question.present?
  return [answer, identity_collection_reply].join(" ").squish if identity_payload[:missing].present?
  return [answer, "If that answers the concern, checkout is the next step."].join(" ").squish if ready_for_handoff?(route)

  return answer if route.to_s == "LAWN_SIGNS" && campaign_fit_payload[:quantity_count].present?

  question = route.to_s == "LAWN_SIGNS" ? "How many signs are you thinking about for the first run?" : "Is the logo going on signs, postcards, door hangers, or a full campaign?"
  [answer, question].join(" ").squish
end

def bundle_composition_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if mixed_postcards_signs_question?(body)
  return true if mixed_postcards_signs_cards_question?(body)

  asks_contents = body.match?(/\b(how many|what(?:'s| is)? included|what do i get|what comes? with|what is in|what's in|in here|inside|included|only option|only choice)\b/)
  asks_fit = body.match?(/\b(better deal|better fit|worth it|make sense|should i|only need|only want|just need|just want|signs[-\s]?only|signs only)\b/)
  mentions_bundle = body.match?(/\b(starter\s*pack|pro\s*pack|pack|bundle|deal|better deal|bigger deal|signs?|yard signs?|lawn signs?|cards?|business cards?|door hangers?|hangers?)\b/)
  (asks_contents || asks_fit) && mentions_bundle
end

def bundle_composition_reply(text)
  return mixed_postcards_signs_reply if mixed_postcards_signs_question?(text)
  return mixed_postcards_signs_cards_reply if mixed_postcards_signs_cards_question?(text)

  route = bundle_composition_route(text)
  return bundle_signs_only_fit_reply(route) if signs_only_bundle_fit_question?(text)

  only_option = text.to_s.match?(/\b(only option|only choice|only one|is this it)\b/i)
  answer = bundle_composition_sentence(route)
  compare = bundle_alternate_sentence(route, only_option: only_option)
  [only_option ? "No, it is not the only option." : nil, answer, compare].compact_blank.join(" ").squish
end

def signs_only_bundle_fit_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  bundle_context = body.match?(/\b(?:starter\s*pack|pro\s*pack|pack|bundle|deal)\b/) ||
    recent_sms_context.match?(/\b(?:starter\s*pack|pro\s*pack|business\s+cards?|door\s+hangers?|bundle)\b/i)
  return false unless bundle_context

  body.match?(/\b(?:only|just)\s+(?:need|want)\s+(?:yard\s+)?signs?\b/) ||
    body.match?(/\bonly\b.{0,40}\b(?:care|need|want|looking)\b.{0,25}\b(?:yard\s+|lawn\s+)?signs?\b/) ||
    body.match?(/\b(?:yard\s+)?signs?\s+only\b|\bsigns[-\s]?only\b/)
end

def signs_only_bundle_context_route
  context = [recent_sms_context, full_recent_sms_context].compact.join(" ").downcase
  return nil if context.match?(/\bstarter\s*pack\b/) && context.match?(/\bpro\s*pack\b/)

  bundle_composition_route(context)
end

def bundle_signs_only_fit_reply(route)
  case route.to_s
  when "PRO_PACK"
    "If you only need yard signs, the Yard Signs package is the cleaner signs-only path. Pro Pack is $599 for 100 signs plus 1,000 business cards and 1,000 door hangers, so it is better only if you want those extra pieces too. Do you want signs-only or the full bundle?"
  when "STARTER_PACK"
    "If you only need yard signs, the Yard Signs package is the cleaner signs-only path. Starter Pack is $299 for 20 signs plus 500 business cards and 500 door hangers, so it makes sense only if you want those pieces too. Do you want signs-only or the bundle?"
  else
    "If you only need yard signs, use the Yard Signs package. Starter Pack ($299) and Pro Pack ($599) are bundles that add business cards and door hangers, so they fit better when you want those extra pieces too. Do you want signs-only or the bundle?"
  end
end

def mixed_postcards_signs_cards_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail)\b/)
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
  return false unless body.match?(/\b(?:business\s+cards?|cards?)\b/)

  body.match?(/\b(?:mixture|mix|combo|combined?|combination|both|also|and|with|do you do|have)\b/)
end

def mixed_postcards_signs_cards_reply
  "Yes. For postcards plus signs, Neighborhood Blitz is the combined local-visibility path. Business cards are in the fixed packs: Starter Pack is $299 with 20 yard signs, 500 business cards, and 500 door hangers; Pro Pack is $599 with 100 signs, 1,000 cards, and 1,000 door hangers. Are you wanting mail plus signs, or the cards bundle?"
end

def mixed_postcards_signs_cards_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|neighborhood blitz)\b/) &&
    body.match?(/\b(?:yard\s+signs?|signs?)\b/) &&
    body.match?(/\bbusiness\s+cards?\b/) &&
    body.match?(/\b(?:starter\s*pack|pro\s*pack)\b/) &&
    !body.match?(/\bneighborhood blitz\b.{0,80}\bbusiness\s+cards?\b/)
end

def mixed_postcards_signs_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if marketing_channel_comparison_question?(body)
  return false if body.match?(/\bbusiness\s+cards?\b/)
  return false unless body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail)\b/)
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)

  body.match?(/\b(?:mixture|mix|combo|combined?|combination|both|also|and|with|few|some)\b/)
end

def mixed_postcards_signs_reply
  "Yes. Neighborhood Blitz is the combined path when you want postcards for neighborhood reach and signs for job-area visibility. How many homes are you trying to reach?"
end

def mixed_postcards_signs_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|neighborhood blitz)\b/) &&
    body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|job-area visibility|signs?)\b/) &&
    body.match?(/\b(?:neighborhood blitz|combined|both|postcards? for neighborhood reach)\b/)
end

def mixed_postcards_signs_reply_sendable?(body)
  text = body.to_s.squish
  return false unless mixed_postcards_signs_question?(latest_inbound_sms)
  return false if text.blank? || text.length > MAX_SMS_CHARS
  return false if analysis_leak?(text) || repeated_recent_outbound?(text)

  mixed_postcards_signs_answer?(text) && customer_visible_question_present?(text)
end

def mixed_signs_cards_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if postcard_interest?(body)
  return false unless body.match?(/\b(?:business\s+cards?|cards?)\b/)
  return false unless sign_interest?(body) || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)

  body.match?(/\b(?:mix|combo|combined?|combination|both|with|and|also|do you sell|do you have|can i do|can we do)\b/)
end

def mixed_signs_cards_reply
  "Yes, you can do business cards with signs. The fixed mixed bundles are Starter Pack at $299 with 20 yard signs, 500 business cards, and 500 door hangers, or Pro Pack at $599 with 100 signs, 1,000 cards, and 1,000 door hangers. If you only want cards plus signs without hangers, a marketing consultant can map that out."
end

def mixed_signs_cards_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:business\s+cards?|cards?)\b/) &&
    body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) &&
    body.match?(/\bstarter\s*pack\b/) &&
    body.match?(/\$299\b/) &&
    body.match?(/\b20\s+(?:yard\s+)?signs?\b/) &&
    body.match?(/\b500\s+(?:business\s+)?cards?\b/) &&
    body.match?(/\bpro\s*pack\b/) &&
    body.match?(/\$599\b/) &&
    body.match?(/\b100\s+(?:yard\s+)?signs?\b/) &&
    body.match?(/\b1,?000\s+(?:business\s+)?cards?\b/)
end

def bundle_composition_answer?(text, inbound)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return mixed_signs_cards_answer?(body) if mixed_signs_cards_question?(inbound)
  return mixed_postcards_signs_answer?(body) if mixed_postcards_signs_question?(inbound)
  return mixed_postcards_signs_cards_answer?(body) if mixed_postcards_signs_cards_question?(inbound)

  if signs_only_bundle_fit_question?(inbound)
    return body.match?(/\byard\s+signs?\s+package\b|\bsigns[-\s]?only\b|\bsigns only\b/) &&
      body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/) &&
      body.match?(/\bbusiness\s+cards?\b/) &&
      body.match?(/\bdoor\s+hangers?\b/)
  end

  route = bundle_composition_route(inbound)
  case route.to_s
  when "PRO_PACK"
    body.match?(/\bpro\s*pack\b/) && body.match?(/\$599\b/) && body.match?(/\b100\s+(?:yard\s+)?signs?\b/) && body.match?(/\b1,?000\s+business\s+cards?\b/) && body.match?(/\b1,?000\s+door\s+hangers?\b/)
  when "STARTER_PACK"
    body.match?(/\bstarter\s*pack\b/) && body.match?(/\$299\b/) && body.match?(/\b20\s+(?:yard\s+)?signs?\b/) && body.match?(/\b500\s+business\s+cards?\b/) && body.match?(/\b500\s+door\s+hangers?\b/)
  else
    body.match?(/\byard\s+signs?\s+package\b|\bsigns[-\s]?only\b|\bsigns only\b/)
  end
end

def bundle_composition_route(text)
  body = text.to_s.downcase
  return "PRO_PACK" if body.match?(/\b(better deal|bigger deal|bigger bundle|better bundle|upgrade|pro\s*pack|pro[-\s]?pack|100\s+yard\s+signs?|1,?000\s+business\s+cards?|1,?000\s+door\s+hangers?)\b/)
  return "STARTER_PACK" if body.match?(/\bstarter\s*pack|starter[-\s]?pack|20\s+yard\s+signs?|500\s+business\s+cards?|500\s+door\s+hangers?\b/)

  recent_bundle_route_from_thread || current_route_code.presence || "STARTER_PACK"
end

def recent_bundle_route_from_thread
  Array(@metadata["sms_thread"]).last(10).reverse_each do |event|
    body = event.to_h["body"].to_s.downcase
    return "STARTER_PACK" if body.match?(/\bstarter\s*pack|starter-pack-bundle|20\s+yard\s+signs?|500\s+business\s+cards?|500\s+door\s+hangers?\b/)
    return "PRO_PACK" if body.match?(/\bpro\s*pack|pro-pack-bundle|100\s+yard\s+signs?|1,?000\s+business\s+cards?|1,?000\s+door\s+hangers?\b/)
  end

  nil
end

def bundle_composition_sentence(route)
  case route.to_s
  when "PRO_PACK"
    "The Pro Pack is $599 and includes 100 signs, 1,000 business cards, and 1,000 door hangers."
  when "STARTER_PACK"
    "The Starter Pack is $299 and includes 20 yard signs, 500 business cards, and 500 door hangers."
  when "LAWN_SIGNS"
    "The Yard Signs option is signs only; the bundle packs add business cards and door hangers."
  else
    "The Starter Pack includes 20 yard signs, 500 business cards, and 500 door hangers."
  end
end

def bundle_alternate_sentence(route, only_option: false)
  case route.to_s
  when "STARTER_PACK"
    only_option ? "Pro Pack is the bigger bundle, and the Yard Signs package is the signs-only path if you do not want cards or door hangers." : "If you only want signs, the Yard Signs package is separate."
  when "PRO_PACK"
    only_option ? "Starter Pack is the smaller bundle, and the Yard Signs package is the signs-only path." : "Starter Pack is the smaller bundle if you want to test first."
  when "LAWN_SIGNS"
    "Starter Pack is the smaller bundle if you also want cards and door hangers."
  end
end

def sign_interest?(text)
  text.to_s.match?(SIGN_INTEREST_PATTERN)
end

def business_card_interest?(text)
  text.to_s.match?(/\b(?:business|biz)\s+cards?\b/i)
end

def door_hanger_interest?(text)
  text.to_s.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/i)
end

def flyer_interest?(text)
  text.to_s.match?(/\bflyers?\b/i)
end

def handoff_owner_name
  value = @metadata["comms_routed_to_user_name"].to_s.squish.presence ||
    @metadata["comms_routed_to_user_first_name"].to_s.squish.presence
  return value if value.present?

  nil
end

def shopify_sentence(route)
  link = route_specific_shopify_link(route)
  return nil if link.blank?

  if fallback_shopify_link?(route, link)
    "Here are the current WIZWIKI checkout options: #{link}"
  elsif route.to_s == "BUSINESS_CARDS"
    "Here is the Business Cards checkout link: #{link}"
  elsif route.to_s == "DOOR_HANGERS"
    "Here is the Door Hangers checkout link: #{link}"
  elsif route.to_s == "FLYERS"
    "Here is the Flyers checkout link: #{link}"
  elsif route.to_s == "NEIGHBORHOOD_BLITZ"
    "Here is the Neighborhood Blitz checkout link: #{link} After checkout, the intake/proof form goes to the checkout email and nothing prints until approval."
  else
    "Here is the checkout link for that option: #{link}"
  end
end

def checkout_sentence(route)
  multi = shopify_link_menu_sentence(route)
  multi.presence || shopify_sentence(route)
end

def shopify_link_menu_sentence(route)
  return unless multi_product_link_menu_allowed?

  options = recommended_shopify_link_options(route)
  return if options.length < 2

  options = options.first(3)
  text = link_menu_text(options)
  if text.length > MAX_SMS_CHARS
    options = options.first(2)
    text = link_menu_text(options)
  end
  text
end

def multi_product_link_menu_allowed?
  fit = campaign_fit_payload
  return true if fit[:wants_both]
  return true if multi_product_link_request?(latest_inbound_sms)

  latest_inbound_sms.to_s.match?(/\b(?:both|combo|combined|compare|comparison|vs\.?|versus|postcards?.{0,40}signs?|signs?.{0,40}postcards?)\b/i)
end

def link_menu_text(options)
  parts = options.map { |option| "#{option[:label]}: #{option[:url]}" }
  "Here are the cleanest links to compare: #{parts.join(' ')}"
end

def recommended_shopify_link_options(route)
  codes = recommended_shopify_link_codes(route)
  seen = Set.new
  codes.filter_map do |code|
    url = route_specific_shopify_link(code)
    next if url.blank?
    next if fallback_shopify_link?(code, url)
    next if shopify_url_already_sent?(url)
    next unless seen.add?(url)

    { code: code, label: ROUTE_LABELS[code].presence || code.to_s.tr("_", " ").titleize, url: url }
  end
end

def recommended_shopify_link_codes(route)
  route = route.to_s
  fit = campaign_fit_payload
  wants_both = fit[:wants_both] || (fit[:wants_signs] && fit[:wants_postcards])

  if wants_both
    return [route, "NEIGHBORHOOD_BLITZ", "EDDM", "LAWN_SIGNS"].compact_blank.uniq
  end

  if route == "EDDM" && fit[:wants_signs]
    return ["EDDM", "LAWN_SIGNS", "NEIGHBORHOOD_BLITZ"]
  end

  if route == "LAWN_SIGNS" && fit[:wants_postcards]
    return ["LAWN_SIGNS", "EDDM", "NEIGHBORHOOD_BLITZ"]
  end

  []
end

def shopify_url_already_sent?(url)
  return false if url.blank?

  Array(@metadata["sms_thread"]).any? do |event|
    event = event.to_h
    event["direction"].to_s == "outbound" && event["body"].to_s.include?(url)
  end
end

def route_specific_shopify_link(route)
  route = route.to_s.presence
  return if route.blank?

  link = shopify_links[route].presence
  if link.present? && shopify_link_matches_route?(route, link)
    return if shopify_product_sold_out?(route)
    return link
  end

  metadata_link = @metadata["shopify_link"].presence
  if metadata_link.present? && @metadata["product_interest_code"].to_s == route && shopify_link_matches_route?(route, metadata_link)
    return if shopify_product_sold_out?(route)
    return metadata_link
  end

  fallback_shopify_link_for(route)
end

def fallback_shopify_link_for(route)
  return unless %w[EDDM NEIGHBORHOOD_BLITZ].include?(route.to_s)

  shopify_links["STORE"].presence
end

def fallback_shopify_link?(route, link)
  fallback = fallback_shopify_link_for(route)
  fallback.present? && link.to_s == fallback.to_s && shopify_links[route.to_s].blank?
end

def product_checkout_summary(route)
  route = route.to_s
  label = ROUTE_LABELS[route].presence || @metadata["processing_label"].presence || route.tr("_", " ").titleize
  [
    product_fit_intro(route),
    product_order_guidance(route, label),
    alternate_offer_sentence(route)
  ].compact_blank.join(" ").squish.presence || "I would start with #{label} based on what you shared."
end

def compact_product_checkout_summary(route)
  route = route.to_s
  fit = campaign_fit_payload
  quantity = fit[:quantity_count].to_s.squish.presence
  homes = fit[:household_count].to_s.squish.presence

  case route
  when "LAWN_SIGNS"
    quantity.present? ? "For #{quantity}, the Yard Signs package is the best fit." : "The Yard Signs package is the best fit for signs-only."
  when "STARTER_PACK"
    "Starter Pack is the tighter bundle: signs, cards, and door hangers."
  when "PRO_PACK"
    "Pro Pack is the bigger bundle for signs, cards, and door hangers."
  when "BUSINESS_CARDS"
    "Business Cards is the clean path if you only want cards."
  when "DOOR_HANGERS"
    "Door Hangers is the clean path if you only want hangers."
  when "FLYERS"
    "Flyers is the clean path if you only want flyers or handouts."
  when "EDDM"
    homes.present? ? "For #{homes}, EDDM is the postcard reach path." : "EDDM is the postcard reach path."
  when "NEIGHBORHOOD_BLITZ"
    "A neighborhood blitz is the fit for mail plus local visibility."
  else
    product_checkout_summary(route)
  end
end

def postcard_generator_sentence(route)
  route = route.to_s
  fit = campaign_fit_payload
  return unless route.in?(%w[EDDM NEIGHBORHOOD_BLITZ]) || fit[:wants_postcards] || fit[:wants_both]

  "If you need help designing the postcard artwork, our easy-to-use AI postcard/art builder can help shape the card."
end

def product_order_guidance(route, label)
  fit = campaign_fit_payload
  budget = numeric_budget_value(fit[:budget])
  households = numeric_household_value(fit[:household_count])
  quantity = numeric_quantity_value(fit[:quantity_count])

  case route.to_s
  when "PRO_PACK"
    if budget.present?
      "On the link page, I would order the Pro Pack for the bigger campaign."
    elsif households.present? && households >= 1_000
      "For that reach, I would order the Pro Pack."
    else
      "I would order the Pro Pack if you want the fuller neighborhood push."
    end
  when "STARTER_PACK"
    if budget.present?
      "On the link page, I would order the Starter Pack to keep the first run tighter."
    elsif households.present? && households < 1_000
      "For that first reach target, I would order the Starter Pack."
    else
      "I would order the Starter Pack if you want the cleanest first step."
    end
  when "BUSINESS_CARDS"
    "I would use the Business Cards checkout if cards are the main thing you need right now."
  when "DOOR_HANGERS"
    "I would use the Door Hangers checkout if hangers are the main thing you need right now."
  when "FLYERS"
    "I would use the Flyers checkout if flyers are the main thing you need right now."
  when "LAWN_SIGNS"
    return "I would use the Yard Signs link and keep the first run focused." if quantity.present?

    "I would order Yard Signs if signs are the main thing you need right now."
  when "EDDM"
    "I would start with the postcard/EDDM option if mailbox reach is the main goal."
  when "NEIGHBORHOOD_BLITZ"
    "I would start with a neighborhood blitz if you want postcards plus local visibility."
  else
    "I would start with #{label} based on what you shared."
  end
end

def alternate_offer_sentence(route)
  fit = campaign_fit_payload
  budget = numeric_budget_value(fit[:budget])
  households = numeric_household_value(fit[:household_count])

  case route.to_s
  when "STARTER_PACK"
    return "If you decide to go bigger, Pro Pack is the upgrade." if (budget.present? && budget >= 1_000) || (households.present? && households >= 1_000)
  when "PRO_PACK"
    return "If you want a lighter test first, Starter Pack is the alternate." if (budget.present? && budget < 1_000) || (households.present? && households < 1_000)
  when "BUSINESS_CARDS"
    return "If you also want signs and door hangers, Starter Pack or Pro Pack are the bundles to compare."
  when "DOOR_HANGERS"
    return "If you also want signs and cards, Starter Pack or Pro Pack are the bundles to compare."
  when "FLYERS"
    return "If the flyer size, quantity, or full print mix is still fuzzy, a marketing consultant can help map it out."
  when "LAWN_SIGNS"
    return "If you also want mail or door hangers, Starter Pack is the next bundle to compare." if fit[:wants_postcards] || fit[:wants_both]
  when "EDDM"
    return "If you want signs with the mailer, Starter Pack is worth comparing." if fit[:wants_signs] || fit[:wants_both]
  end

  nil
end

def post_link_follow_up_reply(text)
  body = text.to_s.downcase.squish
  route = current_route_code
  if pricing_question?(body)
    pricing = pricing_reply(body)
    return pricing if pricing.present?
  end

  return post_link_option_mismatch_reply(route) if product_option_mismatch?(body)
  return post_link_next_step_reply(route) if body.match?(/\b(what do i do|next|now what|how do i order|checkout|buy|purchase|set me up|get me set up|get started)\b/)
  return post_link_close_reply(route) if buyer_close_signal?(body)

  alt_route = alternative_route_from_text(body)
  return product_alternative_reply(route, alt_route) if alt_route.present?

  post_link_next_step_reply(route)
end

def buyer_close_signal?(text)
  text.to_s.match?(/\b(that works|that should work|sounds good|looks good|ok|okay|cool|perfect|great|yes|yep|yeah|sure|yes please|i'?ll do that|i will do that|let'?s do it|lets do it|send it|send the link|get me the link|let me get the link)\b/i)
end

def buyer_accepts_recent_recommendation?(route = nil)
  route = route.to_s.presence || accepted_recent_recommendation_route.to_s.presence || current_route_code.to_s
  return false if route.blank?
  return false unless buyer_close_signal?(latest_inbound_sms)
  return false if shopify_link_already_sent?(route)
  return false if checkout_sentence(route).blank?

  label = ROUTE_LABELS[route].presence || route.tr("_", " ").titleize
  route_words = route.tr("_", " ")
  recent_recommendation_texts.any? do |body|
    body = body.to_s.squish
    body.match?(/\b(?:would you like to proceed|proceed with this|checkout|bundle|package|best fit|good fit|right fit)\b/i) &&
      (
        body.match?(/\b#{Regexp.escape(label)}\b/i) ||
          body.match?(/\b#{Regexp.escape(route_words)}\b/i) ||
          accepted_recommendation_text_route(body).to_s == route ||
          (route == "NEIGHBORHOOD_BLITZ" && body.match?(/\bblitz\b/i))
      )
  end
end

def accepted_recent_recommendation_route
  return unless buyer_close_signal?(latest_inbound_sms)

  recent_recommendation_texts.filter_map do |body|
    next unless route_ready_recommendation_text?(body)

    accepted_recommendation_text_route(body)
  end.first
end

def accepted_recent_recommendation_quantity(route = accepted_recent_recommendation_route)
  route = route.to_s
  return if route.blank?

  recent_recommendation_texts.each do |body|
    body = body.to_s.squish
    next unless accepted_recommendation_text_route(body).to_s == route

    case route
    when "LAWN_SIGNS"
      quantity = body[/\b(\d{1,6})\s*(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i, 1]
      return quantity if quantity.present?
    when "EDDM", "NEIGHBORHOOD_BLITZ"
      quantity = body[/\b(\d{2,6})\s*(?:homes?|households?|doors?|postcards?)\b/i, 1]
      return quantity if quantity.present?
    end
  end

  nil
end

def recent_recommendation_texts
  if buyer_close_signal?(latest_inbound_sms) && !explicit_link_or_checkout_language?(latest_inbound_sms)
    return [latest_outbound_text_before_latest_inbound].compact_blank
  end

  recent_outbound_texts_before_latest_inbound.first(4).presence || recent_outbound_texts.first(4)
end

def explicit_link_or_checkout_language?(text)
  text.to_s.match?(/\b(?:send|text|share|give|get|checkout|check out|order|buy|purchase|product page)\b.{0,60}\blink\b|\blink\b.{0,60}\b(?:send|text|share|give|get|checkout|check out|order|buy|purchase|product page)\b|\b(?:checkout|check out|order|buy|purchase)\b/i)
end

def latest_outbound_checkout_prompt_route
  return unless buyer_close_signal?(latest_inbound_sms)

  checkout_prompt_route(latest_outbound_text_before_latest_inbound)
end

def latest_outbound_text_before_latest_inbound
  recent_outbound_texts_before_latest_inbound.first
end

def checkout_prompt_route(text)
  body = text.to_s.downcase.squish
  return if body.blank?
  return unless checkout_prompt_text?(body)

  accepted_recommendation_text_route(body)
end

def checkout_prompt_text?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:checkout|order|buy|purchase|product page)\s+links?\b|\blinks?\b.*\b(?:checkout|order|buy|purchase|product page)\b|\bcheckout\b.*\blinks?\b/)

  body.match?(/\b(?:want me to send|want the|send|share|text|give|get|let me get|can send|should i send|checkout link)\b/)
end

def accepted_recommendation_text_route(text)
  body = text.to_s.downcase.squish
  return if body.blank?
  return if ambiguous_product_menu_recommendation?(body)

  return "STARTER_PACK" if body.match?(/\bstarter\s*pack\b/)
  return "PRO_PACK" if body.match?(/\bpro\s*pack\b/)
  return "BUSINESS_CARDS" if body.match?(/\b(?:business cards?|business-card|business card)\b/)
  return "DOOR_HANGERS" if body.match?(/\b(?:door\s*hangers?|door-hanger|door hanger|doorhanger|hangers?)\b/)
  return "FLYERS" if body.match?(/\b(?:flyers?|flyer|handouts?)\b/)
  return "NEIGHBORHOOD_BLITZ" if body.match?(/\b(?:neighbou?rhood\s+blitz|main course|postcards?\s+plus\s+signs?|mail\s+plus\s+local visibility)\b/)
  return "EDDM" if body.match?(/\b(?:eddm|postcards?|direct mail|mail-only route|postcard mailing)\b/) && !body.match?(/\bsigns?\b/)
  return "LAWN_SIGNS" if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs-only|signs only|smallest\s+sign\s+package|sign\s+package|\d{1,6}\s+signs?)\b/)

  nil
end

def route_ready_recommendation_text?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:are you mailing|how many|what quantity|which count|which option|are you thinking|were you thinking|do you want .{0,40}\bor|would one route fit)\b.*\?/)

  body.match?(/\b(?:would you like to proceed|proceed with this|checkout|checkout link|order link|send .*link|want me to send|use this link|here is the checkout|best fit|good fit|right fit)\b/) ||
    body.match?(/\b(?:starter\s*pack|pro\s*pack|neighbou?rhood\s+blitz)\b/) && body.match?(/\b(?:bundle|package|deal|checkout|link|proceed)\b/)
end

def ambiguous_product_menu_recommendation?(body)
  text = body.to_s.downcase.squish
  return false if text.blank?
  return false if text.match?(/\b(?:checkout|checkout link|order link|send .*link|want me to send)\b/)

  product_count = [
    text.match?(/\bbusiness cards?\b/),
    text.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/),
    text.match?(/\bflyers?\b/),
    text.match?(/\bpostcards?\b/),
    text.match?(/\byard signs?\b/)
  ].count(true)

  product_count >= 3 && text.match?(/\b(?:besides|what else|other print|can help with|related campaign materials|which pieces)\b/)
end

def accepted_recommendation_without_link?(body)
  route = accepted_recent_recommendation_route.to_s.presence || current_route_code.to_s
  return false unless buyer_accepts_recent_recommendation?(route)

  text = body.to_s.squish
  return false if text.blank?
  return false if text.match?(%r{https?://}i)

  true
end

def alternative_route_from_text(text)
  body = text.to_s.downcase.squish
  return "PRO_PACK" if body.match?(/\b(pro pack|bigger|larger|more signs|more door hangers|more cards|scale|full push)\b/)
  return "STARTER_PACK" if body.match?(/\b(starter pack|bundle|cards?|business cards?|door hangers?|hangers?|smaller|test run)\b/)
  return "LAWN_SIGNS" if sign_interest?(body) || body.match?(/\bsigns? only\b/)
  return "EDDM" if body.match?(/\b(post\s*cards?|postcards?|mailers?|direct mail|eddm|mailboxes?|mailing)\b/)

  nil
end

def product_alternative_reply(current_route, alt_route)
  alt_route = alt_route.to_s
  return post_link_next_step_reply(current_route) if alt_route.blank? || alt_route == current_route.to_s

  case alt_route
  when "STARTER_PACK"
    [starter_pack_summary_sentence, shopify_sentence("STARTER_PACK"), "If you want signs only, stay with Yard Signs."].compact_blank.join(" ").squish
  when "PRO_PACK"
    [pro_pack_summary_sentence, shopify_sentence("PRO_PACK"), "If you want a smaller first run, Starter Pack is the lighter bundle."].compact_blank.join(" ").squish
  when "LAWN_SIGNS"
    [yard_signs_summary_sentence, shopify_sentence("LAWN_SIGNS"), "If you also want cards or door hangers, compare Starter Pack."].compact_blank.join(" ").squish
  when "EDDM"
    [compact_product_checkout_summary("EDDM"), postcard_generator_sentence("EDDM"), checkout_sentence("EDDM")].compact_blank.join(" ").squish
  else
    post_link_next_step_reply(current_route)
  end
end

def post_link_option_mismatch_reply(route)
  case route.to_s
  when "LAWN_SIGNS"
    "Good catch. The Yard Signs package is still the signs-only path; if the exact quantity is not listed, compare the nearest listed counts or #{handoff_owner_name || 'a WIZWIKI teammate'} can help set the right count by text. If you want cards or door hangers too, Starter Pack is the bundle to compare."
  when "STARTER_PACK"
    "The Starter Pack is a fixed smaller bundle. If that mix is not right, the closest comparisons are Yard Signs for signs only or Pro Pack for the bigger bundle."
  when "PRO_PACK"
    "The Pro Pack is the bigger fixed bundle. If that is more than you need, Starter Pack is the smaller bundle and the Yard Signs package is the signs-only path."
  else
    "Good catch. If that checkout option does not match what you need, the closest comparisons are Yard Signs, Starter Pack, and Pro Pack."
  end
end

def post_link_next_step_reply(route)
  context_question = business_context_question(route)
  if context_question.present?
    answer = case route.to_s
    when "LAWN_SIGNS"
      yard_signs_summary_sentence
    when "STARTER_PACK"
      starter_pack_summary_sentence
    when "PRO_PACK"
      pro_pack_summary_sentence
    else
      product_checkout_summary(route)
    end
    return [answer, context_question].compact_blank.join(" ").squish
  end

  case route.to_s
  when "LAWN_SIGNS"
    [yard_signs_summary_sentence, "If you want cards or door hangers too, Starter Pack is the bundle to compare."].join(" ").squish
  when "STARTER_PACK"
    [starter_pack_summary_sentence, "Use Starter Pack for the smaller bundle. If you only want signs, the Yard Signs package is the cleaner deal; if you want a bigger push, Pro Pack is the upgrade."].join(" ").squish
  when "PRO_PACK"
    [pro_pack_summary_sentence, "Use Pro Pack for the bigger bundle. If you want to test smaller first, Starter Pack is the lighter option."].join(" ").squish
  else
    "The three checkout paths are Yard Signs for signs only, Starter Pack for a smaller signs/cards/door-hangers bundle, and Pro Pack for the bigger bundle. Which one feels closest?"
  end
end

def post_link_close_reply(route)
  case route.to_s
  when "LAWN_SIGNS"
    "Sounds good. For signs only, stay with the Yard Signs link. If you decide you also want cards or door hangers, Starter Pack is the next option to compare."
  when "STARTER_PACK"
    "Sounds good. Starter Pack is the smaller bundle. If you decide you only need signs, use Yard Signs; if you want more volume, compare Pro Pack."
  when "PRO_PACK"
    "Sounds good. Pro Pack is the bigger bundle. If you decide you want a lighter first run, compare Starter Pack."
  else
    "Sounds good. If you want to compare before ordering, the main choices are Yard Signs, Starter Pack, and Pro Pack."
  end
end

def yard_signs_summary_sentence
  details = product_details_for_route("LAWN_SIGNS").to_h
  included = yard_sign_inclusion_sentence(details)
  ["Yep, we can help with yard signs.", included].compact_blank.join(" ").squish
end

def starter_pack_summary_sentence
  "Starter Pack includes 20 yard signs, 500 business cards, and 500 door hangers."
end

def pro_pack_summary_sentence
  "Pro Pack includes 100 yard signs, 1,000 business cards, and 1,000 door hangers."
end

def product_link_reply(reply, route: current_route_code)
  return reply unless link_fit_ready?(route)

  sentence = checkout_sentence(route)
  return reply if sentence.blank?
  return reply if shopify_link_already_sent?(route) && shopify_link_menu_sentence(route).blank?
  return reply if reply.to_s.include?(sentence)

  intro = compact_product_checkout_summary(route)
  clean_reply = reply.to_s.sub(/\AHappy to help\.\s*/i, "")
  [intro, postcard_generator_sentence(route), clean_reply, sms_customer_support_close, sentence].compact_blank.join(" ").squish
end

def focused_single_step_reply
  route = current_route_code
  return handoff_reply(route) if link_fit_ready?(route)
  company_question = quantity_company_follow_up(route)
  return company_question if company_question.present?
  return route_next_question(route) if route.present? && next_route_fit_question(route).present?
  return identity_collection_reply if route.present? || identity_payload[:missing].present?

  product_direction_question
end

def product_fit_intro(route)
  fit = campaign_fit_payload
  case route.to_s
  when "STARTER_PACK"
    if fit[:budget].present? && fit[:wants_both]
      "With #{fit[:budget]} and both signs plus local print, the Starter Pack looks like the closest fit."
    elsif fit[:household_count].present? && fit[:wants_both]
      "For #{fit[:household_count]} with signs plus local print, the Starter Pack looks like the closest fit."
    end
  when "PRO_PACK"
    if fit[:budget].present? && fit[:wants_both]
      "With #{fit[:budget]} and a bigger signs-plus-print push, the Pro Pack looks like the closest fit."
    elsif fit[:household_count].present? && fit[:wants_both]
      "For #{fit[:household_count]} with signs plus supporting print, the Pro Pack looks like the stronger fit."
    end
  when "BUSINESS_CARDS"
    "Business Cards look like the right fit." if business_card_interest?(latest_inbound_sms) || business_card_interest?(recent_sms_context)
  when "DOOR_HANGERS"
    "Door Hangers look like the right fit." if door_hanger_interest?(latest_inbound_sms) || door_hanger_interest?(recent_sms_context)
  when "FLYERS"
    "Flyers look like the right fit." if flyer_interest?(latest_inbound_sms) || flyer_interest?(recent_sms_context)
  when "LAWN_SIGNS"
    if fit[:quantity_count].present?
      "For #{fit[:quantity_count]}, the Yard Signs package looks like the best fit."
    elsif fit[:wants_signs]
      "The Yard Signs package looks like the best fit."
    end
  when "EDDM"
    "Postcards/EDDM look like the right fit." if fit[:wants_postcards]
  end
end

def shopify_link_already_sent?(route = current_route_code)
  link = route_specific_shopify_link(route)
  return false if link.blank?

  Array(@metadata["sms_thread"]).any? do |event|
    event = event.to_h
    event["direction"].to_s == "outbound" && event["body"].to_s.include?(link)
  end
end

def missing_location_reply
  if zip_present?
    return identity_collection_reply if identity_payload[:missing].present?
    return handoff_reply(current_route_code) if ready_for_handoff?(current_route_code)
    return route_next_question(current_route_code) if current_route_code.present?
  end

  location_url = location_capture_url
  if location_url.present?
    "Thanks. Use this secure link to share your ZIP so I can point you to the right mailing route: #{location_url}"
  else
    "Thanks. What ZIP or service area should I use?"
  end
end

def off_topic?(text)
      text.match?(/\b(oil|car|volvo|engine|tire|recipe|weather|sports|stock|bitcoin)\b/i)
    end

      def stop_intent?(text)
        return false if email_decline_response?(text)

        hard_sms_opt_out_intent?(text)
      end

      def hard_sms_opt_out_intent?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if body.match?(/\A(?:stop|unsubscribe|quit|end|cancel)\s*[.!]?\z/i)

        body.match?(/\b(?:unsubscribe|opt\s*-?\s*out|remove me|take me off)\b/i) ||
          body.match?(/\b(?:do not|don't|dont)\s+(?:text|message|contact|sms)\b/i) ||
          body.match?(/\b(?:stop|quit|end|cancel)\s+(?:texting|messaging|messages?|texts?|sms)\b/i)
      end

      def negative_answer_to_recent_expansion_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank? || body.include?("?")
        return false if hard_sms_opt_out_intent?(body)
        return false unless short_negative_scope_answer?(body)

        prompt = (recent_outbound_texts_before_latest_inbound.first.presence || recent_outbound_texts.first).to_s.downcase.squish
        prompt.match?(
          /\b(?:want|wanna|need|trying|looking|like)\b.{0,50}\b(?:reach|do|get|order|send|mail|cover)?\s*(?:more|bigger|larger|higher|additional)\b|\bwant to reach more\b/
        )
      end

      def short_negative_scope_answer?(text)
        body = text.to_s.downcase.squish
        return false if body.blank? || body.length > 80

        body.match?(/\A(?:no|nope|nah|not really|no thanks|no thank you)\b.*\b(?:enough|fine|good|works|ok|okay|all set)\b/) ||
          body.match?(/\A(?:no|nope|nah|not really|no thanks|no thank you)[\s.!]*\z/) ||
          body.match?(/\A(?:that'?s|thats|this is|one route is|1 route is).{0,30}\b(?:enough|fine|good|works|ok|okay)\b/)
      end

      def negative_scope_confirmation_reply
        context = [recent_sms_context, current_route_code].compact.join(" ").downcase
        if context.match?(/\b(?:eddm|post\s*cards?|postcards?|direct mail|mailboxes?|mailers?|route|homes?)\b/)
          price = bundle_price_text("EDDM").presence || "$399"
          return "Got it. One EDDM route is the #{price} path and usually reaches about 500-700 homes. Want the one-route checkout link?"
        end

        route = current_route_code
        return [compact_product_checkout_summary(route), "Want the checkout link for that option?"].compact_blank.join(" ").squish if route.present?

        "Got it. I will keep it to that scope. Want the checkout link for the option we just discussed?"
      end

      def customer_goodbye_intent?(text)
        text.to_s.match?(/\b(?:bye|goodbye|all set|that'?s all|nothing else|no more questions|i'?m good|we'?re good|thanks(?:,|\.|!|\s+that'?s all|\s+i'?m good))\b/i)
      end

      def customer_acknowledgment_no_reply?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if negative_answer_to_recent_expansion_question?(body)
        return false if body.include?("?")
        return false if body.match?(/\b(?:how|what|when|where|why|can|could|do|does|will|would|price|pricing|cost|quote|link|order|checkout|design|proof|upload|artwork|need|want|help|support|confused|understand)\b/)

      body.match?(/\A(?:thanks|thank you|thx|got it|ok|okay|sounds good|cool|perfect|great|awesome|appreciate it|i'?ll check (?:it|them) out|i will check (?:it|them) out|let me check|checking now|will do)[\s,.!]*(?:i'?ll check (?:it|them) out|i will check (?:it|them) out|checking now|will do|for now|thanks|thank you)?[\s.!]*\z/i)
    end

    def premature_closing_reply?(text)
      return false if customer_goodbye_intent?(latest_inbound_sms)

        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:nice to meet you|thank you for choosing|thanks for choosing|please let me know if you have any questions|let me know if you need anything else|need help with anything else|help with anything else|need anything else|anything else you need|anything else i can help|need more support|if questions come up|anything else i can get you|it was great chatting|great chatting)\b/)
      end

    def human_request?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false if body.match?(/\b(?:sales pitch|not a sales pitch|no sales pitch|like a real person|explain like a real person|sound human|human voice)\b/)
      return false if body.match?(/\b(?:artwork|art work|design|logo|creative|file|files|image|images|proof|screenshot)\b/) &&
        !body.match?(/\b(?:person|someone|rep|representative|account\s*manager|call|connect|contact|reach out|follow\s*up)\b/)

      body.match?(/\b(?:human|person|rep|representative|sales\s*(?:person|rep)|account\s*manager|manager|someone|team|owner)\b/) &&
        body.match?(/\b(?:talk|speak|call|connect|contact|reach|help|get|want|need|can|please)\b/)
    end

    def frustrated_or_support_pressure?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?

      body.match?(/\b(?:frustrated|upset|angry|annoyed|not helping|isn'?t helping|this isn'?t helping|you(?:'re| are)? not answering|not answering my question|still confused|still don'?t understand|still do not understand|still lost|need support|want support|support person)\b/)
    end

      def account_manager_answer_needed?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if human_request?(body)
        return true if checkout_handoff_needed?(body)
        return false if full_options_pricing_question?(body) || bundle_price_question?(body) || bundle_composition_question?(body)
        return false if bundle_inclusion_question?(body)
        return false if design_process_question?(body) && !design_process_handoff_needed?(body)
        return true if frustrated_or_support_pressure?(body) && explicit_support_handoff_request?(body)
        return false if outside_deal_quantity_pressure?(body)
      if pricing_question?(body)
        pricing = pricing_reply(body)
        return false if pricing.present?
      end
      return false if turnaround_question?(body) && turnaround_reply(body).present?
      return false unless body.include?("?") || body.match?(/\A(?:can|could|do|does|will|would|what|when|where|how|why|is|are)\b/)

      body.match?(/\b(guarantee|refund|cancel(?:lation)?|order status|invoice|financing|tax|file setup|bleed|material|installation|install|permit|contract|terms|legal)\b/) ||
        (product_option_mismatch?(body) && frustrated_or_support_pressure?(body))
    end

    def proof_handoff_request?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return true if design_process_handoff_needed?(body)
      return false if design_process_question?(body)

      body.match?(/\b(file setup|print[-\s]?ready|press[-\s]?ready|bleed|material|installation|install|permit|contract|terms|legal)\b/) ||
        (body.match?(/\b(complex|unusual|special case|custom setup)\b/) && body.match?(/\b(proof|logo|artwork|design|file|layout|order)\b/))
    end

    def product_option_mismatch?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return true if bundle_change_custom_request?(body)
      return true if outside_deal_quantity_pressure?(body)

      body.match?(/\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|where is|missing)\b.*\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b/) ||
        body.match?(/\b(?:option|quantity|qty|pack|bundle|link|checkout|product)\b.*\b(?:isn'?t|is not|aren'?t|are not|no|not|don'?t see|do not see|can'?t find|cannot find|missing)\b/) ||
        body.match?(/\b(?:option|quantity|qty|pack|bundle)\s+for\s+\d+\b/) ||
        body.match?(/\b\d+\s+(?:signs?|yard signs?|lawn signs?)\b.*\b(?:option|link|checkout|pack|bundle)\b/) ||
        body.match?(/\b(?:custom|different|specific)\s+(?:quantity|qty|amount|count|number)\b/)
    end

    def bundle_change_custom_request?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false if bundle_inclusion_question?(body)

      mentions_bundle_item = body.match?(/\b(?:starter\s*pack|pro\s*pack|pack|bundle|business\s*cards?|cards?|door\s*hangers?|hangers?|yard\s*signs?|lawn\s*signs?|signs?)\b/)
      asks_swap = body.match?(/\b(?:instead|swap|replace|trade|change|more|extra|less|fewer|don'?t need|do not need|without|rather than)\b/)
      asks_quantity_change = body.match?(/\b(?:can|could|do|does|would|will|is it possible|get|add|make)\b.*\b(?:more|extra|instead|swap|replace|without|custom)\b/)
      mentions_bundle_item && (asks_swap || asks_quantity_change)
    end

    def bundle_inclusion_question?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false unless body.match?(/\b(?:cost extra|included|include|same price|come with|comes with|what comes|what's included|whats included)\b/)
      return false unless body.match?(/\b(?:starter\s*pack|pro\s*pack|pack|bundle|business\s*cards?|cards?|door\s*hangers?|hangers?|yard\s*signs?|lawn\s*signs?|signs?)\b/)

      !body.match?(/\b(?:instead|swap|replace|trade|change|more|less|fewer|without|rather than|custom)\b/)
    end

    def outside_deal_quantity_pressure?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return true if body.match?(/\b(?:custom|specific|exact|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk)\b.*\b(?:quantity|qty|count|number|amount|price|pricing|quote|deal|package|pack|bundle)\b/)
      return true if body.match?(/\b(?:quantity|qty|count|number|amount|price|pricing|quote|deal|package|pack|bundle)\b.*\b(?:custom|specific|exact|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk)\b/)
      return true if body.match?(/\b(?:can|could|do|does|will|would|need|want|order|get|quote|price|cost|how much)\b.*\b\d{2,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i) && yard_sign_quantity_outside_deals?(body)
      return true if body.match?(/\b\d{2,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b.*\b(?:quote|price|cost|option|checkout|order|deal|special|bulk|custom|exact|available|listed)\b/i) && yard_sign_quantity_outside_deals?(body)
      return true if body.match?(/\b\d{2,6}\s*(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing)\b.*\b(?:quote|exact|custom|special|bulk|discount|deal|pricing)\b/i)

      false
    end

    def yard_sign_quantity_outside_deals?(text)
      quantities = requested_quantities(text)
      return false if quantities.blank?

      table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
      return true if table.blank?

      available = table.keys.map(&:to_i)
      quantities.any? { |quantity| available.exclude?(quantity.to_i) }
    end

      def outside_deal_quantity_handoff_reply
        fallback_variant([
          "That count looks outside the exact listed package quantities for self-checkout. The clean starting point is the closest standard bundle or listed Yard Signs quantity, and custom specials need an account-manager check so pricing stays accurate. Do you want the closest standard path?",
          "That quantity is off-menu, so I would start with the clean listed options: Starter Pack, Pro Pack, and the Yard Signs package by quantity. What quantity are you trying to land on?",
          "That is outside the standard checkout quantities for a confident text quote. Starter, Pro, and the listed Yard Signs package options are the clean comparison first. Which one feels closest?"
        ])
      end

      def custom_bundle_handoff_reply
        fallback_variant([
          "The Starter Pack checkout is a fixed bundle, so swapping cards for extra door hangers would need a custom setup. The standard packs are the clean comparison first; custom mix checks come after that if the listed bundles do not fit.",
          "That mix is outside the fixed Starter Pack checkout. The simple path is using the listed bundles as-is; a door-hanger-heavy setup needs a custom check so the pricing stays accurate.",
          "We can talk through that. The listed packs are fixed for self-checkout, so a changed mix needs custom setup. The standard options are still the clean first comparison."
        ])
      end

    def email_decline_response?(text)
      body = text.to_s.squish.downcase
      return true if body.match?(/\b(no email|don't email|do not email|not by email)\b/)
      return false unless email_opt_in_recently_requested?

      body.match?(/\b(no|nope|nah|not now|no thanks)\b/i)
    end

    def email_opt_in_recently_requested?
      recent_outbound_texts.any? do |body|
        body.match?(/\b(receive updates by email|want email|email too|by email too)\b/i)
      end
    end

    def current_route_code
      monitor_route = fresh_lane_monitor_route_code
      persisted_route = @metadata["product_interest_code"].presence
      persisted_route = nil if generic_route_code?(persisted_route)
      persisted_route = nil if discovery_reset_active?
      latest_route = latest_inbound_route_code
      latest_route = nil if generic_route_code?(latest_route)
      explicit_print_routes = explicit_standalone_print_routes(latest_inbound_sms)
      return budget_adjusted_route(explicit_print_routes.first) if explicit_print_routes.present?
      explicit_product_route = latest_explicit_product_route_from_thread
      return budget_adjusted_route(explicit_product_route) if explicit_product_route.present?

      accepted_route = accepted_recent_recommendation_route
      return budget_adjusted_route(accepted_route) if accepted_route.present?

      fit = campaign_fit_payload
      route = if latest_route_override?(monitor_route || persisted_route, latest_route)
        latest_route
      elsif fit[:wants_both] || fit[:wants_bundle]
        inferred_product_route_from_fit.presence || monitor_route || persisted_route || latest_route
      else
        monitor_route || persisted_route || latest_route
      end
      route ||= inferred_product_route_from_fit
      budget_adjusted_route(route)
    end

    def lane_monitor_payload
      @metadata["sms_lane_monitor"].to_h
    end

    def fresh_lane_monitor_route_code
      monitor = lane_monitor_payload
      route = monitor["route_code"].presence
      return if generic_route_code?(route)

      latest_body = latest_inbound_sms.to_s.squish
      monitor_latest = monitor["latest_body"].to_s.squish
      if latest_body.present? && monitor_latest.present? && latest_body != monitor_latest
        return
      end

      route
    end

    def latest_inbound_route_code
      return unless defined?(DealReports::CommsProcessingCode)

      body = latest_inbound_sms.to_s.squish
      return if body.blank?

      DealReports::CommsProcessingCode.classify(body, latest_body: body)
    end

    def generic_route_code?(route)
      non_product_route_code?(route)
    end

    def non_product_route_code?(route)
      route.to_s.in?(%w[PRODUCT_INTEREST CONTACT_OWNER CUSTOM_ARTWORK])
    end

    def latest_route_override?(persisted_route, latest_route)
      return false if latest_route.blank?
      return false if persisted_route.blank? || persisted_route == latest_route

      latest_inbound_sms.to_s.match?(/\b(what about|how about|instead|rather|only|just|combo|combined?|combination|both|post\s*cards?|postcards?|mailers?|eddm|direct mail|mailing|mail|reach|target|homes?|houses?|households?|doors?|addresses?|mailboxes?|yard signs?|lawn signs?|signs?|business cards?|door hangers?|hangers?|flyers?|handouts?|pro pack|starter pack|blitz|artwork|design)\b/i)
    end

def conversation_state
  route = current_route_code
  contact = conversation_contact_name
  company = conversation_company_name
  industry = industry_value
  missing = missing_discovery_fields
  known = {
    route: route.present?,
    product_interest: route.present?,
    contact_name: contact.present?,
    company_name: company.present?,
    industry: industry.present?
  }

  {
    route_code: route,
    route_label: ROUTE_LABELS[route.to_s].presence || @metadata["processing_label"],
    lane_monitor: lane_monitor_payload,
    contact_name: contact,
    company_name: company,
    industry: industry,
    business_context: business_context_value,
    campaign_fit: campaign_fit_payload,
    shopify_link: route_specific_shopify_link(route) || (route.blank? ? sendable_shopify_links["STORE"].presence : nil),
    known: known,
    missing_fields: missing,
    next_missing_field: missing.first,
    next_missing_prompt: next_missing_prompt(missing.first),
    contact_known: known[:contact_name],
    company_known: known[:company_name],
    industry_known: known[:industry],
    handoff_ready: ready_for_handoff?(route),
    autopilot_complete: completion_message_sent?,
    completion_message_sent: completion_message_sent?,
    routed_to: handoff_owner_name,
    recent_question: latest_outbound_question
  }.compact
end

def identity_display_value(value)
      return if generic_identity_value?(value)

      value.to_s.squish.presence
    end

    def current_zip_value
      @metadata.dig("location_capture_last", "postal_code").presence ||
        @metadata.dig("location_capture_last", "zip").presence ||
        Array(@metadata["sms_thread"]).filter_map { |event| event.to_h["body"].to_s[/\b\d{5}(?:-\d{4})?\b/] }.last
    end

def industry_value
  candidates = if discovery_reset_active?
    [
      @metadata.dig("comms_bot_state", "industry"),
      inferred_industry_from_thread
    ]
  else
    [
      @metadata["captured_industry"],
      @metadata["industry"],
      @metadata["company_industry"],
      @metadata["crm_industry"],
      @metadata["industry_strategy_label"],
      @metadata.dig("industry_strategy", "label"),
      @metadata.dig("industry_strategy", "industry"),
      @stage&.crm_record&.properties.to_h["industry"],
      @stage&.crm_record&.properties.to_h["hs_industry_group"],
      @stage&.crm_record&.properties.to_h["sms_captured_industry"],
      infer_industry_from_company_name(@metadata["captured_company_name"].presence || @metadata["company_name"].presence || @stage&.crm_record&.name),
      infer_industry_from_company_name(conversation_company_name),
      inferred_industry_from_thread
    ]
  end
  candidates.each do |candidate|
    value = normalize_industry(candidate)
    return value if value.present?
  end
  nil
end

def infer_industry_from_company_name(value)
  text = value.to_s.squish
  return if generic_identity_value?(text)

  INDUSTRY_COMPANY_KEYWORDS.each do |pattern, label|
    return label if text.match?(pattern)
  end
  nil
end

def industry_missing?
      industry_value.blank?
    end

def normalize_industry(value)
  text = value.to_s.tr("_", " ").squish
  return if text.blank?
  return if company_legal_suffix?(text)
  return if text.match?(/\A(auto|unknown|not provided|not set|n\/a|na|none|general|fallback)\z/i)
  return if text.match?(/\A(general )?local services?\z/i)

      text
    end

    def recent_inbound_text
      sms_thread_events.filter_map do |event|
        event = event.to_h
        next unless event["channel"].to_s == "sms" && event["direction"].to_s == "inbound"

        event["body"].to_s.squish.presence
      end.join("\n")
    end

    def latest_outbound_question
      recent_outbound_texts.find { |text| text.include?("?") }
    end

    def recently_asked?(question)
      normalized_question = normalize_for_compare(question)
      recent_outbound_texts.any? do |text|
        normalized = normalize_for_compare(text)
        normalized.include?(normalized_question) || normalized_question.include?(normalized)
      end
    end

    def recently_asked_identity?
      recent_outbound_texts.any? { |text| text.match?(/\b(what name|name should|company should|what company|what name and company)\b/i) }
    end

    def location_permission_recently_requested?
      recent_outbound_texts.any? { |text| text.match?(/\b(check where|zip codes? for shipping|share your zip|location)\b/i) }
    end

    def location_permission_accepted?(text)
      return false unless location_permission_recently_requested?

      text.match?(/\b(yes|yeah|yep|sure|ok|okay|go ahead|please do|send it)\b/i)
    end

    def zip_present?
      return true if @metadata.dig("location_capture_last", "postal_code").present?
      return true if @metadata.dig("location_capture_last", "zip").present?

      Array(@metadata["sms_thread"]).any? { |event| event.to_h["body"].to_s.match?(/\b\d{5}(?:-\d{4})?\b/) }
    end

    def sender_name
      @metadata.dig("sender_profile", "name").presence || @metadata["sender_name"].presence || @user&.display_name.to_s.presence || "WIZWIKI Marketing"
    end

    def sender_phone_number
      @metadata.dig("sender_profile", "phone").presence || @metadata["sender_phone"].presence || @user&.display_phone_number
    end

    def location_capture_url
      token = @metadata["location_capture_token"].to_s.presence
      return if token.blank?

      base_url = ENV["WIZWIKI_PUBLIC_URL"].presence || ENV["APP_HOST"].presence || "https://wizwiki.local"
      "#{base_url.to_s.chomp('/')}/comms/location/#{token}"
    end

    def rewrite_reason
      @operator_prompt.present? ? "Rebuilt from operator prompt." : "Fresh alternate rebuilt from CRM and COMM KIT context."
    end

    def sanitize_sms(value)
      raw_text = value.to_s
        .gsub(/[\u2010\u2011\u2012\u2212]/, "-")
        .gsub(/[\u2018\u2019]/, "'")
        .gsub(/[\u201C\u201D]/, '"')
        .gsub(/[\u00A0\u202F]/, " ")
        .sub(/\A```(?:json|text)?\s*/i, "")
        .sub(/\s*```\z/, "")
        .gsub(/\r\n?/, "\n")
      raw_text = strip_thinking_markup(raw_text)
      text = extract_sendable_sms_candidate(raw_text).presence || raw_text
      text = text
        .gsub(sms_answer_wrapper_prefix_pattern, "")
        .squish
      text = remove_yep_from_voice(text)
      text = remove_prompt_style_preface(text)
      text = remove_that_makes_sense_unless_contextual(text)
      text = customerize_sms_language(text)
      text = correct_fixed_bundle_price_mismatches(text)
      text = correct_yard_sign_price_mismatches(text)
      if postcard_special_quantity_only_followup?(latest_inbound_sms)
        return enforce_sms_length(postcard_large_quantity_followup_reply(latest_inbound_sms))
      end
      text = repair_unlinked_checkout_claim(text)
      if sold_out_shopify_link_in_text?(text)
        route = sold_out_shopify_route_in_text(text).presence || checkout_request_route(latest_inbound_sms).presence || current_route_code.presence
        return enforce_sms_length(sold_out_checkout_reply(route))
      end
      return "" if analysis_leak?(text)
      return guardrail_sms_text(text) if premature_closing_reply?(text)

      if current_open_customer_message_bodies.length >= 2 && misses_open_customer_messages?(text)
        stacked_reply = enforce_sms_length(stacked_open_messages_reply)
        if stacked_reply.present? && acceptable_sms_body?(stacked_reply, include_drafts: false)
          return stacked_reply
        end
      end

      if marketing_channel_comparison_question?(latest_inbound_sms)
        return enforce_sms_length(text) if marketing_channel_comparison_answer?(text)

        return enforce_sms_length(marketing_channel_comparison_reply)
      end

      if (numeric_reply = numeric_route_guardrail_reply(text)).present?
        return enforce_sms_length(numeric_reply)
      end

      if turnaround_question?(latest_inbound_sms)
        return enforce_sms_length(text) if turnaround_answer_for_inbound?(text, latest_inbound_sms)

        turnaround = turnaround_reply(latest_inbound_sms)
        return enforce_sms_length(turnaround) if turnaround.present?
      end

      if support_handoff_confirmation_request?(latest_inbound_sms)
        return enforce_sms_length(human_handoff_reply)
      end

      if direct_checkout_link_request?(latest_inbound_sms)
        direct_link = direct_checkout_link_reply(latest_inbound_sms)
        return enforce_sms_length(direct_link) if direct_link.present?
      end

      if yard_sign_included_items_question?(latest_inbound_sms)
        included = yard_sign_included_items_reply(latest_inbound_sms)
        return enforce_sms_length(included) if included.present?
      end

      if messy_print_consultant_question?(latest_inbound_sms)
        return enforce_sms_length(messy_print_consultant_reply)
      end

      if direct_mail_strategy_handoff_question?(latest_inbound_sms)
        return enforce_sms_length(direct_mail_strategy_handoff_reply)
      end

      if postcard_special_below_minimum_followup?(latest_inbound_sms)
        return enforce_sms_length(postcard_special_below_minimum_reply)
      end

      if postcard_special_quantity_followup?(latest_inbound_sms)
        return enforce_sms_length(postcard_special_quantity_followup_reply(latest_inbound_sms))
      end

      if standalone_print_product_quantity_followup?(latest_inbound_sms)
        return enforce_sms_length(standalone_print_product_quantity_reply(latest_inbound_sms))
      end

      if print_products_question?(latest_inbound_sms)
        return enforce_sms_length(print_products_reply)
      end

      if yard_sign_cheapest_package_question?(latest_inbound_sms)
        return enforce_sms_length(yard_sign_cheapest_entry_reply(latest_inbound_sms))
      end

      if unit_pricing_request?(latest_inbound_sms)
        reply = unit_pricing_reply(latest_inbound_sms)
        return enforce_sms_length(reply) if reply.present?
      end

      if postcard_minimum_path_question?(latest_inbound_sms)
        return enforce_sms_length(postcard_minimum_path_reply)
      end

      if explicit_support_handoff_request?(latest_inbound_sms) && !pricing_question?(latest_inbound_sms)
        return enforce_sms_length(human_handoff_reply)
      end

      if negative_answer_to_recent_expansion_question?(latest_inbound_sms)
        return enforce_sms_length(negative_scope_confirmation_reply)
      end

      if veteran_discount_question?(latest_inbound_sms)
        return enforce_sms_length(veteran_discount_reply)
      end

      if postcard_below_minimum_quantity_followup?(latest_inbound_sms)
        return enforce_sms_length(postcard_below_minimum_quantity_reply(latest_inbound_sms))
      end

      if current_specials_question?(latest_inbound_sms)
        return enforce_sms_length(current_specials_reply(latest_inbound_sms))
      end

      if cheapest_overall_pricing_question?(latest_inbound_sms)
        return enforce_sms_length(text) if cheapest_overall_pricing_answer?(text)
        return enforce_sms_length(cheapest_overall_pricing_reply(latest_inbound_sms))
      end

      if eddm_neighborhood_blitz_question?(latest_inbound_sms)
        return enforce_sms_length(text) if eddm_neighborhood_blitz_answer?(text)
        return enforce_sms_length(eddm_neighborhood_blitz_reply)
      end

      if starter_pro_compare_question?(latest_inbound_sms)
        return enforce_sms_length(bundle_compare_pricing_reply)
      end

      if checkout_confusion_question?(latest_inbound_sms)
        return enforce_sms_length(text) if checkout_confusion_answer?(text)
        return enforce_sms_length(checkout_confusion_reply(current_route_code))
      end

      if bundle_price_question?(latest_inbound_sms)
        direct_pricing = bundle_pricing_answer_for_guardrail(text)
        return enforce_sms_length(enforce_single_question(direct_pricing)) if direct_pricing.present?
      end

      if bundle_composition_question?(latest_inbound_sms)
        return enforce_sms_length(bundle_composition_reply(latest_inbound_sms))
      end

      if signs_only_options_question?(latest_inbound_sms)
        return enforce_sms_length(text) if yard_sign_options_answer_for_inbound?(text, latest_inbound_sms)

        pricing = yard_sign_pricing_reply(latest_inbound_sms)
        return enforce_sms_length(pricing) if pricing.present?

        return ""
      end

      if full_options_pricing_question?(latest_inbound_sms)
        return enforce_sms_length(standard_options_pricing_reply)
      end

      if standalone_zip_code?(latest_inbound_sms)
        return enforce_sms_length(zip_code_follow_up_reply(latest_inbound_sms))
      end

      if neighborhood_blitz_best_deal_request?(latest_inbound_sms)
        return enforce_sms_length(neighborhood_blitz_best_deal_reply)
      end

      if yard_sign_pricing_request?(latest_inbound_sms)
        return enforce_sms_length(text) if yard_sign_pricing_answer_for_inbound?(text, latest_inbound_sms)
        pricing = yard_sign_pricing_reply(latest_inbound_sms)
        return enforce_sms_length(pricing) if pricing.present?
      end

      if large_volume_request?(latest_inbound_sms) || outside_deal_quantity_pressure?(latest_inbound_sms)
        return enforce_sms_length(large_volume_standard_options_reply)
      end

      if own_art_discount_question?(latest_inbound_sms)
        return enforce_sms_length(own_art_discount_reply)
      end

      if multiple_bundle_same_art_question?(latest_inbound_sms)
        return enforce_sms_length(multiple_bundle_same_art_reply)
      end

      if ai_art_builder_question?(latest_inbound_sms)
        return enforce_sms_length(ai_art_builder_onboarding_reply)
      end

      if brand_explanation_question?(latest_inbound_sms)
        return enforce_sms_length(text) if brand_explanation_answer?(text)
        return enforce_sms_length(brand_explanation_reply)
      end

      if neighborhood_blitz_contents_question?(latest_inbound_sms)
        return enforce_sms_length(text) if neighborhood_blitz_contents_answer?(text)
        return enforce_sms_length(neighborhood_blitz_contents_reply)
      end

      if yard_signs_package_proof_question?(latest_inbound_sms)
        return enforce_sms_length(yard_signs_package_proof_reply)
      end

      if design_process_priority_question?(latest_inbound_sms)
        return enforce_sms_length(design_process_reply(current_route_code))
      end

      if postcard_design_help_request?(latest_inbound_sms)
        return enforce_sms_length(artwork_creation_help_reply("EDDM"))
      end

      if contact_context_question?(latest_inbound_sms)
        return enforce_sms_length(contact_context_reply)
      end

      if artwork_creation_followup_request?(latest_inbound_sms)
        return enforce_sms_length(artwork_creation_help_reply(artwork_creation_route_for_inbound(latest_inbound_sms)))
      end

      direct_text = prepare_deterministic_fallback_body(text)
      if direct_text.present?
        guarded_text = guardrail_sms_text(direct_text)
        return guarded_text if guarded_text.present? && guarded_text != direct_text && fallback_sms_sendable?(guarded_text)
        return direct_text if fallback_sms_sendable?(direct_text)
      end

      text = guardrail_sms_text(remove_latest_inbound_echo(text))
      text = DealReports::CommsStager.apply_sender_profile(text, sender_name, nil) if defined?(DealReports::CommsStager)
      text.gsub!(/\[(?:your name|sender name|name|your phone|sender phone|phone number|callback number)\]/i, "")
      text = remove_sender_phone(text)
      text = strip_url_trailing_punctuation(text)
      text = remove_prompt_style_preface(text)
      text = customerize_sms_language(text)
      text = correct_fixed_bundle_price_mismatches(text)
      text = correct_yard_sign_price_mismatches(text)
      text = text.sub(/\A[\s,;:\-]+/, "")
      text = avoid_identical_thread_response(text)
      text = enforce_single_question(text)
      text = enforce_first_outbound_opener(text)
      enforce_sms_length(text)
    end

    def strip_thinking_markup(value)
      value.to_s
        .sub(/\A\s*<think>.*?<\/think>\s*/mi, "")
        .sub(/\A\s*<\/think>\s*/i, "")
        .gsub(%r{</?think>}i, "")
        .strip
    end

    def extract_sendable_sms_candidate(raw_text)
      text = raw_text.to_s.strip
      return if text.blank?

      candidates = []
      candidates << text
      stripped_answer_wrapper = text.sub(sms_answer_wrapper_prefix_pattern, "").strip
      candidates << stripped_answer_wrapper if stripped_answer_wrapper.present? && stripped_answer_wrapper != text
      text.scan(/\A(?:(?:here(?:'|’)?s|here\s+is)\s+)?(?:the\s+)?(?:sendable\s+)?(?:(?:customer-facing|customer facing)\s+)?(?:sms|text|body|reply|draft|answer|message)(?:\s+body)?\s*:\s*["“]?(.+?)["”]?\s*\z/im) do |match|
        candidates << match.first
      end
      text.scan(/(?:sms|text|body|reply|draft)(?:\s+(?:should be|is))?\s*:\s*["“]?(.+?)(?:["”]?\s*(?:\n|$))/im) do |match|
        candidates << match.first
      end
      text.scan(/["“]([^"”]{18,900})["”]/m) do |match|
        candidates << match.first
      end
      candidates.concat(text.lines.map(&:strip).reject(&:blank?).reverse.take(8))

      inbound = normalize_draft_text(latest_inbound_sms.to_s)
      candidates.each do |candidate|
        body = candidate.to_s
          .sub(/\A(?:[-*]\s+|\d{1,2}[.)]\s+)/, "")
          .sub(sms_answer_wrapper_prefix_pattern, "")
          .squish
        next if body.blank?
        next if body.length > MAX_SMS_CHARS + 120
        next if analysis_leak?(body)
        next if internal_context_fragment?(body)
        next if normalize_draft_text(body) == inbound && inbound.present?

        return body
      end

      nil
    end

    def sms_answer_wrapper_prefix_pattern
      return Comms::SmsBodySafety::ANSWER_WRAPPER_PREFIX_PATTERN if defined?(Comms::SmsBodySafety::ANSWER_WRAPPER_PREFIX_PATTERN)

      /\A(?:(?:here(?:'|’)?s|here\s+is)\s+)?(?:the\s+)?(?:(?:best|strongest|recommended|suggested|cleanest|next|short|quick|final|sendable|customer[-\s]?facing|customer\s+ready)\s+)*(?:sms|text|body|reply|draft|answer|message)(?:\s+(?:sms|text|body|reply|draft|answer|message))*?(?:\s+(?:as|for|to\s+send\s+to|to)\s+[^:\n]{1,140})?\s*:\s*/i
    end

    def enforce_sms_length(text)
      body = text.to_s.squish
      return body if body.length <= MAX_SMS_CHARS

      route = current_route_code
      if link_fit_ready?(route)
        compact = handoff_reply(route)
        return compact if compact.present? && compact.length <= MAX_SMS_CHARS
      end

      focused = focused_single_step_reply
      return focused if focused.present? && focused.length <= MAX_SMS_CHARS && !similar_thread_response?(focused)

      trim_sms_at_boundary(body)
    end

    def trim_sms_at_boundary(text)
      body = text.to_s.squish
      return body if body.length <= MAX_SMS_CHARS

      trimmed = body[0, MAX_SMS_CHARS].to_s.sub(/\s+\S*\z/, "").sub(/[,\s;:.-]+\z/, "")
      trimmed.presence || body[0, MAX_SMS_CHARS].to_s
    end

    def enforce_first_outbound_opener(text)
      body = text.to_s.squish
      first = customer_first_name
      return body unless first_outbound_thread? && first.present?
      return body if body.match?(/\b#{Regexp.escape(first)}\b/i)

      opening_offer
    end

    def strip_url_trailing_punctuation(text)
      text.to_s.gsub(%r{https?://\S+}) do |url|
        url.sub(/[.,;:!?)]+\z/, "")
      end
    end

    def remove_sender_phone(text)
      phone = sender_phone_number.to_s
      digits = phone.gsub(/\D/, "")
      return text if digits.length < 7

      pattern_digits = digits.length == 11 && digits.start_with?("1") ? digits[1..] : digits
      flexible = pattern_digits.chars.map { |digit| Regexp.escape(digit) }.join("[^0-9]*")
      cleaned = text.to_s.gsub(/\b(?:\+?1[^0-9]*)?#{flexible}\b/, "")
      cleaned.gsub(phone, "").squish
    end

def guardrail_sms_text(text)
  inbound = latest_inbound_sms.to_s.squish
  return fallback_reply_to_inbound(inbound) if text.blank? || analysis_leak?(text)
  return fallback_reply_to_inbound(inbound) if premature_closing_reply?(text)
  if sold_out_shopify_link_in_text?(text)
    route = sold_out_shopify_route_in_text(text).presence || checkout_request_route(inbound).presence || current_route_code.presence
    return sold_out_checkout_reply(route)
  end

  if inbound.present?
    return missing_location_reply if location_permission_accepted?(inbound) && !zip_present?
    return fallback_reply_to_inbound(inbound) if off_topic?(inbound)
    return contact_context_reply if contact_context_question?(inbound)
    if (numeric_reply = numeric_route_guardrail_reply(text, inbound)).present?
      return numeric_reply
    end
    return fallback_reply_to_inbound(inbound) if double_discovery_ask?(text)
    return fallback_reply_to_inbound(inbound) if premature_identity_reply?(text, inbound)
    return fallback_reply_to_inbound(inbound) if missing_requested_product_context?(text, inbound)
    if turnaround_question?(inbound)
      return text if turnaround_answer_for_inbound?(text, inbound)
      turnaround = turnaround_reply(inbound)
      return turnaround if turnaround.present?
    end
    if support_handoff_confirmation_request?(inbound)
      return human_handoff_reply
    end
    if yard_sign_included_items_question?(inbound)
      included = yard_sign_included_items_reply(inbound)
      return included if included.present?
    end
    if yard_sign_cheapest_package_question?(inbound)
      return yard_sign_cheapest_entry_reply(inbound)
    end
    if unit_pricing_request?(inbound)
      reply = unit_pricing_reply(inbound)
      return reply if reply.present?
    end
    if postcard_minimum_path_question?(inbound)
      return postcard_minimum_path_reply
    end
    if explicit_support_handoff_request?(inbound) && !pricing_question?(inbound)
      return human_handoff_reply
    end
      if direct_checkout_link_request?(inbound)
        direct_link = direct_checkout_link_reply(inbound)
        return direct_link if direct_link.present?
      end
    if negative_answer_to_recent_expansion_question?(inbound)
      return negative_scope_confirmation_reply
    end
    if veteran_discount_question?(inbound)
      return text if veteran_discount_answer?(text)
      return veteran_discount_reply
    end
    if postcard_special_below_minimum_followup?(inbound)
      return text if postcard_special_below_minimum_answer?(text)
      return postcard_special_below_minimum_reply
    end
    if postcard_special_quantity_followup?(inbound)
      return postcard_special_quantity_followup_reply(inbound)
    end
    if postcard_below_minimum_quantity_followup?(inbound)
      return text if postcard_below_minimum_quantity_answer?(text, inbound)
      return postcard_below_minimum_quantity_reply(inbound)
    end
    if current_specials_question?(inbound)
      return text if current_specials_answer?(text)
      return current_specials_reply(inbound)
    end
    if cheapest_overall_pricing_question?(inbound)
      return text if cheapest_overall_pricing_answer?(text)
        return cheapest_overall_pricing_reply(inbound)
    end
        if checkout_confusion_question?(inbound)
          return text if checkout_confusion_answer?(text)
          return checkout_confusion_reply(current_route_code)
        end
    if eddm_neighborhood_blitz_question?(inbound)
      return text if eddm_neighborhood_blitz_answer?(text)
      return eddm_neighborhood_blitz_reply
    end
    if starter_pro_compare_question?(inbound)
      return bundle_compare_pricing_reply
    end
      if signs_only_options_question?(inbound)
        return text if yard_sign_options_answer_for_inbound?(text, inbound)

        pricing = yard_sign_pricing_reply(inbound)
        return pricing if pricing.present?

        return ""
      end
    if bundle_price_question?(inbound)
      direct_pricing = bundle_pricing_answer_for_guardrail(text)
      return direct_pricing if direct_pricing.present?
    end
    if bundle_composition_question?(inbound)
      return text if bundle_composition_answer?(text, inbound)
      return bundle_composition_reply(inbound)
    end
    if standalone_zip_code?(inbound)
      return text if zip_code_answer?(text, inbound)
      return zip_code_follow_up_reply(inbound)
    end
    if neighborhood_blitz_best_deal_request?(inbound)
      return text if neighborhood_blitz_best_deal_answer?(text)
      return neighborhood_blitz_best_deal_reply
    end
      if yard_sign_pricing_request?(inbound)
        return text if yard_sign_pricing_answer_for_inbound?(text, inbound)
        pricing = yard_sign_pricing_reply(inbound)
        return pricing if pricing.present?
      end
      if large_volume_request?(inbound) || outside_deal_quantity_pressure?(inbound)
        return text if large_volume_standard_options_answer?(text)
        return large_volume_standard_options_reply
      end
    if own_art_discount_question?(inbound)
      return own_art_discount_reply
    end
    if multiple_bundle_same_art_question?(inbound)
      return text if multiple_bundle_same_art_answer?(text)
      return multiple_bundle_same_art_reply
    end
    if ai_art_builder_question?(inbound)
      return text if ai_art_builder_answer?(text)
      return ai_art_builder_onboarding_reply
    end
    if postcards_only_pivot?(inbound)
      return text if postcards_only_pivot_answer?(text)
      return postcards_only_pivot_reply
    end
    if brand_explanation_question?(inbound)
      return text if brand_explanation_answer?(text)
      return brand_explanation_reply
    end
    if design_process_priority_question?(inbound)
      return text if design_process_answer?(text)
      return design_process_reply(current_route_code)
    end
    if artwork_creation_followup_request?(inbound)
      return text if artwork_creation_help_answer?(text) && !missing_requested_product_context?(text, inbound)
      return artwork_creation_help_reply
    end
    if signs_only_bundle_compare_question?(inbound)
      return text if signs_only_bundle_compare_answer?(text)
      return signs_only_and_bundle_options_reply
    end
    if mixed_postcards_signs_question?(inbound)
      return text if mixed_postcards_signs_answer?(text)
      return mixed_postcards_signs_reply
    end
    if mixed_postcards_signs_cards_question?(inbound)
      return text if mixed_postcards_signs_cards_answer?(text)
      return mixed_postcards_signs_cards_reply
    end
    if signs_only_pricing_question?(inbound)
      return text if yard_sign_pricing_answer_for_inbound?(text, inbound)
      return yard_sign_pricing_reply(inbound)
    end
    if pricing_question?(inbound)
      return text if pricing_answer_for_inbound?(text, inbound)
      pricing = pricing_reply(inbound)
      return pricing if pricing.present?
    end
    if neighborhood_blitz_contents_question?(inbound)
      return text if neighborhood_blitz_contents_answer?(text)
      return neighborhood_blitz_contents_reply
    end
    if yard_signs_package_proof_question?(inbound)
      return text if yard_signs_package_proof_answer?(text)
      return yard_signs_package_proof_reply
    end
    if eddm_neighborhood_blitz_question?(inbound)
      return text if eddm_neighborhood_blitz_answer?(text)
      return eddm_neighborhood_blitz_reply
    end
    if clarification_request?(inbound)
      return text if clarification_answer_for_inbound?(text, inbound)

      clarification = clarification_reply_for_context(inbound)
      return clarification if clarification.present?
    end
    return lane_answer_follow_up_reply if repeated_lane_question_after_lane_answer?(text)
    return text if llm_led_sms_keepable?(text)
    return design_process_reply(current_route_code) if design_process_question?(inbound) && !proof_handoff_request?(inbound)
  end

  text
end

def llm_led_sms_keepable?(text)
  body = text.to_s.squish
  return false if body.blank? || body.length > MAX_SMS_CHARS
  return false if yard_sign_price_conflict_for_guardrail?(body)
  return false if repeated_lane_question_after_lane_answer?(body)
  return false if analysis_leak?(body) || internal_context_fragment?(body)
  return false if premature_closing_reply?(body)
  return false if exact_recent_outbound?(body)
  return false if stale_latest_pivot_reply?(body)
  return false if missing_requested_product_context?(body, latest_inbound_sms)
  return true if price_only_pricing_answer_without_checkout_url?(body, latest_inbound_sms)
  return false if checkout_before_ready?(body) || link_ready_without_link?(body)
  return false if wrong_route_shopify_link?(body)
  return false if direct_checkout_link_request?(latest_inbound_sms) && checkout_request_route(latest_inbound_sms).present? && !body.match?(%r{https?://\S+}i)
  return false if unanswered_question_only_reply?(body)
  return false if double_discovery_ask?(body)

  true
end

def unanswered_question_only_reply?(body)
  return false unless direct_answer_required?(latest_inbound_sms)

  question_only_sms?(body)
end

def direct_answer_required?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.include?("?") ||
    pricing_intent?(body) ||
    body.match?(/\b(?:why|what|which|how do|how does|can you|can i|do i|does it|is that|same as|difference|included|comes with|come with|with it|i don'?t understand)\b/)
end

def large_volume_standard_options_reply
  inbound = latest_inbound_sms.to_s
  quantity = requested_quantities(inbound).max
  quantity_text = quantity.present? && quantity.positive? ? "#{format_quantity_count(quantity)} " : ""

  if postcard_interest?(inbound) && !sign_interest?(inbound)
    return "No automatic discount unless a specific special is listed. For #{quantity_text}postcards, the clean standard paths are EDDM for postcards only or Neighborhood Blitz if you want postcards plus local visibility. Larger-volume custom specials need a custom check so pricing stays accurate.".squish
  end

  if sign_interest?(inbound) && !postcard_interest?(inbound)
    return "No automatic discount unless a specific special is listed. For #{quantity_text}signs, start with the listed Yard Signs package quantities first. Anything beyond the listed quantities needs a custom check so pricing stays accurate.".squish
  end

  "Outside the listed packages, the clean comparison is Starter Pack at $299, Pro Pack at $599, and Yard Signs package options by listed quantity. Larger-volume custom specials need a custom check so pricing stays accurate."
end

def large_volume_standard_options_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.match?(/\b(?:postcards?|eddm|neighborhood blitz)\b/) &&
    body.match?(/\b(?:standard|listed|larger-volume|custom specials|automatic discount|specific special)\b/)
  return true if body.match?(/\b(?:yard signs?|signs?)\b/) &&
    body.match?(/\b(?:standard|listed|larger-volume|custom specials|automatic discount|specific special)\b/)
  return false if body.match?(/\$(?:299|599)\b/) && !body.match?(/\boutside|off-menu|custom|larger-volume|standard|listed\b/)

  body.match?(/\b(?:outside|off-menu|larger-volume|larger volume|standard|listed|self-checkout|do not want to invent|not invent|safely)\b/) &&
    body.match?(/\b(?:starter pack|pro pack|yard signs package|yard-sign|listed yard signs?)\b/) &&
    body.match?(/\b(?:custom pricing|custom specials|larger-volume pricing|pricing help)\b/)
end

def ai_art_builder_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:ai\s+art|ai\s+builder|art\s+builder|postcard\s+generator|ai\s+postcard)\b/) ||
    (postcard_interest?(body) && body.match?(/\b(?:make|create|design|build|help)\b/) && body.match?(/\b(?:ai|generator|builder)\b/))
end

def ai_art_builder_onboarding_reply
  fallback_variant([
    "The AI postcard/art builder can help start the postcard design, and in-house designers can clean it up. Complete checkout first; after the order, the intake form goes to the checkout email for images, logo, wording, colors, and notes. You review the proof, can request changes, and nothing prints until approval.",
    "WIZWIKI can use the AI postcard/art builder and in-house designers to create the design after checkout. Once you order, the intake form collects your images, logo, wording, colors, and notes; then you review the proof and approve it before anything prints.",
    "We can help create it with the AI postcard/art builder plus designer support. The order comes first, then the checkout-email intake form collects your files and notes. The team builds the proof, you can request changes, and nothing prints until you approve it."
  ])
end

def ai_art_builder_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:ai\s+postcard|ai\s+art|art builder|postcard\/art builder|postcard builder)\b/) &&
    body.match?(/\b(?:checkout|order)\b/) &&
    body.match?(/\b(?:intake|upload|logo|images?|wording|colors|notes|files)\b/) &&
    body.match?(/\b(?:proof|approve|approval|nothing prints)\b/)
end

def postcards_only_pivot?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless postcard_interest?(body) || body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/)
  return false if body.match?(/\b(?:do\s+not|don'?t|dont|no|not|isn'?t|is not|wasn'?t|was not|weren'?t|were not|without|instead of|rather than)\b.{0,80}\b(?:eddm|every door|direct mail|post\s*cards?|postcards?|mailers?|mailing)\b/)
  return false if body.match?(/\b(?:eddm|every door|direct mail|post\s*cards?|postcards?|mailers?|mailing)\b.{0,60}\b(?:do\s+not|don'?t|dont|no|not|isn'?t|is not|aren'?t|are not|without)\b/)

  body.match?(/\b(?:actually|just|only|instead|rather|rather than|instead of|not signs?|no signs?)\b/) ||
    body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\s+only\b/)
end

def postcards_only_pivot_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if stale_postcards_only_pivot_reply?(body)

  body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/) &&
    body.match?(/\b(?:mail|mailing|route|area|homes|households|checkout|order|proof|design|artwork|print)\b/)
end

def postcards_only_pivot_reply
  enforce_sms_length(
    fallback_variant([
      "If you want postcards only, EDDM postcards are the cleaner path. For 750 homes, we help pick the mailing area, you complete the postcard order, then the checkout-email intake/proof process handles artwork before anything prints. Do you want to keep it around 750 homes?",
      "For postcards only, I would move you out of the combined bundle and into the EDDM postcard path. You choose the mailing reach, place the postcard order, then the intake/proof flow handles artwork before print. Are you thinking right around 750 homes?",
      "Postcards only is simpler: use the EDDM postcard path, choose the homes or route you want to reach, then after checkout the design intake and proof process starts before anything prints. Do you want to keep the target at 750 homes?"
    ])
  )
end

def stale_latest_pivot_reply?(text)
  body = text.to_s.downcase.squish
  inbound = latest_inbound_sms.to_s.downcase.squish
  return false if body.blank? || inbound.blank?

  return true if postcards_only_pivot?(inbound) && stale_postcards_only_pivot_reply?(body)
  return true if repeated_lane_question_after_lane_answer?(body)
  return true if latest_customer_pivot?(inbound) && similar_thread_response?(body)

  false
end

def signs_only_reply_against_mail_or_both_intent?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:18x24|yard\s+signs?|lawn\s+signs?|signs?|stakes?)\b/)
  return false if body.match?(/\b(?:starter\s*pack|pro\s*pack|business\s+cards?|door\s+hangers?)\b/)
  return false if body.match?(/\b(?:eddm|post\s*cards?|postcards?|direct mail|mailboxes?|mail-only|mail route|neighborhood blitz|blitz|mail plus|mailboxes plus|both)\b/)

  fit = campaign_fit_payload
  customer_context = recent_customer_sms_context
  route = current_route_code.to_s
  wants_mail = fit[:wants_postcards] || fit[:wants_both] || route.in?(%w[EDDM NEIGHBORHOOD_BLITZ]) || postcard_interest?(customer_context)
  wants_both = fit[:wants_both] || route == "NEIGHBORHOOD_BLITZ" || customer_context.match?(/\b(?:both|combo|combined?|combination|mailboxes?.{0,80}signs?|signs?.{0,80}mailboxes?|postcards?.{0,80}signs?|signs?.{0,80}postcards?)\b/i)
  latest_signs_only = sign_interest?(latest_inbound_sms) && !postcard_interest?(latest_inbound_sms) && !latest_inbound_sms.to_s.match?(/\b(?:both|combo|combined?|combination)\b/i)
  return false if latest_signs_only

  wants_mail && wants_both
end

def misses_open_customer_messages?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  open_messages = current_open_customer_message_bodies
  return false if open_messages.length < 2

  open_messages.any? do |message|
    open_customer_message_answer_required?(message) && !answers_open_customer_message?(body, message)
  end
end

def current_open_customer_message_bodies
  open_messages = active_open_inbound_sms_events.filter_map { |event| event.to_h["body"].to_s.squish.presence }
  return [] if open_messages.blank?

  seen_messages = []
  open_messages.each_with_index.filter_map do |message, index|
    next if open_messages[(index + 1)..].to_a.any? { |later| open_message_superseded_by_later_pivot?(message, later) }

    normalized = message.downcase.squish
    next if seen_messages.include?(normalized)

    seen_messages << normalized
    message
  end
end

def stacked_open_messages_reply
  messages = current_open_customer_message_bodies
  return if messages.length < 2

  combined = messages.join(" ").squish
  return if combined.blank?

  reply = stacked_signs_specials_rush_reply(messages)
  return reply if reply.present?

  reply = stacked_rush_product_reply(messages)
  return reply if reply.present?

  reply = stacked_postcard_pivot_link_reply(messages)
  return reply if reply.present?

  reply = stacked_business_card_link_package_reply(messages)
  return reply if reply.present?

  reply = stacked_both_specials_print_reply(messages)
  return reply if reply.present?

  reply = stacked_postcard_specials_pivot_reply(messages)
  return reply if reply.present?

  reply = stacked_signs_only_specials_reply(messages)
  return reply if reply.present?

  if direct_mail_strategy_handoff_question?(combined)
    return direct_mail_strategy_handoff_reply
  end

  if messy_print_consultant_question?(combined)
    return messy_print_consultant_reply
  end

  if mixed_signs_cards_question?(combined)
    return mixed_signs_cards_reply
  end

  if print_products_question?(combined) && !pricing_question?(combined)
    return print_products_reply(combined)
  end

  reply = stacked_mixed_open_messages_reply(messages)
  return reply if reply.present?

  if human_request?(combined) && pricing_question?(combined)
    return price_then_handoff_reply(combined)
  end

  if human_request?(combined) || support_handoff_confirmation_request?(combined)
    return human_handoff_stack_reply
  end

  if sign_interest?(combined) && pricing_question?(combined)
    reply = stacked_yard_sign_process_reply(combined)
    return reply if reply.present?
  end

  nil
end

def stacked_signs_specials_rush_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 3
  return unless messages.any? { |message| sign_interest?(message) }
  return unless messages.any? { |message| current_specials_question?(message) || postcard_special_all_tiers_request?(message) || postcard_special_quantity_followup?(message) }
  return unless messages.any? { |message| turnaround_question?(message) || rush_checkout_boundary_question?(message) }

  special = if defined?(Comms::CurrentSpecials) && Comms::CurrentSpecials.active?
    line = if Comms::CurrentSpecials.respond_to?(:sms_line)
      Comms::CurrentSpecials.sms_line.to_s.squish.presence
    end
    line.present? ? "The active special is postcard-only: #{line}." : "The active special is postcard-only."
  else
    "I do not have an active special showing right now."
  end
  details = turnaround_details
  shipping = details[:shipping].to_s.squish.presence || "UPS/FedEx ground"
  body = [
    "Yard signs start at 10 for $99.",
    special,
    "Rush is handled through a marketing consultant before normal checkout; they confirm availability for your quantity and deadline.",
    "It starts after proof approval, moves production ahead, and shipping is still usually #{shipping}.",
    "What deadline do you need the signs by?"
  ].join(" ").squish
  body = enforce_sms_length(enforce_single_question(body))

  return unless messages.all? do |message|
    !open_customer_message_answer_required?(message) || answers_open_customer_message?(body, message)
  end

  body
end

def stacked_rush_product_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2
  return unless messages.any? { |message| turnaround_question?(message) || rush_checkout_boundary_question?(message) }

  context = messages.join(" ")
  products = []
  products << "business cards" if business_card_interest?(context)
  products << "door hangers" if door_hanger_interest?(context)
  products << "flyers" if flyer_interest?(context)
  products << "postcards" if postcard_interest?(context)
  products << "yard signs" if sign_interest?(context)
  products.uniq!
  return if products.blank?

  details = turnaround_details
  rush_window = details[:rush_print_window].to_s
    .sub(/\s+after proof approval(?:\s+when rush is available)?\z/i, "")
    .presence || "about 2-3 business days"
  quantity_label = products.one? ? "quantity" : "quantities"
  body = [
    "Rush may be available, and a marketing consultant needs to check the #{products.to_sentence} against your #{quantity_label} and deadline.",
    "It starts after proof approval, can move production to #{rush_window} when available, and shipping is still usually #{details[:shipping]}.",
    "What deadline are you working with?"
  ].join(" ").squish
  body = enforce_sms_length(enforce_single_question(body))

  return unless messages.all? { |message| !open_customer_message_answer_required?(message) || answers_open_customer_message?(body, message) }

  body
end

def stacked_signs_only_specials_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2
  return if messages.any? { |message| postcard_interest?(message) || both_mailboxes_and_signs_intent?(message) }
  return unless messages.any? { |message| sign_interest?(message) }

  specials_message = messages.reverse.find { |message| current_specials_question?(message) || postcard_special_all_tiers_request?(message) || postcard_special_quantity_followup?(message) }
  return if specials_message.blank?

  enforce_sms_length(enforce_single_question(current_specials_reply(specials_message)))
end

def stacked_mixed_open_messages_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2

  parts = []
  if messages.any? { |message| design_process_question?(message) || design_process_priority_question?(message) || proof_handoff_request?(message) }
    parts << "You do not need finished artwork. After checkout, the intake form collects your logo/artwork/notes, and you approve the proof before anything prints."
  end

  specials_message = messages.reverse.find { |message| current_specials_question?(message) || postcard_special_all_tiers_request?(message) || postcard_special_quantity_followup?(message) }
  parts << current_specials_reply(specials_message) if specials_message.present?

  pricing_message = messages.reverse.find { |message| pricing_intent?(message) && !current_specials_question?(message) }
  if pricing_message.present?
    pricing = pricing_reply(pricing_message)
    parts << pricing if pricing.present?
  end

  return if parts.length < 2

  body = parts.compact_blank.join(" ").squish
  enforce_sms_length(enforce_single_question(body))
end

def stacked_both_specials_print_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2

  wants_both = messages.any? { |message| both_mailboxes_and_signs_intent?(message) || combined_postcard_sign_interest?(message) }
  asks_specials = messages.any? { |message| current_specials_question?(message) || postcard_special_all_tiers_request?(message) || postcard_special_quantity_followup?(message) }
  wants_business_cards = messages.any? { |message| business_card_interest?(message) }
  return unless wants_both && asks_specials && wants_business_cards

  special = if defined?(Comms::CurrentSpecials) && Comms::CurrentSpecials.active?
    "The active special is postcard-only: #{Comms::CurrentSpecials.sms_line}"
  else
    "I do not have an active postcard special showing right now."
  end

  [
    "Yes, we can cover postcards/signs and business cards.",
    "Yard signs start at 10 for $99, and EDDM postcards start at $399.",
    special,
    "Business cards start at 250 for $70.",
    "Are you mailing homes too?"
  ].join(" ").squish
end

def stacked_business_card_link_package_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2

  wants_business_card_link = messages.any? do |message|
    body = message.downcase
    body.match?(/\b(?:biz\s*cards?|business\s+cards?|cards?)\b/) &&
      (direct_checkout_link_request?(message) || body.match?(/\b(?:need|send|share|text|give me|link|checkout)\b/))
  end
  wants_package_deals = messages.any? { |message| package_deals_question?(message) || bundle_price_question?(message) || bundle_composition_question?(message) }
  return unless wants_business_card_link && wants_package_deals

  link = route_specific_shopify_link("BUSINESS_CARDS").to_s.squish.presence ||
    "https://shop.example.invalid/products/business-cards"
  [
    "Business Cards checkout link: #{link}",
    "Package deals are Starter Pack at $299 with 20 yard signs, 500 business cards, and 500 door hangers, or Pro Pack at $599 with 100 signs, 1,000 business cards, and 1,000 door hangers."
  ].join(" ").squish
end

def package_deals_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:package|packages|bundle|bundles|pack|packs)\s+deals?\b/) ||
    body.match?(/\b(?:any|do you have|have any|what|which|compare|package|bundle|pack)\b.{0,40}\b(?:deals?|packages?|bundles?|packs?)\b/)
end

def open_customer_stack_link_answer_sendable?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || body.length > MAX_SMS_CHARS
  return false if analysis_leak?(body) || internal_context_fragment?(body)
  return false if sold_out_shopify_link_in_text?(body)
  return false if repeated_recent_outbound?(body)

  open_messages = current_open_customer_message_bodies
  return false if open_messages.length < 2

  link_messages = open_messages.select { |message| direct_checkout_link_request?(message) || multi_product_link_request?(message) }
  return false if link_messages.blank?
  return false unless link_messages.all? { |message| direct_checkout_link_answer_for_message?(body, message) }

  required_messages = open_messages.select { |message| open_customer_message_answer_required?(message) }
  required_messages.all? { |message| answers_open_customer_message?(body, message) }
end

def stacked_business_card_link_package_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || body.length > MAX_SMS_CHARS
  return false unless stacked_business_card_link_package_reply(current_open_customer_message_bodies).present?

  business_card_link = route_specific_shopify_link("BUSINESS_CARDS").to_s.downcase
  body.include?(business_card_link) &&
    body.match?(/\bstarter\s*pack\b.{0,120}\$299|\$299.{0,120}\bstarter\s*pack\b/) &&
    body.match?(/\bpro\s*pack\b.{0,120}\$599|\$599.{0,120}\bpro\s*pack\b/) &&
    body.match?(/\bbusiness\s+cards?\b/) &&
    body.match?(/\bdoor\s+hangers?\b/)
end

def stacked_yard_sign_process_reply(text)
  body = text.to_s.squish
  parts = []

  if veteran_discount_question?(body)
    parts << "I do not see a veteran discount listed."
  end

  if unit_pricing_request?(body)
    parts << "For a single sign, Yard Signs start at 10 for $99, about $9.90 per sign; there is not a single-sign order option."
  else
    quantity = yard_sign_pricing_quantity_for(body)
    return if quantity.blank? && parts.blank?

    if quantity.present?
      table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
      options = price_options_for_quantity(table, quantity)
      price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
      return if price.blank? && parts.blank?

      parts << "For #{format_quantity_count(quantity)} yard signs, you are at #{display_yard_sign_price(price)} with design help, stakes, and shipping included." if price.present?
    end
  end
  if design_process_question?(body) || proof_handoff_request?(body)
    parts << "After checkout, the intake form collects your logo/artwork/notes, and you approve the proof before anything prints."
  end
  if turnaround_question?(body) || rush_checkout_boundary_question?(body)
    parts << "Do not use the normal checkout for rush; a marketing consultant needs to confirm availability and pricing because it depends on quantity, timeline, and proof approval."
    parts << "Want me to have a marketing consultant check this with you?"
  elsif unit_pricing_request?(body)
    parts << "Want the 10-sign entry point, or are you thinking bigger?"
  end

  return if parts.blank?

  parts.join(" ").squish
end

def stacked_yard_sign_price_process_context_text
  open_messages = current_open_customer_message_bodies
  source = open_messages.length >= 2 ? open_messages : [latest_inbound_sms]
  source.compact.join(" ").squish
end

def stacked_yard_sign_price_process_context?
  body = stacked_yard_sign_price_process_context_text.downcase
  return false if body.blank?
  return false unless sign_interest?(body)
  return false if yard_sign_pricing_quantity_for(body).blank?
  return false unless pricing_intent?(body) || body.match?(/\b(?:how much|cost|price|pricing|quote|what do)\b/)

  design_process_question?(body) ||
    proof_handoff_request?(body) ||
    turnaround_question?(body) ||
    rush_checkout_boundary_question?(body)
end

def stacked_yard_sign_price_process_missing?(text)
  return false unless stacked_yard_sign_price_process_context?

  context = stacked_yard_sign_price_process_context_text
  quantity = yard_sign_pricing_quantity_for(context)
  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  options = price_options_for_quantity(table, quantity)
  price = options["double_sided_included"].presence || options["double_sided"].presence || options["price"].presence
  return false if price.blank?

  body = text.to_s.downcase.squish
  return true if body.blank?

  price_text = display_yard_sign_price(price).to_s
  price_pattern = Regexp.escape(price_text).gsub("\\ ", "\\s?")
  missing_price = !body.match?(/#{price_pattern}/i)
  needs_included = yard_sign_included_items_question?(context)
  needs_proof = proof_handoff_request?(context) || (design_process_question?(context) && !needs_included)
  missing_proof = needs_proof && !(proof_approval_answer?(body) || design_process_answer?(body))
  missing_included = needs_included && !(body.match?(/\b(?:design|design help)\b/) && body.match?(/\bstakes?\b/) && body.match?(/\bshipping\b/))
  needs_rush = turnaround_question?(context) || rush_checkout_boundary_question?(context)
  missing_rush = needs_rush && !turnaround_answer_for_inbound?(body, context)

  missing_price || missing_proof || missing_included || missing_rush
end

def stacked_postcard_specials_pivot_reply(messages)
  messages = Array(messages).map { |message| message.to_s.squish }.compact_blank
  return if messages.length < 2
  return unless messages.any? { |message| current_specials_question?(message) || postcard_special_all_tiers_request?(message) || postcard_special_quantity_followup?(message) }
  return unless messages.any? { |message| postcard_interest?(message) }

  reply = current_specials_reply(messages.join(" "))
  return if reply.blank?

  enforce_sms_length(enforce_single_question(reply))
end

def stacked_postcard_pivot_link_reply(messages)
  return unless current_postcard_special_active?
  return unless messages.any? { |message| direct_checkout_link_request?(message) }
  latest_pivot = messages.reverse.find { |message| superseding_customer_pivot_message?(message) && postcard_interest?(message) }
  return if latest_pivot.blank?

  quantity = postcard_special_quantity_from_text(latest_pivot) || requested_quantities(latest_pivot).select { |value| value >= 1_000 }.min
  return if quantity.blank?

  price = postcard_special_price_for_quantity(quantity)
  link = route_specific_shopify_link("EDDM").to_s.squish.presence
  return if price.blank? || link.blank?

  "For #{format_quantity_count(quantity)} postcards, the 4th of July postcard Block Sale is #{price}. Here is the checkout link: #{link}".squish
end

def superseding_customer_pivot_message?(message)
  body = message.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:actually|nevermind|never mind|scratch that|ignore that|forget that|instead|rather|rather than|prefer|change|switch|not that|not those|don'?t want|do not want)\b/) ||
    body.match?(/\b(?:just|only)\b/) && open_message_product_lane(body).present?
end

def open_message_superseded_by_later_pivot?(earlier_message, later_message)
  earlier_lane = open_message_product_lane(earlier_message)
  later_lane = open_message_product_lane(later_message)
  return false if earlier_lane.blank? || later_lane.blank?
  return false if earlier_lane == later_lane

  superseding_customer_pivot_message?(later_message)
end

def open_message_product_lane(message)
  body = message.to_s.downcase.squish
  return nil if body.blank?

  return "both" if both_mailboxes_and_signs_intent?(body)
  return "postcards" if postcard_interest?(body) || body.match?(/\b(?:eddm|direct mail|mailers?|mailboxes?|homes?|houses?|routes?|lists?)\b/)
  return "yard_signs" if sign_interest?(body) || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?)\b/)
  return "bundle" if body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/)
  return "print" if body.match?(/\b(?:business\s+cards?|door\s+hangers?|flyers?|rack\s+cards?|magnets?|print products?)\b/)

  nil
end

def bare_product_lane_selection_message?(message)
  body = message.to_s.downcase.squish
  return false if body.blank?
  return false if body.include?("?")
  return false if pricing_intent?(body) || current_specials_question?(body) || direct_checkout_link_request?(body) || multi_product_link_request?(body)

  body.match?(/\A(?:actually\s+|ok(?:ay)?\s+|please\s+)?(?:just\s+)?(?:post\s*cards?|postcards?|eddm|yard\s+signs?|lawn\s+signs?|signs?|business\s+cards?|door\s+hangers?|flyers?)(?:\s+only)?(?:\s+please)?[.!]*\z/)
end

def both_mailboxes_and_signs_intent?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.match?(/\b(?:signs?|yard signs?|lawn signs?)\b.{0,80}\b(?:postcards?|mailboxes?|mail|eddm|direct mail)\b/)
  return true if body.match?(/\b(?:postcards?|mailboxes?|mail|eddm|direct mail)\b.{0,80}\b(?:signs?|yard signs?|lawn signs?)\b/)
  return false unless body.match?(/\A(?:both|both please|both of those|both sounds good|both works)\b/)

  recent_outbound_texts.any? do |message|
    outbound = message.to_s.downcase
    outbound.match?(/\bmailboxes\b/) && outbound.match?(/\bsigns?\b/) && outbound.match?(/\bboth\b/)
  end
end

def open_customer_message_answer_required?(message)
  body = message.to_s.downcase.squish
  return false if body.blank?
  return false if bare_product_lane_selection_message?(body)

  both_mailboxes_and_signs_intent?(body) ||
    pricing_intent?(body) ||
    current_specials_question?(body) ||
    postcard_special_all_tiers_request?(body) ||
    postcard_special_quantity_followup?(body) ||
    direct_checkout_link_request?(body) ||
    multi_product_link_request?(body) ||
    package_deals_question?(body) ||
    bundle_price_question?(body) ||
    bundle_composition_question?(body) ||
    human_request?(body) ||
    support_handoff_confirmation_request?(body) ||
    design_process_question?(body) ||
    design_process_priority_question?(body) ||
    proof_handoff_request?(body) ||
    turnaround_question?(body) ||
    rush_checkout_boundary_question?(body) ||
    yard_sign_included_items_question?(body) ||
    mixed_signs_cards_question?(body) ||
    print_products_question?(body) ||
    messy_print_consultant_question?(body) ||
    direct_mail_strategy_handoff_question?(body) ||
    body.match?(/\b(?:how much|cost|price|pricing|total|quote)\b/) ||
    body.match?(/\b(?:what else|what other|options?|offer)\b/)
end

def answers_open_customer_message?(answer, message)
  inbound = message.to_s
  body = answer.to_s.downcase.squish
  return true if body.blank? || inbound.blank?

  if current_specials_question?(inbound) || postcard_special_all_tiers_request?(inbound) || postcard_special_quantity_followup?(inbound)
    return yard_sign_specials_answer?(body) || current_specials_answer?(body) || inactive_postcard_specials_answer?(body) || general_specials_answer?(body)
  end

  if both_mailboxes_and_signs_intent?(inbound)
    return body.match?(/\b(?:postcards?|mailboxes?|mail|eddm|direct mail|homes?)\b/) &&
      body.match?(/\b(?:yard signs?|lawn signs?|signs?)\b/)
  end

  if unit_pricing_request?(inbound)
    return unit_pricing_answer_for_inbound?(body, inbound)
  end

  if turnaround_question?(inbound) || rush_checkout_boundary_question?(inbound)
    return turnaround_answer_for_inbound?(body, inbound)
  end

  if direct_checkout_link_request?(inbound) || multi_product_link_request?(inbound)
    return direct_checkout_link_answer_for_message?(body, inbound)
  end

  if package_deals_question?(inbound) || bundle_price_question?(inbound) || bundle_composition_question?(inbound)
    return bundle_detail_pricing_answer?(body) ||
      body.match?(/\bstarter\s*pack\b.{0,160}\$299|\$299.{0,160}\bstarter\s*pack\b/) &&
        body.match?(/\bpro\s*pack\b.{0,160}\$599|\$599.{0,160}\bpro\s*pack\b/) &&
        body.match?(/\bbusiness\s+cards?\b/) &&
        body.match?(/\bdoor\s+hangers?\b/)
  end

  if inbound.match?(/\b(?:how much|cost|costs|price|pricing|total|quote)\b/i)
    return yard_sign_pricing_answer_for_inbound?(body, inbound) if sign_interest?(inbound) || pricing_route(inbound).to_s == "LAWN_SIGNS"
    return postcard_pricing_answer_for_inbound?(body, inbound) if postcard_interest?(inbound) || pricing_route(inbound).to_s == "EDDM"

    return pricing_answer_for_inbound?(body, inbound)
  end

  if design_process_question?(inbound) || design_process_priority_question?(inbound) || proof_handoff_request?(inbound)
    return proof_approval_answer?(body) || design_process_answer?(body) || artwork_creation_help_answer?(body)
  end

  if yard_sign_included_items_question?(inbound)
    return body.match?(/\b(?:design|design help)\b/) &&
      body.match?(/\bstakes?\b/) &&
      body.match?(/\bshipping\b/)
  end

  if mixed_signs_cards_question?(inbound)
    return mixed_signs_cards_answer?(body)
  end

  if print_products_question?(inbound)
    return print_products_answer_for_inbound?(body, inbound)
  end

  if messy_print_consultant_question?(inbound) || direct_mail_strategy_handoff_question?(inbound) || human_request?(inbound) || support_handoff_confirmation_request?(inbound)
    return print_products_answer_for_inbound?(body, inbound) && human_handoff_answer?(body) if messy_print_consultant_question?(inbound)

    return human_handoff_answer?(body)
  end

  if sign_interest?(inbound) && pricing_intent?(inbound)
    return yard_sign_pricing_answer_for_inbound?(body, inbound)
  end

  if postcard_interest?(inbound) && pricing_intent?(inbound)
    return postcard_pricing_answer_for_inbound?(body, inbound)
  end

  if full_options_pricing_question?(inbound) || inbound.match?(/\b(?:what else|what other|options?|offer)\b/i)
    return standard_options_pricing_answer?(body) ||
      body.match?(/\b(?:yard\s+signs?|postcards?|eddm|starter\s*pack|pro\s*pack|neighborhood\s+blitz)\b/)
  end

  true
end

def direct_checkout_link_answer_for_message?(answer, message)
  body = answer.to_s.downcase.squish
  return false if body.blank?
  return multi_product_link_answer_for_message?(body, message) if multi_product_link_request?(message)

  route = checkout_request_route(message)
  link = route_specific_shopify_link(route).to_s.downcase
  return false if route.blank? || link.blank?
  return false unless body.include?(link)
  return false if sold_out_shopify_link_in_text?(body)

  true
end

def multi_product_link_answer_for_message?(answer, message)
  body = answer.to_s.downcase.squish
  expected_links = multi_product_link_routes(message).first(3).filter_map { |route| route_specific_shopify_link(route).to_s.downcase.presence }
  return false if body.blank? || expected_links.length < 2

  expected_links.all? { |link| body.include?(link) }
end

def print_products_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  print_product_terms_present?(body) &&
    (
      body.match?(/\b(?:marketing consultant|consultant|sizes?|quantit(?:y|ies)|custom mix|standard paths|standalone|checkout paths?|starter\s*pack|pro\s*pack|can help)\b/) ||
      body.match?(/\$\s?\d{2,5}\b/)
    )
end

def latest_rush_or_turnaround_question?
  turnaround_question?(latest_inbound_sms) || rush_checkout_boundary_question?(latest_inbound_sms)
end

def latest_print_products_question?
  print_products_question?(latest_inbound_sms) || messy_print_consultant_question?(latest_inbound_sms)
end

def print_products_answer_for_inbound?(text, inbound)
  body = text.to_s.downcase.squish
  question = inbound.to_s.downcase.squish
  return false unless print_products_answer?(body)
  return false if body.match?(/\Afor\s+\d{1,6}\s+(?:yard\s+|lawn\s+)?signs?\b/)

  requested = requested_print_product_terms(question)
  requested = requested_print_product_terms(recent_sms_context) if requested.blank? && question.match?(/\b(?:those|these|that|all that|help me choose|person|consultant)\b/)
  requested.all? { |term| body.match?(print_product_term_pattern(term)) }
end

def requested_print_product_terms(text)
  body = text.to_s.downcase.squish
  terms = []
  terms << :business_cards if body.match?(/\bbusiness cards?\b/)
  terms << :door_hangers if body.match?(/\bdoor hangers?\b/)
  terms << :flyers if body.match?(/\bflyers?\b/)
  terms << :rack_cards if body.match?(/\brack cards?\b/)
  terms << :magnets if body.match?(/\bmagnets?|vehicle magnets?\b/)
  terms << :brochures if body.match?(/\bbrochures?\b/)
  terms.uniq
end

def print_product_term_pattern(term)
  case term
  when :business_cards then /\bbusiness cards?\b/
  when :door_hangers then /\bdoor hangers?\b/
  when :flyers then /\bflyers?\b/
  when :rack_cards then /\brack cards?\b/
  when :magnets then /\b(?:vehicle )?magnets?\b/
  when :brochures then /\bbrochures?\b/
  else /\bprint\b/
  end
end

def human_handoff_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  return true if body.match?(/\b(?:marketing consultant|consultant|teammate|team|person|someone|owner)\b/) &&
    body.match?(/\b(?:get|pass|connect|front of|follow[-\s]?up|reach out|best way for (?:them|someone|a consultant|our consultant) to reach|what(?:'s| is) the best way)\b/)

  false
end

def print_products_reply_sendable?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || body.length > MAX_SMS_CHARS
  return false unless print_products_question?(latest_inbound_sms) || messy_print_consultant_question?(latest_inbound_sms)
  return false if analysis_leak?(body) || premature_closing_reply?(body) || repeated_recent_outbound?(body)

  print_products_answer_for_inbound?(body, latest_inbound_sms)
end

def consultant_handoff_reply_sendable?(text)
  body = text.to_s.downcase.squish
  return false if body.blank? || body.length > MAX_SMS_CHARS
  return false unless human_request?(latest_inbound_sms) || support_handoff_confirmation_request?(latest_inbound_sms) || messy_print_consultant_question?(latest_inbound_sms) || direct_mail_strategy_handoff_question?(latest_inbound_sms)
  return false if analysis_leak?(body) || premature_closing_reply?(body) || repeated_recent_outbound?(body)
  return false if pricing_question?(latest_inbound_sms) && !pricing_answer_for_inbound?(body, latest_inbound_sms)
  if print_products_question?(latest_inbound_sms) || messy_print_consultant_question?(latest_inbound_sms)
    return false unless print_products_answer_for_inbound?(body, latest_inbound_sms)
  end

  human_handoff_answer?(body)
end

def recent_customer_sms_context
  Array(@metadata["sms_thread"]).last(8).filter_map do |event|
    event = event.to_h
    next unless event["direction"].to_s == "inbound"

    event["body"].to_s.squish.presence
  end.join(" ")
end

def latest_customer_pivot?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:actually|just|only|instead|rather|rather than|instead of|change|switch|not that|not those|don'?t want|do not want)\b/) &&
    body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|yard signs?|lawn signs?|signs?|starter pack|pro pack|bundle|blitz|artwork|design)\b/)
end

def latest_inbound_product_lane_answer?
  body = latest_inbound_sms.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\A(?:combo|both|both together|combined?|combination|post\s*cards?|postcards?|mailers?|eddm|direct mail|yard signs?|lawn signs?|signs?)\z/) ||
    body.match?(/\b(?:combo|both together|combined push|combine both|post\s*cards?.{0,40}signs?|signs?.{0,40}post\s*cards?)\b/)
end

def repeated_lane_question_after_lane_answer?(text)
  latest_inbound_product_lane_answer? && product_lane_selection_question?(text)
end

def lane_answer_follow_up_reply
  route = current_route_code.presence || latest_inbound_route_code.presence || inferred_product_route_from_fit
  route = "NEIGHBORHOOD_BLITZ" if route.blank? && latest_inbound_sms.to_s.match?(/\b(?:combo|both|combined?|combination)\b/i)
  return route_next_question(route) if route.present?

  "About how many homes or businesses are you trying to reach?"
end

def stale_postcards_only_pivot_reply?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:neighborhood blitz|neighbourhood blitz|main course|a-frames?|rack cards?|yard signs?|lawn signs?|signs package|signs-only|signs only)\b/)
end

def premature_identity_reply?(text, inbound)
  reply = text.to_s.downcase.squish
  latest = inbound.to_s.downcase.squish
  return false if reply.blank? || latest.blank?
  return false unless reply.match?(/\b(?:first name|your name|what name|company name|what company|business name)\b/)

  pricing_intent?(latest) ||
    latest.match?(/\b(?:include|included|business cards?|door hangers?|yard signs?|signs?|postcards?|artwork|proof|design)\b/)
end

def large_volume_request?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  quantity = quantity_candidates_without_zip_tokens(body, pattern: /\b\d{3,6}\b/).max.to_i
  return false if listed_yard_sign_quantity_request?(body, quantity)

  quantity >= 300 && body.match?(/\b(?:signs?|cards?|business\s+cards?|door\s+hangers?|pieces?|prints?)\b/)
end

def listed_yard_sign_quantity_request?(text, quantity = nil)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)

  quantity = nil if zip_code_quantity_token?(body, quantity.to_i)
  quantity = quantity.presence || quantity_candidates_without_zip_tokens(body, pattern: /\b\d{1,6}\b/).max.to_i
  quantity = [quantity.to_i, quantity_candidates_without_zip_tokens(body, pattern: /\b\d{1,6}\b/).max.to_i].max
  return false if quantity <= 0

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.blank?

  table.key?(quantity) || table.key?(quantity.to_s)
end

def quantity_candidates_without_zip_tokens(body, pattern:)
  explicit = requested_quantities(body)
  scanned = body.to_s.scan(pattern).map { |value| value.to_s.delete(",").to_i }
  (explicit + scanned)
    .select(&:positive?)
    .uniq
    .reject { |quantity| zip_code_quantity_token?(body, quantity) }
end

def zip_code_quantity_token?(body, quantity)
  token = quantity.to_i.to_s
  return false unless token.match?(/\A\d{5}\z/)

  escaped = Regexp.escape(token)
  return true if body.match?(/\b(?:zip|zipcode|zip\s+code|postal|area|market|location)\b.{0,24}\b#{escaped}\b/)
  return true if body.match?(/\b(?:in|near|around|serving|located\s+in|service\s+area)\s+#{escaped}\b/)

  explicit_budget_value(body).present? && !body.match?(/\b#{escaped}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|post\s*cards?|postcards?|mailers?|cards?|business\s+cards?|door\s+hangers?|pieces?|prints?)\b/)
end

def missing_requested_product_context?(text, inbound)
  body = text.to_s.downcase.squish
  latest = inbound.to_s.downcase.squish
  return true if latest.match?(/\bpro\s*pack\b/) && !body.match?(/\bpro\s*pack\b/)
  return true if latest.match?(/\bstarter\s*(?:pack|bundle)\b/) && !body.match?(/\bstarter\s*pack\b/)
  return true if postcard_interest?(latest) && !body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mail-only|mailing|route)\b/)

  false
end

def price_only_question_with_checkout_url?(text, inbound = latest_inbound_sms)
  body = text.to_s.squish
  return false if body.blank?
  return false unless body.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
  return false if direct_checkout_link_request?(inbound)

  price_only_pricing_question?(inbound)
end

def unsolicited_yard_sign_quantity_checkout_url?(text, inbound = latest_inbound_sms)
  body = text.to_s.squish
  latest = inbound.to_s.squish
  return false if body.blank? || latest.blank?
  return false unless body.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
  return false if direct_checkout_link_request?(latest)
  return false unless sign_interest?(latest) || pricing_route(latest).to_s == "LAWN_SIGNS" || current_route_code.to_s == "LAWN_SIGNS"

  quantity = exact_yard_sign_quantity_from_text(latest)
  quantity ||= requested_quantities(latest).then { |quantities| quantities.one? ? quantities.first : nil }
  return false if quantity.blank?
  return false unless latest.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i)

  body.include?(route_specific_shopify_link("LAWN_SIGNS").to_s) || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i)
end

def price_only_pricing_answer_without_checkout_url?(text, inbound = latest_inbound_sms)
  body = text.to_s.squish
  return false if body.blank?
  return false if body.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
  return false unless price_only_pricing_question?(inbound)

  yard_sign_pricing_answer_for_inbound?(body, inbound) ||
    postcard_pricing_answer_for_inbound?(body, inbound)
end

def price_only_pricing_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\b(?:links?|checkout|order|buy|purchase|ready|send|share|text me|where)\b/)

  pricing_or_options = body.match?(PRICING_INTENT_PATTERN) ||
    signs_only_options_question?(body) ||
    body.match?(/\b(?:what'?s|what is)\s+the\s+total\b/)
  return false unless pricing_or_options

  return true if postcard_interest?(body)
  body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) ||
    pricing_route(body).to_s == "LAWN_SIGNS" ||
    current_route_code.to_s == "LAWN_SIGNS" && body.match?(/\b\d{1,5}\b/)
end

def postcard_pricing_answer_for_inbound?(text, inbound = latest_inbound_sms)
  body = text.to_s.downcase.squish
  question = inbound.to_s.downcase.squish
  return false if body.blank? || question.blank?
  return false unless postcard_interest?(question) || pricing_route(question).to_s == "EDDM"
  return false unless body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mail-only|mail route|route|homes?)\b/)
  return false unless body.match?(/\$\s?(?:399|790|1,?725|3,?250|6,?300|14,?750)\b/)

  quantity = requested_quantities(question).max
  return true if quantity.blank?
  return body.match?(/\$\s?399\b/) if quantity < 1_000

  case quantity
  when 1_000 then body.match?(/\$\s?790\b/)
  when 2_500 then body.match?(/\$\s?1,?725\b/)
  when 5_000 then body.match?(/\$\s?3,?250\b/)
  when 10_000 then body.match?(/\$\s?6,?300\b/)
  when 25_000 then body.match?(/\$\s?14,?750\b/)
  else
    body.match?(/\$\s?\d/)
  end
end

def pricing_answer_for_inbound?(text, inbound)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if price_only_question_with_checkout_url?(body, inbound)
  return false if yard_sign_price_conflict_for_guardrail?(body)
  return false if missing_requested_product_context?(body, inbound)
  return veteran_discount_answer?(body) if veteran_discount_question?(inbound)
  return postcard_special_below_minimum_answer?(body) if postcard_special_below_minimum_followup?(inbound)
  return body.match?(/\b(?:postcards?|block\s+sale|direct mail|mail)\b/) && body.match?(/\$\s?790\b|\$\s?1,?725\b|\$\s?3,?250\b|\$\s?6,?300\b|\$\s?14,?750\b/) if postcard_special_quantity_followup?(inbound)
  return current_specials_answer?(body) if current_specials_question?(inbound)
  return body.match?(/\b10\b.{0,80}\$\s?99\b|\$\s?99\b.{0,80}\b10\b/i) if yard_sign_cheapest_package_question?(inbound)
  return cheapest_overall_pricing_answer?(body) if cheapest_overall_pricing_question?(inbound)
  return eddm_neighborhood_blitz_answer?(body) if eddm_neighborhood_blitz_question?(inbound)
  return bundle_detail_pricing_answer?(body) if starter_pro_compare_question?(inbound)
  return standard_options_pricing_answer?(body) if full_options_pricing_question?(inbound)
  return signs_only_bundle_compare_answer?(body) if signs_only_bundle_compare_question?(inbound)
  return unit_pricing_answer_for_inbound?(body, inbound) if unit_pricing_request?(inbound)
  return yard_sign_pricing_answer_for_inbound?(body, inbound) if yard_sign_pricing_request?(inbound)
  return yard_sign_pricing_answer_for_inbound?(body, inbound) if signs_only_pricing_question?(inbound)
  return yard_sign_options_answer_for_inbound?(body, inbound) if signs_only_options_question?(inbound)
  return bundle_detail_pricing_answer?(body) if bundle_price_question?(inbound)
  return yard_sign_budget_answer?(body) if yard_sign_budget_question?(inbound)
  return yard_sign_pricing_answer_for_inbound?(body, inbound) if pricing_route(inbound).to_s == "LAWN_SIGNS"

  body.include?("$") ||
    body.match?(/\b(?:price|pricing|cost|total|starts at|is included|are included|shipping included)\b/) ||
    large_volume_standard_options_answer?(body)
end

def unit_pricing_answer_for_inbound?(text, inbound = latest_inbound_sms)
  return false unless unit_pricing_request?(inbound)

  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if yard_sign_price_conflict_for_guardrail?(body)
  return false unless body.match?(/\$\s?\d/) || body.match?(/\b(?:per|each|works out|planning math)\b/)

  if sign_interest?(inbound) || current_route_code.to_s == "LAWN_SIGNS"
    return body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) &&
      body.match?(/\b10\b/) &&
      body.match?(/\$99\b/) &&
      body.match?(/\$9\.90\b|\bper\s+sign\b/)
  end

  if postcard_unit_pricing_context?(inbound) || postcard_interest?(inbound) || pricing_route(inbound).to_s == "EDDM"
    return body.match?(/\b(?:eddm|postcards?|postcard\/home|home\/postcard|mail-only|route)\b/) &&
      body.match?(/\$399\b/) &&
      body.match?(/\b(?:per\s+(?:postcard|home|home\/postcard|postcard\/home)|postcard\/home|home\/postcard|\$0\.57|\$0\.80)\b/)
  end

  if bundle_pack_interest?(inbound)
    return bundle_detail_pricing_answer?(body) || body.match?(/\b(?:starter\s*pack|pro\s*pack)\b/) && body.match?(/\$(?:299|599)\b/)
  end

  body.match?(/\b(?:per|each|works out|planning math)\b/) && body.match?(/\$\s?\d/)
end

def cheapest_overall_pricing_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if body.match?(/\bstarter\s*pack\b/) && body.match?(/\bpro\s*pack\b/)
  return false if body.match?(/\bneighborhood\s+blitz\b/) && body.match?(/\beddm\b/)
  return false if standard_options_pricing_answer?(body)
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
  return false unless body.match?(/\b(?:cheap(?:er|est)?|lowest|entry|starter|simple|smallest)\b/)

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  entry = lowest_yard_sign_deal_option(table)
  return false if entry.blank?

  body.match?(/\b#{Regexp.escape(entry[:quantity].to_s)}\b/) &&
    dollar_amounts(body).any? { |amount| amount.to_f.round(2) == entry[:amount].to_f.round(2) }
end

def current_specials_answer?(text)
  body = text.to_s.downcase.squish
  return false unless defined?(Comms::CurrentSpecials) && Comms::CurrentSpecials.active?

  if postcard_special_all_tiers_request?(latest_inbound_sms)
    tier_pairs = [
      [/\b(?:1,?000|1000|1k)\b/, /\$\s?790\b/],
      [/\b(?:2,?500|2500|2\.5k)\b/, /\$\s?1,?725\b/],
      [/\b(?:5,?000|5000|5k)\b/, /\$\s?3,?250\b/],
      [/\b(?:10,?000|10000|10k)\b/, /\$\s?6,?300\b/],
      [/\b(?:25,?000|25000|25k)\b/, /\$\s?14,?750\b/]
    ]
    return tier_pairs.all? { |quantity_pattern, price_pattern| body.match?(quantity_pattern) && body.match?(price_pattern) }
  end

  anchor = postcard_special_anchor_quantity(latest_inbound_sms)
  if anchor.present?
    return body.match?(/\bpostcards?\b/) &&
      body.match?(/\b(?:4th\s+of\s+july|july\s*4|block\s+sale|postcard\s+special)\b/) &&
      body.match?(Regexp.new(Regexp.escape(postcard_special_price_for_quantity(anchor))))
  end

  body.match?(/\b(?:4th\s+of\s+july|july\s*4)\b/) &&
    body.match?(/\bpostcards?\b/) &&
    body.match?(/\b(?:postcard-only|postcards?\s+only|only\s+(?:for\s+)?postcards?|postcard\s+special)\b/) &&
    body.match?(/\$790\b|\b1k\b|\b1,000\b/)
end

def inactive_postcard_specials_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  no_active_special = body.match?(/\b(?:do not|don't|dont|no)\b.{0,80}\b(?:active|current|running|available)?\s*(?:postcard\s+)?special/i)
  standard_eddm = body.match?(/\b(?:standard\s+)?eddm\b/) && body.match?(/\$399\b/)
  no_active_special || standard_eddm
end

def general_specials_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:listed packages|exact listed packages|starter\s+pack|pro\s+pack|yard signs? priced|larger-volume custom specials|custom specials|specific special|specific deal)\b/) &&
    body.match?(/\b(?:specials?|deals?|packages?|pricing|price|custom)\b/)
end

def yard_sign_specials_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
  return false unless body.match?(/\b(?:specials?|deals?|postcard-only|postcards?\s+only|listed\s+(?:yard\s+)?signs?\s+(?:package|deal|price)|priced\s+by\s+quantity)\b/)

  body.match?(/\$\s?(?:99|159|249|399|790|1,?699|3,?349)\b/) ||
    body.match?(/\b(?:priced\s+by\s+quantity|lowest\s+listed\s+yard\s+signs?\s+deal)\b/)
end

def yard_sign_options_answer_for_inbound?(text, inbound)
  return false unless signs_only_options_question?(inbound)

  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if signs_only_bundle_push?(body)
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
  return false unless body.match?(/\b(?:stakes?|shipping|design)\b/)

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.blank?

  yard_sign_option_tier_claims(body, table).length >= 3
end

def signs_only_bundle_compare_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.blank?

  yard_sign_option_tier_claims(body, table).length >= 3 &&
    body.match?(/\bstarter\s*pack\b/) && body.match?(/\$299\b/) &&
    body.match?(/\bpro\s*pack\b/) && body.match?(/\$599\b/)
end

def yard_sign_option_tier_claims(text, table)
  body = text.to_s.downcase.squish
  claims = []
  body.scan(/\b(\d{1,5})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)?\s*(?:are|is|for|at|=|:|-)?\s*\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
    claims << { quantity: quantity.to_i, amount: price.delete(",").to_f }
  end
  body.scan(/\$([\d,]+(?:\.\d{2})?)\s*(?:for|gets?|covers?|=|:|-)?\s*(\d{1,5})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)?/i) do |price, quantity|
    claims << { quantity: quantity.to_i, amount: price.delete(",").to_f }
  end

  claims
    .select { |claim| claim[:quantity].positive? && claim[:amount].positive? }
    .select { |claim| valid_yard_sign_price_for_quantity?(table, claim[:quantity], claim[:amount]) }
    .uniq { |claim| [claim[:quantity], claim[:amount].round(2)] }
end

def yard_sign_pricing_answer_for_inbound?(text, inbound)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.blank?
  return false if yard_sign_price_claim_conflicts?(body, table)

  claims = yard_sign_price_claims(body)
  return true if claims.present?

  quantity = yard_sign_pricing_quantity_for(inbound)
  amounts = dollar_amounts(body)
  if quantity.present? && amounts.any? { |amount| valid_yard_sign_price_for_quantity?(table, quantity, amount) }
    return true
  end

  entry = lowest_yard_sign_deal_option(table)
  entry.present? &&
    body.match?(/\b(?:lowest|cheapest|entry|special|deal|listed)\b/) &&
    body.match?(/\b#{Regexp.escape(entry[:quantity].to_s)}\b/) &&
    amounts.any? { |amount| amount.to_f == entry[:amount].to_f }
end

def yard_sign_price_claim_conflicts?(body, table)
  yard_sign_price_claims(body).any? do |claim|
    !valid_yard_sign_price_for_quantity?(table, claim[:quantity], claim[:amount])
  end
end

def yard_sign_price_claims(text)
  body = text.to_s.downcase.squish
  claims = []
  body.scan(/\b(?:for\s+)?(\d{1,5})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b[^$]{0,120}\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
    claims << { quantity: quantity.to_i, amount: price.delete(",").to_f }
  end
  body.to_enum(:scan, /\$([\d,]+(?:\.\d{2})?)[^$]{0,120}\b(?:for\s+)?(\d{1,5})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i).each do
    match = Regexp.last_match
    price = match[1].to_s
    quantity = match[2].to_s
    next if match[0].match?(/\$[\d,]+(?:\.\d{2})?\s*(?:per\s+sign|each|apiece|per\s+piece|per\s+unit)\b/i)

    claims << { quantity: quantity.to_i, amount: price.delete(",").to_f }
  end
  if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
    body.scan(/\b(\d{1,5})\s*(?:for|at)\s*\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
      claims << { quantity: quantity.to_i, amount: price.delete(",").to_f }
    end
  end

  claims.select { |claim| claim[:quantity].positive? && claim[:amount].positive? }.uniq
end

def dollar_amounts(text)
  text.to_s.scan(/\$([\d,]+(?:\.\d{2})?)/).flatten.map { |value| value.delete(",").to_f }.select(&:positive?)
end

def valid_yard_sign_price_for_quantity?(table, quantity, amount)
  options = price_options_for_quantity(table, quantity)
  return false if options.blank?

  valid_amounts = options.values.filter_map { |price| numeric_budget_value(price) }
  valid_amounts.any? { |valid| valid.to_f.round(2) == amount.to_f.round(2) }
end

def yard_sign_budget_answer?(text)
  body = text.to_s.downcase.squish
  body.match?(/\$100 gets you about 10 yard signs/) &&
    body.match?(/\byard signs package\b/) &&
    body.match?(/\bstakes\b/) &&
    body.match?(/\bshipping\b/) &&
    body.match?(/\bdesign\b/)
end

def standard_options_pricing_answer?(text)
  body = text.to_s.downcase.squish
  return false unless body.match?(/\bstarter\s*pack\b/) &&
    body.match?(/\bpro\s*pack\b/) &&
    body.match?(/\byard\s*signs?\b/) &&
    body.match?(/\$299\b/) &&
    body.match?(/\$599\b/)

  table = product_details_for_route("LAWN_SIGNS").to_h[:price_table].to_h
  return false if table.present? && yard_sign_option_tier_claims(body, table).length < 3

  expected = standard_options_pricing_reply.to_s.downcase
  if expected.match?(/\bneighborhood\s+blitz\b[^.?!]{0,80}\$\s?\d/)
    return false unless body.match?(/\bneighborhood\s+blitz\b[^.?!]{0,80}\$\s?\d|\$\s?\d[^.?!]{0,80}\bneighborhood\s+blitz\b/)
    return false unless body.match?(/\b(?:500[-\s]?home|500\s+homes|mail[-\s]?plus[-\s]?visibility|local visibility|visibility push)\b/)
  end

  if expected.match?(/\beddm\b[^.?!]{0,80}\$\s?\d/)
    return false unless body.match?(/\beddm\b[^.?!]{0,80}\$\s?\d|\$\s?\d[^.?!]{0,80}\beddm\b/)
    return false unless body.match?(/\b(?:one\s+mail[-\s]?only\s+route|one\s+route|500[-\s]?700\s+homes|500\s+to\s+700\s+homes|route)\b/)
  end

  true
end

def turnaround_answer_for_inbound?(text, inbound)
  body = text.to_s.downcase.squish
  inbound_body = inbound.to_s.downcase.squish
  return false if incorrect_rush_timing_claim?(body)

  if rush_timing_question?(inbound_body) && !rush_checkout_boundary_question?(inbound_body)
    return false if body.match?(%r{https?://})

    consultant = body.match?(/\b(?:marketing consultant|consultant|person|someone|teammate|team)\b/) &&
      body.match?(/\b(?:confirm|check|availability|pricing|connect|reach out|get|handled|follow[-\s]?up)\b/)
    process = body.match?(/\b(?:proof approval|proof is approved|after proof|after the proof|proof)\b/) &&
      body.match?(/\b(?:production|queue|ahead)\b/) &&
      body.match?(/\b(?:shipping|ups|fedex|ground|2\s*to\s*5|2-5)\b/)

    return consultant && process
  end

  if rush_checkout_boundary_question?(inbound_body)
    boundary = body.match?(/\b(?:correct|no|not|do not|don'?t|should not|shouldn'?t|avoid|outside|instead)\b.{0,120}\b(?:normal|standard|regular|checkout|check\s+out)\b/) ||
      body.match?(/\b(?:normal|standard|regular)\b.{0,40}\b(?:checkout|check\s+out)\b.{0,80}\b(?:not|avoid|rush|outside|consultant)\b/) ||
      body.match?(/\boutside\b.{0,80}\b(?:checkout|standard|normal|regular)\b/) ||
      body.match?(/\brush\b.{0,80}\b(?:handled|needs?|goes|should)\b.{0,80}\b(?:marketing consultant|consultant|outside|before)\b.{0,80}\b(?:normal|standard|regular|checkout|check\s+out)\b/) ||
      body.match?(/\b(?:marketing consultant|consultant)\b.{0,80}\b(?:before|instead of|outside)\b.{0,80}\b(?:normal|standard|regular|checkout|check\s+out)\b/)
    consultant = body.match?(/\b(?:marketing consultant|consultant|person|someone|teammate|team)\b/) &&
      body.match?(/\b(?:confirm|check|availability|pricing|connect|reach out|get|handled)\b/)
    process = body.match?(/\b(?:proof approval|proof is approved|after proof|after the proof|proof)\b/) &&
      body.match?(/\b(?:production|queue|ahead)\b/) &&
      body.match?(/\b(?:shipping|ups|fedex|ground|2\s*to\s*5|2-5)\b/)

    return boundary && consultant && process
  end

  body.match?(/\b(?:business days?|production|proof|approval|shipping|rush|timeline|turnaround)\b/)
end

def incorrect_rush_timing_claim?(text)
  body = text.to_s.downcase.squish
  return false unless body.match?(/\b(?:rush|rushed)\b/)
  return true if body.match?(/\b(?:rush|rushed)(?:\s+printing)?\b[^.?!]{0,100}\b(?:adds?|adding)\b[^.?!]{0,60}\b\d+(?:\s*(?:-|to)\s*\d+)?\s+business days?\b/)

  range = body.match(/\b(?:move|moves|cut|cuts|reduce|reduces)\s+(?:print\s+)?production\s+to\s+(?:about\s+)?(\d+)\s*(?:-|to)\s*(\d+)\s+business days?\b/)
  return range[1].to_i != 2 || range[2].to_i != 3 if range.present?

  body.match?(/\b(?:move|moves|cut|cuts|reduce|reduces)\s+(?:print\s+)?production\s+to\s+(?:about\s+)?\d+\s+business days?\b/)
end

def artwork_included_bundle_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  body.match?(/\b(?:pro\s*pack|starter\s*pack|pack|bundle)\b/) &&
    body.match?(/\b(?:design|artwork|art)\b/) &&
    body.match?(/\b(?:included|includes|ready|help creating|help create|creating it|create it)\b/) &&
    body.match?(/\b(?:do you have|would you like|should wizwiki|need help|artwork ready)\b/)
end

def artwork_creation_help_answer?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return false if bundle_artwork_answer_wrong_for_current_lane?(body)
  return true if artwork_included_bundle_answer?(body) && artwork_proof_reassurance?(body)

  body.match?(/\b(?:yes|we can|wizwiki can|the team can|design team)\b/) &&
    body.match?(/\b(?:create|make|build|design|artwork|logo|creative)\b/) &&
    body.match?(/\b(?:logo|brand|files?|start from scratch|artwork ready|upload|intake)\b/) &&
    artwork_proof_reassurance?(body)
end

def bundle_artwork_answer_wrong_for_current_lane?(text)
  body = text.to_s.downcase.squish
  return false unless body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/)

  inbound = latest_inbound_sms.to_s.downcase.squish
  return false if inbound.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/)
  return false unless current_route_code.to_s == "LAWN_SIGNS" || sign_interest?(inbound)

  design_process_question?(inbound) || artwork_creation_followup_request?(inbound) || proof_handoff_request?(inbound)
end

def artwork_proof_reassurance?(text)
  text.to_s.downcase.match?(/\b(?:proof|intake|approve|approval|nothing prints|before print|before anything prints)\b/)
end

def avoid_identical_thread_response(text)
  body = text.to_s.squish
  return body if body.blank?
  return body if (design_process_question?(latest_inbound_sms) || artwork_creation_followup_request?(latest_inbound_sms)) && artwork_creation_help_answer?(body)
  return body if direct_checkout_link_request?(latest_inbound_sms)
  return body if product_contents_question?(latest_inbound_sms)
  return body unless repetitive_thread_response?(body)

  if bundle_change_custom_request?(latest_inbound_sms) || bundle_change_custom_request?(body)
    handoff = custom_bundle_handoff_reply
    return handoff if handoff.present? && !repetitive_thread_response?(handoff)
  end

  situation = stale_situation_alternate
  return situation if situation.present? && !repetitive_thread_response?(situation)

  candidates = if current_route_code.to_s == "LAWN_SIGNS"
    [
      "About how many signs do you want to start with?",
      "I can price the signs cleanly once I know the rough count.",
      "I can point you to the right sign option once I know the rough sign count."
    ]
  else
    [
      "I can narrow this down quickly. Roughly how many homes should I use to point you to the right option?",
      "I can compare the options cleanly once I know the rough count.",
      "I can send a few useful options, but I want to point you to the right one. Are you thinking a smaller test run or a bigger push?"
    ]
  end

  candidates.map { |candidate| strip_url_trailing_punctuation(candidate.to_s.squish) }
    .find { |candidate| candidate.present? && !similar_thread_response?(candidate) && candidate.length <= MAX_SMS_CHARS } ||
    body
end

def exact_recent_outbound?(text)
  normalized = normalize_draft_text(text)
  return false if normalized.blank?

  recent_outbound_texts.any? { |outbound| normalize_draft_text(outbound) == normalized }
end

def similar_thread_response?(text)
  normalized = normalize_for_compare(text)
  return false if normalized.blank?

  comparison_texts = prior_thumper_thread_messages + recent_draft_texts
  comparison_texts.any? { |candidate| similar_message?(text, candidate) }
end

def repetitive_thread_response?(text)
  body = text.to_s.squish
  return false if body.blank?
  return false if customer_repeat_request?(latest_inbound_sms)
  return false if direct_checkout_link_request?(latest_inbound_sms) && body.match?(%r{https?://\S+}i)

  exact_recent_outbound?(body) || similar_thread_response?(body)
end

def customer_repeat_request?(text)
  text.to_s.downcase.squish.match?(/\b(?:repeat|say that again|send (?:that|it|the link) again|same link|again please|what was that|can you resend)\b/)
end

def stale_situation_alternate
  route = current_route_code
  return custom_bundle_handoff_reply if bundle_change_custom_request?(latest_inbound_sms)

  if route.present?
    return post_link_follow_up_reply(latest_inbound_sms) if shopify_link_already_sent?(route)

    company_question = quantity_company_follow_up(route)
    return company_question if company_question.present?
    question = next_route_fit_question(route)
    return question if question.present?
    return identity_collection_reply if identity_payload[:missing].present?
    return options_link_fit_question if options_link_fit_question_needed?(route)
  end

  product_direction_question
end

def similar_message?(left, right)
  left_norm = normalize_for_compare(left)
  right_norm = normalize_for_compare(right)
  return false if left_norm.blank? || right_norm.blank?
  return true if left_norm == right_norm
  return true if left_norm.length > 24 && right_norm.include?(left_norm)
  return true if right_norm.length > 24 && left_norm.include?(right_norm)

  left_tokens = comparison_tokens(left_norm)
  right_tokens = comparison_tokens(right_norm)
  return false if left_tokens.length < 4 || right_tokens.length < 4

  overlap = (left_tokens & right_tokens).length
  union = (left_tokens | right_tokens).length
  overlap_ratio = overlap.to_f / [left_tokens.length, right_tokens.length].min
  jaccard = overlap.to_f / union
  overlap_ratio >= 0.72 || jaccard >= 0.58
end

def comparison_tokens(value)
  stopwords = %w[
    a an and are as at be but by can do does for from get have i if in is it me of on or our should so that the them this to we what when where which with would you your
    wizwiki thumper marketing
  ]
  normalize_for_compare(value).split.uniq.reject { |token| token.length < 3 || stopwords.include?(token) }
end

def asks_for_known_discovery_field?(text)
  body = text.to_s.downcase
  return true if current_route_code.present? && product_lane_selection_question?(body)
  return true if conversation_contact_name.present? && body.match?(/\b(what name|your name|name should|put on this conversation)\b/)
  return true if conversation_company_name.present? && body.match?(/\b(what company|company should|company name|business name|connect this to|what business)\b/)
  return true if industry_value.present? && body.match?(/\b(what industry|type of business|business type|what kind of business|what field)\b/)
  return true if email_value.present? && body.match?(/\b(email address|what email|your email|send email)\b/)
  return true if contact_preference_value.present? && body.match?(/\b(contact method|contact preference|prefer sms|prefer phone|prefer email)\b/)

  false
end

def asks_for_known_fit_field?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?

  fit = campaign_fit_payload
  if current_route_code.to_s == "LAWN_SIGNS" && fit[:quantity_count].present?
    return true if body.match?(/\b(how many|what|rough(?:ly)?|sign count|quantity).{0,40}\b(signs?|count|quantity)\b/i)
    return true if body.match?(/\b(sign count|quantity).{0,40}\b(should|use|need|want)\b/i)
  end

  if fit[:household_count].present?
    return true if body.match?(/\b(how many|rough(?:ly)?).{0,50}\b(homes?|households?|doors?|mailboxes?|addresses?)\b/i)
    return true if body.match?(/\b(?:what(?:'s| is)?|which|rough(?:ly)?|rough)\s+(?:the\s+)?(?:home|homes|household|households|door|doors|mailbox|mailboxes|address|addresses)?\s*count\b/i)
    return true if body.match?(/\b(?:home|homes|household|households|door|doors|mailbox|mailboxes|address|addresses)\s+count\b/i)
  end

  false
end

def product_lane_selection_question?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.match?(/\b(?:postcards?,?\s+yard signs?,?\s+or both|yard signs?,?\s+or both|mail homes|get seen with signs|get visible with signs|what are you trying to build)\b/)

  route_terms = 0
  route_terms += 1 if body.match?(/\b(?:post\s*cards?|postcards?|mailers?|direct mail|mailboxes?|mail homes|reach homes)\b/)
  route_terms += 1 if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?|signs in the ground|get seen with signs|get visible with signs)\b/)
  route_terms += 1 if body.match?(/\b(?:both|combine|together|full(?:er)?\s+(?:neighborhood\s+)?push|neighborhood\s+push|blitz)\b/)
  return false unless route_terms >= 2

  body.include?("?") || body.match?(/\b(?:are you|is this|which|what|leaning|thinking|trying|looking|need|want|mostly)\b/)
end

def zip_request?(text)
  body = text.to_s.downcase
  return false unless body.match?(/\b(zip|service area|location|where|shipping area|route area)\b/)

  body.match?(/\b(what|which|share|send|text|provide|tell me|check|where are|where you're|use this|secure link)\b/)
end

def industry_request?(text)
  text.to_s.downcase.match?(/\b(what industry|type of business|business type|what kind of business|what field|what industry are)\b/)
end

def analysis_leak?(text)
  body = text.to_s.squish.downcase
  return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)
  return true if internal_route_code_token?(body)
  return true if disallowed_shopify_link?(body)
  return true if body.match?(/\A(?:true|false|null)\s*[\]}:,]/)
  return true if body.match?(/\A(?:please\s+)?(?:apologize|mention|reconnect|follow|convert|write|draft|ask)\b/)
  return true if body.match?(/\b(?:operator instruction|follow the operator|ask at most one useful next question|reconnect to the current thread|mention my boss|mention the boss|in a casual human way)\b/)
  return true if body.match?(/\b(?:never return|do not return|don't return)\b.*\b(?:current draft|recent unsent draft|recent unsent drafts|minor word swaps|verbatim)\b/)
  return true if body.match?(/\b(?:current draft|recent unsent draft|recent unsent drafts)\b.*\b(?:verbatim|minor word swaps|materially different|avoid)\b/)
  return true if body.match?(/\b(?:manual rewrite id|this click must produce|materially different next sms|recent unsent drafts to avoid)\b/)
  return true if body.match?(/\A(?:use when|fit\s*:|usage_rule\s*:|recommended_next_question\s*:)/)
  return true if body.match?(/\b(?:missing_fields|next_missing_field|prompt_if_missing|current_next_text|captured_contact_name|captured_company_name|captured_industry|customer_first_name|customer_company_name|context_json|identity_capture|conversation_state|conversation\s+state|latest_inbound_event|latest_sms_event|latest_outbound_event|latest\s+inbound\s+message|recent_unsent_drafts|recent_outbound_texts|prior_thumper_messages|operator_prompt|thread_authority|full_sms_thread|recent_sms_thread|product_decision_guide|product\s+decision\s+guide|decision_guide|decision\s+guide|fine_training|campaign_fit_payload|campaign_fit|product_interest|route_code|shopify_link|product_key|product_label|checkout_url|style_variation|artwork_status|missing\s+fit\s+signal|sign_quantity|ask_if_unclear)\b/)
  return true if body.match?(/\A[-*]\s*(?:the\s+)?(?:route|route_code|shopify_link|product_key|known|missing|latest|prior|context|answer|fit|usage_rule|steps?)\b/)

  body.match?(/\A(?:however,?\s+)?(?:let me|looking at|we are drafting|we are in the middle of|i need to|i should|analysis|reasoning|based on the context|from the context|from the conversation|the context shows|the conversation|the customer'?s latest|the previous sms|the latest inbound|the latest outbound|latest inbound|latest outbound|the latest inbound message|context json|conversation_state)\b/) ||
    body.match?(/\A(?:latest_inbound_event|latest_sms_event|latest_inbound_sms|full_sms_thread|recent_sms_thread|conversation_state|operator_prompt|context_json|thread_authority)\s*:/) ||
    body.match?(/\A(?:however,?\s+)?(?:important|note that|the opening offer|the problem is|we are now|we are in\b|since there is no|we must|we must not|we have to answer|steps?|the instructions say)\b/) ||
    body.match?(/\A(?:to the question about|this answers|the next step is to (?:provide|ask|collect|route)|they (?:want|asked|said|need|gave)|they'?ve (?:given|asked|said)|we'?ve (?:learned|got|received)|we have (?:learned|got|received))\b/) ||
    body.match?(/\b(?:let me analyze|looking at the context|context from the json|current situation|craft the next sms|latest inbound event|latest_inbound_event|latest sms event|latest_sms_event|latest outbound event|latest_outbound_event|latest customer message|latest_customer_message|latest outbound sms|latest_outbound_sms|unanswered question|household count question|from the context|from the conversation|operator_prompt|context json|context_json|conversation_state|customer-facing sms)\b/) ||
    body.match?(/\b(?:the instructions say|the prompt says|the product_decision_guide|the product decision guide|according to (?:the\s+)?(?:product\s+)?decision guide|the decision guide|the guide says|customer-facing response|recommended next question|use when they only need|use when the customer|the customer has already been engaged|history of conversation|we are in (?:the\s+)?["']?[a-z_]+["']?\s+lane|we are to answer|we are to write|we are writing|we have to answer|we must ask|we must not|we need to answer|we know the customer|we know they|we do not have|we don't have|we must follow up|we need to follow up|there is no inbound sms|the customer hasn't replied|customer has not replied|ask at most one short next-step question|the route code is|the shopify link is)\b/) ||
    body.include?("return only the sms") ||
    body.include?("operator prompt")
end

def internal_context_fragment?(text)
  text.to_s.squish.match?(/\A["']?(?:latest_inbound_event|latest_sms_event|latest_outbound_event|latest_inbound_sms|full_sms_thread|recent_sms_thread|conversation_state|operator_prompt|context_json|thread_authority|missing_fields|next_missing_field|prompt_if_missing|current_next_text|captured_contact_name|captured_company_name|captured_industry|customer_first_name|customer_company_name|product_interest|route_code|shopify_link|product_key|product_label|checkout_url|style_variation)["']?\s*[:=]/i)
end

def enforce_single_question(text)
  body = text.to_s.squish
  return body if body.count("?") <= 1

  focused = focused_single_step_reply
  if focused.present? && focused.count("?") <= 1 && focused.length <= MAX_SMS_CHARS && !similar_thread_response?(focused)
    return focused
  end

  question_seen = false
  body.split(/(?<=\?)/).filter_map do |segment|
    if segment.include?("?")
      next if question_seen

      question_seen = true
    end
    segment
  end.join(" ").squish
end

def multi_discovery_ask?(text)
      body = text.to_s.downcase
      return false unless body.include?("?") || body.match?(/\b(share|send|provide|tell me|what|which)\b/)

      question_body = body.scan(/[^.!?]*\?/).join(" ")
      imperative_body = body.scan(/(?:share|send|provide|tell me|what|which)[^.!?]*/).join(" ")
      ask_body = [question_body, imperative_body].join(" ").squish
      ask_body = body if ask_body.blank?

      signals = 0
      signals += 1 if ask_body.match?(/\b(name|first name|your name)\b/)
      signals += 1 if ask_body.match?(/\b(company|business name|organization)\b/)
      signals += 1 if ask_body.match?(/\b(industry|business type|type of business|field)\b/)
signals += 1 if ask_body.match?(/\b(zip|service area|where|location)\b/)
signals += 1 if ask_body.match?(/\b(email|contact preference|sms|text|phone|call|days|times)\b/)
signals += 1 if ask_body.match?(/\b(budget|spend|price|cost|dollars?|dolla(?:rs?)?|bucks?)\b/)
signals += 1 if ask_body.match?(/\b(quantity|qty|how many|sign count|rough count|homes?|households?|doors?|addresses?|mailboxes?|reach)\b/)
signals += 1 if ask_body.match?(/\b(artwork|art|design|logo|creative|file)\b/)
signals > 1
    end

def double_discovery_ask?(text)
  body = text.to_s.downcase.squish
  return false if body.blank?
  return true if body.count("?") > 1
  return true if multi_discovery_ask?(body)

  body.match?(/\b(budget|spend|price|cost|dollars?|dolla(?:rs?)?|bucks?)\b.*\b(quantity|qty|how many|rough count|homes?|households?|reach)\b/) ||
    body.match?(/\b(quantity|qty|how many|rough count|homes?|households?|reach)\b.*\b(budget|spend|price|cost|dollars?|dolla(?:rs?)?|bucks?)\b/)
end

    def remove_latest_inbound_echo(text)
      inbound = latest_inbound_sms.to_s.squish
      return text if inbound.length < 14

      cleaned = text.to_s.squish
      escaped = Regexp.escape(inbound)
      cleaned = cleaned.sub(/\A#{escaped}\s*[?!.:;\-–—]*\s*/i, "")
      first_sentence = cleaned.split(/[.!?]/).first.to_s.squish
      if paraphrased_inbound_opening?(first_sentence, inbound) || short_inbound_echo_opening?(first_sentence, inbound)
        cleaned = cleaned.sub(/\A#{Regexp.escape(first_sentence)}\s*[?!.:;\-–—]*\s*/i, "")
      end
      cleaned.squish
        .sub(/\A([a-z])/) { Regexp.last_match(1).upcase }
        .gsub(/([.!?]\s+)([a-z])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}" }
    end

    def remove_yep_from_voice(text)
      text.to_s
        .sub(/\Ayep\b\s*,\s*/i, "Got it, ")
        .sub(/\Ayep\b\s*/i, "Got it, ")
        .squish
    end

    def remove_prompt_style_preface(text)
      body = text.to_s.squish
      return body unless prompt_style_preface?(body)

      body
        .sub(prompt_style_preface_pattern, "")
        .sub(/\A([a-z])/) { Regexp.last_match(1).upcase }
        .squish
    end

    def customerize_sms_language(text)
      CUSTOMER_LANGUAGE_REPLACEMENTS.reduce(text.to_s) do |body, (pattern, replacement)|
        body.gsub(pattern, replacement)
      end.squish
    end

    def prompt_style_preface?(text)
      text.to_s.squish.match?(prompt_style_preface_pattern)
    end

    def prompt_style_preface_pattern
      /\A(?:quick practical check|one useful detail|still worth asking|one clean next step|a simple next step|small practical check|no rush,?\s+one helpful detail|fresh start here)\s*[:\-–—,.]?\s*/i
    end

    def remove_that_makes_sense_unless_contextual(text)
      return text if that_makes_sense_contextual?

      cleaned = text.to_s
        .sub(/\A(?:yes|yeah|ok|okay)[,\s]+that makes sense[.!?,]*\s*/i, "")
        .sub(/\Athat makes sense[.!?,]*\s*/i, "")
        .squish
      cleaned.sub(/\A([a-z])/) { Regexp.last_match(1).upcase }
    end

    def repair_unlinked_checkout_claim(text)
      body = text.to_s.squish
      return body if body.blank?
      return body if body.match?(%r{https?://\S+}i)
      return body unless unlinked_checkout_claim?(body) || direct_checkout_link_request?(latest_inbound_sms)

      route = checkout_request_route(latest_inbound_sms).presence || current_route_code.presence || inferred_product_route_from_fit
      link = route_specific_shopify_link(route)
      if route.present? && link.present? && !fallback_shopify_link?(route, link)
        cleaned = body
          .gsub(/\bcheckout\s+links?\b/i, "checkout link")
          .gsub(/\border\s+links?\b/i, "order link")
          .squish
        with_link = [cleaned, link].join(" ").squish
        return with_link if with_link.length <= MAX_SMS_CHARS

        label = ROUTE_LABELS[route].presence || route.to_s.tr("_", " ").titleize
        compact = "#{label} checkout link: #{link}"
        return compact if compact.length <= MAX_SMS_CHARS
      end

      body
        .gsub(/\bcheckout\s+links?\b/i, "best-fit option")
        .gsub(/\border\s+links?\b/i, "order option")
        .squish
    end

    def unlinked_checkout_claim?(text)
      body = text.to_s.downcase.squish
      return false if body.blank? || body.match?(%r{https?://\S+}i)

      body.match?(/\b(?:checkout|order|buy|purchase|product page)\s+links?\b/) ||
        body.match?(/\blinks?\s+(?:for|to)\s+(?:checkout|order|buy|purchase)\b/) ||
        body.match?(/\bhere(?:'s| is)\b.{0,90}\b(?:checkout|order|buy|purchase|product page)\s+links?\b/)
    end

    def that_makes_sense_contextual?
      inbound = latest_inbound_sms.to_s.downcase.squish
      return false if inbound.blank?

      inbound.match?(/\b(confus|concern|worried|worry|nervous|hesitant|frustrat|stuck|unclear|not clear)\b/) ||
        inbound.match?(/\b(doesn'?t|does not|dont|don't|do not)\s+make\s+sense\b/) ||
        inbound.match?(/\b(i don'?t understand|i do not understand|why do i|why would i|why should i)\b/) ||
        inbound.match?(/\b(pay|payment|checkout|order)\b.*\b(before|proof|artwork|design|see|seeing)\b/) ||
        inbound.match?(/\b(before|proof|artwork|design|see|seeing)\b.*\b(pay|payment|checkout|order)\b/)
    end

    def paraphrased_inbound_opening?(opening, inbound)
      opening_tokens = echo_compare_tokens(opening)
      return false if opening_tokens.length < 5

      inbound_tokens = echo_compare_tokens(inbound)
      overlap = (opening_tokens & inbound_tokens).length
      overlap >= [4, (opening_tokens.length * 0.6).ceil].max
    end

    def short_inbound_echo_opening?(opening, inbound)
      prefix = opening.to_s.squish
      return false if prefix.blank? || prefix.length > 80
      return false if prefix.match?(/\$|\b(?:price|pricing|cost|discount|discounts|special|specials|postcards?|yard signs?|lawn signs?|signs?)\b/i)

      inbound_prefix = inbound.to_s.split(/[.!?]/).first.to_s
      opening_tokens = echo_compare_tokens(prefix)
      inbound_tokens = echo_compare_tokens(inbound_prefix)
      return false unless opening_tokens.length.between?(2, 4)

      overlap = (opening_tokens & inbound_tokens).length
      overlap >= [2, opening_tokens.length - 1].max
    end

    def echo_compare_tokens(text)
      stop_words = %w[
        a an and are as at be but can do for from get have i if in is it me my of ok okay on or
        the this to want we with you your
      ]
      text.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| stop_words.include?(token) || token.length < 3 }.uniq
    end

    def repeated_recent_outbound?(text)
      draft_validator.repeated_recent_outbound?(text)
    end

    def normalize_for_compare(value)
      draft_validator.normalize_for_compare(value)
    end
  end
end
