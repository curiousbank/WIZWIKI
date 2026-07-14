class CreateCanvaConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :canva_connections do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :state
      t.string :code_verifier
      t.text :access_token
      t.text :refresh_token
      t.datetime :access_token_expires_at
      t.text :scope
      t.jsonb :metadata, null: false, default: {}
      t.datetime :authorized_at

      t.timestamps
    end

    add_index :canva_connections, [:organization_id, :user_id], unique: true
    add_index :canva_connections, :state, unique: true, where: "state IS NOT NULL"
    add_index :canva_connections, :status
  end
end
