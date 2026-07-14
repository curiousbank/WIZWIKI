class PipelineStatusController < ApplicationController
  allow_unauthenticated_access

  before_action :require_local_request!

  def show
    render json: Rails.cache.fetch("pipeline_status/local/v3", expires_in: 30.seconds, race_condition_ttl: 10.seconds) {
      {
        ok: true,
        app: "WIZWIKI",
        generated_at: Time.current.iso8601,
        pipelines: pipeline_rows
      }
    }
  rescue StandardError => error
    Rails.logger.warn("[PipelineStatus] #{error.class}: #{error.message}")
    render json: {
      ok: false,
      app: "WIZWIKI",
      generated_at: Time.current.iso8601,
      error: "#{error.class}: #{error.message}",
      pipelines: [pipeline_row(
        source: "WIZWIKI.APP",
        label: "WIZWIKI",
        status: "error",
        message: "Pipeline status failed while collecting safe counts.",
        failed: 1
      )]
    }, status: :ok
  end

  private

  def require_local_request!
    return if request.local? || request.remote_ip.to_s.in?(%w[127.0.0.1 ::1])

    head :not_found
  end

  def pipeline_rows
    [
      app_pipeline_row,
      autos_pipeline_row,
      sms_pipeline_row,
      dojo_pipeline_row,
      email_pipeline_row,
      fathom_pipeline_row,
      weather_pipeline_row,
      reports_pipeline_row,
      embeddings_pipeline_row,
      memory_pipeline_row
    ].compact
  end

  def app_pipeline_row
    pipeline_row(
      source: "WIZWIKI.APP",
      label: "WIZWIKI",
      status: "online",
      message: "Rails app and database are responding on the local status lane.",
      updated_at: Time.current,
      details: {
        environment: Rails.env,
        organization_count: safe_count(Organization.all)
      }
    )
  end

  def autos_pipeline_row
    status = Autos::WorkerQueue.status_for(worker_id: "pb-ai-dashboard", worker_queue: "all").with_indifferent_access
    queued = status[:queued_all].to_i
    claimed = status[:claimed].to_i
    pipeline_row(
      source: "AUTOS.ASK",
      label: "AUTOS Ask",
      status: status[:enabled] ? (queued.positive? || claimed.positive? ? "working" : "ready") : "disabled",
      active: queued.positive? || claimed.positive?,
      queued: queued,
      processing: claimed,
      message: "#{queued} ask/comms jobs queued, #{claimed} claimed.",
      model: status[:local_model].presence || status[:provider],
      updated_at: status[:generated_at],
      details: status.slice(:queued_web, :queued_sms, :queued_comms, :priority_work, :qwen_only, :openai_runtime_enabled)
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.ASK", "AUTOS Ask", error)
  end

  def sms_pipeline_row
    return missing_pipeline_row("AUTOS.SMS", "Thumper SMS", "comm staging table missing") unless crm_record_artifacts_ready?

    board_snapshot = comms_board_status_counts_snapshot_for_pipeline
    board_counts = board_snapshot.fetch("counts", {}).to_h
    worker_status = Autos::WorkerQueue.status_for(worker_id: "pipeline-status", worker_queue: "all").with_indifferent_access
    queued = worker_status[:queued_comms].to_i + worker_status[:queued_sms].to_i
    processing = worker_status[:claimed].to_i
    active_count = queued + processing
    autopilot_threads = board_counts["autopilot"].to_i
    awaiting = board_counts["needs_reply"].to_i
    sent_recent = board_counts["waiting"].to_i

    pipeline_row(
      source: "AUTOS.SMS",
      label: "Thumper SMS",
      status: active_count.positive? ? "drafting" : (autopilot_threads.positive? ? "listening" : "ready"),
      active: active_count.positive?,
      queued: queued,
      processing: processing,
      completed: sent_recent,
      failed: 0,
      message: "#{autopilot_threads} autopilot threads, #{awaiting} awaiting answer, #{sent_recent} waiting/recent sends.",
      model: "Thumper SMS autopilot",
      updated_at: board_snapshot["updated_at"],
      details: {
        active_threads: autopilot_threads,
        inbound_waiting: awaiting,
        snapshot_records: board_snapshot["record_count"].to_i
      }
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.SMS", "Thumper SMS", error)
  end

  def dojo_pipeline_row
    return missing_pipeline_row("AUTOS.DOJO", "Thumper Dojo", "comm staging table missing") unless crm_record_artifacts_ready?

    counts = recent_dojo_status_sample

    queued = counts["queued"].to_i
    running = counts["running"].to_i
    complete_recent = counts["complete_recent"].to_i
    failed_recent = counts["failed_recent"].to_i

    pipeline_row(
      source: "AUTOS.DOJO",
      label: "Thumper Dojo",
      status: running.positive? ? "running" : queued.positive? ? "queued" : "ready",
      active: (queued + running).positive?,
      queued: queued,
      processing: running,
      completed: complete_recent,
      failed: failed_recent,
      message: "#{queued} queued, #{running} running, #{complete_recent} completed recently.",
      model: "Qwen judge + recursive convo dojo",
      updated_at: counts["latest_stage_at"],
      details: {
        total_dojo_threads: counts["total_dojo_threads"].to_i
      }
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.DOJO", "Thumper Dojo", error)
  end

  def email_pipeline_row
    return missing_pipeline_row("AUTOS.EMAIL", "Thumper Email", "comm staging table missing") unless crm_record_artifacts_ready?

    scope = comm_staging_scope
    recent_scope = scope.where(updated_at: recent_cutoff..)
    draft_questions = autos_questions_ready? ? AutosQuestion.where("metadata ->> 'surface' IN (?)", %w[comms_email_draft email_follow_up]).where(status: "queued").count : 0
    sent_recent = recent_scope.where("metadata ->> 'email_follow_up_last_status' = ?", "sent").count
    errors_recent = recent_scope.where("metadata ? 'email_follow_up_last_error'")

    pipeline_row(
      source: "AUTOS.EMAIL",
      label: "Thumper Email",
      status: draft_questions.positive? ? "drafting" : "ready",
      active: draft_questions.positive?,
      queued: draft_questions,
      completed: sent_recent,
      failed: errors_recent.count,
      message: "#{draft_questions} email drafts queued, #{sent_recent} recent follow-up sends.",
      model: "Thumper email follow-up",
      updated_at: [recent_scope.maximum(:updated_at), latest_autos_question_at("comms_email_draft")].compact.max
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.EMAIL", "Thumper Email", error)
  end

  def fathom_pipeline_row
    return missing_pipeline_row("AUTOS.FATHOM", "Fathom Brain", "Fathom call table missing") unless model_ready?(FathomCall)

    scope = FathomCall.all
    recent_scope = scope.where(updated_at: recent_cutoff..)
    failed_recent = recent_scope.where(status: "failed").count

    pipeline_row(
      source: "AUTOS.FATHOM",
      label: "Fathom Brain",
      status: failed_recent.positive? ? "needs_review" : "synced",
      active: recent_scope.exists?,
      completed: recent_scope.where(status: "synced").count,
      failed: failed_recent,
      message: "#{recent_scope.count} Fathom calls updated recently, #{scope.count} total synced records.",
      model: "Fathom digest + training docs",
      updated_at: scope.maximum(:updated_at),
      details: {
        total_calls: scope.count,
        archived: scope.where(status: "archived").count
      }
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.FATHOM", "Fathom Brain", error)
  end

  def weather_pipeline_row
    org = pipeline_organization
    scan = org.present? && defined?(Weather::ScanStatus) ? Weather::ScanStatus.for(org).with_indifferent_access : {}
    signals = model_ready?(WeatherLeadSignal) ? WeatherLeadSignal.where(status: "active").count : 0
    predictions = model_ready?(KalshiWeatherPrediction) ? KalshiWeatherPrediction.where(status: "open", result_status: "pending").count : 0
    wagers = model_ready?(KalshiWeatherWager) ? KalshiWeatherWager.open_journal.count : 0
    placed_today = model_ready?(KalshiWeatherWager) ? KalshiWeatherWager.where(budget_date: Time.zone.today).where(status: %w[pending placed filled won lost pushed]).count : 0
    active = ActiveModel::Type::Boolean.new.cast(scan[:active]) || wagers.positive?

    pipeline_row(
      source: "AUTOS.WEATHER",
      label: "Weather + Kalshi",
      status: active ? (scan[:state].presence || "watching") : "watching",
      active: active,
      queued: scan[:queued] ? 1 : 0,
      processing: scan[:running] ? 1 : wagers,
      completed: placed_today,
      failed: scan[:last_error].present? ? 1 : 0,
      message: "#{scan[:state_label].presence || "Storm Watch ready"}; #{predictions} open markets, #{wagers} open wagers, #{signals} active signals.",
      model: "Qwen weather scout + Kalshi journal",
      updated_at: [scan[:started_at], scan[:completed_at], latest_model_time(KalshiWeatherPrediction), latest_model_time(KalshiWeatherWager)].compact.max,
      details: {
        active_weather_signals: signals,
        open_predictions: predictions,
        open_wagers: wagers,
        wagers_today: placed_today,
        fresh_today: scan[:fresh_today]
      }
    )
  rescue StandardError => error
    fallback_pipeline_row("AUTOS.WEATHER", "Weather + Kalshi", error)
  end

  def reports_pipeline_row
    status = DealReports::WorkerQueue.status_for(worker_id: "pb-ai-dashboard").with_indifferent_access
    queued = status[:queued].to_i
    generating = status[:generating].to_i

    pipeline_row(
      source: "WIZWIKI.REPORTS",
      label: "WIZWIKI Reports",
      status: generating.positive? ? "generating" : queued.positive? ? "queued" : "ready",
      active: (queued + generating).positive?,
      queued: queued,
      processing: generating,
      completed: status[:completed].to_i,
      failed: status[:failed].to_i + status[:stale_generating].to_i,
      message: "#{queued} queued, #{generating} generating, #{status[:ready].to_i} ready.",
      model: status[:target_model].presence || status[:provider],
      updated_at: latest_report_time,
      details: status.slice(:priority_queued, :report_ready, :canva_kit_ready, :ready, :stale_generating, :qwen_only, :openai_runtime_enabled)
    )
  rescue StandardError => error
    fallback_pipeline_row("WIZWIKI.REPORTS", "WIZWIKI Reports", error)
  end

  def embeddings_pipeline_row
    status = Autos::EmbeddingQueue.status_for(worker_id: "pb-ai-dashboard").with_indifferent_access
    queued = status[:queued].to_i
    claimed = status[:claimed].to_i

    pipeline_row(
      source: "WIZWIKI.EMBEDDINGS",
      label: "WIZWIKI Vectors",
      status: claimed.positive? ? "embedding" : queued.positive? ? "queued" : status[:paused] ? "paused" : "ready",
      active: (queued + claimed).positive?,
      queued: queued,
      processing: claimed,
      completed: status[:embedded].to_i,
      failed: status[:failed].to_i,
      message: "#{queued} pending, #{claimed} claimed, #{status[:embedded].to_i} embedded.",
      model: status[:embedder_model].presence || "qwen3-embedding:4b",
      updated_at: latest_model_time(AutosEmbeddingChunk),
      details: status.slice(:pgvector, :table, :paused, :pause_reason, :report_queue, :priority_text_queue)
    )
  rescue StandardError => error
    fallback_pipeline_row("WIZWIKI.EMBEDDINGS", "WIZWIKI Vectors", error)
  end

  def memory_pipeline_row
    training_waiting = model_ready?(TrainingDocument) ? TrainingDocument.where(status: "ingested").count : 0
    training_processing = model_ready?(TrainingDocument) ? TrainingDocument.where(status: "processing").count : 0
    training_indexed = model_ready?(TrainingDocument) ? TrainingDocument.where(status: "indexed").count : 0
    vault_waiting = model_ready?(TrainingVaultDocument) ? TrainingVaultDocument.where(status: "approved").count : 0
    vault_indexed = model_ready?(TrainingVaultDocument) ? TrainingVaultDocument.where(status: "indexed").count : 0
    queued = training_waiting + training_processing + vault_waiting
    embedded_docs = model_ready?(AutosEmbeddingChunk) ? AutosEmbeddingChunk.where(source_type: %w[TrainingDocument TrainingVaultDocument], status: "embedded").distinct.count(:source_id) : 0

    pipeline_row(
      source: "WIZWIKI.MEMORY",
      label: "WIZWIKI Memory",
      status: queued.positive? ? "indexing" : "indexed",
      active: queued.positive?,
      queued: training_waiting + vault_waiting,
      processing: training_processing,
      completed: training_indexed + vault_indexed,
      failed: model_ready?(AutosEmbeddingChunk) ? AutosEmbeddingChunk.where(source_type: %w[TrainingDocument TrainingVaultDocument], status: "failed").count : 0,
      message: "#{queued} docs waiting/indexing, #{training_indexed + vault_indexed} indexed, #{embedded_docs} vectorized sources.",
      model: "Training docs + RAG memory",
      updated_at: [latest_model_time(TrainingDocument), latest_model_time(TrainingVaultDocument), latest_model_time(AutosEmbeddingChunk)].compact.max,
      details: {
        training_indexed: training_indexed,
        vault_indexed: vault_indexed,
        embedded_sources: embedded_docs
      }
    )
  rescue StandardError => error
    fallback_pipeline_row("WIZWIKI.MEMORY", "WIZWIKI Memory", error)
  end

  def pipeline_row(source:, label:, status:, message:, active: false, queued: 0, processing: 0, completed: 0, failed: 0, model: nil, updated_at: nil, details: {})
    normalized_time = normalize_time(updated_at)
    {
      source: source,
      label: label,
      status: status.to_s,
      active: ActiveModel::Type::Boolean.new.cast(active) || queued.to_i.positive? || processing.to_i.positive?,
      queued: queued.to_i,
      processing: processing.to_i,
      completed: completed.to_i,
      failed: failed.to_i,
      message: message.to_s.squish.first(240),
      model: model.to_s.squish.first(80),
      updated_at: normalized_time&.iso8601,
      time_label: normalized_time.present? ? time_label(normalized_time) : "standby",
      details: details.to_h.compact_blank
    }.compact_blank
  end

  def fallback_pipeline_row(source, label, error)
    pipeline_row(
      source: source,
      label: label,
      status: "error",
      message: "#{error.class}: #{error.message}".truncate(220),
      failed: 1
    )
  end

  def missing_pipeline_row(source, label, message)
    pipeline_row(
      source: source,
      label: label,
      status: "missing",
      message: message
    )
  end

  def crm_record_artifacts_ready?
    model_ready?(CrmRecordArtifact)
  end

  def autos_questions_ready?
    model_ready?(AutosQuestion)
  end

  def comm_staging_scope
    CrmRecordArtifact.where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
  end

  def pipeline_organization
    @pipeline_organization ||= Organization.order(:id).first
  end

  def recent_cutoff
    30.minutes.ago
  end

  def model_ready?(model)
    model.respond_to?(:table_exists?) && model.table_exists?
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
    false
  end

  def safe_count(scope)
    scope.count
  rescue StandardError
    0
  end

  def comms_board_status_counts_snapshot_for_pipeline
    Rails.cache.fetch("pipeline_status/comms_board_snapshot/v1", expires_in: 30.seconds, race_condition_ttl: 10.seconds) do
      pipeline_organization&.settings.to_h.fetch("comms_board_status_counts", {}).to_h
    end
  end

  def recent_dojo_status_sample
    Rails.cache.fetch("pipeline_status/dojo_recent_sample/v1", expires_in: 30.seconds, race_condition_ttl: 10.seconds) do
      counts = Hash.new(0)
      latest_stage_at = nil

      CrmRecordArtifact
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .order(updated_at: :desc)
        .limit(400)
        .pluck(:metadata, :updated_at)
        .each do |metadata, updated_at|
          status = metadata.to_h["recursive_dojo_status"].to_s
          next if status.blank?

          latest_stage_at = [latest_stage_at, updated_at].compact.max
          counts["total_dojo_threads"] += 1
          counts[status] += 1
          counts["complete_recent"] += 1 if status == "complete" && updated_at >= recent_cutoff
          counts["failed_recent"] += 1 if status == "failed" && updated_at >= recent_cutoff
        end

      counts["latest_stage_at"] = latest_stage_at
      counts
    end
  end

  def latest_autos_question_at(surface)
    return unless autos_questions_ready?

    AutosQuestion.where("metadata ->> 'surface' = ?", surface).maximum(:updated_at)
  end

  def latest_report_time
    return unless crm_record_artifacts_ready?

    CrmRecordArtifact.where(artifact_type: "market_report").maximum(:updated_at)
  end

  def latest_model_time(model)
    return unless model_ready?(model)

    model.maximum(:updated_at)
  rescue StandardError
    nil
  end

  def normalize_time(value)
    case value
    when ActiveSupport::TimeWithZone, Time
      value.in_time_zone
    when Date
      value.in_time_zone
    else
      Time.zone.parse(value.to_s) if value.present?
    end
  rescue ArgumentError, TypeError
    nil
  end

  def time_label(time)
    seconds = (Time.current - time).to_i
    return "now" if seconds < 5
    return "#{seconds}s ago" if seconds < 90

    minutes = seconds / 60
    return "#{minutes}m ago" if minutes < 90

    hours = minutes / 60
    return "#{hours}h ago" if hours < 48

    "#{hours / 24}d ago"
  end
end
