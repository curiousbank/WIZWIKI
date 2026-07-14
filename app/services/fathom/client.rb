require "json"
require "net/http"
require "uri"

module Fathom
  class Error < StandardError; end

  class Client
    DEFAULT_BASE_URL = "https://api.fathom.ai/external/v1".freeze
    DEFAULT_TIMEOUT = 45

    def self.configured?
      WizwikiSettings.fathom_configured?
    end

    def initialize(api_key: WizwikiSettings.fathom_api_key, base_url: WizwikiSettings.fathom_base_url, timeout: DEFAULT_TIMEOUT)
      @api_key = api_key.to_s.strip
      @base_url = base_url.to_s.strip.presence || DEFAULT_BASE_URL
      @timeout = timeout.to_i.clamp(5, 180)
    end

    def list_meetings(params = {})
      get("/meetings", params)
    end

    def recording_summary(recording_id)
      get("/recordings/#{recording_id}/summary")
    end

    def recording_transcript(recording_id)
      get("/recordings/#{recording_id}/transcript")
    end

    def get(path, params = {})
      raise Error, "Fathom API key is not configured" if api_key.blank?

      uri = build_uri(path, params)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["X-Api-Key"] = api_key

      response = perform(uri, request)
      parse_response(response)
    end

    private

    attr_reader :api_key, :base_url, :timeout

    def build_uri(path, params)
      root = base_url.end_with?("/") ? base_url : "#{base_url}/"
      uri = URI.join(root, path.to_s.delete_prefix("/"))
      query = encoded_params(params)
      uri.query = query if query.present?
      uri
    end

    def encoded_params(params)
      pairs = params.to_h.flat_map do |key, value|
        next [] if value.nil?

        if value.is_a?(Array)
          value.reject(&:blank?).map { |entry| [key.to_s, entry] }
        else
          [[key.to_s, value]]
        end
      end
      URI.encode_www_form(pairs)
    end

    def perform(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: timeout, open_timeout: timeout) do |http|
        http.request(request)
      end
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "Fathom request failed: #{error.class}"
    end

    def parse_response(response)
      body = response.body.to_s
      case response
      when Net::HTTPSuccess
        body.blank? ? {} : JSON.parse(body)
      else
        raise Error, "Fathom HTTP #{response.code}: #{body.squish.truncate(260)}"
      end
    rescue JSON::ParserError => error
      raise Error, "Fathom response was not valid JSON: #{error.message}"
    end
  end
end
