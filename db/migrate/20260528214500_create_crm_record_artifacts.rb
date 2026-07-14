class CreateCrmRecordArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_record_artifacts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :artifact_type, null: false, default: "market_report"
      t.string :status, null: false, default: "queued"
      t.string :title, null: false
      t.string :storage_provider
      t.string :storage_bucket
      t.string :storage_key
      t.string :file_url
      t.string :content_type
      t.bigint :byte_size
      t.jsonb :metadata, null: false, default: {}
      t.datetime :generated_at

      t.timestamps
    end

    add_index :crm_record_artifacts, [:organization_id, :artifact_type, :status], name: "idx_crm_record_artifacts_queue"
    add_index :crm_record_artifacts, [:crm_record_id, :artifact_type]
    add_index :crm_record_artifacts, :storage_key
  end
end
