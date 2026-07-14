require "json"
require "net/http"
require "uri"

module Hubspot
  class Error < StandardError; end

  class Client
    BASE_URL = "https://api.hubapi.com".freeze

    def initialize(access_token: WizwikiSettings.hubspot_key)
      @access_token = access_token.to_s.strip
      raise Error, "HUBSPOT_KEY is not configured." if @access_token.blank?
    end

    def get(path, params = {})
      uri = uri_for(path, params)
      request = Net::HTTP::Get.new(uri)
      perform(uri, request)
    end

    def post(path, body = {})
      uri = uri_for(path)
      request = Net::HTTP::Post.new(uri)
      request.body = JSON.generate(body)
      perform(uri, request)
    end

    private

    attr_reader :access_token

    def uri_for(path, params = {})
      uri = URI.join(BASE_URL, path)
      uri.query = URI.encode_www_form(params) if params.present?
      uri
    end

    def perform(uri, request)
      request["Authorization"] = "Bearer #{access_token}"
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"

      response = http_for(uri).request(request)
      parsed = parse_json(response.body)
      return parsed if response.is_a?(Net::HTTPSuccess)

      raise Error, "HubSpot #{response.code}: #{error_message(parsed, response.body)}"
    end

    def http_for(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 45
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s.presence || "{}")
    rescue JSON::ParserError
      { "raw" => body.to_s }
    end

    def error_message(parsed, body)
      parsed["message"].presence || parsed.dig("errors", 0, "message").presence || body.to_s.truncate(220)
    end
  end
end
