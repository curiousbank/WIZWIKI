class CreateAutosEmbeddingChunks < ActiveRecord::Migration[8.1]
  def up
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :autos_embedding_chunks do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :scope, null: false, default: "wizwiki"
      t.string :source_type, null: false
      t.bigint :source_id, null: false
      t.integer :chunk_index, null: false, default: 0
      t.string :label
      t.text :content, null: false
      t.string :source_digest, null: false
      t.string :content_digest, null: false
      t.string :embedding_model, null: false
      t.integer :embedding_dimensions
      t.string :status, null: false, default: "pending"
      t.string :worker_id
      t.datetime :claimed_at
      t.datetime :embedded_at
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    execute "ALTER TABLE autos_embedding_chunks ADD COLUMN embedding vector"

    add_index :autos_embedding_chunks,
      [:organization_id, :source_type, :source_id, :chunk_index, :embedding_model],
      unique: true,
      name: "idx_autos_embedding_chunks_unique_source"
    add_index :autos_embedding_chunks,
      [:organization_id, :scope, :embedding_model, :embedding_dimensions, :status],
      name: "idx_autos_embedding_chunks_search_filter"
    add_index :autos_embedding_chunks, :content_digest
    add_index :autos_embedding_chunks, :source_digest
  end

  def down
    drop_table :autos_embedding_chunks
  end
end
