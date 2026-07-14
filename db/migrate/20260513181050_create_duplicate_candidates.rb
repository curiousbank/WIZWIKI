class CreateDuplicateCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :duplicate_candidates do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, null: false, foreign_key: true
      t.references :duplicate_record, null: false, foreign_key: { to_table: :crm_records }
      t.decimal :score, precision: 5, scale: 2, null: false, default: 0
      t.string :status, null: false, default: "open"
      t.jsonb :reasons, null: false, default: []

      t.timestamps
    end

    add_index :duplicate_candidates, [:organization_id, :crm_record_id, :duplicate_record_id], unique: true, name: "idx_duplicate_candidates_unique_pair"
    add_index :duplicate_candidates, [:organization_id, :status]
  end
end
