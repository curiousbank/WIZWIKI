module Fathom
  class DailyCallSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id:, requested_by_user_id: nil, requested_at: nil, request_id: nil, date: nil, automation_run_id: nil, publish_digest: nil)
      raise Fathom::Error, "Fathom API key is not configured" unless WizwikiSettings.fathom_configured?

      organization = Organization.find(organization_id)
      automation_run = automation_run_for(automation_run_id)
      sync_date = parse_date(date)
      publish_digest = publish_digest_enabled?(publish_digest, sync_date)
      automation_run&.mark_running!(step: "fathom_sync_started", data: { date: sync_date.iso8601 })
      Fathom::DailyCallSyncStatus.mark_running!(
        organization: organization,
        request_id: request_id,
        job_id: job_id,
        requested_by_user_id: requested_by_user_id,
        requested_at: requested_at,
        date: sync_date
      )

      started_at = Time.current
      result = Fathom::DailyCallSync.call(organization: organization, date: sync_date)
      completed_at = Time.current
      Fathom::DailyCallSyncStatus.mark_success!(organization: organization, result: result, request_id: request_id, job_id: job_id)
      automation_run&.append_event!(step: "fathom_sync_complete", data: result.to_h.merge(duration_seconds: (completed_at.to_f - started_at.to_f).round))
      if result.call_count.to_i.zero?
        Fathom::DailyCallSyncStatus.mark_no_calls!(
          organization: organization,
          request_id: request_id.presence || job_id,
          job_id: job_id
        )
        automation_run&.mark_skipped!(step: "no_fathom_calls", data: result.to_h.merge(reason: "no calls found; digest skipped"))
        Rails.logger.info("[Fathom::DailyCallSyncJob] organization=#{organization.id} date=#{sync_date} no Fathom calls found; digest skipped")
        return
      end
      enqueue_digest_publish(
        organization: organization,
        date: sync_date,
        result: result,
        started_at: started_at,
        completed_at: completed_at,
        request_id: request_id,
        automation_run: automation_run,
        publish_digest: publish_digest
      )
      Rails.logger.info("[Fathom::DailyCallSyncJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} #{result.to_h.inspect}")
    rescue Fathom::Error, ActiveRecord::ActiveRecordError => error
      Fathom::DailyCallSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id) if defined?(organization) && organization.present?
      automation_run&.mark_failed!(step: "fathom_sync_failed", error: error) if defined?(automation_run) && automation_run.present?
      Rails.logger.warn("[Fathom::DailyCallSyncJob] organization_id=#{organization_id} failed: #{error.class}: #{error.message}")
    end

    private

    def enqueue_digest_publish(organization:, date:, result:, started_at:, completed_at:, request_id:, automation_run:, publish_digest:)
      if content_hydration_enabled?
        enqueue_content_hydration(
          organization: organization,
          date: date,
          result: result,
          started_at: started_at,
          completed_at: completed_at,
          request_id: request_id,
          automation_run: automation_run,
          publish_digest: publish_digest
        )
        return
      end

      unless publish_digest
        automation_run&.mark_succeeded!(
          step: "historical_digest_suppressed",
          data: {
            date: date.iso8601,
            reason: "Historical Fathom catch-up sync completed without sending an email digest."
          }
        )
        return
      end

      enqueue_direct_digest_publish(
        organization: organization,
        date: date,
        result: result,
        started_at: started_at,
        completed_at: completed_at,
        request_id: request_id,
        automation_run: automation_run
      )
    end

    def enqueue_content_hydration(organization:, date:, result:, started_at:, completed_at:, request_id:, automation_run:, publish_digest:)
      hydration_at = next_content_hydration_time(date)
      job = Fathom::ContentHydrationJob.set(wait_until: hydration_at).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        result: result.to_h,
        started_at: started_at.iso8601,
        completed_at: completed_at.iso8601,
        request_id: request_id,
        queued_at: hydration_at.iso8601,
        automation_run_id: automation_run&.id,
        attempt: 1,
        publish_digest: publish_digest
      )
      automation_run&.mark_waiting!(
        step: "content_hydration_queued",
        data: {
          job_id: job.job_id,
          scheduled_for: hydration_at.iso8601,
          publish_digest: publish_digest
        }
      )

      Fathom::DailyCallSyncStatus.mark_embedding!(
        organization: organization,
        request_id: request_id.presence || job_id,
        job_id: job_id,
        digest_job_id: job.job_id,
        embedding_status: {
          "status" => "queued_for_content_hydration",
          "scheduled_for" => hydration_at.iso8601,
          "embedding_model" => Autos::EmbeddingQueue.embedder_model
        }
      )
    rescue StandardError => error
      automation_run&.mark_failed!(step: "content_hydration_enqueue_failed", error: error)
      Rails.logger.warn("[Fathom::DailyCallSyncJob] content hydration enqueue failed organization=#{organization.id}: #{error.class}: #{error.message}")
    end

    def enqueue_direct_digest_publish(organization:, date:, result:, started_at:, completed_at:, request_id:, automation_run:)
      publish_at = next_digest_publish_time(date)
      job = Fathom::PublishTrainingDigestJob.set(wait_until: publish_at).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        result: result.to_h,
        started_at: started_at.iso8601,
        completed_at: completed_at.iso8601,
        request_id: request_id,
        queued_at: publish_at.iso8601,
        automation_run_id: automation_run&.id
      )
      automation_run&.mark_waiting!(step: "digest_queued", data: { job_id: job.job_id, scheduled_for: publish_at.iso8601 })

      Fathom::DailyCallSyncStatus.mark_embedding!(
        organization: organization,
        request_id: request_id.presence || job_id,
        job_id: job_id,
        digest_job_id: job.job_id,
        embedding_status: {
          "status" => "queued_for_embedding_digest",
          "scheduled_for" => publish_at.iso8601,
          "embedding_model" => Autos::EmbeddingQueue.embedder_model
        }
      )
    rescue StandardError => error
      automation_run&.mark_failed!(step: "digest_enqueue_failed", error: error)
      Rails.logger.warn("[Fathom::DailyCallSyncJob] digest publish enqueue failed organization=#{organization.id}: #{error.class}: #{error.message}")
    end

    def automation_run_for(id)
      return if id.blank?

      WizwikiAutomationRun.find_by(id: id)
    end

    def next_digest_publish_time(_date)
      minutes = ENV.fetch("FATHOM_DIGEST_INITIAL_WAIT_MINUTES", "5").to_i
      [minutes, 1].max.minutes.from_now
    end

    def next_content_hydration_time(_date)
      minutes = ENV.fetch("FATHOM_CONTENT_HYDRATION_INITIAL_WAIT_MINUTES", "3").to_i
      [minutes, 1].max.minutes.from_now
    end

    def content_hydration_enabled?
      value = ENV["FATHOM_CONTENT_HYDRATION_ENABLED"]
      value.blank? || ActiveModel::Type::Boolean.new.cast(value)
    end

    def publish_digest_enabled?(value, date)
      return ActiveModel::Type::Boolean.new.cast(value) unless value.nil?
      return true if date == Time.current.in_time_zone("Central Time (US & Canada)").to_date

      ActiveModel::Type::Boolean.new.cast(ENV["FATHOM_DIGEST_EMAIL_HISTORICAL_ENABLED"]) == true
    end

    def parse_date(value)
      return Time.current.in_time_zone("Central Time (US & Canada)").to_date if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.current.in_time_zone("Central Time (US & Canada)").to_date
    end
  end
end
