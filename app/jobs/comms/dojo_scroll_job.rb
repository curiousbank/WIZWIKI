require "securerandom"

module Comms
  class DojoScrollJob < ApplicationJob
    queue_as :default

    AUTOMATION_KEY = "thumper_dojo_daily_scroll".freeze
    ZONE = "Central Time (US & Canada)".freeze

    def perform(organization_id: nil, date: nil, trigger: "systemd", force: false, automation_run_id: nil, queued_at: nil)
      organizations = organization_id.present? ? [Organization.find(organization_id)] : Organization.all.to_a
      organizations.each do |organization|
        publish_for_organization!(
          organization: organization,
          date: parse_date(date),
          trigger: trigger,
          force: force,
          automation_run_id: automation_run_id,
          queued_at: queued_at
        )
      end
    end

    private

    def publish_for_organization!(organization:, date:, trigger:, force:, automation_run_id:, queued_at:)
      run = automation_run_for(organization: organization, date: date, trigger: trigger, force: force, automation_run_id: automation_run_id)
      return if run.blank?

      run.mark_running!(step: "dojo_learning_refresh", data: { date: date.iso8601 })
      learning_result = Comms::AutopilotLearning.call(
        organization: organization,
        lookback_days: ENV.fetch("THUMPER_DOJO_SCROLL_LEARNING_LOOKBACK_DAYS", "14").to_i,
        limit: ENV.fetch("THUMPER_DOJO_SCROLL_LEARNING_LIMIT", "120").to_i,
        dry_run: false
      )
      learning_result_hash = learning_result.to_h.stringify_keys
      run.append_event!(step: "dojo_learning_refreshed", data: learning_result_hash)

      embedding_status = scorecard_embedding_status(organization).merge(
        "memory_retention" => learning_result_hash.slice("memory_documents_archived", "memory_embedding_sources_staled")
      )
      run.append_event!(step: "scorecard_embedding_status", data: embedding_status)
      if embedding_status["waiting"] && wait_for_embeddings?(queued_at)
        reschedule_for_embeddings(organization: organization, date: date, trigger: trigger, force: force, run: run, queued_at: parse_time(queued_at) || Time.current, embedding_status: embedding_status)
        return
      end

      result = Comms::DojoScrollDocument.publish(
        organization: organization,
        date: date,
        embedding_status: embedding_status
      )

      if result[:skipped] || result["skipped"]
        run.mark_skipped!(step: "dojo_scroll_skipped", data: result)
      else
        run.mark_succeeded!(step: "dojo_scroll_published", data: result)
      end
    rescue StandardError => error
      run&.mark_failed!(step: "dojo_scroll_failed", error: error)
      Rails.logger.warn("[Comms::DojoScrollJob] organization=#{organization&.id} date=#{date} failed: #{error.class}: #{error.message}")
    end

    def automation_run_for(organization:, date:, trigger:, force:, automation_run_id:)
      return WizwikiAutomationRun.find_by(id: automation_run_id) if automation_run_id.present?

      previous = organization.wizwiki_automation_runs
        .for_automation(AUTOMATION_KEY)
        .where(target_date: date, status: %w[succeeded skipped])
        .recent
        .first
      force_refresh = ActiveModel::Type::Boolean.new.cast(force)

      request_id = SecureRandom.uuid
      run = organization.wizwiki_automation_runs.create!(
        automation_key: AUTOMATION_KEY,
        run_key: "#{AUTOMATION_KEY}:#{organization.id}:#{date.iso8601}:#{request_id}",
        status: "queued",
        trigger: trigger.to_s.presence || "systemd",
        target_date: date,
        scheduled_for: Time.current,
        request_id: request_id,
        current_step: "queued",
        metadata: {
          "force" => force_refresh,
          "daily_doc_mode" => "upsert",
          "refresh_of_run_id" => previous&.id,
          "source" => "solid_queue_recurring",
          "schedule" => "daily at 5:00 AM #{ZONE}",
          "google_folder" => Comms::DojoScrollDocument::FOLDER_NAME
        }
      )
      run.mark_queued!(data: { date: date.iso8601, force: force_refresh, refresh_of_run_id: previous&.id }.compact)
      run
    end

    def reschedule_for_embeddings(organization:, date:, trigger:, force:, run:, queued_at:, embedding_status:)
      job = self.class.set(wait: poll_interval).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        trigger: trigger,
        force: force,
        automation_run_id: run.id,
        queued_at: queued_at.iso8601
      )
      run.mark_waiting!(
        step: "waiting_for_scorecard_embeddings",
        data: embedding_status.merge(next_check_job_id: job.job_id, queued_at: queued_at.iso8601)
      )
    end

    def scorecard_embedding_status(organization)
      return empty_embedding_status("vector storage is not ready") unless defined?(AutosEmbeddingChunk) && Autos::EmbeddingQueue.storage_ready?

      docs = organization.training_documents
        .where(source_type: Comms::AutopilotLearning::SOURCE_TYPE)
        .where("metadata @> ?", { training_kind: Comms::AutopilotLearning::DOJO_SCORECARD_TRAINING_KIND }.to_json)
      doc_ids = docs.pluck(:id)
      model = Autos::EmbeddingQueue.embedder_model
      chunks = AutosEmbeddingChunk.where(
        organization: organization,
        source_type: "TrainingDocument",
        source_id: doc_ids,
        embedding_model: model
      )
      active_chunks = chunks.where.not(status: "stale")
      counts = chunks.group(:status).count
      incomplete = active_chunks.where.not(status: "embedded").count
      missing = [doc_ids.length - active_chunks.distinct.count(:source_id), 0].max
      waiting = incomplete + missing
      {
        "status" => waiting.positive? ? "embedding_in_progress" : "embedding_complete",
        "complete" => waiting.zero?,
        "waiting" => waiting.positive?,
        "embedding_model" => model,
        "document_count" => doc_ids.length,
        "chunk_count" => chunks.count,
        "active_chunk_count" => active_chunks.count,
        "missing_sources" => missing,
        "pending" => counts["pending"].to_i,
        "claimed" => counts["claimed"].to_i,
        "stale" => counts["stale"].to_i,
        "embedded" => counts["embedded"].to_i,
        "failed" => counts["failed"].to_i
      }
    end

    def empty_embedding_status(reason)
      {
        "status" => "embedding_skipped",
        "complete" => true,
        "waiting" => false,
        "reason" => reason,
        "document_count" => 0,
        "chunk_count" => 0,
        "pending" => 0,
        "claimed" => 0,
        "stale" => 0,
        "embedded" => 0,
        "failed" => 0
      }
    end

    def wait_for_embeddings?(queued_at)
      first_queued_at = parse_time(queued_at) || Time.current
      Time.current < first_queued_at + max_wait
    end

    def max_wait
      ENV.fetch("THUMPER_DOJO_EMBEDDING_MAX_WAIT_MINUTES", "90").to_i.clamp(1, 360).minutes
    end

    def poll_interval
      ENV.fetch("THUMPER_DOJO_EMBEDDING_POLL_SECONDS", "600").to_i.clamp(60, 1800).seconds
    end

    def parse_date(value)
      zone = Time.find_zone(ZONE) || Time.zone
      return zone.yesterday.to_date if value.blank?

      value.respond_to?(:to_date) ? value.to_date : zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      (Time.find_zone(ZONE) || Time.zone).yesterday.to_date
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
