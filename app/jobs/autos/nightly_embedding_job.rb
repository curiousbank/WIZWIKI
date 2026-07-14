module Autos
  class NightlyEmbeddingJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, limit: nil)
      return unless Autos::EmbeddingQueue.storage_ready?

      model = Autos::EmbeddingQueue.embedder_model
      organizations = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      organizations.find_each do |organization|
        legacy_cleanup = Autos::EmbeddingQueue.discard_legacy_crm_backlog!(
          organization: organization,
          embedding_model: model,
          max_rows: ENV.fetch("WIZWIKI_CRM_LEGACY_CLEANUP_LIMIT", "25000")
        )
        result = Autos::EmbeddingQueue.enqueue_crm_recent!(
          organization: organization,
          limit: limit.presence,
          embedding_model: model
        )
        fine_training_result = enqueue_fine_training!(organization, model)

        Autos::MemoryBus.publish("memory.nightly_embedding_queued", {
          organization_id: organization.id,
          embedding_model: model,
          counts: result[:counts].to_h,
          fine_training: fine_training_result,
          legacy_cleanup: legacy_cleanup,
          queued: result[:queued].to_i,
          backlog: result[:backlog].to_i,
          scope: "crm_records_and_fine_training",
          generated_at: Time.current.iso8601
        })
        Rails.logger.info("[Autos::NightlyEmbeddingJob] organization=#{organization.id} model=#{model} scope=crm_records_and_fine_training #{result.to_h.merge(fine_training: fine_training_result, legacy_cleanup: legacy_cleanup).inspect}")
      end
    end

    private

    def enqueue_fine_training!(organization, model)
      return { queued: 0, failed: 0, waiting: 0 } unless organization.respond_to?(:training_documents)

      queued = 0
      failed = 0
      documents = organization.training_documents
        .waiting_for_embedding
        .where.not(status: "archived")
        .where(<<~SQL.squish)
          NOT (
            COALESCE(metadata ->> 'training_kind', '') = 'comms_playbook_memory'
            AND COALESCE(metadata ->> 'learning_status', '') <> 'approved_positive'
          )
        SQL
      waiting = documents.count
      documents.find_each do |document|
        if Autos::EmbeddingQueue.enqueue_source!(document, embedding_model: model)
          queued += 1
        else
          failed += 1
        end
      end

      { queued: queued, failed: failed, waiting: waiting }
    end
  end
end
