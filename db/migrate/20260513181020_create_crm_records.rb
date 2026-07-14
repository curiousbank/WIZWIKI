class CreateCrmRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_records do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :owner, foreign_key: { to_table: :users }
      t.string :record_type, null: false
      t.string :name, null: false
      t.string :email
      t.string :phone
      t.string :domain
      t.string :stage
      t.string :status, null: false, default: "open"
      t.decimal :amount, precision: 12, scale: 2
      t.date :close_date
      t.string :source
      t.string :source_uid
      t.string :fingerprint
      t.jsonb :properties, null: false, default: {}

      t.timestamps
    end

    add_index :crm_records, [:organization_id, :record_type]
    add_index :crm_records, [:organization_id, :record_type, :email]
    add_index :crm_records, [:organization_id, :record_type, :domain]
    add_index :crm_records, [:organization_id, :record_type, :phone]
    add_index :crm_records, [:organization_id, :record_type, :fingerprint], unique: true
    add_index :crm_records, [:organization_id, :source, :source_uid], unique: true, where: "source IS NOT NULL AND source_uid IS NOT NULL"
    add_index :crm_records, :properties, using: :gin
  end
end
