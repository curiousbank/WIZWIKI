module Comms
  class OrderReconciliationJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil)
      scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
      scope.find_each do |organization|
        result = Comms::OrderReconciler.call(organization: organization)
        Rails.logger.info("[Comms::OrderReconciliationJob] organization=#{organization.id} #{result.inspect}")
      end
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::OrderReconciliationJob] skipped: #{error.class}: #{error.message}")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Comms::OrderReconciliationJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
    end
  end
end
