class AddCommsHotPathIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_STAGE_PREDICATE = <<~SQL.squish.freeze
    artifact_type = 'comm_staging'
      AND status <> 'archived'
      AND (metadata ->> 'stage_type') IN ('manual_comms', 'storm_watch_comms')
  SQL

  BOARD_STAGE_PREDICATE = <<~SQL.squish.freeze
    artifact_type = 'comm_staging'
      AND status IN ('staged', 'aircall_ready', 'aircall_sent', 'aircall_failed')
      AND (metadata ->> 'stage_type') IN ('manual_comms', 'storm_watch_comms')
  SQL

  def up
    backfill_stage_contact_fields
    backfill_record_contact_fields

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_active_contact_phone
      ON crm_record_artifacts (
        organization_id,
        ((metadata ->> 'manual_comms_contact_phone_digits')),
        updated_at DESC
      )
      WHERE #{ACTIVE_STAGE_PREDICATE}
        AND NULLIF(metadata ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_active_contact_email
      ON crm_record_artifacts (
        organization_id,
        ((metadata ->> 'manual_comms_contact_email')),
        updated_at DESC
      )
      WHERE #{ACTIVE_STAGE_PREDICATE}
        AND NULLIF(metadata ->> 'manual_comms_contact_email', '') IS NOT NULL
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_active_claimed_user
      ON crm_record_artifacts (
        organization_id,
        ((metadata ->> 'claimed_by_user_id')),
        updated_at DESC
      )
      WHERE #{BOARD_STAGE_PREDICATE}
        AND NULLIF(metadata ->> 'claimed_by_user_id', '') IS NOT NULL
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_board_change_token
      ON crm_record_artifacts (organization_id, updated_at DESC, id DESC)
      WHERE #{BOARD_STAGE_PREDICATE}
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_manual_comms_record_phone
      ON crm_records (
        organization_id,
        ((properties ->> 'manual_comms_contact_phone_digits')),
        updated_at DESC
      )
      WHERE source = 'manual_comms'
        AND NULLIF(properties ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_manual_comms_record_email
      ON crm_records (
        organization_id,
        ((properties ->> 'manual_comms_contact_email')),
        updated_at DESC
      )
      WHERE source = 'manual_comms'
        AND NULLIF(properties ->> 'manual_comms_contact_email', '') IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_manual_comms_record_email"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_manual_comms_record_phone"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_board_change_token"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_active_claimed_user"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_active_contact_email"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_active_contact_phone"
  end

  private

  def backfill_stage_contact_fields
    execute <<~SQL
      WITH candidates AS (
        SELECT
          id,
          RIGHT(
            regexp_replace(
              COALESCE(
                NULLIF(metadata ->> 'manual_comms_contact_phone_digits', ''),
                NULLIF(metadata ->> 'captured_phone', ''),
                NULLIF(metadata ->> 'selected_phone', ''),
                (
                  SELECT COALESCE(
                    item ->> 'value',
                    item ->> 'phone',
                    item ->> 'number',
                    CASE WHEN jsonb_typeof(item) = 'string' THEN TRIM(BOTH '"' FROM item::text) END
                  )
                  FROM jsonb_array_elements(
                    CASE WHEN jsonb_typeof(metadata -> 'phone_options') = 'array'
                      THEN metadata -> 'phone_options'
                      ELSE '[]'::jsonb
                    END
                  ) AS option_row(item)
                  LIMIT 1
                ),
                ''
              ),
              '[^0-9]',
              '',
              'g'
            ),
            10
          ) AS phone_digits,
          LOWER(
            COALESCE(
              NULLIF(metadata ->> 'manual_comms_contact_email', ''),
              NULLIF(metadata ->> 'captured_email', ''),
              NULLIF(metadata ->> 'selected_recipient_email', ''),
              (
                SELECT COALESCE(
                  item ->> 'value',
                  item ->> 'email',
                  item ->> 'address',
                  CASE WHEN jsonb_typeof(item) = 'string' THEN TRIM(BOTH '"' FROM item::text) END
                )
                FROM jsonb_array_elements(
                  CASE WHEN jsonb_typeof(metadata -> 'recipient_email_options') = 'array'
                    THEN metadata -> 'recipient_email_options'
                    ELSE '[]'::jsonb
                  END
                ) AS email_row(item)
                LIMIT 1
              ),
              ''
            )
          ) AS email_address
        FROM crm_record_artifacts
        WHERE #{ACTIVE_STAGE_PREDICATE}
      )
      UPDATE crm_record_artifacts AS artifacts
      SET metadata = jsonb_set(
        jsonb_set(
          artifacts.metadata,
          '{manual_comms_contact_phone_digits}',
          CASE WHEN LENGTH(candidates.phone_digits) >= 7
            THEN to_jsonb(candidates.phone_digits)
            ELSE COALESCE(artifacts.metadata -> 'manual_comms_contact_phone_digits', 'null'::jsonb)
          END,
          true
        ),
        '{manual_comms_contact_email}',
        CASE WHEN candidates.email_address LIKE '%@%'
          THEN to_jsonb(candidates.email_address)
          ELSE COALESCE(artifacts.metadata -> 'manual_comms_contact_email', 'null'::jsonb)
        END,
        true
      )
      FROM candidates
      WHERE artifacts.id = candidates.id
        AND (
          (LENGTH(candidates.phone_digits) >= 7 AND NULLIF(artifacts.metadata ->> 'manual_comms_contact_phone_digits', '') IS NULL)
          OR (candidates.email_address LIKE '%@%' AND NULLIF(artifacts.metadata ->> 'manual_comms_contact_email', '') IS NULL)
        )
    SQL

    execute <<~SQL
      UPDATE crm_record_artifacts
      SET metadata = jsonb_set(
        metadata,
        '{manual_comms_contact_keys}',
        to_jsonb(
          array_remove(
            ARRAY[
              CASE WHEN NULLIF(metadata ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
                THEN 'phone:' || (metadata ->> 'manual_comms_contact_phone_digits') END,
              CASE WHEN NULLIF(metadata ->> 'manual_comms_contact_email', '') IS NOT NULL
                THEN 'email:' || LOWER(metadata ->> 'manual_comms_contact_email') END
            ],
            NULL
          )
        ),
        true
      )
      WHERE #{ACTIVE_STAGE_PREDICATE}
        AND (
          CASE WHEN jsonb_typeof(metadata -> 'manual_comms_contact_keys') = 'array'
            THEN jsonb_array_length(metadata -> 'manual_comms_contact_keys')
            ELSE 0
          END
        ) = 0
        AND (
          NULLIF(metadata ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
          OR NULLIF(metadata ->> 'manual_comms_contact_email', '') IS NOT NULL
        )
    SQL
  end

  def backfill_record_contact_fields
    execute <<~SQL
      UPDATE crm_records
      SET properties = jsonb_set(
        jsonb_set(
          properties,
          '{manual_comms_contact_phone_digits}',
          to_jsonb(RIGHT(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10)),
          true
        ),
        '{manual_comms_contact_email}',
        to_jsonb(LOWER(COALESCE(email, ''))),
        true
      )
      WHERE source = 'manual_comms'
        AND (
          NULLIF(properties ->> 'manual_comms_contact_phone_digits', '') IS NULL
          OR NULLIF(properties ->> 'manual_comms_contact_email', '') IS NULL
        )
    SQL

    execute <<~SQL
      UPDATE crm_records
      SET properties = jsonb_set(
        properties,
        '{manual_comms_contact_keys}',
        to_jsonb(
          array_remove(
            ARRAY[
              CASE WHEN LENGTH(properties ->> 'manual_comms_contact_phone_digits') >= 7
                THEN 'phone:' || (properties ->> 'manual_comms_contact_phone_digits') END,
              CASE WHEN properties ->> 'manual_comms_contact_email' LIKE '%@%'
                THEN 'email:' || LOWER(properties ->> 'manual_comms_contact_email') END
            ],
            NULL
          )
        ),
        true
      )
      WHERE source = 'manual_comms'
        AND (
          CASE WHEN jsonb_typeof(properties -> 'manual_comms_contact_keys') = 'array'
            THEN jsonb_array_length(properties -> 'manual_comms_contact_keys')
            ELSE 0
          END
        ) = 0
    SQL
  end
end
