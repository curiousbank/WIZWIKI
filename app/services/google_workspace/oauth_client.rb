require "json"
require "net/http"
require "uri"

module GoogleWorkspace
  class Error < StandardError; end

  class OauthClient
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze

    def self.configured?
      ENV["GOOGLE_OAUTH_CLIENT_ID"].present? &&
        ENV["GOOGLE_OAUTH_CLIENT_SECRET"].present? &&
        ENV["GOOGLE_OAUTH_REFRESH_TOKEN"].present?
    end

    def access_token
      response = post_token
      token = response["access_token"].presence
      raise Error, "Google OAuth response did not include an access token" if token.blank?

      token
    end

    private

    def post_token
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request.set_form_data(
        client_id: ENV["GOOGLE_OAUTH_CLIENT_ID"],
        client_secret: ENV["GOOGLE_OAUTH_CLIENT_SECRET"],
        refresh_token: ENV["GOOGLE_OAUTH_REFRESH_TOKEN"],
        grant_type: "refresh_token"
      )

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 45, open_timeout: 15) do |http|
        http.request(request)
      end

      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "Google OAuth request failed: #{error.class}"
    end

    def parse_response(response)
      body = response.body.to_s
      case response
      when Net::HTTPSuccess
        body.blank? ? {} : JSON.parse(body)
      else
        raise Error, "Google OAuth HTTP #{response.code}: #{body.squish.truncate(260)}"
      end
    rescue JSON::ParserError => error
      raise Error, "Google OAuth response was not valid JSON: #{error.message}"
    end
  end
end
