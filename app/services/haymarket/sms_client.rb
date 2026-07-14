require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"
require "base64"

module Haymarket
  class SmsClient
    def self.configured?(from_number: nil)
      auth_ready? && base_url.present? && send_path.present? && inbox_id.present? && creator_id.present?
    end

    def self.api_key
      ENV["HAYMARKET_API_KEY"].presence ||
        ENV["HEYMARKET_API_KEY"].presence ||
        ENV["HAYMARKET_ACCESS_TOKEN"].presence ||
        ENV["HEYMARKET_ACCESS_TOKEN"].presence ||
        ENV["HAYMARKET_TOKEN"].presence ||
        ENV["HEYMARKET_TOKEN"].presence
    end

    def self.secret_id
      ENV["HAYMARKET_API_SECRET_ID"].presence || ENV["HEYMARKET_API_SECRET_ID"].presence
    end

    def self.secret_key
      ENV["HAYMARKET_API_SECRET_KEY"].presence || ENV["HEYMARKET_API_SECRET_KEY"].presence
    end

    def self.auth_ready?
      api_key.present? || (secret_id.present? && secret_key.present?)
    end

    def self.base_url
      ENV["HAYMARKET_API_BASE_URL"].presence || ENV["HEYMARKET_API_BASE_URL"].presence || "https://api.heymarket.com"
    end

    def self.send_path
      ENV["HAYMARKET_SMS_SEND_PATH"].presence ||
        ENV["HEYMARKET_SMS_SEND_PATH"].presence ||
        ENV["HAYMARKET_SEND_PATH"].presence ||
        ENV["HEYMARKET_SEND_PATH"].presence ||
        "/v1/message/send"
    end

    def self.sender
      ENV["HAYMARKET_FROM_NUMBER"].presence ||
        ENV["HEYMARKET_FROM_NUMBER"].presence ||
        ENV["HAYMARKET_SENDER"].presence ||
        ENV["HEYMARKET_SENDER"].presence
    end

    def self.inbox_id
      ENV["HAYMARKET_INBOX_ID"].presence ||
        ENV["HEYMARKET_INBOX_ID"].presence ||
        ENV["HAYMARKET_OUTBOUND_INBOX_ID"].presence ||
        ENV["HEYMARKET_OUTBOUND_INBOX_ID"].presence ||
        ENV["HAYMARKET_ACCOUNT_ID"].presence ||
        ENV["HEYMARKET_ACCOUNT_ID"].presence
    end

    def self.creator_id
      ENV["HAYMARKET_CREATOR_ID"].presence || ENV["HEYMARKET_CREATOR_ID"].presence
    end

    def self.public_status(user: nil)
      profile = user&.respond_to?(:twilio_profile) ? user.twilio_profile.to_h : {}
      profile_from_number = profile["from_number"].presence
      active_sender = profile_from_number || sender
      {
        configured: configured?(from_number: profile_from_number),
        api_key_present: auth_ready?,
        api_secret_present: secret_id.present? && secret_key.present?,
        base_url_present: base_url.present?,
        send_path_present: send_path.present?,
        from_number_present: active_sender.present?,
        inbox_id_present: inbox_id.present?,
        creator_id_present: creator_id.present?,
        auth_mode: api_key.present? ? "token" : "jwt",
        auth_prefix: auth_prefix,
        jwt_claim_mode: jwt_claim_mode,
        jwt_secret_mode: jwt_secret_mode,
        user_sender_present: profile_from_number.present?,
        sender_number: active_sender,
        sender_number_source: profile_from_number.present? ? "profile" : (sender.present? ? "env" : nil),
        inbox_id: inbox_id,
        creator_id: creator_id
      }
    end

    def self.deliver!(to:, body:, from_number: nil)
      new(from_number: from_number).deliver!(to: to, body: body)
    end

    def initialize(from_number: nil)
      @from_number = from_number.to_s.presence
    end

    def deliver!(to:, body:)
      raise "Haymarket SMS is not configured" unless self.class.configured?(from_number: sender_from_number)

      recipient = normalize_phone(to)
      message = body.to_s.strip
      raise ArgumentError, "recipient phone required" if recipient.blank?
      raise ArgumentError, "message body required" if message.blank?

      response = post_message(to: recipient, body: message.first(1_600))
      {
        "provider" => "haymarket",
        "sid" => response["id"].presence || response["sid"].presence || response["message_id"].presence,
        "status" => response["status"].presence || response["state"].presence || "sent",
        "to" => response["to"].presence || response["phone_number"].presence || recipient,
        "from" => response["from"].presence || sender_from_number || self.class.inbox_id,
        "date_created" => response["created_at"].presence || response["createdAt"].presence || response["date"].presence,
        "date_sent" => response["sent_at"].presence || response["sentAt"].presence || response["date"].presence,
        "raw_response" => response
      }.compact
    end

    private

    def normalize_phone(value)
      digits = value.to_s.squish.gsub(/\D/, "")
      digits.presence
    end

    def post_message(to:, body:)
      uri = URI.join(self.class.base_url.to_s.chomp("/") + "/", self.class.send_path.to_s.sub(%r{\A/+}, ""))
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request[auth_header_name] = auth_header_value
      request.body = JSON.generate(message_payload(to: to, body: body))

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 12, read_timeout: 30) do |http|
        http.request(request)
      end
      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise "Haymarket SMS request failed: #{error.class}"
    end

    def message_payload(to:, body:)
      {
        inbox_id: self.class.inbox_id.to_i,
        creator_id: self.class.creator_id.to_i,
        phone_number: to,
        text: body,
        local_id: SecureRandom.uuid
      }.compact_blank
    end

    def parse_response(response)
      body = response.body.to_s
      parsed = body.present? ? JSON.parse(body) : {}
      return parsed.is_a?(Hash) ? parsed : { "response" => parsed } if response.is_a?(Net::HTTPSuccess)

      message = parsed["message"].presence || parsed["error"].presence || body.squish.truncate(240)
      raise "Haymarket SMS HTTP #{response.code}: #{message}"
    rescue JSON::ParserError
      message = body.squish.truncate(240).presence || "non-JSON response"
      return { "status" => "sent", "raw_response" => message } if response.is_a?(Net::HTTPSuccess)

      raise "Haymarket SMS HTTP #{response.code}: #{message}"
    end

    def auth_header_name
      ENV["HAYMARKET_AUTH_HEADER"].presence || ENV["HEYMARKET_AUTH_HEADER"].presence || "Authorization"
    end

    def self.auth_prefix
      ENV["HAYMARKET_AUTH_PREFIX"].presence || ENV["HEYMARKET_AUTH_PREFIX"].presence || "Bearer"
    end

    def auth_prefix
      self.class.auth_prefix
    end

    def auth_header_value
      token = self.class.api_key.presence || signed_jwt
      return token if auth_prefix.blank? || auth_prefix.to_s.casecmp("none").zero?

      "#{auth_prefix} #{token}"
    end

    def self.jwt_secret_mode
      mode = ENV["HAYMARKET_JWT_SECRET_MODE"].presence || ENV["HEYMARKET_JWT_SECRET_MODE"].presence
      return mode if %w[id_double_pipe_key id_colon_key id_key secret_key].include?(mode)

      "id_double_pipe_key"
    end

    def self.jwt_claim_mode
      mode = ENV["HAYMARKET_JWT_CLAIM_MODE"].presence || ENV["HEYMARKET_JWT_CLAIM_MODE"].presence
      return mode if %w[heymarket timed].include?(mode)

      "heymarket"
    end

    def jwt_secret
      case self.class.jwt_secret_mode
      when "id_double_pipe_key"
        "#{self.class.secret_id}||#{self.class.secret_key}"
      when "id_colon_key"
        "#{self.class.secret_id}:#{self.class.secret_key}"
      when "id_key"
        "#{self.class.secret_id}#{self.class.secret_key}"
      else
        self.class.secret_key
      end
    end

    def signed_jwt
      header = jwt_base64(JSON.generate({ alg: "HS256", typ: "JWT" }))
      now = Time.now.to_i
      claims = case self.class.jwt_claim_mode
      when "timed"
        { iss: self.class.secret_id, iat: now, exp: now + 300 }
      else
        { iss: self.class.secret_id, iat: now }
      end
      payload = jwt_base64(JSON.generate(claims))
      signing_input = "#{header}.#{payload}"
      signature = jwt_base64(OpenSSL::HMAC.digest("SHA256", jwt_secret, signing_input))
      "#{signing_input}.#{signature}"
    end

    def jwt_base64(value)
      Base64.urlsafe_encode64(value).delete("=")
    end

    def sender_from_number
      @from_number.presence || self.class.sender
    end
  end
end
