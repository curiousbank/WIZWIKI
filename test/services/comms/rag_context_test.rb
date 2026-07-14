# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class RagContextTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "RAG context #{suffix}", slug: "rag-context-#{suffix}")
      @user = users(:one)
    end

    test "retrieval stays inside the selected profile without embeddings" do
      support = training_document(
        title: "313.cash support // FAQ",
        body: "Powderball tickets are reviewed and confirmed from the signed-in play interface.",
        profile: "313_cash"
      )
      training_document(
        title: "WIZWIKI CRM catalog",
        body: "This unrelated organization catalog should not enter the support answer.",
        profile: "wizwiki"
      )

      result = RagContext.call(
        organization: @organization,
        profile: "313_cash",
        query: "How do I play Powderball?"
      )

      assert_equal "versioned_document_keyword", result.fetch(:mode)
      assert_equal [support.id], result.fetch(:selected_documents).map { |item| item.fetch(:id) }
      refute_includes result.to_json, "unrelated organization catalog"
    end

    private

    def training_document(title:, body:, profile:)
      @organization.training_documents.create!(
        user: @user,
        title: title,
        body: body,
        source_type: "pasted_text",
        status: "ingested",
        metadata: {
          "rag_profile" => profile,
          "rag_scope" => profile,
          "retrieval_priority" => "paramount"
        }
      )
    end
  end
end
