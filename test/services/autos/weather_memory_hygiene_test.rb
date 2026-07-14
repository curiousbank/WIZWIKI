# frozen_string_literal: true

require "test_helper"
require "digest"
require "securerandom"

module Autos
  class WeatherMemoryHygieneTest < ActiveSupport::TestCase
    test "quarantines legacy weather memory without deleting history" do
      suffix = SecureRandom.hex(4)
      organization = Organization.create!(name: "Weather Hygiene #{suffix}", slug: "weather-hygiene-#{suffix}")
      question = organization.autos_questions.create!(
        user: users(:one),
        question: "Legacy weather analysis",
        answer: "Let me analyze this first. 1.",
        status: "answered",
        metadata: {
          "surface" => "weather_outcome_analysis",
          "weather_analysis_version" => "legacy_v1"
        }
      )
      content = "THUMPER ANSWER: Let me analyze this first. 1."
      chunk = AutosEmbeddingChunk.create!(
        organization: organization,
        source_type: "AutosQuestion",
        source_id: question.id,
        chunk_index: 0,
        label: "Legacy weather memory",
        content: content,
        source_digest: Digest::SHA256.hexdigest(content),
        content_digest: Digest::SHA256.hexdigest(content),
        embedding_model: EmbeddingQueue.embedder_model,
        embedding_dimensions: 3,
        status: "embedded",
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        metadata: {}
      )

      result = WeatherMemoryHygiene.call(organization: organization)

      assert_equal 1, result[:quarantined_chunks]
      assert_equal "stale", chunk.reload.status
      assert_equal false, chunk.metadata["composition_eligible"]
      assert question.reload.metadata["weather_memory_quarantined_at"].present?
    end
  end
end
