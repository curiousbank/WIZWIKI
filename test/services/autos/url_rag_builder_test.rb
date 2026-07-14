# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Autos
  class UrlRagBuilderTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "URL RAG #{suffix}", slug: "url-rag-#{suffix}")
      @user = users(:one)
    end

    test "builds versioned documents and registers a profile without requesting embeddings" do
      builder = UrlRagBuilder.new(
        organization: @organization,
        user: @user,
        profile_key: "member_manual",
        profile_label: "Member Manual",
        profile_kind: "support",
        description: "Member onboarding",
        pages: { "guide" => "https://example.test/guide" },
        enqueue_embeddings: false
      )
      builder.define_singleton_method(:fetch_page_text) do |_url, redirects: 0|
        "Member guide: sign in and confirm every transaction. #{redirects}"
      end

      result = builder.call
      document = @organization.training_documents.find(result.dig(:documents, 0, :id))

      assert_equal true, result.fetch(:ok)
      assert_equal false, result.fetch(:embeddings_requested)
      assert_equal false, result.fetch(:continuous_embedding_worker_required)
      assert_equal "member_manual", document.metadata.fetch("rag_profile")
      assert_equal "paramount", document.metadata.fetch("retrieval_priority")
      assert_includes Comms::RagProfile.options(organization: @organization), ["Member Manual", "member_manual"]
    end
  end
end
