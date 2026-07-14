module Hubspot
  class CompanyAddressSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, requested_by_user_id: nil, requested_at: nil, request_id: nil, limit: nil)
      return unless WizwikiSettings.hubspot_configured?

      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        Hubspot::TicketSyncStatus.mark_running!(
          organization: organization,
          request_id: request_id,
          job_id: job_id,
          requested_by_user_id: requested_by_user_id,
          requested_at: requested_at,
          lead_source: "hubspot_company_zip_store",
          record_type: "company"
        ) if defined?(Hubspot::TicketSyncStatus)

        result = Hubspot::CompanyAddressSync.call(
          organization: organization,
          limit: limit
        )

        Hubspot::TicketSyncStatus.mark_success!(organization: organization, result: result, request_id: request_id, job_id: job_id) if defined?(Hubspot::TicketSyncStatus)
        Rails.logger.info("[Hubspot::CompanyAddressSyncJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} requested_at=#{requested_at.presence || "scheduled"} #{result.to_h.inspect}")
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
        Hubspot::TicketSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id) if defined?(Hubspot::TicketSyncStatus)
        Rails.logger.warn("[Hubspot::CompanyAddressSyncJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
