class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.string :role, null: false, default: "scribe"
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :memberships, [:user_id, :organization_id], unique: true
    add_index :memberships, [:organization_id, :role]
  end
end
