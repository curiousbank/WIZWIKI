class CreateKalshiWeatherWagers < ActiveRecord::Migration[8.1]
  def change
    create_table :kalshi_weather_wagers do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :kalshi_weather_prediction, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :execution_mode, null: false, default: "dry_run"
      t.string :side, null: false, default: "yes"
      t.string :action, null: false, default: "buy"
      t.string :market_ticker, null: false
      t.string :client_order_id
      t.string :kalshi_order_id
      t.integer :contracts, null: false, default: 0
      t.integer :filled_contracts, null: false, default: 0
      t.decimal :price, precision: 8, scale: 4
      t.decimal :max_cost, precision: 12, scale: 2, null: false, default: "0.0"
      t.decimal :actual_cost, precision: 12, scale: 2
      t.decimal :realized_profit, precision: 12, scale: 2
      t.date :budget_date, null: false
      t.string :opportunity_tier
      t.text :reason
      t.datetime :placed_at
      t.datetime :filled_at
      t.datetime :settled_at
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps

      t.index [:organization_id, :budget_date, :status], name: "idx_kalshi_weather_wagers_budget"
      t.index [:organization_id, :market_ticker], name: "idx_kalshi_weather_wagers_market"
      t.index [:organization_id, :kalshi_weather_prediction_id], unique: true, name: "idx_kalshi_weather_wagers_unique_prediction"
      t.index :client_order_id, unique: true, where: "client_order_id IS NOT NULL"
    end
  end
end
