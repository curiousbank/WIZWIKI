module Comms
  class DraftValidator
    LINK_OR_CHECKOUT_PATTERN = /\b(thank you for choosing|you can order|order it here|checkout|shopify|links?|buy|purchase|product page)\b|https?:\/\//i

    def initialize(context:, max_sms_chars:)
      @context = context
      @max_sms_chars = max_sms_chars
    end

    def acceptable_draft?(draft)
      body = draft.to_h["body"].to_s.squish
      acceptable_sms_body?(body)
    end

    def rejection_reason(body, include_drafts: true)
      body = body.to_s.squish
      return "validator_blank" if body.blank?
      return "validator_too_long" if body.length > @max_sms_chars
      return "validator_repeated_draft" if include_drafts ? repeated_draft?(body) : repeated_recent_outbound?(body)
      return "validator_analysis_leak" if context(:analysis_leak?, body)
      if (voice_reason = consultant_voice_rejection_reason(body)).present?
        return voice_reason
      end
      return "validator_premature_closing" if context(:premature_closing_reply?, body)
      return "validator_checkout_before_ready" if checkout_before_ready?(body)
      return "validator_link_ready_without_link" if link_ready_without_link?(body)
      return "validator_accepted_recommendation_without_link" if context(:accepted_recommendation_without_link?, body)
      return "validator_wrong_route_shopify_link" if context(:wrong_route_shopify_link?, body)

      nil
    end

    def acceptable_sms_body?(body, include_drafts: true)
      rejection_reason(body, include_drafts: include_drafts).blank?
    end

    def repeated_draft?(body)
      context(:exact_recent_outbound?, body)
    end

    def checkout_before_ready?(body)
      return false unless link_or_checkout_text?(body)
      return false if context(:design_process_answer?, body)
      return false if context?(:unit_pricing_answer_for_inbound?, body)
      return false if context?(:route_link_answer_has_required_fit?, body)
      return false if rush_or_turnaround_boundary_answer?(body)

      route = context(:current_route_code)
      return false if context(:link_fit_ready?, route)

      body.to_s.match?(/\b(thank you for choosing|you can order|order it here|checkout|shopify)\b/i) ||
        body.to_s.match?(%r{https?://}i)
    end

    def link_ready_without_link?(body)
      return false unless link_or_checkout_text?(body)
      return false if context(:design_process_answer?, body)

      route = context(:current_route_code)
      return false unless context(:link_fit_ready?, route)

      link = context(:route_specific_shopify_link, route).to_s
      return false if link.blank?

      !body.to_s.include?(link)
    end

    def normalize_draft_text(text)
      text.to_s.downcase.gsub(/\s+/, " ").gsub(/[[:punct:]]+\z/, "").strip
    end

    def repeated_recent_outbound?(text)
      context(:exact_recent_outbound?, text)
    end

    def normalize_for_compare(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    private

    def link_or_checkout_text?(body)
      body.to_s.match?(LINK_OR_CHECKOUT_PATTERN)
    end

    def rush_or_turnaround_boundary_answer?(body)
      return false unless @context.respond_to?(:latest_rush_or_turnaround_question?, true)
      return false unless @context.__send__(:latest_rush_or_turnaround_question?)
      return false unless @context.respond_to?(:latest_inbound_sms, true)
      return false unless @context.respond_to?(:turnaround_answer_for_inbound?, true)

      @context.__send__(:turnaround_answer_for_inbound?, body, @context.__send__(:latest_inbound_sms))
    rescue StandardError
      false
    end

    def consultant_voice_rejection_reason(body)
      return unless defined?(Comms::ConsultantVoice)

      inbound = @context.__send__(:latest_inbound_sms) if @context.respond_to?(:latest_inbound_sms, true)
      Comms::ConsultantVoice.rejection_reason(body, inbound: inbound)
    rescue StandardError
      nil
    end

    def context(method_name, *args)
      @context.__send__(method_name, *args)
    end

    def context?(method_name, *args)
      return false unless @context.respond_to?(method_name, true)

      @context.__send__(method_name, *args)
    end
  end
end
