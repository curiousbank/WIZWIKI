# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class AdaptiveLearningReviewTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Adaptive Review #{suffix}", slug: "adaptive-review-#{suffix}")
      @user = users(:one)
      @document = TrainingDocument.create!(
        organization: @organization,
        user: @user,
        title: "Thumper LEARNING CANDIDATE // YARD SIGNS // CUSTOMER_REPLIED // STAGE 12",
        body: "# Thumper CONVERSATION LEARNING\n\nA redacted, grounded conversation pattern.",
        source_type: AutopilotLearning::SOURCE_TYPE,
        status: "ingested",
        metadata: {
          "training_kind" => AutopilotLearning::TRAINING_KIND,
          "learning_status" => AdaptiveLearningReview::PENDING_STATUS,
          "retrieval_role" => "quarantined_memory",
          "composition_eligible" => false,
          "human_review_required" => true
        }
      )
    end

    test "approval requires a human and queues only the isolated learning scope" do
      result = AdaptiveLearningReview.approve!(document: @document, reviewer: @user, note: "Useful consultative pattern")

      metadata = @document.reload.metadata
      assert result[:queued]
      assert_equal "approved_positive", metadata["learning_status"]
      assert_equal true, metadata["human_reviewed"]
      assert_equal true, metadata["composition_eligible"]
      assert_equal @user.id, metadata["reviewed_by_user_id"]
      assert_equal [AdaptiveLearningReview::EMBEDDING_SCOPE], AutosEmbeddingChunk.where(source_type: "TrainingDocument", source_id: @document.id).distinct.pluck(:scope)
    end

    test "rejection archives the candidate without embedding it" do
      AdaptiveLearningReview.reject!(document: @document, reviewer: @user, note: "Too specific")

      metadata = @document.reload.metadata
      assert_equal "archived", @document.status
      assert_equal "rejected", metadata["learning_status"]
      assert_equal false, metadata["composition_eligible"]
      assert_equal "negative_example", metadata["retrieval_role"]
      refute AutosEmbeddingChunk.where(source_type: "TrainingDocument", source_id: @document.id, status: "embedded").exists?
    end
  end
end
