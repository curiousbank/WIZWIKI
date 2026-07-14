require "json"
require "net/http"
require "uri"
require "cgi"

module Twilio
  class SmsClient
    API_HOST = "api.twilio.com".freeze

    def self.configured?(from_number: nil, messaging_service_sid: nil)
      account_sid.present? && auth_token.present? && (from_number.to_s.presence || messaging_service_sid.to_s.presence || self.from_number.present? || self.messaging_service_sid.present?)
    end

    def self.account_sid
      ENV["TWILIO_ACCOUNT_SID"].presence || ENV["twilio_account_sid"].presence
    end

    def self.auth_token
      ENV["TWILIO_AUTH_TOKEN"].presence || ENV["twilio_auth_token"].presence
    end

    def self.from_number
      ENV["TWILIO_PHONE_NUMBER"].presence || ENV["TWILIO_FROM_NUMBER"].presence || ENV["twilio_phone_number"].presence
    end

    def self.messaging_service_sid
      ENV["TWILIO_MESSAGING_SERVICE_SID"].presence || ENV["twilio_messaging_service_sid"].presence
    end

    def self.public_status(user: nil)
      profile = user&.respond_to?(:twilio_profile) ? user.twilio_profile : {}
      profile_from_number = profile.to_h["from_number"].presence
      profile_messaging_service_sid = profile.to_h["messaging_service_sid"].presence
      active_from_number = profile_from_number || from_number
      active_messaging_service_sid = profile_messaging_service_sid || messaging_service_sid
      {
        configured: configured?(from_number: profile_from_number, messaging_service_sid: profile_messaging_service_sid),
        account_sid_present: account_sid.present?,
        auth_token_present: auth_token.present?,
        from_number_present: active_from_number.present?,
        messaging_service_sid_present: active_messaging_service_sid.present?,
        user_sender_present: profile_from_number.present? || profile_messaging_service_sid.present?,
        sender_number: active_from_number,
        sender_number_source: profile_from_number.present? ? "profile" : (from_number.present? ? "env" : nil),
        messaging_service_sid: active_messaging_service_sid,
        messaging_service_source: profile_messaging_service_sid.present? ? "profile" : (messaging_service_sid.present? ? "env" : nil),
        status_callback_configured: status_callback_url.present?
      }
    end

    def self.deliver!(to:, body:, from_number: nil, messaging_service_sid: nil)
      new(from_number: from_number, messaging_service_sid: messaging_service_sid).deliver!(to: to, body: body)
    end

    def self.status_callback_url
      ENV["TWILIO_STATUS_CALLBACK_URL"].presence
    end

    def initialize(from_number: nil, messaging_service_sid: nil)
      @from_number = from_number.to_s.presence
      @messaging_service_sid = messaging_service_sid.to_s.presence
    end

    def deliver!(to:, body:)
      raise "Twilio SMS is not configured" unless self.class.configured?(from_number: sender_from_number, messaging_service_sid: sender_messaging_service_sid)

      recipient = normalize_phone(to)
      message = body.to_s.strip
      raise ArgumentError, "recipient phone required" if recipient.blank?
      raise ArgumentError, "message body required" if message.blank?

      response = post_message(to: recipient, body: message.first(1_600))
      {
        "provider" => "twilio",
        "sid" => response["sid"],
        "status" => response["status"],
        "to" => response["to"],
        "from" => response["from"],
        "date_created" => response["date_created"],
        "date_sent" => response["date_sent"],
        "error_code" => response["error_code"],
        "error_message" => response["error_message"]
      }.compact
    end

    private

    def normalize_phone(value)
      value.to_s.squish.gsub(/[^\d+]/, "").presence
    end

    def post_message(to:, body:)
      uri = URI::HTTPS.build(
        host: API_HOST,
        path: "/2010-04-01/Accounts/#{CGI.escape(self.class.account_sid)}/Messages.json"
      )
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(self.class.account_sid, self.class.auth_token)
      request["Accept"] = "application/json"

      form = {
        "To" => to,
        "Body" => body
      }
      form["StatusCallback"] = self.class.status_callback_url if self.class.status_callback_url.present?
      if sender_messaging_service_sid.present?
        form["MessagingServiceSid"] = sender_messaging_service_sid
      else
        form["From"] = sender_from_number
      end
      request.set_form_data(form)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 12, read_timeout: 30) do |http|
        http.request(request)
      end
      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise "Twilio SMS request failed: #{error.class}"
    end

    def parse_response(response)
      body = response.body.to_s
      parsed = body.present? ? JSON.parse(body) : {}
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed["message"].presence || body.squish.truncate(240)
      raise "Twilio SMS HTTP #{response.code}: #{message}"
    rescue JSON::ParserError => error
      raise "Twilio SMS response was not valid JSON: #{error.message}"
    end

    def sender_from_number
      @from_number.presence || self.class.from_number
    end

    def sender_messaging_service_sid
      @messaging_service_sid.presence || self.class.messaging_service_sid
    end
  end
end
