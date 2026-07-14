class CreateCrmPropertyDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_property_definitions do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :record_type, null: false
      t.string :key, null: false
      t.string :label, null: false
      t.string :data_type, null: false, default: "text"
      t.boolean :required, null: false, default: false
      t.boolean :unique_value, null: false, default: false
      t.boolean :active, null: false, default: true
      t.jsonb :options, null: false, default: {}

      t.timestamps
    end

    add_index :crm_property_definitions, [:organization_id, :record_type, :key], unique: true, name: "idx_crm_property_definitions_unique_key"
  end
end
