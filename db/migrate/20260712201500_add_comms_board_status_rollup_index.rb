class AddCommsBoardStatusRollupIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

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

  def up
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_board_status_rollup_v1
      ON crm_record_artifacts (
        organization_id,
        (#{STATUS_KEY_SQL}),
        (#{ACTIVE_VISIBLE_SQL}),
        (#{OWNER_QUEUE_SQL}),
        (#{STORM_WATCH_SQL})
      )
      WHERE #{BOARD_STAGE_PREDICATE}
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_board_status_rollup_v1"
  end
end
