class CreateAutosQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :autos_questions do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :question, null: false
      t.text :context
      t.text :answer
      t.string :status, null: false, default: "queued"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :autos_questions, [:organization_id, :status]
    add_index :autos_questions, [:organization_id, :user_id, :created_at]
  end
end
