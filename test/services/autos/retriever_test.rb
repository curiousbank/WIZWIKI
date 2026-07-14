# frozen_string_literal: true

require "test_helper"
require "digest"
require "securerandom"

module Autos
  class RetrieverTest < ActiveSupport::TestCase
    test "keyword retrieval searches embedded chunks and skips the pending backlog" do
      suffix = SecureRandom.hex(4)
      organization = Organization.create!(name: "Retriever #{suffix}", slug: "retriever-#{suffix}")
      model = Autos::EmbeddingQueue.embedder_model
      pending = embedding_chunk(
        organization: organization,
        model: model,
        source_id: 10_001,
        token: "pendingonlytoken",
        status: "pending"
      )
      embedded = embedding_chunk(
        organization: organization,
        model: model,
        source_id: 10_002,
        token: "embeddedonlytoken",
        status: "embedded"
      )

      pending_result = Autos::Retriever.call(
        organization: organization,
        query: "pendingonlytoken",
        embedding_model: model,
        surface: "comms_sms_draft",
        source_types: ["TrainingDocument"]
      )
      embedded_result = Autos::Retriever.call(
        organization: organization,
        query: "embeddedonlytoken",
        embedding_model: model,
        surface: "comms_sms_draft",
        source_types: ["TrainingDocument"]
      )

      assert_empty pending_result.fetch(:results)
      assert_equal [embedded.id], embedded_result.fetch(:results).map { |result| result.fetch(:id) }
      refute_includes embedded_result.fetch(:results).map { |result| result.fetch(:id) }, pending.id
    end

    test "passes source filters into vector SQL and removes duplicate content" do
      suffix = SecureRandom.hex(4)
      organization = Organization.create!(name: "Vector filter #{suffix}", slug: "vector-filter-#{suffix}")
      captured = nil
      vector_rows = [
        vector_result(id: 1, score: 0.82),
        vector_result(id: 2, score: 0.91)
      ]

      with_singleton_method(Autos::EmbeddingQueue, :storage_ready?, -> { true }) do
        with_singleton_method(Autos::EmbeddingQueue, :search, ->(**options) { captured = options; vector_rows }) do
          result = Autos::Retriever.call(
            organization: organization,
            query: "",
            embedding: [0.1, 0.2, 0.3],
            embedding_model: Autos::EmbeddingQueue.embedder_model,
            surface: "comms_sms_draft",
            source_types: ["TrainingDocument"]
          )

          assert_equal ["TrainingDocument"], captured.fetch(:source_types)
          assert_equal [2], result.fetch(:results).map { |item| item.fetch(:id) }
        end
      end
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

    def vector_result(id:, score:)
      {
        id: id,
        content_digest: "same-content",
        source_type: "TrainingDocument",
        source_id: id,
        chunk_index: 0,
        label: "Duplicate #{id}",
        text: "The same retrieved guidance",
        distance: 1.0 - score,
        score: score,
        retrieval_channels: ["vector"],
        metadata: {
          "retrieval_role" => "training_reference",
          "composition_eligible" => true
        }
      }
    end

    def embedding_chunk(organization:, model:, source_id:, token:, status:)
      AutosEmbeddingChunk.create!(
        organization: organization,
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        source_type: "TrainingDocument",
        source_id: source_id,
        chunk_index: 0,
        label: token,
        content: "Retrieval fixture #{token}",
        source_digest: Digest::SHA256.hexdigest("source-#{source_id}"),
        content_digest: Digest::SHA256.hexdigest(token),
        embedding_model: model,
        embedding_dimensions: status == "embedded" ? 3 : nil,
        embedded_at: status == "embedded" ? Time.current : nil,
        status: status,
        metadata: {
          "retrieval_role" => "training_reference",
          "composition_eligible" => true
        }
      )
    end
  end
end
