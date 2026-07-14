require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"

module Canva
  class OauthError < StandardError; end

  class OauthClient
    AUTHORIZATION_URL = "https://www.canva.com/api/oauth/authorize".freeze
    TOKEN_URL = "https://api.canva.com/rest/v1/oauth/token".freeze

    def self.code_verifier
      Base64.urlsafe_encode64(SecureRandom.random_bytes(96), padding: false)
    end

    def self.code_challenge(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    def self.state
      Base64.urlsafe_encode64(SecureRandom.random_bytes(48), padding: false)
    end

    def self.authorization_url(code_verifier:, state:)
      raise OauthError, "Canva client ID is not configured." unless WizwikiSettings.canva_client_id.present?

      params = {
        code_challenge: code_challenge(code_verifier),
        code_challenge_method: "S256",
        scope: WizwikiSettings.canva_scopes,
        response_type: "code",
        client_id: WizwikiSettings.canva_client_id,
        state: state,
        redirect_uri: WizwikiSettings.canva_redirect_uri
      }.compact

      "#{AUTHORIZATION_URL}?#{URI.encode_www_form(params)}"
    end

    def initialize(connection)
      @connection = connection
    end

    def exchange_code!(code)
      raise OauthError, "Canva client secret is not configured." unless WizwikiSettings.canva_client_secret.present?
      raise OauthError, "Canva authorization code is missing." if code.blank?
      raise OauthError, "Canva code verifier is missing." if connection.code_verifier.blank?

      payload = token_request(
        grant_type: "authorization_code",
        code: code,
        code_verifier: connection.code_verifier,
        redirect_uri: WizwikiSettings.canva_redirect_uri
      )
      persist_tokens!(payload)
    end

    def refresh!
      raise OauthError, "Canva refresh token is missing." if connection.refresh_token.blank?

      payload = token_request(
        grant_type: "refresh_token",
        refresh_token: connection.refresh_token
      )
      persist_tokens!(payload)
    end

    private

    attr_reader :connection

    def token_request(params)
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Basic #{basic_credentials}"
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(params.compact)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
      body = response.body.to_s
      parsed = body.present? ? JSON.parse(body) : {}

      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed["error_description"].presence || parsed["error"].presence || body.first(300)
      raise OauthError, "Canva token request failed (#{response.code}): #{message}"
    rescue JSON::ParserError
      raise OauthError, "Canva token request returned invalid JSON."
    end

    def persist_tokens!(payload)
      expires_in = payload["expires_in"].to_i
      connection.update!(
        status: "connected",
        access_token: payload["access_token"],
        refresh_token: payload["refresh_token"],
        access_token_expires_at: expires_in.positive? ? Time.current + expires_in.seconds : nil,
        scope: payload["scope"].presence || WizwikiSettings.canva_scopes,
        state: nil,
        code_verifier: nil,
        authorized_at: Time.current,
        metadata: connection.metadata.to_h.merge(
          "token_type" => payload["token_type"],
          "connected_at" => Time.current.iso8601
        )
      )
      connection
    end

    def basic_credentials
      Base64.strict_encode64("#{WizwikiSettings.canva_client_id}:#{WizwikiSettings.canva_client_secret}")
    end
  end
end
