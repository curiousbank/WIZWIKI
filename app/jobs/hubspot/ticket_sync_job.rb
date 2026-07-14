module Hubspot
  class TicketSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, requested_by_user_id: nil, requested_at: nil, request_id: nil)
      return unless WizwikiSettings.hubspot_configured?

      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        Hubspot::TicketSyncStatus.mark_running!(
          organization: organization,
          request_id: request_id,
          job_id: job_id,
          requested_by_user_id: requested_by_user_id,
          requested_at: requested_at,
          lead_source: "sam_tickets",
          record_type: "ticket"
        )
        result = Hubspot::TicketSync.call(
          organization: organization,
          since: 90.days.ago,
          limit: nil,
          create_only: false,
          prune_stale: true
        )
        Hubspot::TicketSyncStatus.mark_success!(organization: organization, result: result, request_id: request_id, job_id: job_id)
        Rails.logger.info("[Hubspot::TicketSyncJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} requested_at=#{requested_at.presence || "scheduled"} #{result.to_h.inspect}")
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
        Hubspot::TicketSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id)
        Rails.logger.warn("[Hubspot::TicketSyncJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
