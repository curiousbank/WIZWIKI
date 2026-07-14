module Autos
  class WorkerStatus
    def self.full(worker_id:, worker_queue: nil, embedding_model: nil)
      Autos::WorkerQueue.status_for(worker_id: worker_id, worker_queue: worker_queue).merge(
        cloud_writer: cloud_writer_status,
        vector_store: Autos::EmbeddingQueue.status_for(worker_id: worker_id, embedding_model: embedding_model)
      )
    end

    def self.lightweight(worker_id:, worker_queue: nil)
      normalized_queue = Autos::WorkerQueue.normalize_worker_queue(worker_queue)
      has_queue_work = safe_boolean { Autos::WorkerQueue.queued_scope_for(normalized_queue).exists? }
      has_claimed_work = safe_boolean { Autos::WorkerQueue.claimed_scope.exists? }
      queued_count = has_queue_work ? 1 : 0
      claimed_count = has_claimed_work ? 1 : 0

      {
        ok: true,
        app: "WIZWIKI",
        node: "Alice",
        worker_id: worker_id.presence || "alice-wizwiki-01",
        worker_queue: normalized_queue,
        role: "Thumper von AUTOS runtime for WIZWIKI",
        enabled: Autos::WorkerQueue.enabled?,
        queued: queued_count,
        queued_all: queued_count,
        queued_telegram: nil,
        queued_web: nil,
        queued_comms: %w[sms comms].include?(normalized_queue) ? queued_count : nil,
        queued_sms: %w[sms comms].include?(normalized_queue) ? queued_count : nil,
        claimed: claimed_count,
        active: claimed_count,
        provider: WizwikiSettings.active_ai_provider,
        local_model: Autos::WorkerQueue.local_model,
        local_frontier_model: Autos::WorkerQueue.local_frontier_model,
        weather_calibration_model: Autos::WorkerQueue.weather_calibration_model,
        embedder_model: Autos::WorkerQueue.embedder_model,
        openai_runtime_enabled: WizwikiSettings.openai_runtime_enabled?,
        qwen_only: WizwikiSettings.qwen_only?,
        lightweight: true,
        generated_at: Time.zone.now.iso8601
      }.compact
    end

    def self.cloud_writer_status
      scope = cloud_writer_scope
      recent_window = 30.minutes.ago
      recent_scope = scope.where("created_at >= :cutoff OR updated_at >= :cutoff", cutoff: recent_window)
      active_scope = scope
        .where(status: "queued", answer: [nil, ""])
        .where("metadata -> 'local_worker' ->> 'status' IN (?)", %w[queued processing])

      {
        active: active_scope.exists?,
        queued: active_scope.where("metadata -> 'local_worker' ->> 'status' = 'queued'").count,
        processing: active_scope.where("metadata -> 'local_worker' ->> 'status' = 'processing'").count,
        answered_recent: recent_scope.where(status: "answered").count,
        failed_recent: recent_scope.where(status: "failed").count,
        role: "SolidQueue cloud writer for ask and comms drafts",
        providers: %w[nvidia openai],
        recent: scope.order(updated_at: :desc).limit(8).map { |question| cloud_writer_row(question) }
      }
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerStatus] cloud writer status failed #{error.class}: #{error.message}")
      {
        active: false,
        queued: 0,
        processing: 0,
        answered_recent: 0,
        failed_recent: 0,
        error: error.message
      }
    end

    def self.cloud_writer_scope
      AutosQuestion.where(<<~SQL.squish)
        (metadata ->> 'cloud_sms_writer' = 'true')
        OR (metadata ->> 'model_lane' = 'ask_cloud_writer')
        OR (metadata -> 'local_worker' ->> 'provider' IN ('nvidia', 'openai'))
      SQL
    end

    def self.cloud_writer_row(question)
      metadata = question.metadata.to_h
      worker = metadata["local_worker"].to_h
      {
        id: question.id,
        status: question.status,
        surface: metadata["surface"],
        stage_id: metadata["comms_stage_id"],
        writer_model: metadata["writer_model"],
        writer_model_label: metadata["writer_model_label"],
        worker_status: worker["status"],
        provider: worker["provider"] || metadata["cloud_sms_writer_provider"],
        model: worker["model"] || metadata["cloud_sms_writer_model"],
        elapsed_seconds: worker["elapsed_seconds"],
        last_error: worker["last_error"],
        created_at: question.created_at&.iso8601,
        updated_at: question.updated_at&.iso8601,
        answer_preview: question.answer.to_s.squish.first(120)
      }.compact_blank
    end

    def self.safe_boolean
      yield
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerStatus] lightweight status check failed #{error.class}: #{error.message}")
      false
    end
  end
end
