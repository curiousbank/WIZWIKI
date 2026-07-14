module Comms
  class FollowUpJob < ApplicationJob
    queue_as :default

    def perform(organization_id: nil, dry_run: false)
      with_sweep_lock(organization_id) do
        scope = organization_id.present? ? Organization.where(id: organization_id) : Organization.all
        scope.find_each do |organization|
          result = Comms::FollowUpRunner.call(organization: organization, dry_run: dry_run)
          Rails.logger.info("[Comms::FollowUpJob] organization=#{organization.id} #{result.inspect}")
        end
      end
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[Comms::FollowUpJob] skipped: #{error.class}: #{error.message}")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Comms::FollowUpJob] failed organization=#{organization_id}: #{error.class}: #{error.message}")
    end

    private

    def with_sweep_lock(organization_id)
      key = ["wizwiki", Rails.env, "comms_follow_up_sweep", organization_id.presence || "all"].join(":")
      quoted = nil
      acquired = false
      quoted = ActiveRecord::Base.connection.quote(key)
      acquired = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(hashtext(#{quoted}))")

      unless acquired
        Rails.logger.info("[Comms::FollowUpJob] skipped overlapping sweep organization=#{organization_id.presence || 'all'}")
        return
      end

      yield
    ensure
      ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(hashtext(#{quoted}))") if acquired && quoted.present?
    end
  end
end
