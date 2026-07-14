module Fathom
  class ContentHydrationJob < ApplicationJob
    queue_as :default

    def perform(
      organization_id:,
      date:,
      result:,
      started_at:,
      completed_at:,
      request_id: nil,
      queued_at: nil,
      automation_run_id: nil,
      attempt: 1,
      publish_digest: true
    )
      organization = Organization.find(organization_id)
      return if digest_already_delivered?(organization, request_id)

      automation_run = automation_run_for(automation_run_id)
      sync_date = parse_date(date)
      first_queued_at = parse_time(queued_at) || Time.current
      result_hash = normalize_result(result)

      automation_run&.append_event!(step: "content_hydration_started", data: { date: sync_date.iso8601, attempt: attempt })
      hydration = Fathom::ContentHydrator.call(
        organization: organization,
        date: sync_date,
        limit: hydration_limit,
        sleep_seconds: hydration_sleep_seconds
      ).to_h.stringify_keys
      automation_run&.append_event!(step: "content_hydration_checked", data: hydration.merge(attempt: attempt))

      if hydration["complete"] || attempt.to_i >= max_attempts
        enqueue_digest_publish(
          organization: organization,
          date: sync_date,
          result: result_hash,
          started_at: started_at,
          completed_at: completed_at,
          request_id: request_id,
          queued_at: first_queued_at,
          automation_run: automation_run,
          hydration: hydration,
          publish_digest: publish_digest
        )
        return
      end

      reschedule_hydration(
        organization: organization,
        date: sync_date,
        result: result_hash,
        started_at: started_at,
        completed_at: completed_at,
        request_id: request_id,
        queued_at: first_queued_at,
        automation_run: automation_run,
        attempt: attempt.to_i + 1,
        hydration: hydration,
        publish_digest: publish_digest
      )
    rescue Fathom::Error, ActiveRecord::ActiveRecordError => error
      Fathom::DailyCallSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id) if defined?(organization) && organization.present?
      automation_run&.mark_failed!(step: "content_hydration_failed", error: error) if defined?(automation_run) && automation_run.present?
      Rails.logger.warn("[Fathom::ContentHydrationJob] organization_id=#{organization_id} failed: #{error.class}: #{error.message}")
    end

    private

    def reschedule_hydration(organization:, date:, result:, started_at:, completed_at:, request_id:, queued_at:, automation_run:, attempt:, hydration:, publish_digest:)
      wait = hydration["rate_limited"].to_i.positive? ? rate_limit_retry_interval : retry_interval
      job = self.class.set(wait: wait).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        result: result,
        started_at: started_at,
        completed_at: completed_at,
        request_id: request_id,
        queued_at: queued_at.iso8601,
        automation_run_id: automation_run&.id,
        attempt: attempt,
        publish_digest: publish_digest
      )
      next_check_at = wait.from_now
      automation_run&.mark_waiting!(
        step: "content_hydration_waiting",
        data: hydration.merge(next_check_job_id: job.job_id, next_check_at: next_check_at.iso8601, attempt: attempt)
      )
      Fathom::DailyCallSyncStatus.mark_embedding!(
        organization: organization,
        request_id: request_id,
        job_id: nil,
        digest_job_id: job.job_id,
        embedding_status: {
          "status" => "hydrating_fathom_content",
          "complete" => false,
          "waiting" => true,
          "hydration" => hydration,
          "attempt" => attempt,
          "next_check_at" => next_check_at.iso8601
        }
      )
    end

    def enqueue_digest_publish(organization:, date:, result:, started_at:, completed_at:, request_id:, queued_at:, automation_run:, hydration:, publish_digest:)
      unless publish_digest
        automation_run&.mark_succeeded!(step: "content_hydration_complete", data: hydration)
        return
      end

      embedding_refresh = refresh_fathom_embeddings(
        organization: organization,
        date: date,
        automation_run: automation_run
      )
      job = Fathom::PublishTrainingDigestJob.set(wait: digest_wait).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        result: digest_result(result, hydration),
        started_at: started_at,
        completed_at: completed_at,
        request_id: request_id,
        queued_at: queued_at.iso8601,
        automation_run_id: automation_run&.id,
        publish_digest: publish_digest
      )
      automation_run&.mark_waiting!(
        step: "digest_queued",
        data: hydration.merge(
          job_id: job.job_id,
          scheduled_for: digest_wait.from_now.iso8601,
          embedding_refresh: embedding_refresh
        )
      )

      Fathom::DailyCallSyncStatus.mark_embedding!(
        organization: organization,
        request_id: request_id,
        job_id: nil,
        digest_job_id: job.job_id,
        embedding_status: {
          "status" => hydration["complete"] ? "content_hydration_complete" : "content_hydration_partial",
          "complete" => hydration["complete"],
          "waiting" => false,
          "hydration" => hydration,
          "embedding_refresh" => embedding_refresh,
          "embedding_model" => Autos::EmbeddingQueue.embedder_model
        }
      )
    rescue StandardError => error
      automation_run&.mark_failed!(step: "digest_enqueue_failed", error: error)
      Rails.logger.warn("[Fathom::ContentHydrationJob] digest enqueue failed organization=#{organization.id}: #{error.class}: #{error.message}")
    end

    def digest_result(result, hydration)
      merged = result.to_h.stringify_keys.merge("content_hydration" => hydration.to_h)
      return merged if hydration["complete"]

      status_note = [
        "Fathom digest sent with partial content hydration after #{hydration["checked"].to_i} checked call(s).",
        "#{hydration["remaining"].to_i} call(s) still had late transcript/detail hydration pending.",
        hydration["rate_limited"].to_i.positive? ? "Fathom rate-limited at least one hydration request, so the email was sent instead of waiting indefinitely." : nil
      ].compact.join(" ")

      merged["operations_note"] = [merged["operations_note"].presence, status_note].compact.join(" ")
      merged
    end

    def digest_already_delivered?(organization, request_id)
      return false if request_id.blank?

      status = Fathom::DailyCallSyncStatus.for(organization)
      status[:request_id].to_s == request_id.to_s && status[:digest_sent_at].present?
    end

    def hydration_limit
      ENV.fetch("FATHOM_CONTENT_HYDRATION_LIMIT", "4").to_i.clamp(1, 25)
    end

    def hydration_sleep_seconds
      ENV.fetch("FATHOM_CONTENT_HYDRATION_SLEEP_SECONDS", "6").to_i.clamp(0, 60)
    end

    def max_attempts
      ENV.fetch("FATHOM_CONTENT_HYDRATION_MAX_ATTEMPTS", "5").to_i.clamp(1, 24)
    end

    def retry_interval
      ENV.fetch("FATHOM_CONTENT_HYDRATION_RETRY_MINUTES", "5").to_i.clamp(1, 120).minutes
    end

    def rate_limit_retry_interval
      ENV.fetch("FATHOM_CONTENT_HYDRATION_RATE_LIMIT_RETRY_MINUTES", "10").to_i.clamp(5, 180).minutes
    end

    def digest_wait
      ENV.fetch("FATHOM_DIGEST_AFTER_HYDRATION_WAIT_SECONDS", "60").to_i.clamp(15, 900).seconds
    end

    def refresh_fathom_embeddings(organization:, date:, automation_run:)
      return { "skipped" => "vector storage is not ready" } unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      result = {
        "call_count" => 0,
        "queued_sources" => 0,
        "failed_sources" => 0,
        "embedding_model" => Autos::EmbeddingQueue.embedder_model
      }

      calls_for_day(organization, date).find_each do |call_record|
        result["call_count"] += 1
        if Autos::EmbeddingQueue.enqueue_source!(call_record)
          result["queued_sources"] += 1
        else
          result["failed_sources"] += 1
        end
      rescue StandardError => error
        result["failed_sources"] += 1
        Rails.logger.warn("[Fathom::ContentHydrationJob] embedding refresh failed call=#{call_record&.id}: #{error.class}: #{error.message}")
      end

      automation_run&.append_event!(step: "fathom_embedding_refresh", data: result)
      result
    end

    def calls_for_day(organization, date)
      start_time = date.beginning_of_day
      end_time = date.tomorrow.beginning_of_day

      organization.fathom_calls
        .active
        .where(
          "(recording_start_time >= :start_time AND recording_start_time < :end_time) OR (fathom_created_at >= :start_time AND fathom_created_at < :end_time)",
          start_time: start_time,
          end_time: end_time
        )
    end

    def automation_run_for(id)
      return if id.blank?

      WizwikiAutomationRun.find_by(id: id)
    end

    def normalize_result(value)
      value.to_h.each_with_object({}) { |(key, result_value), memo| memo[key.to_s] = result_value }
    end

    def parse_date(value)
      return Time.zone.today if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.zone.today
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
