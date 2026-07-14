class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :domain
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :organizations, :slug, unique: true
    add_index :organizations, :domain
  end
end
