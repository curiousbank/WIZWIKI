module Comms
  class InboundSmsRecoverySweepJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, limit: nil, dry_run: false)
      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        result = Comms::InboundSmsRecoverySweep.call(
          organization: organization,
          limit: limit,
          dry_run: dry_run
        )
        Rails.logger.info("[Comms::InboundSmsRecoverySweepJob] organization=#{organization.id} #{result.inspect}")
      end
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::InboundSmsRecoverySweepJob] skipped: #{error.class}: #{error.message}")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Comms::InboundSmsRecoverySweepJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
    end
  end
end
