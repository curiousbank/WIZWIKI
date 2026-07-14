class CreateWeatherZipCrosswalks < ActiveRecord::Migration[8.1]
  def change
    create_table :weather_zip_crosswalks do |t|
      t.string :postal_code, null: false
      t.string :county_fips, null: false
      t.string :state
      t.string :preferred_city
      t.decimal :res_ratio, precision: 12, scale: 8
      t.decimal :bus_ratio, precision: 12, scale: 8
      t.decimal :oth_ratio, precision: 12, scale: 8
      t.decimal :total_ratio, precision: 12, scale: 8
      t.string :source, null: false, default: "hud_usps"
      t.string :source_version, null: false, default: "unknown"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :weather_zip_crosswalks, [:source, :source_version, :postal_code, :county_fips],
      unique: true,
      name: "idx_weather_zip_crosswalks_unique_source_version"
    add_index :weather_zip_crosswalks, [:county_fips, :postal_code], name: "idx_weather_zip_crosswalks_county_zip"
    add_index :weather_zip_crosswalks, [:state, :postal_code], name: "idx_weather_zip_crosswalks_state_zip"
    add_index :weather_zip_crosswalks, :postal_code
    add_index :weather_zip_crosswalks, :metadata, using: :gin
  end
end
