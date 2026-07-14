# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Autos
  class QueryEmbedderTest < ActiveSupport::TestCase
    FakeHttp = Struct.new(:response, :request_count, keyword_init: true) do
      attr_accessor :use_ssl, :open_timeout, :read_timeout

      def request(_request)
        self.request_count = request_count.to_i + 1
        response
      end
    end

    test "returns a cached Ollama query embedding" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, { embeddings: [[0.25, 0.5, 0.75]] }.to_json)
      client = FakeHttp.new(response: response, request_count: 0)
      cache = ActiveSupport::Cache::MemoryStore.new
      query = "unique RAG query #{SecureRandom.hex(8)}"

      with_singleton_method(Rails, :cache, -> { cache }) do
        with_singleton_method(Net::HTTP, :new, ->(*) { client }) do
          first = QueryEmbedder.call(query: query, model: "qwen-test")
          second = QueryEmbedder.call(query: query, model: "qwen-test")

          assert first[:ok]
          assert_equal [0.25, 0.5, 0.75], first[:embedding]
          assert_equal 3, first[:dimensions]
          refute first[:cached]
          assert second[:cached]
          assert_equal 1, client.request_count
        end
      end
    end

    test "does not call Ollama for a blank query" do
      result = QueryEmbedder.call(query: "", model: "qwen-test")

      refute result[:ok]
      assert_equal "query missing", result[:error]
      assert_empty result[:embedding]
    end

    private

    def with_singleton_method(object, method_name, replacement)
      singleton = object.singleton_class
      original = singleton.instance_method(method_name)
      singleton.define_method(method_name, replacement)
      yield
    ensure
      singleton&.define_method(method_name, original) if original
    end
  end
end
