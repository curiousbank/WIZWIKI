module Comms
  class EmailDraftWarmupJob < ApplicationJob
    queue_as :default
    queue_with_priority 50 if respond_to?(:queue_with_priority)

    def perform(organization_id: nil, limit: nil, dry_run: false)
      with_warmup_lock(organization_id) do
        scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
        scope.find_each do |organization|
          result = Comms::EmailDraftWarmupRunner.call(organization: organization, limit: limit, dry_run: dry_run)
          Rails.logger.info("[Comms::EmailDraftWarmupJob] organization=#{organization.id} #{result.inspect}")
        end
      end
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::EmailDraftWarmupJob] skipped: #{error.class}: #{error.message}")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Comms::EmailDraftWarmupJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
    end

    private

    def with_warmup_lock(organization_id)
      key = ["wizwiki", Rails.env, "comms_email_draft_warmup", organization_id.presence || "all"].join(":")
      quoted = ActiveRecord::Base.connection.quote(key)
      acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(hashtext(#{quoted}))")

      unless acquired
        Rails.logger.info("[Comms::EmailDraftWarmupJob] skipped overlapping warmup organization=#{organization_id.presence || 'all'}")
        return
      end

      yield
    ensure
      ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(hashtext(#{quoted}))") if acquired && quoted.present?
    end
  end
end
