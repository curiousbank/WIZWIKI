class AddCommsBoardLaneIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_artifacts_source_updated
      ON crm_record_artifacts (
        organization_id,
        ((metadata ->> 'csv_call_import_source')),
        updated_at DESC
      )
      WHERE artifact_type = 'comm_staging'
        AND status IN ('staged', 'aircall_ready', 'aircall_sent', 'aircall_failed')
    SQL

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comm_artifacts_stage_updated
      ON crm_record_artifacts (
        organization_id,
        ((metadata ->> 'stage_type')),
        updated_at DESC
      )
      WHERE artifact_type = 'comm_staging'
        AND status IN ('staged', 'aircall_ready', 'aircall_sent', 'aircall_failed')
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_artifacts_source_updated"
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_comm_artifacts_stage_updated"
  end
end
