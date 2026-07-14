require "test_helper"
require "digest"
require "securerandom"

module Autos
  class RagHygieneTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(
        name: "RAG Hygiene #{suffix}",
        slug: "rag-hygiene-#{suffix}"
      )
      @model = Autos::EmbeddingQueue.embedder_model
    end

    test "reclaims stale claimed chunks and clears claim token" do
      chunk = embedding_chunk(
        status: "claimed",
        claimed_at: 2.hours.ago,
        worker_id: "dead-worker",
        metadata: { "claim_token" => "stale-token" }
      )

      result = RagHygiene.call(organization: @organization, claimed_stale_minutes: 30)

      assert_equal 1, result.dig(:reclaimed_stale_claims, :count)
      chunk.reload
      assert_equal "pending", chunk.status
      assert_nil chunk.worker_id
      assert_nil chunk.claimed_at
      assert_nil chunk.metadata["claim_token"]
      assert_equal "dead-worker", chunk.metadata["hygiene_previous_worker_id"]
    end

    test "dry run reports stale claims without mutating them" do
      chunk = embedding_chunk(
        status: "claimed",
        claimed_at: 2.hours.ago,
        worker_id: "dead-worker",
        metadata: { "claim_token" => "stale-token" }
      )

      result = RagHygiene.call(organization: @organization, claimed_stale_minutes: 30, dry_run: true)

      assert_equal true, result.fetch(:dry_run)
      assert_equal 1, result.dig(:reclaimed_stale_claims, :count)
      chunk.reload
      assert_equal "claimed", chunk.status
      assert_equal "dead-worker", chunk.worker_id
      assert_equal "stale-token", chunk.metadata["claim_token"]
    end

    test "optionally prunes old stale chunks only when requested" do
      old_stale = embedding_chunk(status: "stale", source_id: 2)
      old_stale.update_columns(updated_at: 45.days.ago)
      recent_stale = embedding_chunk(status: "stale", source_id: 3)

      result = RagHygiene.call(organization: @organization, prune_stale_days: 30)

      assert_equal 1, result.dig(:pruned_stale_chunks, :count)
      assert_nil AutosEmbeddingChunk.find_by(id: old_stale.id)
      assert AutosEmbeddingChunk.find_by(id: recent_stale.id).present?
    end

    private

    def embedding_chunk(attrs = {})
      source_id = attrs.delete(:source_id) || 1
      status = attrs.delete(:status) || "pending"
      content = "Hygiene content #{source_id}"
      AutosEmbeddingChunk.create!(
        {
          organization: @organization,
          source_type: "CrmRecord",
          source_id: source_id,
          chunk_index: 0,
          label: "CRM #{source_id}",
          content: content,
          source_digest: Digest::SHA256.hexdigest("source #{source_id}"),
          content_digest: Digest::SHA256.hexdigest(content),
          embedding_model: @model,
          status: status,
          scope: RagHygiene::DEFAULT_SCOPE
        }.merge(attrs)
      )
    end
  end
end
