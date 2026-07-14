class CreateKalshiWeatherPredictions < ActiveRecord::Migration[8.1]
  def change
    create_table :kalshi_weather_predictions do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :series_ticker, null: false
      t.string :event_ticker
      t.string :market_ticker, null: false
      t.string :city, null: false
      t.string :state
      t.text :market_title
      t.string :market_range
      t.string :action, null: false, default: "watch"
      t.string :side, null: false, default: "YES"
      t.string :size_label, null: false, default: "0 contracts"
      t.integer :forecast_high_f
      t.integer :adjusted_high_f
      t.decimal :market_floor_strike, precision: 8, scale: 2
      t.decimal :market_cap_strike, precision: 8, scale: 2
      t.decimal :market_midpoint_f, precision: 8, scale: 2
      t.decimal :confidence, precision: 8, scale: 4
      t.decimal :ask, precision: 8, scale: 4
      t.decimal :edge, precision: 8, scale: 4
      t.datetime :close_time
      t.date :prediction_date, null: false
      t.text :rationale
      t.text :training_note
      t.string :status, null: false, default: "open"
      t.string :result_status, null: false, default: "pending"
      t.integer :observed_high_f
      t.string :settlement_value
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :kalshi_weather_predictions, [:organization_id, :market_ticker], unique: true, name: "idx_kalshi_weather_predictions_unique_market"
    add_index :kalshi_weather_predictions, [:organization_id, :prediction_date], name: "idx_kalshi_weather_predictions_org_date"
    add_index :kalshi_weather_predictions, [:organization_id, :status, :result_status], name: "idx_kalshi_weather_predictions_status"
    add_index :kalshi_weather_predictions, [:series_ticker, :prediction_date], name: "idx_kalshi_weather_predictions_series_date"
    add_index :kalshi_weather_predictions, :metadata, using: :gin
    add_index :kalshi_weather_predictions, :raw_payload, using: :gin
  end
end
