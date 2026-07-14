class CreateWeatherLeadSignals < ActiveRecord::Migration[7.1]
  def change
    create_table :weather_lead_signals do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :source, null: false, default: "weather.gov"
      t.string :source_uid, null: false
      t.string :signal_type, null: false, default: "alert"
      t.string :event, null: false
      t.string :headline
      t.text :description
      t.string :severity
      t.string :urgency
      t.string :certainty
      t.string :status, null: false, default: "active"
      t.string :area_desc
      t.jsonb :affected_states, null: false, default: []
      t.jsonb :affected_postal_codes, null: false, default: []
      t.datetime :started_at
      t.datetime :expires_at
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :weather_lead_signals, [:organization_id, :source, :source_uid], unique: true, name: "idx_weather_signals_unique_source"
    add_index :weather_lead_signals, [:organization_id, :signal_type, :status], name: "idx_weather_signals_type_status"
    add_index :weather_lead_signals, [:organization_id, :status, :expires_at], name: "idx_weather_signals_status_expiry"
    add_index :weather_lead_signals, :affected_states, using: :gin
    add_index :weather_lead_signals, :affected_postal_codes, using: :gin
    add_index :weather_lead_signals, :metadata, using: :gin
  end
end
