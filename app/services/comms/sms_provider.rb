module Comms
  class SmsProvider
    def self.provider
      explicit_provider =
        ENV["WIZWIKI_COMMS_SMS_PROVIDER"].presence ||
        ENV["WIZWIKI_SMS_PROVIDER"].presence ||
        ENV["SMS_PROVIDER"].presence
      return explicit_provider.to_s.strip.downcase if explicit_provider.present?

      Haymarket::SmsClient.configured? ? "haymarket" : "twilio"
    end

    def self.haymarket?
      provider.in?(%w[haymarket heymarket])
    end

    def self.public_status(user: nil)
      if haymarket?
        Haymarket::SmsClient.public_status(user: user).merge(provider: "haymarket", label: "Haymarket SMS")
      else
        Twilio::SmsClient.public_status(user: user).merge(provider: "twilio", label: "Twilio SMS")
      end
    end

    def self.deliver!(to:, body:, from_number: nil, messaging_service_sid: nil, metadata: nil, include_opt_out_notice: nil)
      body = deliverable_body(body, metadata: metadata, include_opt_out_notice: include_opt_out_notice)
      raise ArgumentError, "SMS body contains a stale Shopify product link" if stale_shopify_product_link?(body)

      if haymarket?
        Haymarket::SmsClient.deliver!(to: to, body: body, from_number: from_number)
      else
        Twilio::SmsClient.deliver!(to: to, body: body, from_number: from_number, messaging_service_sid: messaging_service_sid)
      end
    end

    def self.stale_shopify_product_link?(body)
      body.to_s.match?(%r{https?://(?:shop\.)?wizwikimarketing\.com/products/[^ \t\r\n]*\bdane\b}i)
    end

    def self.deliverable_body(body, metadata: nil, include_opt_out_notice: nil)
      if defined?(Comms::SmsBodySafety)
        Comms::SmsBodySafety.prepare_outbound_body(body, metadata: metadata, include_opt_out_notice: include_opt_out_notice)
      else
        body.to_s.squish
      end
    end
  end
end
