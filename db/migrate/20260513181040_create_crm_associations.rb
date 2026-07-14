class CreateCrmAssociations < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_associations do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :from_record, null: false, foreign_key: { to_table: :crm_records }
      t.references :to_record, null: false, foreign_key: { to_table: :crm_records }
      t.string :association_type, null: false

      t.timestamps
    end

    add_index :crm_associations, [:organization_id, :from_record_id, :to_record_id, :association_type], unique: true, name: "idx_crm_associations_unique_edge"
    add_index :crm_associations, [:organization_id, :association_type]
  end
end
