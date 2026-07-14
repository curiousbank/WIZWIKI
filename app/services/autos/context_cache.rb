# frozen_string_literal: true

module Autos
  class ContextCache
    DEFAULT_SIZE = ENV.fetch("WIZWIKI_CONTEXT_CACHE_MB", "128").to_i.clamp(32, 512).megabytes
    SHORT_TTL = ENV.fetch("WIZWIKI_CONTEXT_CACHE_SHORT_TTL_SECONDS", "120").to_i.clamp(15, 600).seconds
    MEDIUM_TTL = ENV.fetch("WIZWIKI_CONTEXT_CACHE_MEDIUM_TTL_SECONDS", "300").to_i.clamp(30, 1800).seconds
    LONG_TTL = ENV.fetch("WIZWIKI_CONTEXT_CACHE_LONG_TTL_SECONDS", "900").to_i.clamp(60, 3600).seconds
    CORPUS_VERSION = 2

    STORE = ActiveSupport::Cache::MemoryStore.new(size: DEFAULT_SIZE)

    class << self
      def fetch(key, expires_in: MEDIUM_TTL, &block)
        return yield unless enabled?

        STORE.fetch(expand_key(key), expires_in: expires_in, race_condition_ttl: 5.seconds, &block)
      rescue StandardError => error
        Rails.logger.warn("[Autos::ContextCache] fetch failed key=#{safe_key_label(key)} #{error.class}: #{error.message}")
        yield
      end

      def warm_later(organization:, user: nil, surface: "ask")
        return unless enabled?
        return if organization.blank?

        lock_key = expand_key(["warm", organization.id, surface])
        return unless STORE.write(lock_key, true, expires_in: 45.seconds, unless_exist: true)

        Thread.new do
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection do
              org = Organization.find_by(id: organization.id)
              usr = user.present? ? User.find_by(id: user.id) : nil
              warm_common!(organization: org, user: usr, surface: surface) if org.present?
            end
          end
        rescue StandardError => error
          Rails.logger.warn("[Autos::ContextCache] warm failed org=#{organization&.id} surface=#{surface} #{error.class}: #{error.message}")
        ensure
          STORE.delete(lock_key)
        end
      rescue StandardError => error
        Rails.logger.warn("[Autos::ContextCache] warm_later failed org=#{organization&.id} surface=#{surface} #{error.class}: #{error.message}")
      end

      def warm_common!(organization:, user: nil, surface: "ask")
        return if organization.blank?

        comms_product_offerings(DealReports::CommsDraftWriter::PRODUCT_OFFERINGS_PATH) if defined?(DealReports::CommsDraftWriter)
        comms_fine_training_source_pack(organization)
        comms_fine_training_embedding_chunks(organization)
        warm_ask_context!(organization: organization, user: user) if surface.to_s == "ask"
      end

      def warm_ask_context!(organization:, user: nil)
        return unless defined?(AutosQuestion)

        question = organization.autos_questions.new(
          user: user,
          question: "configured products pricing fulfillment account context and recent calls",
          context: "",
          metadata: { "surface" => "ask", "cache_warmup" => true }
        )
        Autos::ContextBuilder.call(question) if defined?(Autos::ContextBuilder)
      rescue StandardError => error
        Rails.logger.warn("[Autos::ContextCache] ask warm failed org=#{organization&.id} #{error.class}: #{error.message}")
      end

      def comms_product_offerings(path)
        fetch(["comms_product_offerings", path.to_s, file_version(path)], expires_in: LONG_TTL) do
          path.exist? ? path.read.first(12_000) : nil
        end
      end

      def comms_fine_training_source_pack(organization, inventory_limit: nil)
        limit = (inventory_limit || default_fine_training_inventory_limit).to_i
        fetch(["comms_fine_training_source_pack", CORPUS_VERSION, organization.id, limit], expires_in: MEDIUM_TTL) do
          build_comms_fine_training_source_pack(organization, inventory_limit: limit)
        end
      end

      def comms_fine_training_embedding_chunks(organization)
        return [] unless defined?(AutosEmbeddingChunk) && defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

        fetch(["comms_fine_training_embedding_chunks", CORPUS_VERSION, organization.id, Autos::WorkerQueue.embedder_model], expires_in: MEDIUM_TTL) do
          AutosEmbeddingChunk
            .embedded
            .where(
              organization: organization,
              source_type: ["TrainingDocument", "TrainingVaultDocument"],
              embedding_model: Autos::WorkerQueue.embedder_model,
              scope: Autos::EmbeddingQueue::DEFAULT_SCOPE
            )
            .where("COALESCE(metadata ->> 'composition_eligible', 'true') <> 'false'")
            .select(:id, :source_type, :source_id, :label, :content, :metadata, :updated_at)
            .to_a
        end
      rescue StandardError => error
        Rails.logger.warn("[Autos::ContextCache] comms chunk load failed org=#{organization&.id} #{error.class}: #{error.message}")
        []
      end

      def comms_call_scenario_context(organization:, crm_record: nil)
        return if organization.blank?

        fetch(["comms_call_scenario_context", organization.id, crm_record&.id || "none"], expires_in: SHORT_TTL) do
          build_comms_call_scenario_context(organization: organization, crm_record: crm_record)
        end
      end

      def enabled?
        ENV.fetch("WIZWIKI_CONTEXT_CACHE_ENABLED", "1") != "0"
      end

      def short_ttl
        SHORT_TTL
      end

      def medium_ttl
        MEDIUM_TTL
      end

      private

      def build_comms_fine_training_source_pack(organization, inventory_limit:)
        return { total: 0, documents: [] } unless defined?(TrainingDocument)

        training_scope = organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"])
        vault_scope = if defined?(TrainingVaultDocument) && organization.respond_to?(:training_vault_documents)
          organization.training_vault_documents.where(status: %w[approved indexed])
        else
          TrainingDocument.none
        end

        priority_documents = training_scope
          .where(<<~SQL.squish)
            metadata ->> 'retrieval_priority' = 'paramount'
            OR metadata ->> 'training_priority' = 'paramount'
            OR metadata ->> 'training_kind' IN ('thumper_voice_canon', 'copywriter_voice')
          SQL
          .order(updated_at: :desc)
          .limit(24)
          .to_a
        recent_documents = training_scope.order(updated_at: :desc).limit(inventory_limit).to_a
        vault_documents = vault_scope.order(updated_at: :desc).limit(inventory_limit).to_a

        {
          total: training_scope.count + vault_scope.count,
          documents: (priority_documents + recent_documents + vault_documents).uniq { |document| [document.class.name, document.id] }
        }
      end

      def build_comms_call_scenario_context(organization:, crm_record:)
        calls = []
        calls += organization.fathom_calls.active.recent.limit(8).to_a if organization.respond_to?(:fathom_calls)
        if organization.respond_to?(:playbook_calls) && defined?(PlaybookCall)
          graph_calls = crm_record.present? ? PlaybookCall.for_crm_record_graph(crm_record).limit(8).to_a : []
          calls += graph_calls + organization.playbook_calls.active.recent.limit(8).to_a
        end

        calls = calls.uniq { |call| [call.class.name, call.id] }.first(12)
        return if calls.blank?

        {
          source: "recent_fathom_and_playbook_calls",
          usage_rule: "Use these as real sales-call scenario memory: objections, buying signals, useful wording, package-fit patterns, and next-step strategy. Do not quote private call details to the customer unless the current thread already includes them.",
          selected_count: calls.length,
          selected_calls: calls.map do |call|
            {
              source_class: call.class.name,
              title: call.respond_to?(:title) ? call.title : nil,
              recorded_at: (call.respond_to?(:recording_start_time) ? call.recording_start_time : nil)&.iso8601,
              occurred_at: (call.respond_to?(:occurred_at) ? call.occurred_at : nil)&.iso8601,
              context: call.respond_to?(:compact_context) ? call.compact_context(max_chars: 1_200) : nil
            }.compact_blank
          end
        }
      end

      def default_fine_training_inventory_limit
        defined?(DealReports::CommsDraftWriter::FINE_TRAINING_INVENTORY_LIMIT) ? DealReports::CommsDraftWriter::FINE_TRAINING_INVENTORY_LIMIT : 40
      end

      def expand_key(key)
        ["wizwiki_context_cache", Rails.env, key].flatten
      end

      def safe_key_label(key)
        Array(key).flatten.compact.join("/").first(180)
      end

      def file_version(path)
        path.exist? ? path.mtime.to_i : "missing"
      rescue StandardError
        "unknown"
      end
    end
  end
end
