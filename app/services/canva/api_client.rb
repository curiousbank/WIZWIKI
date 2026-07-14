require "base64"
require "json"
require "net/http"
require "uri"

module Canva
  class ApiError < StandardError; end

  class ApiClient
    BASE_URL = "https://api.canva.com/rest/v1".freeze

    def initialize(connection)
      @connection = connection
    end

    def get(path)
      request_json(:get, path)
    end

    def post(path, payload)
      request_json(:post, path, payload: payload)
    end

def import_design(bytes:, title:, mime_type:)
  safe_title = title.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").scrub
  metadata = {
    title_base64: Base64.strict_encode64(safe_title.first(50)),
    mime_type: mime_type
  }
  request_binary(:post, "/imports", bytes: bytes, metadata_header: "Import-Metadata", metadata: metadata)
end

    def download(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 90) do |http|
        http.get(uri.request_uri)
      end
      return response.body.to_s.b if response.is_a?(Net::HTTPSuccess)

      raise ApiError, "Canva download failed (#{response.code}): #{response.body.to_s.first(300)}"
    end

    private

    attr_reader :connection

def request_binary(method, path, bytes:, metadata_header:, metadata:)
  uri = URI(path.to_s.start_with?("http") ? path : "#{BASE_URL}#{path}")
  request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{access_token!}"
  request["Content-Type"] = "application/octet-stream"
  request[metadata_header] = JSON.generate(metadata)
  request.body = bytes.to_s.b

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
    http.request(request)
  end
  body = response.body.to_s
  parsed = body.present? ? JSON.parse(body) : {}
  return parsed if response.is_a?(Net::HTTPSuccess)

  message = parsed["message"].presence || parsed["error_description"].presence || parsed["error"].presence || body.first(300)
  raise ApiError, "Canva API failed (#{response.code} #{uri.path}): #{message}"
rescue JSON::ParserError
  raise ApiError, "Canva API returned invalid JSON for #{uri.path}."
end

    def request_json(method, path, payload: nil)
      uri = URI(path.to_s.start_with?("http") ? path : "#{BASE_URL}#{path}")
      request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token!}"
      request["Content-Type"] = "application/json" if method == :post
      request.body = JSON.generate(payload) if payload.present?

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 90) do |http|
        http.request(request)
      end
      body = response.body.to_s
      parsed = body.present? ? JSON.parse(body) : {}
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed["message"].presence || parsed["error_description"].presence || parsed["error"].presence || body.first(300)
      raise ApiError, "Canva API failed (#{response.code} #{uri.path}): #{message}"
    rescue JSON::ParserError
      raise ApiError, "Canva API returned invalid JSON for #{uri.path}."
    end

    def access_token!
      if connection.access_token_expired?
        connection.with_lock do
          connection.reload
          Canva::OauthClient.new(connection).refresh! if connection.access_token_expired?
        end
      end
      token = connection.reload.access_token
      raise ApiError, "Canva access token is missing. Reconnect Canva." if token.blank?

      token
    end
  end
end
