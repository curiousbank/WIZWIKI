module Hubspot
  class PlaybookCallSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id:, requested_by_user_id: nil, requested_at: nil, request_id: nil)
      return unless WizwikiSettings.hubspot_configured?

      organization = Organization.find(organization_id)
      Hubspot::PlaybookCallSyncStatus.mark_running!(
        organization: organization,
        request_id: request_id,
        job_id: job_id,
        requested_by_user_id: requested_by_user_id,
        requested_at: requested_at
      )

      result = Hubspot::PlaybookCallSync.call(organization: organization, since: 90.days.ago)
      Hubspot::PlaybookCallSyncStatus.mark_success!(organization: organization, result: result, request_id: request_id, job_id: job_id)
      Rails.logger.info("[Hubspot::PlaybookCallSyncJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} #{result.to_h.inspect}")
    rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
      Hubspot::PlaybookCallSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id) if defined?(organization) && organization.present?
      Rails.logger.warn("[Hubspot::PlaybookCallSyncJob] organization_id=#{organization_id} failed: #{error.class}: #{error.message}")
    end
  end
end
