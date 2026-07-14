class CreateFathomCalls < ActiveRecord::Migration[8.0]
  def change
    create_table :fathom_calls do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :recording_id, null: false
      t.string :status, null: false, default: "synced"
      t.string :title
      t.string :meeting_title
      t.string :meeting_type
      t.string :url
      t.string :share_url
      t.string :meeting_url
      t.string :transcript_language
      t.string :recorded_by_name
      t.string :recorded_by_email
      t.string :recorded_by_team
      t.datetime :fathom_created_at
      t.datetime :scheduled_start_time
      t.datetime :scheduled_end_time
      t.datetime :recording_start_time
      t.datetime :recording_end_time
      t.text :summary
      t.text :transcript
      t.text :action_items_text
      t.text :highlights_text
      t.jsonb :calendar_invitees, null: false, default: []
      t.jsonb :crm_matches, null: false, default: {}
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :synced_at

      t.timestamps
    end

    add_index :fathom_calls, [:organization_id, :recording_id], unique: true
    add_index :fathom_calls, [:organization_id, :recording_start_time]
    add_index :fathom_calls, [:organization_id, :status]
  end
end
