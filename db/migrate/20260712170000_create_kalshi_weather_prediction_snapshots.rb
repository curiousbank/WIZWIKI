class CreateKalshiWeatherPredictionSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :kalshi_weather_prediction_snapshots do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :kalshi_weather_prediction, null: false, foreign_key: true, index: { name: "idx_weather_snapshots_prediction" }
      t.string :series_ticker, null: false
      t.string :event_ticker, null: false
      t.string :market_ticker, null: false
      t.date :prediction_date, null: false
      t.datetime :captured_at, null: false
      t.string :action, null: false
      t.integer :forecast_high_f
      t.integer :adjusted_high_f
      t.decimal :market_floor_strike, precision: 8, scale: 2
      t.decimal :market_cap_strike, precision: 8, scale: 2
      t.decimal :confidence, precision: 8, scale: 4
      t.decimal :confidence_lower_bound, precision: 8, scale: 4
      t.decimal :ask, precision: 8, scale: 4
      t.decimal :edge, precision: 8, scale: 4
      t.decimal :conservative_edge, precision: 8, scale: 4
      t.integer :forecast_source_count
      t.decimal :forecast_source_spread_f, precision: 8, scale: 2
      t.string :feature_digest, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :kalshi_weather_prediction_snapshots,
      [:kalshi_weather_prediction_id, :feature_digest],
      unique: true,
      name: "idx_weather_snapshots_unique_features"
    add_index :kalshi_weather_prediction_snapshots,
      [:organization_id, :event_ticker, :captured_at],
      name: "idx_weather_snapshots_event_time"
    add_index :kalshi_weather_prediction_snapshots,
      [:organization_id, :prediction_date, :captured_at],
      name: "idx_weather_snapshots_date_time"
  end
end
