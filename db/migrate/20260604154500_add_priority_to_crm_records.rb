class AddPriorityToCrmRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_records, :priority_level, :string, null: false, default: "normal"
    add_column :crm_records, :priority_note, :text
    add_column :crm_records, :priority_marked_at, :datetime
    add_reference :crm_records, :priority_marked_by, foreign_key: { to_table: :users }, index: true

    add_index :crm_records, [:organization_id, :record_type, :priority_level], name: "idx_crm_records_priority_queue"
  end
end
