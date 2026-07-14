class CreateBuildRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :build_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false
      t.string :target_area, null: false
      t.text :prompt, null: false
      t.string :status, null: false, default: "staged"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :build_requests, [:organization_id, :status]
    add_index :build_requests, [:organization_id, :user_id, :created_at]
  end
end
