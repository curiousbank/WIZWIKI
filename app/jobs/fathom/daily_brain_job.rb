module Fathom
  class DailyBrainJob < ApplicationJob
    queue_as :default

    def perform(date: nil)
      return unless WizwikiSettings.fathom_configured?

      sync_date = parse_date(date)
      Organization.find_each do |organization|
        next if Fathom::DailyCallSyncStatus.active?(organization)

        request_id = SecureRandom.uuid
        requested_at = Time.current
        Fathom::DailyCallSyncStatus.mark_queued!(
          organization: organization,
          request_id: request_id,
          requested_by_user_id: nil,
          requested_by: "The Fathom Brain",
          requested_at: requested_at,
          date: sync_date
        )
        job = Fathom::DailyCallSyncJob.perform_later(
          organization_id: organization.id,
          requested_by_user_id: nil,
          requested_at: requested_at.iso8601,
          request_id: request_id,
          date: sync_date.iso8601
        )
        Fathom::DailyCallSyncStatus.mark_enqueued!(organization: organization, request_id: request_id, job_id: job.job_id)
      rescue Fathom::Error, ActiveRecord::ActiveRecordError => error
        Fathom::DailyCallSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: nil)
        Rails.logger.warn("[Fathom::DailyBrainJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end

    private

    def parse_date(value)
      return Time.current.in_time_zone("Central Time (US & Canada)").to_date if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.current.in_time_zone("Central Time (US & Canada)").to_date
    end
  end
end
