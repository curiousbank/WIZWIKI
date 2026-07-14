require "json"
require "securerandom"

module WizwikiBrain
  class Thumper
    FATHOM_KEY = "fathom_brain_daily_sync".freeze
    DEFAULT_ZONE = "Central Time (US & Canada)".freeze
    FATHOM_QUEUE_JOB_CLASSES = %w[
      Fathom::DailyCallSyncJob
      Fathom::ContentHydrationJob
      Fathom::PublishTrainingDigestJob
    ].freeze
    FATHOM_DIGEST_JOB_CLASSES = %w[
      Fathom::ContentHydrationJob
      Fathom::PublishTrainingDigestJob
    ].freeze

    class << self
      def tick!(now: Time.current)
        new(now: now).tick!
      end

      def enqueue_fathom!(organization:, date: nil, trigger: "manual", force: false)
        new.enqueue_fathom!(organization: organization, date: date, trigger: trigger, force: force)
      end

      def status(limit: 12)
        {
          generated_at: Time.current.iso8601,
          automations: registered_automations,
          recent_runs: WizwikiAutomationRun.includes(:organization).recent.limit(limit).map { |run| serialize_run(run) }
        }
      end

      def registered_automations
        [
          {
            key: FATHOM_KEY,
            label: "Fathom Brain",
            source: "systemd wizwiki-brain-thumper.timer",
            schedule: "daily at #{fathom_schedule_label}; catches up recent missed dates; digest only sends when calls are found",
            owns: [
              "Fathom API sync",
              "FathomCall database upsert",
              "Throttled summary/transcript hydration",
              "Qwen pgvector embedding gate",
              "Cleanup for stale or duplicate Fathom queue jobs",
              "Google Doc digest",
              "Postmark email delivery"
            ]
          }
        ]
      end

      def fathom_zone
        Time.find_zone(ENV["WIZWIKI_BRAIN_FATHOM_ZONE"].presence || DEFAULT_ZONE) ||
          Time.find_zone(DEFAULT_ZONE) ||
          Time.zone
      end

      def serialize_run(run)
        {
          id: run.id,
          organization: run.organization&.name,
          automation_key: run.automation_key,
          status: run.status,
          trigger: run.trigger,
          current_step: run.current_step,
          target_date: run.target_date&.iso8601,
          scheduled_for: run.scheduled_for&.iso8601,
          started_at: run.started_at&.iso8601,
          finished_at: run.finished_at&.iso8601,
          request_id: run.request_id,
          solid_queue_job_id: run.solid_queue_job_id,
          error_message: run.error_message,
          result: run.result.to_h
        }
      end

      private

      def fathom_schedule_label
        zone = fathom_zone
        time = zone.local(2000, 1, 1, fathom_hour, fathom_minute).strftime("%-l:%M %p")
        "#{time} #{zone.name}"
      end

      def fathom_hour
        ENV.fetch("WIZWIKI_BRAIN_FATHOM_HOUR", "18").to_i.clamp(0, 23)
      end

      def fathom_minute
        ENV.fetch("WIZWIKI_BRAIN_FATHOM_MINUTE", "0").to_i.clamp(0, 59)
      end
    end

    def initialize(now: Time.current)
      @now = now.in_time_zone(self.class.fathom_zone)
    end

    def tick!
      results = []
      results << clear_extra_fathom_jobs!
      results << tick_fathom!
      {
        ok: true,
        generated_at: now.iso8601,
        results: results
      }
    end

    def enqueue_fathom!(organization:, date: nil, trigger: "manual", force: false)
      sync_date = parse_date(date)
      return skipped_hash(FATHOM_KEY, "Fathom API is not configured") unless WizwikiSettings.fathom_configured?

      clear_extra_fathom_jobs!

      active = active_run(organization: organization, date: sync_date)
      return skipped_hash(FATHOM_KEY, "Fathom automation already active", run: active) if active.present?

      previous = previous_success(organization: organization, date: sync_date)
      return skipped_hash(FATHOM_KEY, "Fathom automation already completed for #{sync_date}", run: previous) if previous.present? && !force

      request_id = SecureRandom.uuid
      run = organization.wizwiki_automation_runs.create!(
        automation_key: FATHOM_KEY,
        run_key: run_key(organization, sync_date, request_id),
        status: "queued",
        trigger: trigger,
        target_date: sync_date,
        scheduled_for: now,
        request_id: request_id,
        current_step: "queued",
        metadata: {
          "force" => force,
          "publish_digest" => publish_digest_for_date?(sync_date),
          "source" => "wizwiki_brain_thumper",
          "schedule" => self.class.registered_automations.first.fetch(:schedule)
        }
      )
      run.mark_queued!(data: { date: sync_date.iso8601, force: force })

      Fathom::DailyCallSyncStatus.mark_queued!(
        organization: organization,
        request_id: request_id,
        requested_by_user_id: nil,
        requested_by: "WIZWIKI Brain Thumper",
        requested_at: now,
        date: sync_date
      )

      job = Fathom::DailyCallSyncJob.perform_later(
        organization_id: organization.id,
        requested_by_user_id: nil,
        requested_at: now.iso8601,
        request_id: request_id,
        date: sync_date.iso8601,
        automation_run_id: run.id,
        publish_digest: publish_digest_for_date?(sync_date)
      )

      run.update!(solid_queue_job_id: job.job_id)
      Fathom::DailyCallSyncStatus.mark_enqueued!(organization: organization, request_id: request_id, job_id: job.job_id)
      run.append_event!(step: "solid_queue_enqueued", data: { job_id: job.job_id })

      { ok: true, automation: FATHOM_KEY, run: self.class.serialize_run(run.reload) }
    rescue StandardError => error
      run&.mark_failed!(step: "enqueue_failed", error: error)
      raise
    end

    private

    attr_reader :now

    def clear_extra_fathom_jobs!
      return skipped_hash(FATHOM_KEY, "Solid Queue is not loaded") unless defined?(SolidQueue::Job)

      jobs = SolidQueue::Job
        .where(class_name: FATHOM_QUEUE_JOB_CLASSES, finished_at: nil)
        .order(:scheduled_at, :id)
        .to_a
      seen = {}
      cleared_jobs = []

      jobs.each do |job|
        next if solid_queue_claimed?(job)

        payload = fathom_job_payload(job)
        job_date = parse_job_date(payload["date"])
        request_id = payload["request_id"].presence
        reason = extra_fathom_job_reason(job: job, date: job_date, request_id: request_id, seen: seen)
        next if reason.blank?

        cleared_jobs << {
          id: job.id,
          active_job_id: job.active_job_id,
          class_name: job.class_name,
          queue_name: job.queue_name,
          scheduled_at: job.scheduled_at&.iso8601,
          date: job_date&.iso8601,
          request_id: request_id,
          reason: reason
        }
        job.destroy!
      end

      {
        ok: true,
        automation: FATHOM_KEY,
        cleanup: "extra_fathom_jobs",
        checked: jobs.size,
        cleared: cleared_jobs.size,
        cleared_jobs: cleared_jobs
      }
    rescue ActiveRecord::StatementInvalid, NameError => error
      {
        ok: true,
        automation: FATHOM_KEY,
        cleanup: "extra_fathom_jobs",
        skipped: true,
        reason: error.message.to_s.truncate(300)
      }
    end

    def tick_fathom!
      return skipped_hash(FATHOM_KEY, "not due yet") unless fathom_due?

      Organization.find_each.flat_map do |organization|
        fathom_catchup_dates.map do |date|
          enqueue_fathom!(organization: organization, date: date, trigger: "systemd", force: false)
        end
      end
    end

    def fathom_catchup_dates
      (fathom_catchup_start_date..now.to_date).to_a
    end

    def fathom_catchup_start_date
      now.to_date - fathom_catchup_days
    end

    def fathom_due?
      now.hour > fathom_hour || (now.hour == fathom_hour && now.min >= fathom_minute)
    end

    def fathom_hour
      ENV.fetch("WIZWIKI_BRAIN_FATHOM_HOUR", "18").to_i.clamp(0, 23)
    end

    def fathom_minute
      ENV.fetch("WIZWIKI_BRAIN_FATHOM_MINUTE", "0").to_i.clamp(0, 59)
    end

    def fathom_catchup_days
      ENV.fetch("WIZWIKI_BRAIN_FATHOM_CATCHUP_DAYS", "3").to_i.clamp(0, 14)
    end

    def publish_digest_for_date?(date)
      return true if date == now.to_date

      ActiveModel::Type::Boolean.new.cast(ENV["FATHOM_DIGEST_EMAIL_HISTORICAL_ENABLED"]) == true
    end

    def extra_fathom_job_reason(job:, date:, request_id:, seen:)
      return "historical_digest_job" if historical_digest_job?(job.class_name, date)
      return "completed_request" if completed_fathom_request?(request_id)

      duplicate_key = fathom_job_duplicate_key(job, date, request_id)
      return if duplicate_key.blank?

      return "duplicate_fathom_job" if seen[duplicate_key]

      seen[duplicate_key] = true
      nil
    end

    def historical_digest_job?(class_name, date)
      return false unless FATHOM_DIGEST_JOB_CLASSES.include?(class_name.to_s)
      return false if date.blank? || date >= now.to_date

      ActiveModel::Type::Boolean.new.cast(ENV["FATHOM_DIGEST_EMAIL_HISTORICAL_ENABLED"]) != true
    end

    def completed_fathom_request?(request_id)
      return false if request_id.blank?

      WizwikiAutomationRun
        .for_automation(FATHOM_KEY)
        .where(request_id: request_id, status: %w[succeeded skipped])
        .exists?
    end

    def fathom_job_duplicate_key(job, date, request_id)
      return if request_id.blank?

      [job.class_name, date&.iso8601, request_id].join(":")
    end

    def solid_queue_claimed?(job)
      defined?(SolidQueue::ClaimedExecution) &&
        SolidQueue::ClaimedExecution.exists?(job_id: job.id)
    end

    def fathom_job_payload(job)
      raw_arguments = job.arguments
      raw_arguments = JSON.parse(raw_arguments) if raw_arguments.is_a?(String)
      raw_arguments = raw_arguments.to_h.with_indifferent_access
      Array(raw_arguments[:arguments]).each_with_object({}.with_indifferent_access) do |argument, payload|
        next unless argument.respond_to?(:to_h)

        payload.merge!(normalize_job_argument(argument.to_h))
      end
    rescue JSON::ParserError, TypeError
      {}.with_indifferent_access
    end

    def normalize_job_argument(argument)
      argument.each_with_object({}.with_indifferent_access) do |(key, value), payload|
        next if key.to_s.start_with?("_aj_")

        payload[key.to_s] = value
      end
    end

    def active_run_stale_cutoff
      ENV.fetch("WIZWIKI_BRAIN_FATHOM_ACTIVE_STALE_MINUTES", "45").to_i.clamp(10, 360).minutes.ago
    end

    def active_run(organization:, date:)
      organization.wizwiki_automation_runs
        .for_automation(FATHOM_KEY)
        .where(target_date: date)
        .active
        .where("updated_at >= ?", active_run_stale_cutoff)
        .recent
        .first
    end

    def previous_success(organization:, date:)
      organization.wizwiki_automation_runs
        .for_automation(FATHOM_KEY)
        .where(target_date: date, status: %w[succeeded skipped])
        .recent
        .first
    end

    def skipped_hash(automation, reason, run: nil)
      payload = { ok: true, automation: automation, skipped: true, reason: reason }
      payload[:run] = self.class.serialize_run(run) if run.present?
      payload
    end

    def parse_date(value)
      return now.to_date if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      now.to_date
    end

    def parse_job_date(value)
      return if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      nil
    end

    def run_key(organization, date, request_id)
      [FATHOM_KEY, organization.id, date.iso8601, request_id].join(":")
    end
  end
end
