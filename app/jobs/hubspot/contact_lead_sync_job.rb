module Hubspot
  class ContactLeadSyncJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, lead_source: nil, requested_by_user_id: nil, requested_at: nil, request_id: nil)
      return unless WizwikiSettings.hubspot_configured?

      source = lead_source.to_s.presence || "all_contacts"
      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        Hubspot::TicketSyncStatus.mark_running!(
          organization: organization,
          request_id: request_id,
          job_id: job_id,
          requested_by_user_id: requested_by_user_id,
          requested_at: requested_at,
          lead_source: source,
          record_type: "contact"
        )
        result = Hubspot::ContactLeadSync.call(
          organization: organization,
          source: source,
          since: 90.days.ago,
          limit: nil
        )
        Hubspot::TicketSyncStatus.mark_success!(organization: organization, result: result, request_id: request_id, job_id: job_id)
        Rails.logger.info("[Hubspot::ContactLeadSyncJob] organization=#{organization.id} source=#{source} requested_by_user_id=#{requested_by_user_id.presence || "system"} #{result.to_h.inspect}")
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
        Hubspot::TicketSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id)
        Rails.logger.warn("[Hubspot::ContactLeadSyncJob] organization=#{organization.id} source=#{source} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
