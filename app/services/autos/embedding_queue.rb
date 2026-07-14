require "digest"
require "securerandom"

module Autos
  class EmbeddingQueue
    CLAIM_TIMEOUT = 5.minutes
    CLAIM_BATCH_LIMIT = 100
    DEFAULT_SCOPE = "wizwiki".freeze
    ADAPTIVE_SMS_SCOPE = "wizwiki_sms_learning".freeze
    MAX_CHUNK_CHARS = 1_500
    MIN_CHUNK_CHARS = 120
    CRM_NIGHTLY_LOOKBACK_HOURS = 72
    CRM_LEGACY_CLEANUP_BATCH_SIZE = 5_000
    SOURCE_TYPE_CLAIM_PRIORITIES = {
      "FathomCall" => 0,
      "AutosQuestion" => 1,
      "CrmRecordArtifact" => 1,
      "PlaybookCall" => 2,
      "TrainingDocument" => 2,
      "TrainingVaultDocument" => 2,
      "WeatherLeadSignal" => 3,
      "CrmAddressRecord" => 8,
      "CrmRecord" => 9
    }.freeze
    DEFAULT_CLAIM_PRIORITY = 5

    class << self
      def default_scope_for(source)
        return DEFAULT_SCOPE unless adaptive_sms_memory?(source)

        ADAPTIVE_SMS_SCOPE
      end

      def source_embedding_allowed?(source)
        return true unless comms_stage_memory?(source)

        source.metadata.to_h["learning_status"].to_s == "approved_positive"
      end

      def status_for(worker_id:, embedding_model: nil)
        model = embedding_model.presence || embedder_model
        claimed = storage_ready? ? claimed_scope(model).count : 0
        report_priority = report_priority_status
        text_priority = text_priority_status
        paused = report_priority[:paused] || text_priority[:paused]
        crm_window = crm_claim_window_status
        {
          ok: true,
          worker_id: worker_id.presence || "alice-wizwiki-embeddings-01",
          enabled: storage_ready?,
          pgvector: pgvector_ready?,
          table: table_ready?,
          paused: paused,
          pause_reason: [report_priority[:reason], text_priority[:reason]].compact.join(", ").presence,
          report_queue: report_priority[:report_queue],
          priority_text_queue: text_priority[:priority_text_queue],
          queued: storage_ready? ? claimable_scope(model).count : 0,
          claimed: claimed,
          active: claimed,
          embedded: storage_ready? ? AutosEmbeddingChunk.embedded.where(embedding_model: model).count : 0,
          failed: storage_ready? ? AutosEmbeddingChunk.where(status: "failed").count : 0,
          embedder_model: model,
          crm_immediate_enqueue: crm_immediate_enqueue_enabled?,
          crm_claim_window: crm_window,
          generated_at: Time.zone.now.iso8601
        }
      end

      def enqueue_source!(source, scope: nil, embedding_model: embedder_model)
        enqueue_source_with_result!(source, scope: scope, embedding_model: embedding_model)[:ok]
      end

      def enqueue_source_with_result!(source, scope: nil, embedding_model: embedder_model)
        return { ok: false, status: :skipped, error: "vector storage is not ready" } unless storage_ready?
        unless source.respond_to?(:organization) && source.organization.present?
          return { ok: false, status: :skipped, error: "source organization is missing" }
        end
        unless source_embedding_allowed?(source)
          return { ok: false, status: :quarantined, error: "source requires human approval before embedding" }
        end

        scope = scope.to_s.presence || default_scope_for(source)

        chunks = Autos::EmbeddingSource.chunks_for(source)
        return { ok: false, status: :skipped, error: "embedding content is blank" } if chunks.blank?

        source_digest = Digest::SHA256.hexdigest(chunks.map { |chunk| chunk[:content] }.join("\n\n"))
        now = Time.zone.now
        counts = Hash.new(0)

        AutosEmbeddingChunk.transaction do
          chunks.each_with_index do |chunk, index|
            content_digest = Digest::SHA256.hexdigest(chunk.fetch(:content))
            chunk_metadata = chunk[:metadata].to_h.stringify_keys
            chunk_label = chunk[:label].presence || "#{source.class.name} #{source.id}"
            row = AutosEmbeddingChunk.find_or_initialize_by(
              organization: source.organization,
              source_type: source.class.name,
              source_id: source.id,
              chunk_index: index,
              embedding_model: embedding_model
            )

            if row.persisted? && row.content_digest == content_digest && row.status.in?(%w[embedded pending claimed])
              merged_metadata = row.metadata.to_h.merge(chunk_metadata)
              metadata_updates = {}
              metadata_updates[:scope] = scope if row.scope != scope
              metadata_updates[:label] = chunk_label if row.label != chunk_label
              metadata_updates[:metadata] = merged_metadata if row.metadata.to_h != merged_metadata
              row.update_columns(metadata_updates.merge(updated_at: now)) if metadata_updates.present?
              counter = row.status == "embedded" ? :unchanged_chunks : :already_queued_chunks
              counts[counter] += 1
              next
            end

            row.assign_attributes(
              scope: scope,
              label: chunk_label,
              content: chunk.fetch(:content),
              source_digest: source_digest,
              content_digest: content_digest,
              embedding_dimensions: nil,
              status: "pending",
              worker_id: nil,
              claimed_at: nil,
              embedded_at: nil,
              last_error: nil,
              metadata: chunk_metadata,
              updated_at: now
            )
            row.save!
            counts[:queued_chunks] += 1
          end

          counts[:stale_chunks] = AutosEmbeddingChunk
            .where(organization: source.organization, source_type: source.class.name, source_id: source.id, embedding_model: embedding_model)
            .where("chunk_index >= ?", chunks.length)
            .where.not(status: "claimed")
            .update_all(status: "stale", updated_at: now)
        end

        if source_embedding_pending?(source, embedding_model: embedding_model)
          mark_source_embedding_queued(source)
        else
          mark_source_embedding_indexed(source)
        end

        status = if counts[:queued_chunks].positive?
          :queued
        elsif counts[:already_queued_chunks].positive?
          :already_queued
        else
          :unchanged
        end
        result = {
          ok: true,
          status: status,
          chunk_count: chunks.length,
          queued_chunks: counts[:queued_chunks],
          already_queued_chunks: counts[:already_queued_chunks],
          unchanged_chunks: counts[:unchanged_chunks],
          stale_chunks: counts[:stale_chunks]
        }

        Autos::MemoryBus.publish("memory.source_enqueued", {
          organization_id: source.organization_id,
          source_type: source.class.name,
          source_id: source.id,
          chunk_count: chunks.length,
          queue_status: status,
          queued_chunks: counts[:queued_chunks],
          embedding_model: embedding_model,
          scope: scope
        })

        result
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] enqueue failed source=#{source.class.name}##{source.try(:id)} #{error.class}: #{error.message}")
        { ok: false, status: :failed, error: "#{error.class}: #{error.message}" }
      end

      def enqueue_recent!(organization:, limit: 250, embedding_model: embedder_model)
        return { ok: false, error: "vector storage is not ready" } unless storage_ready?

        Autos::MemoryBus.publish("memory.backfill_started", {
          organization_id: organization.id,
          limit: limit,
          embedding_model: embedding_model
        })

        counts = Hash.new(0)
        scopes = [
          organization.crm_records.order(updated_at: :desc).limit(limit),
          organization.training_documents.order(updated_at: :desc).limit(limit),
          organization.playbook_calls.active.recent.limit(limit)
        ]
        if organization.respond_to?(:training_vault_documents)
          scopes << organization.training_vault_documents.approved_for_memory.recent.limit(limit)
        end
        if organization.respond_to?(:fathom_calls)
          scopes << organization.fathom_calls.active.recent.limit(limit)
        end
        if ActiveRecord::Base.connection.table_exists?(:crm_address_records)
          scopes.insert(1, organization.crm_address_records.order(updated_at: :desc).limit(limit))
        end

        scopes.each do |scope|
          scope.find_each do |source|
            counts[source.class.name] += 1 if enqueue_source!(source, embedding_model: embedding_model)
          end
        end

        result = { ok: true, counts: counts, queued: claimable_scope(embedding_model).count, embedder_model: embedding_model }
        Autos::MemoryBus.publish("memory.backfill_queued", {
          organization_id: organization.id,
          counts: counts,
          queued: result.fetch(:queued),
          embedding_model: embedding_model
        })
        result
      end

      def enqueue_crm_recent!(organization:, limit: nil, embedding_model: embedder_model)
        return { ok: false, error: "vector storage is not ready" } unless storage_ready?

        limit_value = (limit.presence || ENV.fetch("WIZWIKI_CRM_NIGHTLY_EMBED_LIMIT", "1000")).to_i.clamp(1, 10_000)
        lookback_hours = ENV.fetch("WIZWIKI_CRM_NIGHTLY_EMBED_LOOKBACK_HOURS", CRM_NIGHTLY_LOOKBACK_HOURS.to_s).to_i.clamp(24, 24 * 30)
        updated_after = lookback_hours.hours.ago
        Autos::MemoryBus.publish("memory.crm_nightly_embedding_started", {
          organization_id: organization.id,
          limit: limit_value,
          lookback_hours: lookback_hours,
          updated_after: updated_after.iso8601,
          embedding_model: embedding_model
        })

        counts = Hash.new(0)
        queued_chunks = 0
        source_version = Autos::EmbeddingSource::CRM_SOURCE_SCHEMA_VERSION.to_s
        organization.crm_records
          .where.not(status: "archived")
          .where("updated_at >= ?", updated_after)
          .where(<<~SQL.squish, embedding_model: embedding_model, source_version: source_version)
            NOT EXISTS (
              SELECT 1
                FROM autos_embedding_chunks current_chunk
               WHERE current_chunk.organization_id = crm_records.organization_id
                 AND current_chunk.source_type = 'CrmRecord'
                 AND current_chunk.source_id = crm_records.id
                 AND current_chunk.chunk_index = 0
                 AND current_chunk.embedding_model = :embedding_model
                 AND current_chunk.status IN ('pending', 'claimed', 'embedded')
                 AND current_chunk.metadata ->> 'source_schema_version' = :source_version
                 AND NULLIF(current_chunk.metadata ->> 'updated_at', '')::timestamptz = DATE_TRUNC('second', crm_records.updated_at)
            )
          SQL
          .order(updated_at: :asc, id: :asc)
          .limit(limit_value)
          .to_a
          .each do |source|
            source_result = enqueue_source_with_result!(source, embedding_model: embedding_model)
            counts[source_result[:status].to_s] += 1
            queued_chunks += source_result[:queued_chunks].to_i
          end

        backlog = claimable_scope(embedding_model).where(organization: organization).count
        result = {
          ok: true,
          counts: counts,
          queued: queued_chunks,
          backlog: backlog,
          embedder_model: embedding_model,
          limit: limit_value,
          lookback_hours: lookback_hours,
          updated_after: updated_after.iso8601
        }
        Autos::MemoryBus.publish("memory.crm_nightly_embedding_queued", {
          organization_id: organization.id,
          counts: counts,
          queued: result.fetch(:queued),
          backlog: backlog,
          embedding_model: embedding_model,
          limit: limit_value,
          lookback_hours: lookback_hours,
          claim_window: crm_claim_window_status
        })
        result
      end

      def discard_legacy_crm_backlog!(organization:, embedding_model: embedder_model, include_embedded: false, max_rows: nil, batch_size: nil)
        return { ok: false, error: "vector storage is not ready" } unless storage_ready?

        version = Autos::EmbeddingSource::CRM_SOURCE_SCHEMA_VERSION.to_s
        statuses = include_embedded ? AutosEmbeddingChunk::STATUSES : %w[pending failed stale]
        scope = AutosEmbeddingChunk
          .where(organization: organization, source_type: "CrmRecord", embedding_model: embedding_model, status: statuses)
          .where("COALESCE(metadata ->> 'source_schema_version', '') != ?", version)
        scope = scope.where("status != 'claimed' OR claimed_at < ?", CLAIM_TIMEOUT.ago) if include_embedded
        batch_size = (batch_size.presence || CRM_LEGACY_CLEANUP_BATCH_SIZE).to_i.clamp(100, 25_000)
        remaining = max_rows.present? ? max_rows.to_i.clamp(1, 5_000_000) : nil
        deleted = 0

        loop do
          take = remaining.present? ? [batch_size, remaining].min : batch_size
          ids = scope.limit(take).pluck(:id)
          break if ids.blank?

          deleted_now = scope.where(id: ids).delete_all
          deleted += deleted_now
          remaining -= deleted_now if remaining.present?
          break if remaining.present? && remaining <= 0
        end

        { ok: true, deleted: deleted, source_type: "CrmRecord", schema_version: version.to_i, include_embedded: include_embedded }
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] legacy CRM cleanup failed organization=#{organization&.id} #{error.class}: #{error.message}")
        { ok: false, deleted: deleted.to_i, error: "#{error.class}: #{error.message}" }
      end

      def claim_next!(worker_id:, embedding_model: nil)
        return nil unless storage_ready?
        return nil if report_work_active?
        return nil if text_priority_work_active?

        model = embedding_model.presence || embedder_model
        chunk = nil
        AutosEmbeddingChunk.transaction do
          chunk = claimable_candidates(model).min_by { |candidate| claim_sort_key(candidate) }
          next unless chunk.present?

          chunk.update!(
            status: "claimed",
            worker_id: worker_id.to_s.presence || "alice-wizwiki-embeddings-01",
            claimed_at: Time.zone.now,
            attempts: chunk.attempts.to_i + 1,
            last_error: nil,
            metadata: chunk.metadata.to_h.merge("claim_token" => SecureRandom.hex(24))
          )
        end
        chunk
      end

      def payload_for(chunk)
        {
          id: chunk.id,
          source: "wizwiki",
          surface: "embedding",
          scope: chunk.scope,
          source_type: chunk.source_type,
          source_id: chunk.source_id,
          chunk_index: chunk.chunk_index,
          label: chunk.label,
          content: chunk.content,
          content_digest: chunk.content_digest,
          embedding_model: chunk.embedding_model,
          claim_token: chunk.metadata.to_h["claim_token"],
          complete_path: "/autos_worker/embeddings/#{chunk.id}/complete",
          fail_path: "/autos_worker/embeddings/#{chunk.id}/fail"
        }
      end

      def complete!(chunk, embedding:, worker_payload: {})
        validate_claim!(chunk, worker_payload: worker_payload)

        values = normalize_embedding(embedding)
        raise ArgumentError, "embedding required" if values.blank?
        raise ArgumentError, "embedding model mismatch" if worker_payload["embedding_model"].present? && worker_payload["embedding_model"].to_s != chunk.embedding_model

        vector_sql = vector_literal(values)
        quoted_vector = ActiveRecord::Base.connection.quote(vector_sql)
        metadata = chunk.metadata.to_h.except("claim_token").merge(
          "completed_by" => worker_payload["worker_id"].presence,
          "provider" => worker_payload["provider"].presence || "ollama/local",
          "model" => worker_payload["model"].presence || chunk.embedding_model,
          "usage" => worker_payload["usage"].presence
        ).compact

        sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            UPDATE autos_embedding_chunks
               SET embedding = #{quoted_vector}::vector,
                   embedding_dimensions = ?,
                   status = 'embedded',
                   embedded_at = ?,
                   last_error = NULL,
                   metadata = ?,
                   updated_at = ?
             WHERE id = ?
          SQL
          values.length,
          Time.zone.now,
          metadata.to_json,
          Time.zone.now,
          chunk.id
        ])
        ActiveRecord::Base.connection.execute(sql)
        chunk.reload.tap do |completed|
          Autos::MemoryBus.publish("memory.embedding_ready", {
            organization_id: completed.organization_id,
            chunk_id: completed.id,
            source_type: completed.source_type,
            source_id: completed.source_id,
            embedding_model: completed.embedding_model,
            embedding_dimensions: completed.embedding_dimensions,
            worker_id: worker_payload["worker_id"].presence
          })
          mark_source_indexed_if_ready(completed)
        end
      end

      def fail!(chunk, error:, worker_payload: {})
        validate_claim!(chunk, worker_payload: worker_payload)

        chunk.update!(
          status: chunk.attempts.to_i >= 3 ? "failed" : "pending",
          last_error: error.to_s.truncate(1_000),
          claimed_at: nil,
          worker_id: nil,
          metadata: chunk.metadata.to_h.except("claim_token")
        )
        Autos::MemoryBus.publish("memory.embedding_failed", {
          organization_id: chunk.organization_id,
          chunk_id: chunk.id,
          source_type: chunk.source_type,
          source_id: chunk.source_id,
          embedding_model: chunk.embedding_model,
          attempts: chunk.attempts,
          error: error.to_s.truncate(300)
        })
      end

      def validate_claim!(chunk, worker_payload:)
        expected = chunk.metadata.to_h["claim_token"].to_s
        supplied = worker_payload.to_h["claim_token"].to_s
        raise ArgumentError, "embedding claim token missing" if expected.blank? || supplied.blank?

        unless expected.bytesize == supplied.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
          raise ArgumentError, "embedding claim token mismatch"
        end

        assigned_worker = chunk.worker_id.to_s
        supplied_worker = worker_payload.to_h["worker_id"].to_s
        return true if supplied_worker.blank? || assigned_worker.blank? || assigned_worker == supplied_worker

        raise ArgumentError, "embedding worker mismatch"
      end

      def delete_source!(source, embedding_model: nil)
        return false unless storage_ready?
        return false unless source.respond_to?(:organization) && source.organization.present?

        scope = AutosEmbeddingChunk.where(
          organization: source.organization,
          source_type: source.class.name,
          source_id: source.id
        )
        scope = scope.where(embedding_model: embedding_model) if embedding_model.present?
        scope.update_all(status: "stale", updated_at: Time.zone.now)
        true
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] delete source failed source=#{source.class.name}##{source.try(:id)} #{error.class}: #{error.message}")
        false
      end

      def search(organization:, embedding:, embedding_model:, scope: DEFAULT_SCOPE, limit: 8, source_types: nil)
        return [] unless storage_ready?

        values = normalize_embedding(embedding)
        return [] if values.blank?

        model = embedding_model.to_s.presence || embedder_model
        dimension = values.length
        vector_sql = vector_literal(values)
        quoted_vector = ActiveRecord::Base.connection.quote(vector_sql)
        max_distance = ENV.fetch("WIZWIKI_VECTOR_MAX_DISTANCE", "0.55").to_f
        limit = limit.to_i.clamp(1, 50)

        rows = AutosEmbeddingChunk
          .embedded
          .where(organization: organization, scope: scope.to_s.presence || DEFAULT_SCOPE, embedding_model: model, embedding_dimensions: dimension)
        allowed_source_types = Array(source_types).flat_map { |value| value.to_s.split(",") }.map(&:strip).compact_blank
        rows = rows.where(source_type: allowed_source_types) if allowed_source_types.present?
        rows = rows
          .select("autos_embedding_chunks.*, (embedding <=> #{quoted_vector}::vector) AS distance")
          .order(Arel.sql("embedding <=> #{quoted_vector}::vector"))
          .limit(limit)

        rows.map do |row|
          distance = row.read_attribute("distance").to_f
          next if distance > max_distance

          {
            id: row.id,
            content_digest: row.content_digest,
            source_type: row.source_type,
            source_id: row.source_id,
            chunk_index: row.chunk_index,
            label: row.label,
            text: row.content,
            distance: distance,
            score: (1.0 - distance).round(6),
            retrieval_channels: ["vector"],
            model: row.embedding_model,
            scope: row.scope,
            metadata: row.metadata.to_h
          }
        end.compact
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] search failed #{error.class}: #{error.message}")
        []
      end

      def storage_ready?
        pgvector_ready? && table_ready?
      end

      def pgvector_ready?
        !!ActiveRecord::Base.connection.extension_enabled?("vector")
      rescue StandardError
        false
      end

      def table_ready?
        !!ActiveRecord::Base.connection.table_exists?(:autos_embedding_chunks)
      rescue StandardError
        false
      end

      def embedder_model
        Autos::WorkerQueue.embedder_model
      rescue StandardError
        WizwikiSettings.normalize_report_embedder_model_alias(ENV["WIZWIKI_AUTOS_EMBEDDER_MODEL"].presence || ENV["AUTOS_CC_EMBED_MODEL"].presence || WizwikiSettings.report_embedder_model)
      end

      def adaptive_sms_memory?(source)
        comms_stage_memory?(source) && source.metadata.to_h["learning_status"].to_s == "approved_positive"
      end

      def comms_stage_memory?(source)
        defined?(TrainingDocument) && source.is_a?(TrainingDocument) &&
          source.metadata.to_h["training_kind"].to_s == "comms_playbook_memory"
      end

      def report_work_active?
        report_priority_status[:paused]
      end

      def text_priority_work_active?
        text_priority_status[:paused]
      end

      def crm_immediate_enqueue_enabled?
        ENV["WIZWIKI_CRM_IMMEDIATE_EMBEDDING"].to_s.match?(/\A(?:1|true|yes|on)\z/i)
      end

      private

      def text_priority_status
        return text_priority_inactive unless defined?(Autos::WorkerQueue)

        priority = Autos::WorkerQueue.priority_work_status
        paused = ActiveModel::Type::Boolean.new.cast(priority[:active])
        {
          paused: paused,
          reason: paused ? "sms_priority" : nil,
          priority_text_queue: priority
        }
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] text priority check failed #{error.class}: #{error.message}")
        text_priority_inactive.merge(error: error.message)
      end

      def text_priority_inactive
        {
          paused: false,
          reason: nil,
          priority_text_queue: {
            active: false,
            queued: 0,
            claimed: 0,
            surfaces: []
          }
        }
      end

      def report_priority_status
        return report_priority_inactive unless defined?(CrmRecordArtifact) && ActiveRecord::Base.connection.table_exists?(:crm_record_artifacts)

        DealReports::WorkerQueue.release_stale_generating! if defined?(DealReports::WorkerQueue)

        scope = CrmRecordArtifact.where(artifact_type: "market_report")
        queued = scope.where(status: "queued").count
        generating = scope.where(status: "generating").count
        paused = queued.positive? || generating.positive?

        {
          paused: paused,
          reason: paused ? "report_priority" : nil,
          report_queue: {
            queued: queued,
            generating: generating
          }
        }
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] report priority check failed #{error.class}: #{error.message}")
        report_priority_inactive
      end

      def report_priority_inactive
        {
          paused: false,
          reason: nil,
          report_queue: {
            queued: 0,
            generating: 0
          }
        }
      end

      def mark_source_embedding_queued(source)
        source.mark_embedding_queued! if source.respond_to?(:mark_embedding_queued!)
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] source status queue failed source=#{source.class.name}##{source.try(:id)} #{error.class}: #{error.message}")
      end

      def mark_source_embedding_indexed(source)
        source.mark_indexed! if source.respond_to?(:mark_indexed!)
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] source status indexed failed source=#{source.class.name}##{source.try(:id)} #{error.class}: #{error.message}")
      end

      def source_embedding_pending?(source, embedding_model:)
        AutosEmbeddingChunk
          .where(
            organization: source.organization,
            source_type: source.class.name,
            source_id: source.id,
            embedding_model: embedding_model
          )
          .where.not(status: ["embedded", "stale"])
          .exists?
      end

      def mark_source_indexed_if_ready(chunk)
        source = source_record_for(chunk)
        return unless source&.respond_to?(:mark_indexed!)

        remaining = AutosEmbeddingChunk
          .where(
            organization_id: chunk.organization_id,
            source_type: chunk.source_type,
            source_id: chunk.source_id,
            embedding_model: chunk.embedding_model
          )
          .where.not(status: ["embedded", "stale"])
          .exists?
        source.mark_indexed! unless remaining
      rescue StandardError => error
        Rails.logger.warn("[Autos::EmbeddingQueue] source status indexed failed source=#{chunk.source_type}##{chunk.source_id} #{error.class}: #{error.message}")
      end

      def source_record_for(chunk)
        klass = chunk.source_type.safe_constantize
        return nil unless klass&.respond_to?(:find_by)

        klass.find_by(id: chunk.source_id)
      end

      def claimable_scope(embedding_model = embedder_model)
        claimable_base_scope(embedding_model)
          .where(<<~SQL.squish, cutoff: CLAIM_TIMEOUT.ago)
            status = 'pending'
            OR (status = 'claimed' AND claimed_at < :cutoff)
          SQL
      end

      def claimable_base_scope(embedding_model = embedder_model)
        scope = AutosEmbeddingChunk
          .where(embedding_model: embedding_model)
        scope = scope.where.not(source_type: "CrmRecord") unless crm_embedding_window_open?
        scope
      end

      def claimable_candidates(embedding_model = embedder_model)
        [
          claimable_base_scope(embedding_model).where(status: "pending"),
          claimable_base_scope(embedding_model).where(status: "claimed").where("claimed_at < ?", CLAIM_TIMEOUT.ago)
        ].flat_map do |scope|
          scope
            .reorder(:updated_at, :id)
            .limit(claim_batch_limit)
            .lock("FOR UPDATE SKIP LOCKED")
            .to_a
        end
      end

      def crm_claim_window_status
        start_hour, end_hour = crm_claim_window
        {
          open: crm_embedding_window_open?,
          start_hour: start_hour,
          end_hour: end_hour,
          timezone: Time.zone.name,
          current_hour: Time.zone.now.hour
        }
      end

      def crm_embedding_window_open?
        start_hour, end_hour = crm_claim_window
        current_hour = Time.zone.now.hour
        return true if start_hour == end_hour

        if start_hour < end_hour
          current_hour >= start_hour && current_hour < end_hour
        else
          current_hour >= start_hour || current_hour < end_hour
        end
      end

      def crm_claim_window
        raw = ENV.fetch("WIZWIKI_CRM_EMBEDDING_WINDOW", "0-6").to_s
        match = raw.match(/\A\s*(\d{1,2})\s*-\s*(\d{1,2})\s*\z/)
        return [0, 6] unless match

        [match[1].to_i.clamp(0, 23), match[2].to_i.clamp(0, 23)]
      end

      def claim_batch_limit
        ENV.fetch("WIZWIKI_AUTOS_EMBEDDING_CLAIM_BATCH_LIMIT", CLAIM_BATCH_LIMIT.to_s).to_i.clamp(10, 500)
      end

      def claim_sort_key(chunk)
        [
          SOURCE_TYPE_CLAIM_PRIORITIES.fetch(chunk.source_type.to_s, DEFAULT_CLAIM_PRIORITY),
          chunk.updated_at || Time.zone.at(0),
          chunk.id.to_i
        ]
      end

      def claimed_scope(embedding_model = embedder_model)
        AutosEmbeddingChunk
          .where(embedding_model: embedding_model, status: "claimed")
          .where(claimed_at: CLAIM_TIMEOUT.ago..)
      end

      def normalize_embedding(values)
        Array(values).map { |value| Float(value) }.select(&:finite?)
      rescue ArgumentError, TypeError
        []
      end

      def vector_literal(values)
        "[#{values.map { |value| format('%.9g', value) }.join(',')}]"
      end
    end
  end
end
