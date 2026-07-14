# frozen_string_literal: true

module Comms
  class ConsultantVoice
    CANNED_OPENING_PATTERN = /\A(?:absolutely|certainly|sure thing|great question|happy to help|of course)[!.,:\s-]+/i.freeze
    GENERIC_CLOSER_PATTERN = /(?:\s+|\A)(?:please\s+)?(?:let me know if you (?:have|need|want) anything(?: else)?|feel free to (?:reach out|ask|contact us).*|happy to help(?: with anything else)?)[.!]*\z/i.freeze
    PROMPT_PREFACE_PATTERN = /\A(?:quick practical check|one useful detail|still worth asking|one clean next step|a simple next step|small practical check|no rush,?\s+one helpful detail|fresh start here)\s*[:\-.,]?\s*/i.freeze
    POLICY_LANGUAGE_PATTERN = /\b(?:according to (?:the|our) (?:policy|system)|per (?:the|our) policy|for compliance|the system (?:says|shows|requires)|i (?:am|'m) unable to|i (?:cannot|can't) safely|based on (?:the )?(?:provided )?context|from (?:the )?(?:provided )?context|retrieved context|available context|product data says)\b/i.freeze
    CORPORATE_LANGUAGE_PATTERN = /\b(?:solutions|leverage|utilize|seamless|elevate|unlock|empower|robust)\b/i.freeze
    META_CAPABILITY_PATTERN = /\A(?:i|we) can (?:help|assist|provide|walk you through|compare|explain|guide you|point you)[^.!?]{0,180}[.!?]?\z/i.freeze
    DASH_PATTERN = /[\u2013\u2014]/.freeze

    FEEDBACK = {
      "consultant_voice_policy_language" => "Write the customer answer itself. Do not mention policies, systems, retrieved context, safety decisions, or what the model can and cannot do.",
      "consultant_voice_corporate_language" => "Use plain Thumper language. Remove corporate filler such as solutions, leverage, utilize, seamless, elevate, unlock, empower, and robust.",
      "consultant_voice_meta_capability" => "Do the useful work instead of describing your ability to help, compare, explain, or guide.",
      "consultant_voice_multiple_questions" => "Answer first, then ask at most one specific low-friction question.",
      "consultant_voice_prompt_preface" => "Remove prompt-like framing and start with the useful customer answer.",
      "consultant_voice_generic_closer" => "Replace the generic service closer with one concrete next step, or end after the complete answer.",
      "consultant_voice_canned_opener" => "Drop the canned acknowledgement and open with the useful answer or a context-specific human response.",
      "consultant_voice_em_dash" => "Use normal sentences. Thumper's customer-facing voice does not use em or en dashes."
    }.freeze

    Review = Struct.new(:body, :issue_codes, :blocking_issue_codes, keyword_init: true) do
      def blocked?
        blocking_issue_codes.present?
      end

      def reason
        Array(blocking_issue_codes).first
      end

      def corrected?
        issue_codes.present? && !blocked?
      end
    end

    class << self
      def review(body:, inbound: nil)
        original = body.to_s.squish
        polished, correction_codes = polish(original)
        blocking = blocking_issue_codes(polished, inbound: inbound)
        Review.new(
          body: blocking.present? ? nil : polished,
          issue_codes: (correction_codes + blocking).uniq,
          blocking_issue_codes: blocking
        )
      end

      def rejection_reason(body, inbound: nil)
        review(body: body, inbound: inbound).reason
      end

      def feedback_for(reason)
        FEEDBACK[reason.to_s]
      end

      def rejection_reasons
        FEEDBACK.keys.freeze
      end

      private

      def polish(body)
        text = body.to_s.squish
        codes = []

        if text.match?(DASH_PATTERN)
          text = text.gsub(DASH_PATTERN, ". ").gsub(/\s+([.!?])/, '\\1').gsub(/\.\s*[,.]/, ".").squish
          text = sentence_case_all(text)
          codes << "consultant_voice_em_dash"
        end

        if text.match?(PROMPT_PREFACE_PATTERN)
          candidate = sentence_case(text.sub(PROMPT_PREFACE_PATTERN, "").squish)
          if usable_remainder?(candidate)
            text = candidate
            codes << "consultant_voice_prompt_preface"
          end
        end

        if text.match?(CANNED_OPENING_PATTERN)
          candidate = sentence_case(text.sub(CANNED_OPENING_PATTERN, "").squish)
          if usable_remainder?(candidate)
            text = candidate
            codes << "consultant_voice_canned_opener"
          end
        end

        if text.match?(GENERIC_CLOSER_PATTERN)
          candidate = text.sub(GENERIC_CLOSER_PATTERN, "").sub(/[,:;\s]+\z/, "").squish
          if usable_remainder?(candidate)
            text = candidate
            codes << "consultant_voice_generic_closer"
          end
        end

        [text, codes]
      end

      def blocking_issue_codes(body, inbound:)
        text = body.to_s.squish
        codes = []
        codes << "consultant_voice_policy_language" if text.match?(POLICY_LANGUAGE_PATTERN)
        codes << "consultant_voice_corporate_language" if text.match?(CORPORATE_LANGUAGE_PATTERN)
        codes << "consultant_voice_meta_capability" if meta_capability_only?(text)
        codes << "consultant_voice_multiple_questions" if text.count("?") > 1
        codes << "consultant_voice_prompt_preface" if text.match?(PROMPT_PREFACE_PATTERN)
        codes << "consultant_voice_generic_closer" if text.match?(GENERIC_CLOSER_PATTERN)
        codes << "consultant_voice_canned_opener" if text.match?(CANNED_OPENING_PATTERN)
        codes << "consultant_voice_em_dash" if text.match?(DASH_PATTERN)
        codes
      end

      def meta_capability_only?(text)
        return false unless text.match?(META_CAPABILITY_PATTERN)
        return false if text.match?(/\$\d|https?:\/\/|\b\d+\s*(?:signs?|cards?|postcards?|homes?|days?)\b/i)

        true
      end

      def usable_remainder?(text)
        text.to_s.scan(/[[:alnum:]]+/).length >= 5
      end

      def sentence_case(text)
        text.to_s.sub(/\A([a-z])/) { Regexp.last_match(1).upcase }
      end

      def sentence_case_all(text)
        sentence_case(text).gsub(/([.!?]\s+)([a-z])/) do
          "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}"
        end
      end
    end
  end
end
