class CreateWizwikiAutomationRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :wizwiki_automation_runs do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :automation_key, null: false
      t.string :run_key, null: false
      t.string :status, null: false, default: "queued"
      t.string :trigger, null: false, default: "systemd"
      t.string :current_step
      t.date :target_date
      t.datetime :scheduled_for
      t.datetime :started_at
      t.datetime :finished_at
      t.string :request_id
      t.string :solid_queue_job_id
      t.jsonb :result, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.text :error_message

      t.timestamps
    end

    add_index :wizwiki_automation_runs, :run_key, unique: true
    add_index :wizwiki_automation_runs, [:organization_id, :automation_key, :target_date]
    add_index :wizwiki_automation_runs, [:automation_key, :status]
    add_index :wizwiki_automation_runs, :scheduled_for
  end
end
