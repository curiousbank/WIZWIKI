module Comms
  class AutopilotLearningJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, lookback_days: nil, limit: nil)
      organizations = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      organizations.find_each do |organization|
        result = Comms::AutopilotLearning.call(
          organization: organization,
          lookback_days: lookback_days.presence || ENV.fetch("WIZWIKI_COMMS_LEARNING_LOOKBACK_DAYS", Comms::AutopilotLearning::DEFAULT_LOOKBACK_DAYS).to_i,
          limit: limit.presence || ENV.fetch("WIZWIKI_COMMS_LEARNING_LIMIT", Comms::AutopilotLearning::DEFAULT_LIMIT).to_i
        )
        Rails.logger.info("[Comms::AutopilotLearningJob] organization=#{organization.id} #{result.to_h.inspect}")
      end
    end
  end
end
