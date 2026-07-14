# frozen_string_literal: true

module Comms
  class CsvImportStatus
    KEY = "comms_csv_import_jobs"
    PURGED_KEY = "comms_csv_import_purged_status_keys"
    ACTIVE_STATES = %w[queued running].freeze
    MAX_STORED_JOBS = 12
    MAX_PURGED_KEYS = 50

    class << self
      def initialize!(organization, job_id:, import_id:, status_key:, title:, filename:, user:, claim_by_current_user: false)
        now = Time.current.iso8601
        update!(organization, job_id, {
          "job_id" => job_id,
          "import_id" => import_id,
          "status_key" => status_key,
          "title" => title,
          "filename" => filename,
          "state" => "queued",
          "rows" => 0,
          "processed" => 0,
          "created" => 0,
          "updated" => 0,
          "skipped" => 0,
          "duplicate_contact" => 0,
          "missing_contact" => 0,
          "errors" => 0,
          "requested_by_user_id" => user&.id,
          "requested_by" => user&.display_name,
          "claim_by_current_user" => ActiveModel::Type::Boolean.new.cast(claim_by_current_user),
          "claimed_by_user_id" => ActiveModel::Type::Boolean.new.cast(claim_by_current_user) ? user&.id : nil,
          "claimed_by" => ActiveModel::Type::Boolean.new.cast(claim_by_current_user) ? user&.display_name : nil,
          "queued_at" => now,
          "updated_at" => now
        }.compact_blank)
      end

      def update!(organization, job_id, attrs)
        organization.with_lock do
          settings = organization.reload.settings.to_h.deep_dup
          jobs = settings.fetch(KEY, {}).to_h
          current = jobs[job_id.to_s].to_h
          jobs[job_id.to_s] = current.merge(stringify(attrs)).merge("updated_at" => Time.current.iso8601)
          settings[KEY] = prune_jobs(jobs)
          organization.update!(settings: settings)
          jobs[job_id.to_s]
        end
      end

      def mark_purged!(organization, status_key:, user: nil)
        status_key = status_key.to_s
        return if status_key.blank?

        organization.with_lock do
          settings = organization.reload.settings.to_h.deep_dup
          now = Time.current.iso8601
          purged = settings.fetch(PURGED_KEY, {}).to_h
          purged[status_key] = {
            "purged_at" => now,
            "purged_by_user_id" => user&.id,
            "purged_by" => user&.display_name
          }.compact_blank
          settings[PURGED_KEY] = prune_purged_keys(purged)

          jobs = settings.fetch(KEY, {}).to_h
          jobs.each_value do |job|
            next unless job.to_h["status_key"].to_s == status_key
            next unless ACTIVE_STATES.include?(job.to_h["state"].to_s)

            job["state"] = "canceled"
            job["cancel_reason"] = "purged"
            job["finished_at"] = now
            job["updated_at"] = now
          end
          settings[KEY] = prune_jobs(jobs)
          organization.update!(settings: settings)
        end
      end

      def purged?(organization, status_key)
        status_key = status_key.to_s
        return false if status_key.blank?

        organization.reload.settings.to_h.fetch(PURGED_KEY, {}).to_h.key?(status_key)
      end

      def job(organization, job_id)
        return {} if job_id.blank?

        organization.reload.settings.to_h.fetch(KEY, {}).to_h[job_id.to_s].to_h
      end

      def latest_active_for_user(organization, user_id)
        jobs = organization.reload.settings.to_h.fetch(KEY, {}).to_h.values.map(&:to_h)
        jobs
          .select { |job| ACTIVE_STATES.include?(job["state"].to_s) }
          .select { |job| job["requested_by_user_id"].to_i == user_id.to_i }
          .max_by { |job| Time.zone.parse(job["updated_at"].to_s) rescue Time.at(0) }
          .to_h
      end

      private

      def stringify(attrs)
        attrs.to_h.transform_keys(&:to_s)
      end

      def prune_jobs(jobs)
        sorted = jobs.to_h.sort_by do |_job_id, job|
          Time.zone.parse(job.to_h["updated_at"].to_s) rescue Time.at(0)
        end.reverse
        keep = sorted.select { |_job_id, job| ACTIVE_STATES.include?(job.to_h["state"].to_s) }
        keep += sorted.reject { |_job_id, job| ACTIVE_STATES.include?(job.to_h["state"].to_s) }
        keep.first(MAX_STORED_JOBS).to_h
      end

      def prune_purged_keys(purged)
        purged.to_h.sort_by do |_status_key, payload|
          Time.zone.parse(payload.to_h["purged_at"].to_s) rescue Time.at(0)
        end.reverse.first(MAX_PURGED_KEYS).to_h
      end
    end
  end
end
