# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module Autos
  class QueryEmbedder
    CACHE_VERSION = 1
    DEFAULT_BASE_URL = "http://127.0.0.1:11434"
    DEFAULT_CACHE_TTL = 30.minutes
    MAX_QUERY_CHARS = 4_000

    class << self
      def call(query:, model: nil)
        new(query: query, model: model).call
      end
    end

    def initialize(query:, model: nil)
      @query = query.to_s.squish.truncate(MAX_QUERY_CHARS, omission: "...")
      @model = model.to_s.presence || Autos::EmbeddingQueue.embedder_model
    end

    def call
      return failure("query embedding disabled") unless enabled?
      return failure("query missing") if query.blank?
      return failure("embedding model missing") if model.blank?

      if (cached = Rails.cache.read(cache_key)).to_h["embedding"].present?
        return cached.to_h.symbolize_keys.merge(cached: true)
      end

      result = request_embedding
      Rails.cache.write(cache_key, result.stringify_keys, expires_in: cache_ttl) if result[:ok]
      result.merge(cached: false)
    rescue StandardError => error
      Rails.logger.warn("[Autos::QueryEmbedder] failed model=#{model} #{error.class}: #{error.message}")
      failure("#{error.class}: #{error.message}")
    end

    private

    attr_reader :query, :model

    def request_embedding
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      uri = embedding_uri
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = { model: model, input: [query] }.to_json

      response = http_client(uri).request(request)
      raise "Ollama embed HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      embedding = normalize_embedding(Array(JSON.parse(response.body)["embeddings"]).first)
      raise "Ollama embed returned no embedding" if embedding.blank?

      {
        ok: true,
        embedding: embedding,
        model: model,
        provider: "ollama/local",
        dimensions: embedding.length,
        elapsed_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)
      }
    end

    def normalize_embedding(values)
      Array(values).map { |value| Float(value) }.select(&:finite?)
    rescue ArgumentError, TypeError
      []
    end

    def embedding_uri
      configured = ENV["WIZWIKI_RAG_EMBED_URL"].presence || ENV["OLLAMA_URL"].presence || ENV["OLLAMA_BASE_URL"].presence || DEFAULT_BASE_URL
      uri = URI.parse(configured)
      uri.path = "/api/embed" if uri.path.blank? || uri.path == "/"
      uri
    end

    def http_client(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |client|
        client.use_ssl = uri.scheme == "https"
        client.open_timeout = ENV.fetch("WIZWIKI_RAG_EMBED_OPEN_TIMEOUT", "2").to_i.clamp(1, 15)
        client.read_timeout = ENV.fetch("WIZWIKI_RAG_EMBED_READ_TIMEOUT", "12").to_i.clamp(5, 180)
      end
    end

    def cache_key
      ["autos_query_embedding", CACHE_VERSION, model, Digest::SHA256.hexdigest(query)]
    end

    def cache_ttl
      ENV.fetch("WIZWIKI_RAG_QUERY_CACHE_MINUTES", "30").to_i.clamp(1, 1_440).minutes
    end

    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_RAG_QUERY_EMBEDDING_ENABLED", "1"))
    end

    def failure(reason)
      {
        ok: false,
        embedding: [],
        model: model,
        provider: "ollama/local",
        dimensions: 0,
        error: reason
      }
    end
  end
end
