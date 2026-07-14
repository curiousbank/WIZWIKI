class CreatePlaybookCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :playbook_calls do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, foreign_key: true
      t.string :hubspot_call_id, null: false
      t.string :title
      t.string :status, null: false, default: "synced"
      t.string :call_status
      t.string :call_direction
      t.string :call_disposition
      t.string :owner_id
      t.string :owner_name
      t.datetime :occurred_at
      t.bigint :duration_ms
      t.boolean :has_transcript, null: false, default: false
      t.string :transcription_id
      t.string :zoom_meeting_uuid
      t.string :meeting_id
      t.text :recording_url
      t.text :video_recording_url
      t.text :summary
      t.text :notes
      t.text :suggested_next_actions
      t.text :analyzer_text
      t.jsonb :playbook_data, null: false, default: {}
      t.jsonb :associations, null: false, default: {}
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :playbook_calls, [:organization_id, :hubspot_call_id], unique: true
    add_index :playbook_calls, [:organization_id, :crm_record_id]
    add_index :playbook_calls, [:organization_id, :occurred_at]
    add_index :playbook_calls, :playbook_data, using: :gin
    add_index :playbook_calls, :associations, using: :gin
    add_index :playbook_calls, :raw_payload, using: :gin
  end
end
