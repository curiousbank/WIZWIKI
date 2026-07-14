class WeatherZipCrosswalk < ApplicationRecord
  before_validation :normalize_fields

  validates :postal_code, :county_fips, :source, :source_version, presence: true
  validates :postal_code, format: { with: /\A\d{5}\z/ }
  validates :county_fips, format: { with: /\A\d{5}\z/ }

  scope :for_counties, ->(county_fips) { where(county_fips: Array(county_fips).compact_blank) }
  scope :for_states, ->(states) { where(state: Array(states).map { |state| state.to_s.upcase }.compact_blank) }
  scope :meaningful, ->(minimum_ratio) {
    where(
      "COALESCE(weather_zip_crosswalks.bus_ratio, 0) >= :minimum OR COALESCE(weather_zip_crosswalks.res_ratio, 0) >= :minimum OR COALESCE(weather_zip_crosswalks.total_ratio, 0) >= :minimum",
      minimum: minimum_ratio
    )
  }

  def self.storage_ready?
    table_exists?
  rescue ActiveRecord::StatementInvalid
    false
  end

  private

  def normalize_fields
    self.postal_code = postal_code.to_s[/\d{5}/]
    self.county_fips = county_fips.to_s[/\d{5}/]
    self.state = state.to_s.strip.upcase[/\A[A-Z]{2}\z/]
    self.preferred_city = preferred_city.to_s.squish.presence
    self.source = source.to_s.strip.downcase.presence || "hud_usps"
    self.source_version = source_version.to_s.strip.presence || "unknown"
    self.metadata = metadata.to_h
  end
end
