class AddMemoryEfficiencyIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :autos_embedding_chunks,
      [:embedding_model, :status, :updated_at, :id],
      name: "idx_autos_embedding_chunks_claim_queue",
      where: "status IN ('pending', 'claimed')",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :autos_embedding_chunks,
      [:embedding_model, :status, :updated_at, :id],
      name: "idx_autos_embedding_chunks_stale_prune",
      where: "status = 'stale'",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :fathom_calls,
      [:organization_id, :fathom_created_at],
      name: "idx_fathom_calls_org_created_at",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :playbook_calls,
      [:organization_id, :status, :occurred_at],
      name: "idx_playbook_calls_active_recent",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
