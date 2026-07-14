# frozen_string_literal: true

module Comms
  class DojoJudgeAudit
    MATERIAL_DELTA = 10

    class << self
      def call(stage:, inbound:, answer:, grade:, fallback_grade:, draft_result: {})
        new(
          stage: stage,
          inbound: inbound,
          answer: answer,
          grade: grade,
          fallback_grade: fallback_grade,
          draft_result: draft_result
        ).call
      end
    end

    def initialize(stage:, inbound:, answer:, grade:, fallback_grade:, draft_result:)
      @stage = stage
      @inbound = inbound.to_s.squish
      @answer = answer.to_s.squish
      @grade = grade.to_h.deep_dup
      @fallback_grade = fallback_grade.to_h.deep_dup
      @draft_result = draft_result.to_h
      @audit_findings = []
      @calibration_lessons = []
      @max_allowed_score = 100
    end

    def call
      audit_grade!
      apply_audit!
    rescue StandardError => error
      grade.merge(
        "judge_audit" => {
          "status" => "audit_failed",
          "error" => "#{error.class}: #{error.message}",
          "audited_at" => Time.current.iso8601
        }
      )
    end

    private

    attr_reader :stage, :inbound, :answer, :grade, :fallback_grade, :draft_result, :audit_findings, :calibration_lessons
    attr_accessor :max_allowed_score

    def audit_grade!
      audit_blank_answer!
      audit_internal_leak!
      audit_meta_preface!
      audit_premature_am_handoff!
      audit_voice_vibe!
      audit_direct_price!
      audit_question_only_nonanswer!
      audit_multi_product!
      audit_design_process!
      audit_budget_translation!
      audit_checkout_confusion!
      audit_accepted_link_request!
      audit_customer_question_count!
      audit_package_label_accuracy!
      audit_product_fit_comparison!
      audit_eddm_blitz_comparison!
      audit_fallback_disagreement!
      audit_near_perfect_ceiling!
      audit_findings_quality!
    end

    def apply_audit!
      original_score = grade["score"].to_i.clamp(0, 100)
      original_verdict = grade["verdict"].to_s.upcase.presence || (original_score >= 85 ? "PASS" : "REVIEW")
      calibrated_score = [original_score, max_allowed_score].min.clamp(0, 100)
      calibrated_verdict = calibrated_score >= 85 && audit_findings.blank? ? "PASS" : (calibrated_score >= 85 ? original_verdict : "REVIEW")
      adjusted = calibrated_score != original_score || calibrated_verdict != original_verdict || hard_miss?

      merged_findings = if adjusted
        (audit_findings + Array(grade["findings"])).map { |finding| finding.to_s.squish }.compact_blank.uniq.first(8)
      else
        Array(grade["findings"])
      end

      grade.merge(
        "score" => calibrated_score,
        "verdict" => calibrated_verdict,
        "findings" => merged_findings.presence || Array(grade["findings"]).presence || ["Judge audit found no calibration issue."],
        "embedding_lesson" => adjusted ? calibration_embedding_lesson : grade["embedding_lesson"],
        "judge_audit" => {
          "status" => adjusted ? "calibrated" : "accepted",
          "original_score" => original_score,
          "original_verdict" => original_verdict,
          "calibrated_score" => calibrated_score,
          "calibrated_verdict" => calibrated_verdict,
          "max_allowed_score" => max_allowed_score,
          "findings" => audit_findings,
          "calibration_lessons" => calibration_lessons,
          "fallback_score" => fallback_grade["score"],
          "fallback_verdict" => fallback_grade["verdict"],
          "audited_at" => Time.current.iso8601
        }.compact_blank
      )
    end

    def hard_miss?
      audit_findings.present? && grade["score"].to_i > max_allowed_score
    end

    def audit_blank_answer!
      return if answer.present?

      cap_score!(30, "Judge must not pass or lightly score a blank customer answer.", "Blank answers are automatic REVIEW.")
    end

    def audit_internal_leak!
      return unless internal_leak?(answer)

      cap_score!(45, "Judge missed internal/backend language leaking into the customer answer.", "Internal prompt, route, guardrail, JSON, fallback, or analysis leakage is a severe REVIEW.")
    end

    def audit_meta_preface!
      return unless meta_preface?(answer)

      cap_score!(45, "Judge missed answer-wrapper language that describes the SMS instead of just sending the SMS.", "Customer-facing answers must not start with meta text like 'Here is the best reply' or 'Recommended SMS.'")
    end

    def audit_premature_am_handoff!
      return unless am_handoff_answer?(answer)
      return if am_handoff_allowed?(inbound)

      cap = direct_price_question?(inbound) && !answer.match?(/\$\s?\d/) ? 68 : 74
      cap_score!(
        cap,
        "Judge missed a premature account-manager handoff when Thumper should answer with standard product guidance first.",
        "Do not PASS AM/support handoffs unless the customer asks for a person, is blocked at checkout, is frustrated and asking for support, or explicitly requests custom/off-menu pricing."
      )
    end

    def audit_voice_vibe!
      issues = voice_vibe_issues(answer)
      return if issues.blank?

      cap_score!(
        82,
        "Judge missed Thumper voice/vibe issues: #{issues.to_sentence}.",
        "Judge vibe like a senior operator: PASS needs a relaxed, useful Thumper voice with complete sentences, direct answer first, no canned policy tone, no patronizing filler, and enough context to feel human."
      )
    end

    def audit_direct_price!
      return unless direct_price_question?(inbound)
      return if answer.match?(/\$\s?\d/)

      cap_score!(78, "Judge missed that the customer asked for price and the answer gave no dollar amount.", "Price questions need a real dollar amount before discovery.")
    end

    def audit_question_only_nonanswer!
      return unless direct_customer_question?(inbound)
      return unless question_only_or_near_question_only?(answer)
      return if material_answer_anchor?(answer)

      cap_score!(76, "Judge missed that Thumper answered a direct customer question with discovery instead of an actual answer.", "Direct questions need the answer first; ask one follow-up only after the customer has been answered.")
    end

    def audit_multi_product!
      return unless multi_part_product_question?(inbound)
      return if answer_mentions_requested_products?(inbound, answer)

      cap_score!(82, "Judge missed that a multi-product question did not answer every requested product lane.", "When a customer asks about multiple products, grade the answer on each material lane.")
    end

    def audit_design_process!
      return unless design_process_question?(inbound)
      return if design_flow_answer?(answer)

      cap_score!(78, "Judge missed an incomplete design/proof process explanation.", "Design/proof answers must explain checkout first, intake/upload after checkout, proof review, and no print before approval.")
    end

    def audit_budget_translation!
      return unless yard_sign_budget_question?(inbound)
      return if answer.match?(/\b(?:10|ten)\s+(?:yard\s+)?signs?\b/i) && answer.match?(/\$\s?100|\$?\s?99\b/i)

      cap_score!(82, "Judge missed that a yard-sign budget question needs a dollars-to-signs translation.", "$100/bucks/dolla questions for yard signs should say roughly 10 signs or the $99 10-sign tier.")
    end

    def audit_checkout_confusion!
      return unless checkout_confusion_question?(inbound)
      return if checkout_confusion_answer?(answer)

      cap_score!(78, "Judge missed that checkout confusion was not answered plainly.", "Checkout-link confusion needs a clear package/link explanation before another question.")
    end

    def audit_accepted_link_request!
      return unless accepted_recommendation_link_request?(inbound)
      return if answer.match?(%r{https?://}i)

      cap_score!(74, "Judge missed that the customer accepted a recommendation or asked for the link but the answer sent no link.", "Once a customer asks for the link after accepting a route, the answer must provide the correct checkout link.")
    end

    def audit_customer_question_count!
      return unless answer.scan("?").length > 1

      cap_score!(84, "Judge missed that the answer asks more than one customer question.", "Customer-facing Thumper answers should ask at most one next question.")
    end

    def audit_package_label_accuracy!
      if starter_pack_mislabeled_as_yard_signs?
        cap_score!(
          82,
          "Judge missed a package-label error: $299 for 20 signs, 500 business cards, and 500 door hangers is the Starter Pack, not the Yard Signs package.",
          "Exact offer names matter: Starter Pack is $299 with signs/cards/hangers; Yard Signs package tiers are signs-only prices."
        )
      end

      if pro_pack_mislabeled_as_yard_signs?
        cap_score!(
          82,
          "Judge missed a package-label error: $599 for 100 signs, 1,000 business cards, and 1,000 door hangers is the Pro Pack, not the Yard Signs package.",
          "Exact offer names matter: Pro Pack is $599 with signs/cards/hangers; Yard Signs package tiers are signs-only prices."
        )
      end
    end

    def audit_product_fit_comparison!
      return unless signs_only_bundle_fit_question?(inbound)
      return if signs_only_bundle_fit_answer?(answer)

      cap_score!(
        76,
        "Judge missed that the customer asked whether a bundle fits signs-only, but the answer did not compare Yard Signs versus Starter/Pro bundle contents.",
        "Signs-only bundle-fit questions must say Yard Signs is the cleaner signs-only path and Starter/Pro adds business cards and door hangers."
      )
    end

    def audit_eddm_blitz_comparison!
      return unless eddm_neighborhood_blitz_question?(inbound)
      return if eddm_neighborhood_blitz_answer?(answer)

      cap_score!(
        78,
        "Judge missed that the customer asked EDDM versus Neighborhood Blitz, but the answer did not compare both paths directly.",
        "EDDM versus Neighborhood Blitz answers must explain mail-only EDDM versus fuller local visibility and recommend based on the customer's goal."
      )
    end

    def audit_fallback_disagreement!
      fallback_score = fallback_grade["score"].to_i
      grade_score = grade["score"].to_i
      return if fallback_score <= 0
      return if fallback_findings.blank?
      return if grade_score - fallback_score < MATERIAL_DELTA && !(fallback_grade["verdict"].to_s == "REVIEW" && grade["verdict"].to_s == "PASS")

      cap_score!(
        [fallback_score + 4, 84].min,
        "Judge was materially more generous than the deterministic checklist without addressing its hard finding: #{fallback_findings.first}",
        "When deterministic hard checks flag a material issue, the judge must explicitly resolve it or keep the answer in REVIEW."
      )
    end

    def audit_findings_quality!
      return if audit_findings.blank?
      text = Array(grade["findings"]).join(" ").downcase
      missed = audit_findings.reject do |finding|
        words = finding.downcase.scan(/[a-z0-9]+/).reject { |word| word.length < 5 }.first(4)
        words.any? { |word| text.include?(word) }
      end
      return if missed.blank?

      calibration_lessons << "Judge findings must name the actual hard miss, not only praise the answer or mention nearby facts."
    end

    def audit_near_perfect_ceiling!
      return if grade["score"].to_i < 98
      return if standout_answer?

      cap_score!(
        96,
        "Judge gave a near-perfect score to a usable answer that was not standout enough for 98-100.",
        "Reserve 98-100 for answers that are direct, complete, specific, warm, grounded, concise, and leave one natural next step."
      )
    end

    def cap_score!(score, finding, lesson)
      self.max_allowed_score = [max_allowed_score, score].min
      audit_findings << finding
      calibration_lessons << lesson
    end

    def calibration_embedding_lesson
      [
        "JUDGE CALIBRATION:",
        *calibration_lessons.uniq,
        "Scenario: #{inbound}",
        "Thumper answer: #{answer}",
        "Original judge score/verdict: #{grade['score']}/#{grade['verdict']}",
        "Calibrated max score: #{max_allowed_score}",
        "Audit findings: #{audit_findings.join(' ')}"
      ].join("\n")
    end

    def fallback_findings
      Array(fallback_grade["findings"]).map(&:to_s).map(&:squish).reject do |finding|
        finding.blank? || finding.match?(/\A(?:complete|no deterministic flags)/i)
      end
    end

    def starter_pack_mislabeled_as_yard_signs?
      text = answer.downcase
      text.match?(/\byard[\s-]?signs?\s+(?:package|deal|bundle|special)\b[^.?!]{0,120}\$\s?299\b/) &&
        text.match?(/\b500\s+(?:business\s+)?cards?\b|\b500\s+door\s+hangers?\b/)
    end

    def pro_pack_mislabeled_as_yard_signs?
      text = answer.downcase
      text.match?(/\byard[\s-]?signs?\s+(?:package|deal|bundle|special)\b[^.?!]{0,120}\$\s?599\b/) &&
        text.match?(/\b1,?000\s+(?:business\s+)?cards?\b|\b1,?000\s+door\s+hangers?\b/)
    end

    def direct_price_question?(body)
      body.to_s.match?(/\b(price|pricing|cost|how much|\$\d+|dollars?|bucks?|dolla|package|deal|special)\b/i)
    end

    def direct_customer_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.include?("?") ||
        text.match?(/\b(?:how much|cost|price|pricing|quote|what exactly|what is|what are|why|how do|how does|can i|can you|do i|does it|included|comes with|link|checkout|design|artwork|proof|i don'?t understand|dont understand|don't understand)\b/)
    end

    def meta_preface?(body)
      text = body.to_s.squish
      return false if text.blank?

      text.match?(/\A(?:here'?s|here is|recommended|suggested|best|draft|the best).{0,90}\b(?:sms|reply|response|message|answer|as thumper|from wizwiki|customer-facing)\b/i) ||
        text.match?(/\b(?:best next short sms reply|customer-facing sms|reply as thumper|as thumper from wizwiki marketing)\b/i)
    end

    def am_handoff_answer?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\b(?:account manager|am support|human|rep|representative|teammate|team member|specialist|someone)\b.{0,90}\b(?:reach out|contact|call|email|text|follow up|confirm|help|pick this up)\b/) ||
        text.match?(/\b(?:reach out|contact|call|email|text|follow up)\b.{0,90}\b(?:account manager|am support|human|rep|representative|teammate|team member|specialist|someone)\b/)
    end

    def am_handoff_allowed?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return true if human_request?(text)
      return true if checkout_handoff_needed?(text)
      return true if frustrated_support_request?(text)

      explicit_custom_pricing_request?(text)
    end

    def human_request?(body)
      body.match?(/\b(?:human|person|rep|representative|sales\s*(?:person|rep)|account\s*manager|manager|someone|team|owner)\b/) &&
        body.match?(/\b(?:talk|speak|call|connect|contact|reach|help|get|want|need|can|please)\b/)
    end

    def checkout_handoff_needed?(body)
      checkout_context = body.match?(/\b(?:checkout|check out|cart|payment|pay|paid|order|link|url|website|site|shopify)\b/)
      blocked = body.match?(/\b(?:can'?t|cannot|couldn'?t|won'?t|will not|error|failed|fails|failure|not working|doesn'?t work|isn'?t working|stuck|broken|declined|decline|missing|issue|problem|trouble|won'?t load|will not load)\b/)
      checkout_context && blocked
    end

    def frustrated_support_request?(body)
      body.match?(/\b(?:frustrated|upset|angry|annoyed|not helping|isn'?t helping|you(?:'re| are)? not answering|not answering my question|still confused|still don'?t understand|need support|want support|support person)\b/) &&
        body.match?(/\b(?:human|person|rep|representative|account manager|manager|someone|support|call|contact|reach|help)\b/)
    end

    def explicit_custom_pricing_request?(body)
      body.match?(/\b(?:custom|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk discount|exact custom)\b/) &&
        body.match?(/\b(?:price|pricing|quote|total|deal|package|pack|bundle|setup)\b/)
    end

    def voice_vibe_issues(body)
      text = body.to_s.squish
      down = text.downcase
      issues = []
      issues << "habitual Yep opener" if text.match?(/\A\s*yep[,.!]/i)
      issues << "robotic corporate wording" if down.match?(/\b(?:solutions|leverage|utilize|seamless|elevate|unlock|empower|robust)\b/)
      issues << "patronizing filler" if down.match?(/\b(?:that makes sense|obviously|as i said|like i mentioned|you just need to|solid start)\b/)
      issues << "clipped or policy-note phrasing" if clipped_policy_note?(text)
      issues << "too thin for a direct question" if direct_customer_question?(inbound) && too_thin_for_direct_question?(text)
      issues.compact_blank.uniq
    end

    def clipped_policy_note?(body)
      text = body.to_s.squish
      return false if text.blank?

      text.match?(/\b(?:exact pricing can vary|cannot safely|policy|standard checkout quantities|I can safely price|I can quote confidently)\b/i) &&
        text.split(/[.?!]/).map(&:squish).reject(&:blank?).length <= 2
    end

    def too_thin_for_direct_question?(body)
      text = body.to_s.squish
      return true if text.length < 55
      return false if material_answer_anchor?(text)

      text.split(/[.?!]/).map(&:squish).reject(&:blank?).length <= 1
    end

    def question_only_or_near_question_only?(body)
      text = body.to_s.squish
      return false if text.blank?
      return true if text.end_with?("?") && text.scan(/[.?!]/).length <= 1

      without_short_ack = text.sub(/\A(?:got it|good question|that helps|that makes sense|yes|yep|sure|absolutely)[,.!]?\s+/i, "")
      without_short_ack.end_with?("?") && without_short_ack.scan(/[.?!]/).length <= 1
    end

    def material_answer_anchor?(body)
      text = body.to_s.downcase.squish
      text.match?(/\$\s?\d/) ||
        text.match?(/\b(?:starter pack|pro pack|yard signs package|neighborhood blitz|eddm|postcards?|business cards?|door hangers?|checkout|intake|proof|approval|nothing prints|link|included|includes|shipping|stakes)\b/)
    end

    def multi_part_product_question?(body)
      product_hits(body).length >= 2
    end

    def answer_mentions_requested_products?(inbound_text, answer_text)
      requested = product_hits(inbound_text)
      answered = product_hits(answer_text)
      (requested - answered).blank?
    end

    def product_hits(body)
      text = body.to_s.downcase
      products = []
      products << "postcards" if text.match?(/\b(postcards?|mailers?|eddm)\b/)
      products << "signs" if text.match?(/\b(signs?|yard signs?|lawn signs?)\b/)
      products << "business cards" if text.match?(/\b(business cards?|cards?)\b/)
      products << "door hangers" if text.match?(/\b(door hangers?|hangers?)\b/)
      products.uniq
    end

    def design_process_question?(body)
      body.to_s.match?(/\b(design|artwork|art work|logo|proof|creative|upload|image|images|ai art|postcard generator|before print|before printing)\b/i)
    end

    def design_flow_answer?(body)
      text = body.to_s.downcase
      text.match?(/\b(order|checkout|pay|payment|purchase)\b/) &&
        text.match?(/\b(intake|upload|email|form|send)\b/) &&
        text.match?(/\b(proof|approval|approve|changes?|review)\b/) &&
        text.match?(/\bnothing prints|no print|before print|before printing|until.*approval\b/)
    end

    def yard_sign_budget_question?(body)
      body.to_s.match?(/\b(?:\$?\s?100|hundred|bucks?|dolla(?:rs?)?).*\b(?:yard\s+)?signs?\b|\b(?:yard\s+)?signs?.*\b(?:\$?\s?100|hundred|bucks?|dolla(?:rs?)?)\b/i)
    end

    def checkout_confusion_question?(body)
      text = body.to_s.downcase.squish
      return false if text.match?(/\bwhat\s+exactly\s+is\s+(?:neighborhood|neighbourhood)\s+blitz\b/)

      text.match?(/\b(confused|do not understand|don't understand|dont understand|what am i buying|checkout link|link mean|what is this link)\b/i) ||
        (text.match?(/\bwhat exactly\b/) && text.match?(/\b(?:checkout|link|buying|order|purchase|package)\b/))
    end

    def checkout_confusion_answer?(body)
      text = body.to_s.downcase
      text.match?(/\b(link|checkout|order)\b/) &&
        text.match?(/\b(package|bundle|includes|buying|covers|gets you)\b/)
    end

    def accepted_recommendation_link_request?(body)
      body.to_s.match?(/\b(send|share|give).{0,20}\blink\b|\blink please\b|\bsounds good\b|\blet'?s do it\b|\bi'?ll take it\b|\bproceed\b/i)
    end

    def signs_only_bundle_fit_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false unless text.match?(/\b(?:starter\s*pack|pro\s*pack|pack|bundle|deal)\b/)

      text.match?(/\b(?:only|just)\s+(?:need|want)\s+(?:yard\s+)?signs?\b/) ||
        text.match?(/\b(?:yard\s+)?signs?\s+only\b|\bsigns[-\s]?only\b/)
    end

    def signs_only_bundle_fit_answer?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\byard\s+signs?\s+package\b|\bsigns[-\s]?only\b|\bsigns only\b/) &&
        text.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/) &&
        text.match?(/\bbusiness\s+cards?\b/) &&
        text.match?(/\bdoor\s+hangers?\b/)
    end

    def eddm_neighborhood_blitz_question?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return false unless text.match?(/\b(?:same|different|difference|versus|vs\.?|compare|like|better|best|recommend|which|should i|right fit)\b/)
      return false unless text.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b/)

      text.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/)
    end

    def eddm_neighborhood_blitz_answer?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?

      text.match?(/\beddm\b/) &&
        text.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b/) &&
        text.match?(/\b(?:mail-only|mail only|postcards?|mailboxes?|usps|route)\b/) &&
        text.match?(/\b(?:fuller|broader|local push|visibility|signs?|door hangers?|rack cards?)\b/)
    end

    def standout_answer?
      body = answer.to_s.squish
      return false if body.blank?
      return false if body.length < 85 || body.length > 420
      return false if answer.scan("?").length > 1
      return false if internal_leak?(body)
      return false if meta_preface?(body)
      return false if voice_vibe_issues(body).present?
      return false if direct_customer_question?(inbound) && !direct_answer_shape?(body)

      material_answer_anchor?(body) && natural_next_step?(body)
    end

    def direct_answer_shape?(body)
      first_sentence = body.to_s.squish.split(/[.?!]/).first.to_s.downcase
      return false if first_sentence.blank?
      return false if first_sentence.match?(/\A(?:what|which|when|where|how|why|can|could|do|does|would|will)\b/)

      material_answer_anchor?(first_sentence) ||
        first_sentence.match?(/\b(?:yes|no|starter pack|pro pack|yard signs?|neighborhood blitz|eddm|checkout|proof|intake|link)\b/)
    end

    def natural_next_step?(body)
      body.to_s.match?(/\b(?:do you want|want me to|send me|tell me|text me|choose|pick|checkout|order|place the order|upload|after checkout|next step|if you want)\b/i)
    end

    def internal_leak?(body)
      text = body.to_s
      return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)

      text.match?(/\b(?:we need to answer|the user is asking|voice rules|context provided|system prompt|developer instruction|guardrail|fallback|analysis|draft candidate|selected answer|metadata|json)\b/i)
    end
  end
end
