# frozen_string_literal: true

module Comms
  class CsvImportJob < ApplicationJob
    queue_as :default
    limits_concurrency to: 1,
      key: ->(organization_id:, **) { organization_id },
      group: "comms_csv_import",
      duration: 2.hours

    def perform(organization_id:, user_id:, path:, job_id:, import_id:, title: nil, status_key: nil, claim_by_current_user: false)
      organization = Organization.find(organization_id)
      user = User.find(user_id)
      result = Comms::CsvImporter.call(
        organization: organization,
        user: user,
        path: path,
        job_id: job_id,
        import_id: import_id,
        title: title,
        status_key: status_key,
        claim_by_current_user: claim_by_current_user
      )
      Rails.logger.info("[Comms::CsvImportJob] organization=#{organization.id} user=#{user.id} #{result.inspect}")
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::CsvImportJob] skipped: #{error.class}: #{error.message}")
    ensure
      Comms::BoardStatusCountsRefreshJob.perform_later(organization_id: organization_id) if defined?(Comms::BoardStatusCountsRefreshJob)
    end
  end
end
