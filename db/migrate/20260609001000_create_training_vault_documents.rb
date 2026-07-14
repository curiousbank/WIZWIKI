class CreateTrainingVaultDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :training_vault_documents do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :source_type, null: false, default: "vault_upload"
      t.string :status, null: false, default: "review"
      t.string :file_name
      t.string :folder_path
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.string :body_sha256, null: false
      t.datetime :approved_at
      t.datetime :indexed_at
      t.datetime :archived_at
      t.jsonb :metadata, null: false, default: {}
      t.text :body, null: false

      t.timestamps
    end

    add_index :training_vault_documents, [:organization_id, :status]
    add_index :training_vault_documents, [:organization_id, :body_sha256], name: "idx_training_vault_documents_org_digest"
    add_index :training_vault_documents, :metadata, using: :gin
  end
end
