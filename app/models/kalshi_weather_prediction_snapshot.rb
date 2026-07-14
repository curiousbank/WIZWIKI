class KalshiWeatherPredictionSnapshot < ApplicationRecord
  belongs_to :organization
  belongs_to :kalshi_weather_prediction

  validates :series_ticker, :event_ticker, :market_ticker, :prediction_date, :captured_at, :action, :feature_digest, presence: true
  validates :feature_digest, uniqueness: { scope: :kalshi_weather_prediction_id }

  def self.storage_ready?
    table_exists?
  rescue ActiveRecord::StatementInvalid
    false
  end
end
