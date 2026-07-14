module Comms
  class OwnerQueueRefreshJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, requested_by_user_id: nil, limit: nil)
      return unless WizwikiSettings.hubspot_configured?

      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        user = User.find_by(id: requested_by_user_id)
        result = Comms::OwnerQueueRefresh.call(
          organization: organization,
          user: user,
          limit: limit
        )
        organization.update!(
          settings: organization.settings.to_h.merge(
            "comms_owner_queue_last_refresh" => result.to_h.merge(
              requested_by_user_id: requested_by_user_id.presence,
              stored_at: Time.current.iso8601
            ).stringify_keys
          )
        )
        Comms::BoardStatusCountsRefreshJob.perform_later(organization_id: organization.id) if defined?(Comms::BoardStatusCountsRefreshJob)
        Rails.logger.info("[Comms::OwnerQueueRefreshJob] organization=#{organization.id} requested_by_user_id=#{requested_by_user_id.presence || "system"} #{result.to_h.inspect}")
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
        Rails.logger.warn("[Comms::OwnerQueueRefreshJob] organization=#{organization.id} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
