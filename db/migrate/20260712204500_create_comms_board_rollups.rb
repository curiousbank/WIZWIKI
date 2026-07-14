class CreateCommsBoardRollups < ActiveRecord::Migration[8.1]
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
    create_rollup_table
    create_sync_function
    create_sync_trigger
    backfill_rollups
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_board_status_rollup_v1"
  end

  def down
    execute "DROP TRIGGER IF EXISTS sync_comms_board_rollup_v1 ON crm_record_artifacts"
    execute "DROP FUNCTION IF EXISTS sync_comms_board_rollup_v1()"
    execute "DROP TABLE IF EXISTS comms_board_rollups"
  end

  private

  def create_rollup_table
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS comms_board_rollups (
        crm_record_artifact_id bigint PRIMARY KEY REFERENCES crm_record_artifacts(id) ON DELETE CASCADE,
        organization_id bigint NOT NULL,
        included boolean NOT NULL DEFAULT FALSE,
        status_key varchar,
        active_visible boolean NOT NULL DEFAULT FALSE,
        owner_queue boolean NOT NULL DEFAULT FALSE,
        storm_watch boolean NOT NULL DEFAULT FALSE,
        source_updated_at timestamptz,
        synced_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_comms_board_rollups_counts
      ON comms_board_rollups (organization_id, included, status_key)
      INCLUDE (active_visible, owner_queue, storm_watch)
    SQL
  end

  def create_sync_function
    execute <<~SQL
      CREATE OR REPLACE FUNCTION sync_comms_board_rollup_v1()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $function$
      BEGIN
        IF NEW.artifact_type = 'comm_staging'
          AND NEW.status IN ('staged', 'aircall_ready', 'aircall_sent', 'aircall_failed')
          AND (NEW.metadata ->> 'stage_type') IN ('manual_comms', 'storm_watch_comms') THEN
          INSERT INTO comms_board_rollups (
            crm_record_artifact_id, organization_id, included, status_key,
            active_visible, owner_queue, storm_watch, source_updated_at, synced_at
          )
          SELECT
            NEW.id, NEW.organization_id, TRUE, #{STATUS_KEY_SQL},
            #{ACTIVE_VISIBLE_SQL}, #{OWNER_QUEUE_SQL}, #{STORM_WATCH_SQL},
            NEW.updated_at, clock_timestamp()
          FROM (SELECT NEW.metadata AS metadata) AS rollup_source
          ON CONFLICT (crm_record_artifact_id) DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            included = EXCLUDED.included,
            status_key = EXCLUDED.status_key,
            active_visible = EXCLUDED.active_visible,
            owner_queue = EXCLUDED.owner_queue,
            storm_watch = EXCLUDED.storm_watch,
            source_updated_at = EXCLUDED.source_updated_at,
            synced_at = EXCLUDED.synced_at;
        ELSE
          INSERT INTO comms_board_rollups (
            crm_record_artifact_id, organization_id, included, status_key,
            active_visible, owner_queue, storm_watch, source_updated_at, synced_at
          ) VALUES (
            NEW.id, NEW.organization_id, FALSE, NULL,
            FALSE, FALSE, FALSE, NEW.updated_at, clock_timestamp()
          )
          ON CONFLICT (crm_record_artifact_id) DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            included = FALSE,
            status_key = NULL,
            active_visible = FALSE,
            owner_queue = FALSE,
            storm_watch = FALSE,
            source_updated_at = EXCLUDED.source_updated_at,
            synced_at = EXCLUDED.synced_at;
        END IF;

        RETURN NEW;
      END;
      $function$
    SQL
  end

  def create_sync_trigger
    execute "DROP TRIGGER IF EXISTS sync_comms_board_rollup_v1 ON crm_record_artifacts"
    execute <<~SQL
      CREATE TRIGGER sync_comms_board_rollup_v1
      AFTER INSERT OR UPDATE OF organization_id, artifact_type, status, metadata
      ON crm_record_artifacts
      FOR EACH ROW
      EXECUTE FUNCTION sync_comms_board_rollup_v1()
    SQL
  end

  def backfill_rollups
    execute <<~SQL
      INSERT INTO comms_board_rollups (
        crm_record_artifact_id, organization_id, included, status_key,
        active_visible, owner_queue, storm_watch, source_updated_at, synced_at
      )
      SELECT
        id, organization_id, TRUE, #{STATUS_KEY_SQL},
        #{ACTIVE_VISIBLE_SQL}, #{OWNER_QUEUE_SQL}, #{STORM_WATCH_SQL},
        updated_at, clock_timestamp()
      FROM crm_record_artifacts
      WHERE #{BOARD_STAGE_PREDICATE}
      ON CONFLICT (crm_record_artifact_id) DO UPDATE SET
        organization_id = EXCLUDED.organization_id,
        included = EXCLUDED.included,
        status_key = EXCLUDED.status_key,
        active_visible = EXCLUDED.active_visible,
        owner_queue = EXCLUDED.owner_queue,
        storm_watch = EXCLUDED.storm_watch,
        source_updated_at = EXCLUDED.source_updated_at,
        synced_at = EXCLUDED.synced_at
      WHERE comms_board_rollups.source_updated_at IS NULL
        OR EXCLUDED.source_updated_at >= comms_board_rollups.source_updated_at
    SQL
  end
end
