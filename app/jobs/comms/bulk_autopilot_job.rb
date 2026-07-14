module Comms
  class BulkAutopilotJob < ApplicationJob
    queue_as :comms_bulk
    limits_concurrency to: 1,
      key: ->(organization_id:, **) { organization_id },
      group: "comms_bulk",
      duration: 4.hours

    def perform(organization_id:, user_id:, stage_ids:, run_id: nil, delay_seconds: nil, source: {})
      organization = Organization.find(organization_id)
      user = User.find(user_id)
      result = Comms::BulkAutopilotRunner.call(
        organization: organization,
        user: user,
        stage_ids: stage_ids,
        run_id: run_id,
        delay_seconds: delay_seconds,
        source: source
      )
      Rails.logger.info("[Comms::BulkAutopilotJob] organization=#{organization.id} user=#{user.id} #{result.to_h.inspect}")
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::BulkAutopilotJob] skipped: #{error.class}: #{error.message}")
    rescue ActiveRecord::ActiveRecordError, ArgumentError => error
      Rails.logger.warn("[Comms::BulkAutopilotJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
      raise
    end
  end
end
