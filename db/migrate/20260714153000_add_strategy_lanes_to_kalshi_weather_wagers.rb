class AddStrategyLanesToKalshiWeatherWagers < ActiveRecord::Migration[8.1]
  OLD_UNIQUE_INDEX = "idx_kalshi_weather_wagers_unique_prediction"
  LANE_UNIQUE_INDEX = "idx_weather_wagers_unique_strategy_lane"
  HISTORY_INDEX = "idx_weather_wagers_history"

  def up
    add_column :kalshi_weather_wagers, :strategy_key, :string, null: false, default: "legacy"
    add_column :kalshi_weather_wagers, :strategy_version, :string

    remove_index :kalshi_weather_wagers, name: OLD_UNIQUE_INDEX, if_exists: true
    add_index :kalshi_weather_wagers,
      [:organization_id, :kalshi_weather_prediction_id, :execution_mode, :strategy_key],
      unique: true,
      name: LANE_UNIQUE_INDEX
    add_index :kalshi_weather_wagers,
      [:organization_id, :execution_mode, :status, :created_at],
      name: HISTORY_INDEX
  end

  def down
    remove_index :kalshi_weather_wagers, name: HISTORY_INDEX, if_exists: true
    remove_index :kalshi_weather_wagers, name: LANE_UNIQUE_INDEX, if_exists: true
    remove_column :kalshi_weather_wagers, :strategy_version
    remove_column :kalshi_weather_wagers, :strategy_key
    add_index :kalshi_weather_wagers,
      [:organization_id, :kalshi_weather_prediction_id],
      unique: true,
      name: OLD_UNIQUE_INDEX
  end
end
