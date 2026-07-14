class CreateIngestionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ingestion_events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, foreign_key: true
      t.string :source, null: false
      t.string :source_uid
      t.string :payload_digest, null: false
      t.string :status, null: false, default: "accepted"
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :ingestion_events, [:organization_id, :source, :source_uid], unique: true, where: "source_uid IS NOT NULL"
    add_index :ingestion_events, [:organization_id, :source, :payload_digest], unique: true, name: "idx_ingestion_events_unique_payload"
  end
end
