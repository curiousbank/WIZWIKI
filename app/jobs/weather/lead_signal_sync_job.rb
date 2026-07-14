module Weather
  class LeadSignalSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, requested_by_user_id: nil, requested_at: nil, request_id: nil)
      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        status = Weather::ScanStatus.for(organization) if defined?(Weather::ScanStatus)
        if status.to_h[:active] && status.to_h[:request_id].present? && request_id.present? && status.to_h[:request_id].to_s != request_id.to_s
          Rails.logger.info("[Weather::LeadSignalSyncJob] skipped duplicate active scan organization=#{organization.id} active_request_id=#{status.to_h[:request_id]} incoming_request_id=#{request_id}")
          next
        elsif status.to_h[:active] && request_id.blank?
          Rails.logger.info("[Weather::LeadSignalSyncJob] skipped recurring scan because active scan is already running organization=#{organization.id} active_request_id=#{status.to_h[:request_id]}")
          next
        end

        Weather::ScanStatus.mark_running!(
          organization: organization,
          request_id: request_id,
          job_id: job_id,
          requested_by_user_id: requested_by_user_id,
          requested_at: requested_at
        ) if defined?(Weather::ScanStatus)
        result = Weather::LeadSignalSync.call(organization: organization)
        storm_result = nil
        if defined?(Comms::StormWatchRefresh)
          storm_result = Comms::StormWatchRefresh.call(
            organization: organization,
            user: User.find_by(id: requested_by_user_id)
          )
          Comms::BoardStatusCountsRefreshJob.perform_later(organization_id: organization.id) if defined?(Comms::BoardStatusCountsRefreshJob)
        end
        Weather::ScanStatus.mark_success!(
          organization: organization,
          result: result,
          request_id: request_id,
          job_id: job_id
        ) if defined?(Weather::ScanStatus)
        Rails.logger.info("[Weather::LeadSignalSyncJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} #{result.inspect}")
        Rails.logger.info("[Weather::LeadSignalSyncJob] storm_watch_blocks organization=#{organization.id} #{storm_result.to_h.inspect}") if storm_result.present?
      end
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Weather::LeadSignalSyncJob] skipped: #{error.class}: #{error.message}")
    rescue Weather::LeadSignalSync::Error, ActiveRecord::ActiveRecordError => error
      if defined?(Weather::ScanStatus) && organization_id.present?
        Organization.where(id: organization_id).find_each do |organization|
          Weather::ScanStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id)
        end
      end
      Rails.logger.warn("[Weather::LeadSignalSyncJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
    end
  end
end
