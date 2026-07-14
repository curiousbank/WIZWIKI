module Comms
  class BoardStatusCountsRefreshJob < ApplicationJob
    queue_as :default

    class << self
      def lock_key(organization_id)
        ["comms_board_status_counts_refresh_lock_v2", organization_id]
      end

      def dirty_key(organization_id)
        ["comms_board_status_counts_refresh_dirty_v2", organization_id]
      end
    end

    STATUS_KEYS = %w[
      owner_queue active new needs_reply autopilot stale_due storm_watch waiting
      link_sent am_support complete hold hidden opt_out all
    ].freeze

    BOARD_STAGE_PREDICATE = <<~SQL.squish.freeze
      artifact_type = 'comm_staging'
        AND status IN ('staged', 'aircall_ready', 'aircall_sent', 'aircall_failed')
        AND (metadata ->> 'stage_type') IN ('manual_comms', 'storm_watch_comms')
    SQL
    BOARD_STATE_SQL = "COALESCE(metadata ->> 'comms_board_state', 'active')".freeze
    OPT_OUT_SQL = <<~SQL.squish.freeze
      (
        #{BOARD_STATE_SQL} = 'opt_out'
        OR COALESCE(metadata ->> 'sms_do_not_contact', 'false') = 'true'
        OR metadata ->> 'sms_do_not_contact_at' IS NOT NULL
        OR COALESCE(metadata ->> 'comms_command_last_status', '') = 'do_not_contact'
      )
    SQL
    OWNER_QUEUE_SQL = "COALESCE(metadata ->> 'csv_call_import_source', '') = 'hubspot_owner_lead'".freeze
    STORM_WATCH_SQL = "COALESCE(metadata ->> 'stage_type', '') = 'storm_watch_comms'".freeze
    AM_SUPPORT_SQL = <<~SQL.squish.freeze
      (
        metadata ->> 'comms_support_state' = 'am_support'
        OR metadata ->> 'comms_command_last_status' IN ('human_requested', 'account_manager_support', 'am_support')
        OR metadata ? 'sms_autopilot_slack_human_requested_at'
        OR metadata ? 'sms_autopilot_slack_completion_without_purchase_at'
        OR metadata ? 'sms_autopilot_slack_handoff_at'
        OR COALESCE(metadata ->> 'comms_route_claim_reason', '') ~* '(human_requested|account_manager_answer_needed)'
      )
    SQL
    LINK_SENT_SQL = "(metadata ? 'shopify_link_sent_at' OR metadata ? 'comms_link_reached_at')".freeze
    AUTOPILOT_COMPLETE_SQL = <<~SQL.squish.freeze
      (
        metadata ? 'sms_autopilot_completed_at'
        OR metadata ? 'sms_autopilot_completion_sent_at'
        OR metadata #>> '{comms_bot_state,autopilot_complete}' = 'true'
      )
    SQL
    NEEDS_REPLY_SQL = <<~SQL.squish.freeze
      (
        metadata ->> 'comms_command_last_channel' = 'sms'
        AND metadata ->> 'comms_command_last_status' IN ('received', 'inbound')
      )
    SQL
    AUTOPILOT_SQL = "COALESCE(metadata ->> 'sms_autopilot_enabled', 'false') = 'true'".freeze
    WAITING_SQL = <<~SQL.squish.freeze
      (
        metadata ->> 'comms_command_last_channel' = 'sms'
        AND metadata ->> 'comms_command_last_status' IN ('sent', 'follow_up_sent')
      )
    SQL
    SMS_EVENTS_SQL = <<~SQL.squish.freeze
      COALESCE(
        jsonb_array_length(
          CASE WHEN jsonb_typeof(metadata -> 'sms_thread') = 'array'
            THEN metadata -> 'sms_thread'
            ELSE '[]'::jsonb
          END
        ),
        0
      )
    SQL
    ACTIVE_VISIBLE_SQL = <<~SQL.squish.freeze
      (NOT #{OPT_OUT_SQL} AND #{BOARD_STATE_SQL} NOT IN ('hidden', 'hold', 'done', 'opt_out'))
    SQL
    STATUS_KEY_SQL = <<~SQL.squish.freeze
      CASE
        WHEN #{OPT_OUT_SQL} THEN 'opt_out'
        WHEN #{BOARD_STATE_SQL} = 'hidden' THEN 'hidden'
        WHEN #{BOARD_STATE_SQL} = 'hold' THEN 'hold'
        WHEN #{BOARD_STATE_SQL} = 'done' THEN 'complete'
        WHEN #{AM_SUPPORT_SQL} THEN 'am_support'
        WHEN #{LINK_SENT_SQL} THEN 'link_sent'
        WHEN #{AUTOPILOT_COMPLETE_SQL} AND NOT #{NEEDS_REPLY_SQL} THEN 'complete'
        WHEN #{NEEDS_REPLY_SQL} THEN 'needs_reply'
        WHEN #{AUTOPILOT_SQL} THEN 'autopilot'
        WHEN #{WAITING_SQL} THEN 'waiting'
        WHEN #{SMS_EVENTS_SQL} = 0 THEN 'new'
        ELSE 'active'
      END
    SQL

    def perform(organization_id:)
      organization = Organization.find_by(id: organization_id)
      return unless organization

      Rails.cache.delete(self.class.dirty_key(organization_id))
      counts = fast_counts(organization)
      STATUS_KEYS.each { |key| counts[key] = counts[key].to_i }

      settings = organization.settings.to_h.deep_dup
      settings["comms_board_status_counts"] = {
        "counts" => counts,
        "updated_at" => Time.current.iso8601,
        "record_count" => counts["all"].to_i
      }
      organization.update_column(:settings, settings)
      Rails.cache.delete(["comms_board_status_counts_snapshot", organization.id])
    ensure
      release_refresh_lock!(organization_id)
    end

    private

    def release_refresh_lock!(organization_id)
      lock_key = self.class.lock_key(organization_id)
      dirty_key = self.class.dirty_key(organization_id)
      Rails.cache.delete(lock_key)
      return unless Rails.cache.delete(dirty_key)
      return unless Rails.cache.write(lock_key, true, expires_in: 15.minutes, unless_exist: true)

      self.class.set(wait: 5.seconds).perform_later(organization_id: organization_id)
    rescue StandardError => error
      Rails.cache.delete(lock_key) if defined?(lock_key)
      Rails.logger.warn("[Comms::BoardStatusCountsRefreshJob] follow-up enqueue failed organization=#{organization_id} #{error.class}: #{error.message}")
    end

    def fast_counts(organization)
      return rollup_counts(organization) if rollups_ready?(organization)

      metadata_counts(organization)
    end

    def rollups_ready?(organization)
      connection = ActiveRecord::Base.connection
      return false unless connection.data_source_exists?("comms_board_rollups")

      organization_id = connection.quote(organization.id)
      expected = connection.select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM crm_record_artifacts
        WHERE organization_id = #{organization_id}
          AND #{BOARD_STAGE_PREDICATE}
      SQL
      indexed = connection.select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM comms_board_rollups
        WHERE organization_id = #{organization_id}
          AND included = TRUE
      SQL
      expected == indexed
    end

    def rollup_counts(organization)
      connection = ActiveRecord::Base.connection
      organization_id = connection.quote(organization.id)
      rows = connection.select_rows(<<~SQL.squish)
        SELECT status_key, active_visible, owner_queue, storm_watch, COUNT(*)::bigint AS total
        FROM comms_board_rollups
        WHERE organization_id = #{organization_id}
          AND included = TRUE
        GROUP BY status_key, active_visible, owner_queue, storm_watch
      SQL

      counts_from_rollup_rows(rows)
    end

    def metadata_counts(organization)
      connection = ActiveRecord::Base.connection
      organization_id = connection.quote(organization.id)
      rows = connection.select_rows(<<~SQL.squish)
        SELECT
          #{STATUS_KEY_SQL} AS status_key,
          #{ACTIVE_VISIBLE_SQL} AS active_visible,
          #{OWNER_QUEUE_SQL} AS owner_queue,
          #{STORM_WATCH_SQL} AS storm_watch,
          COUNT(*)::bigint AS total
        FROM crm_record_artifacts
        WHERE organization_id = #{organization_id}
          AND #{BOARD_STAGE_PREDICATE}
        GROUP BY 1, 2, 3, 4
      SQL

      counts_from_rollup_rows(rows)
    end

    def counts_from_rollup_rows(rows)
      rows.each_with_object(Hash.new(0)) do |(status_key, active_visible, owner_queue, storm_watch, total), counts|
        total = total.to_i
        counts[status_key.to_s] += total
        counts["all"] += total
        counts["active"] += total if ActiveModel::Type::Boolean.new.cast(active_visible)
        if ActiveModel::Type::Boolean.new.cast(active_visible) && ActiveModel::Type::Boolean.new.cast(owner_queue)
          counts["owner_queue"] += total
        end
        counts["storm_watch"] += total if ActiveModel::Type::Boolean.new.cast(storm_watch)
      end
    end
  end
end
