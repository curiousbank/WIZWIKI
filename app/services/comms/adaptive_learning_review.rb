# frozen_string_literal: true

module Comms
  class AdaptiveLearningReview
    EMBEDDING_SCOPE = Autos::EmbeddingQueue::ADAPTIVE_SMS_SCOPE
    PENDING_STATUS = "pending_review".freeze
    APPROVED_STATUS = "approved_positive".freeze
    REJECTED_STATUS = "rejected".freeze
    REVOKED_STATUS = "revoked".freeze
    REVIEW_NOTE_LIMIT = 500
    FEED_LIMIT = 24

    class << self
      def candidate_scope(organization)
        stage_memory_scope(organization)
          .where.not(status: "archived")
          .where("metadata ->> 'learning_status' = ?", PENDING_STATUS)
      end

      def approved_scope(organization)
        stage_memory_scope(organization)
          .where.not(status: "archived")
          .where("metadata ->> 'learning_status' = ?", APPROVED_STATUS)
      end

      def feed(organization:, limit: FEED_LIMIT)
        limit = limit.to_i.clamp(1, 50)
        candidates = candidate_scope(organization).order(updated_at: :desc, id: :desc).limit(limit).to_a
        activity = learning_activity_scope(organization).order(updated_at: :desc, id: :desc).limit(limit).to_a
        stages = stages_for(organization, candidates)
        latest_quality = learning_kind_scope(organization, Comms::AutopilotLearning::QUALITY_TRAINING_KIND)
          .where.not(status: "archived")
          .order(updated_at: :desc)
          .first

        {
          generated_at: Time.current.iso8601,
          stats: {
            pending: candidate_scope(organization).count,
            approved: approved_scope(organization).count,
            embedded: embedded_count(organization),
            rejected_7d: rejected_recent_scope(organization).count,
            quality_flags: latest_quality&.metadata.to_h["quality_issue_count"].to_i
          },
          candidates: candidates.map { |document| serialize_candidate(document, stages[document.metadata.to_h["comms_stage_id"].to_i]) },
          activity: activity.map { |document| serialize_activity(document) }
        }
      end

      def approve!(document:, reviewer:, note: nil)
        ensure_stage_memory!(document)
        metadata = document.metadata.to_h
        unless metadata["learning_status"].to_s == PENDING_STATUS
          raise ArgumentError, "Only pending learning candidates can be approved."
        end

        stale_vectors!(document)
        now = Time.current
        document.with_lock do
          document.update!(
            title: document.title.to_s.sub(/\ATHUMPER LEARNING CANDIDATE/, "Thumper APPROVED MEMORY"),
            status: "ingested",
            metadata: metadata.merge(
              "learning_status" => APPROVED_STATUS,
              "retrieval_role" => "positive_example",
              "composition_eligible" => true,
              "human_review_required" => false,
              "human_reviewed" => true,
              "reviewed_by_user_id" => reviewer.id,
              "reviewed_by" => reviewer.display_name,
              "reviewed_at" => now.iso8601,
              "review_note" => clean_note(note),
              "embedding_scope" => EMBEDDING_SCOPE
            ).compact
          )
        end

        queued = Autos::EmbeddingQueue.enqueue_source!(document, scope: EMBEDDING_SCOPE)
        publish("comms.adaptive_learning_approved", document, reviewer, queued: queued)
        { ok: true, queued: queued, document_id: document.id, status: document.reload.status }
      end

      def reject!(document:, reviewer:, note: nil)
        ensure_stage_memory!(document)
        unless document.metadata.to_h["learning_status"].to_s == PENDING_STATUS
          raise ArgumentError, "Only pending learning candidates can be rejected."
        end

        stale_vectors!(document)
        now = Time.current
        document.update!(
          status: "archived",
          metadata: document.metadata.to_h.merge(
            "learning_status" => REJECTED_STATUS,
            "retrieval_role" => "negative_example",
            "composition_eligible" => false,
            "human_review_required" => false,
            "human_reviewed" => true,
            "reviewed_by_user_id" => reviewer.id,
            "reviewed_by" => reviewer.display_name,
            "reviewed_at" => now.iso8601,
            "review_note" => clean_note(note),
            "archived_at" => now.iso8601,
            "archived_reason" => "human_rejected_adaptive_learning_candidate"
          ).compact
        )
        publish("comms.adaptive_learning_rejected", document, reviewer)
        { ok: true, document_id: document.id, status: document.status }
      end

      def revoke!(document:, reviewer:, note: nil)
        ensure_stage_memory!(document)
        unless document.metadata.to_h["learning_status"].to_s == APPROVED_STATUS
          raise ArgumentError, "Only approved adaptive memory can be removed."
        end

        stale_vectors!(document)
        now = Time.current
        document.update!(
          status: "archived",
          metadata: document.metadata.to_h.merge(
            "learning_status" => REVOKED_STATUS,
            "retrieval_role" => "negative_example",
            "composition_eligible" => false,
            "revoked_by_user_id" => reviewer.id,
            "revoked_by" => reviewer.display_name,
            "revoked_at" => now.iso8601,
            "review_note" => clean_note(note).presence || document.metadata.to_h["review_note"],
            "archived_at" => now.iso8601,
            "archived_reason" => "human_revoked_adaptive_learning_memory"
          ).compact
        )
        publish("comms.adaptive_learning_revoked", document, reviewer)
        { ok: true, document_id: document.id, status: document.status }
      end

      private

      def stage_memory_scope(organization)
        learning_kind_scope(organization, Comms::AutopilotLearning::TRAINING_KIND)
      end

      def learning_kind_scope(organization, kind)
        organization.training_documents
          .where(source_type: Comms::AutopilotLearning::SOURCE_TYPE)
          .where("metadata ->> 'training_kind' = ?", kind)
      end

      def learning_activity_scope(organization)
        kinds = [
          Comms::AutopilotLearning::TRAINING_KIND,
          Comms::AutopilotLearning::QUALITY_TRAINING_KIND,
          Comms::AutopilotLearning::DOJO_SCORECARD_TRAINING_KIND,
          Comms::AutopilotLearning::DOJO_JUDGE_TRAINING_KIND
        ]
        organization.training_documents
          .where(source_type: Comms::AutopilotLearning::SOURCE_TYPE)
          .where("metadata ->> 'training_kind' IN (?)", kinds)
      end

      def rejected_recent_scope(organization)
        stage_memory_scope(organization)
          .where("metadata ->> 'learning_status' IN (?)", [REJECTED_STATUS, REVOKED_STATUS])
          .where("updated_at >= ?", 7.days.ago)
      end

      def stages_for(organization, documents)
        ids = documents.filter_map { |document| document.metadata.to_h["comms_stage_id"].presence }.map(&:to_i).uniq
        return {} if ids.blank?

        organization.crm_record_artifacts.includes(:crm_record).where(id: ids).index_by(&:id)
      end

      def serialize_candidate(document, stage)
        metadata = document.metadata.to_h
        {
          id: document.id,
          title: document.title,
          source_label: stage&.crm_record&.name.to_s.presence || stage&.title.to_s.presence || "COMMS stage #{metadata['comms_stage_id']}",
          outcome: metadata["outcome"].to_s.humanize,
          product: metadata["product_interest_label"].presence || metadata["product_interest_code"].to_s.humanize.presence || "General SMS",
          score: metadata["candidate_score"].to_i,
          evidence: Array(metadata["candidate_evidence"]).first(8),
          inbound_count: metadata["sms_inbound_count"].to_i,
          outbound_count: metadata["sms_outbound_count"].to_i,
          body: document.body.to_s.truncate(3_500, omission: "..."),
          updated_at: document.updated_at&.iso8601
        }
      end

      def serialize_activity(document)
        metadata = document.metadata.to_h
        learning_status = metadata["learning_status"].to_s.presence
        {
          id: document.id,
          title: document.title,
          kind: metadata["training_kind"].to_s.humanize,
          state: learning_status || document.status,
          retrieval_role: metadata["retrieval_role"].to_s.humanize.presence,
          updated_at: document.updated_at&.iso8601,
          can_revoke: learning_status == APPROVED_STATUS && document.status != "archived"
        }
      end

      def embedded_count(organization)
        return 0 unless Autos::EmbeddingQueue.storage_ready?

        AutosEmbeddingChunk.where(organization: organization, scope: EMBEDDING_SCOPE, status: "embedded").count
      rescue StandardError
        0
      end

      def ensure_stage_memory!(document)
        metadata = document.metadata.to_h
        return if metadata["training_kind"].to_s == Comms::AutopilotLearning::TRAINING_KIND

        raise ArgumentError, "Document is not an adaptive SMS learning record."
      end

      def stale_vectors!(document)
        Autos::EmbeddingQueue.delete_source!(document) if Autos::EmbeddingQueue.storage_ready?
      end

      def clean_note(note)
        note.to_s.squish.truncate(REVIEW_NOTE_LIMIT).presence
      end

      def publish(event, document, reviewer, extra = {})
        return unless defined?(Autos::MemoryBus)

        Autos::MemoryBus.publish(event, {
          organization_id: document.organization_id,
          training_document_id: document.id,
          reviewer_id: reviewer.id,
          generated_at: Time.current.iso8601
        }.merge(extra))
      rescue StandardError => error
        Rails.logger.warn("[Comms::AdaptiveLearningReview] publish failed #{error.class}: #{error.message}")
      end
    end
  end
end
