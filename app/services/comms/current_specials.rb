# frozen_string_literal: true

module Comms
  module CurrentSpecials
    ENV_FLAG = "WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"
    PRICE_SHEET_RESOURCE = "config/autos/current_specials.md"

    module_function

    def special_key
      return unless defined?(Comms::ProductCatalog)

      Comms::ProductCatalog.default_special_key
    end

    def active?(date = Time.zone.today)
      return false if special_key.blank?

      configured_flag = ENV[ENV_FLAG]
      return false if configured_flag.present? && !ActiveModel::Type::Boolean.new.cast(configured_flag)

      Comms::ProductCatalog.special_available?(special_key, date: date)
    end

    def sms_line
      return unless active?

      Comms::ProductCatalog.special_sms_line(special_key)
    end

    def full_sms_line
      return unless active?

      Comms::ProductCatalog.special_full_sms_line(special_key).presence || sms_line
    end

    def checkout_url
      return unless active?

      Comms::ProductCatalog.special_checkout_url(special_key)
    end

    def prompt_instruction
      return unless active?

      [
        "Use this reviewed special only when it directly answers the customer's current request.",
        sms_line,
        ("Use the configured checkout URL only when the customer asks to order: #{checkout_url}" if checkout_url.present?),
        "Do not invent eligibility, pricing, dates, availability, or package contents."
      ].compact_blank.join(" ")
    end

    def context_payload
      return unless active?

      payload = Comms::ProductCatalog.current_special(special_key)
      {
        "key" => special_key,
        "name" => payload["label"].presence || special_key.to_s.tr("_", " ").titleize,
        "active" => true,
        "active_until" => Comms::ProductCatalog.special_active_until(special_key)&.iso8601,
        "offer_type" => payload["offer_type"].presence,
        "usage_rule" => payload["usage_rule"].presence,
        "checkout_url" => checkout_url,
        "price_sheet_resource" => PRICE_SHEET_RESOURCE,
        "sms_line" => sms_line,
        "full_pricing_line" => full_sms_line,
        "pricing" => Comms::ProductCatalog.special_pricing(special_key)
      }.compact_blank
    end

    # Public WIZWIKI never injects an offer into model output. Operators may provide
    # reviewed catalog facts, but the original response is preserved for a human or a
    # downstream policy to evaluate in context.
    def ensure_sms_mention(value, max_chars: 480, force: false)
      value.to_s.squish.truncate(max_chars, separator: " ")
    end
  end
end
