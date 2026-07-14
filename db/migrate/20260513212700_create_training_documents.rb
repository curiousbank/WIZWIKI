class CreateTrainingDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :training_documents do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false
      t.string :source_type, null: false, default: "pasted_text"
      t.text :body, null: false
      t.string :file_name
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.string :status, null: false, default: "ingested"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :training_documents, [:organization_id, :status]
    add_index :training_documents, [:organization_id, :user_id, :created_at]
    add_index :training_documents, :metadata, using: :gin
  end
end
