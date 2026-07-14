class CreateCrmAddressRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_address_records do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, foreign_key: true
      t.references :playbook_call, foreign_key: true
      t.string :source_type, null: false
      t.bigint :source_id
      t.string :source_key, null: false
      t.string :source_path, null: false
      t.string :source_label
      t.string :record_type
      t.string :address_kind, null: false, default: "address"
      t.string :address1
      t.string :address2
      t.string :city
      t.string :state
      t.string :postal_code
      t.string :country
      t.string :address_line
      t.string :address_one_line, null: false
      t.string :normalized_key, null: false
      t.integer :confidence, null: false, default: 50
      t.jsonb :raw_components, null: false, default: {}
      t.jsonb :association_context, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :crm_address_records, [:organization_id, :normalized_key]
    add_index :crm_address_records, [:organization_id, :source_key, :source_path],
      unique: true,
      name: "idx_crm_address_records_unique_source_path"
    add_index :crm_address_records, [:organization_id, :city, :state]
    add_index :crm_address_records, [:organization_id, :postal_code]
    add_index :crm_address_records, :raw_components, using: :gin
    add_index :crm_address_records, :association_context, using: :gin
  end
end
