# frozen_string_literal: true

module Kalshi
  class WeatherBucketProbability
    MODEL_VERSION = "station_residual_normal_v1".freeze
    BLIND_MODEL_VERSION = "source_spread_normal_v1".freeze
    COORDINATE_VERSION = "settlement_station_v1".freeze
    DEFAULT_SIGMA_F = 4.5
    MIN_SIGMA_F = 2.5
    MAX_SIGMA_F = 10.0
    PRIOR_STRENGTH = 24.0
    MIN_LIVE_SAMPLE = 30
    MAX_LOOKBACK = 240
    LOWER_BOUND_Z = 1.28

    class << self
      def call(**kwargs)
        new(**kwargs).call
      end
    end

    def initialize(organization:, series_ticker:, target_date:, forecast_high_f:, market_floor_strike:, market_cap_strike:, source_spread_f:, residuals: nil, use_history: true)
      @organization = organization
      @series_ticker = series_ticker.to_s
      @target_date = target_date
      @forecast_high_f = forecast_high_f.to_f
      @market_floor_strike = market_floor_strike
      @market_cap_strike = market_cap_strike
      @source_spread_f = source_spread_f
      @supplied_residuals = residuals
      @use_history = use_history
    end

    def call
      residuals = use_history ? historical_residuals : []
      distribution = distribution_for(residuals)
      probability = probability_for(
        mean: forecast_high_f + distribution.fetch(:bias_f),
        sigma: distribution.fetch(:sigma_f)
      ).clamp(0.01, 0.99)
      effective_sample = residuals.length + PRIOR_STRENGTH
      uncertainty = LOWER_BOUND_Z * Math.sqrt((probability * (1.0 - probability)) / effective_sample)
      lower_bound = (probability - uncertainty).clamp(0.01, probability)

      {
        confidence: probability.round(4),
        confidence_lower_bound: lower_bound.round(4),
        model_version: use_history ? MODEL_VERSION : BLIND_MODEL_VERSION,
        coordinate_version: COORDINATE_VERSION,
        training_sample_size: residuals.length,
        min_live_sample: MIN_LIVE_SAMPLE,
        model_ready: use_history ? residuals.length >= MIN_LIVE_SAMPLE : true,
        history_enabled: use_history,
        blind_edge_mode: !use_history,
        residual_bias_f: distribution.fetch(:bias_f).round(3),
        residual_sigma_f: distribution.fetch(:sigma_f).round(3),
        source_spread_f: source_spread_f,
        prior_strength: PRIOR_STRENGTH,
        lower_bound_z: LOWER_BOUND_Z,
        market_floor_strike: market_floor_strike,
        market_cap_strike: market_cap_strike
      }
    end

    private

    attr_reader :organization, :series_ticker, :target_date, :forecast_high_f,
      :market_floor_strike, :market_cap_strike, :source_spread_f, :supplied_residuals, :use_history

    def historical_residuals
      return Array(supplied_residuals).map(&:to_f).first(MAX_LOOKBACK) unless supplied_residuals.nil?
      return [] if organization.blank? || series_ticker.blank?

      scope = organization.kalshi_weather_predictions
        .where(series_ticker: series_ticker)
        .where.not(observed_high_f: nil)
        .where.not(adjusted_high_f: nil)
        .where("metadata ? 'official_market_reconciled_at'")
        .where("metadata ->> 'forecast_coordinate_version' = ?", COORDINATE_VERSION)
      scope = scope.where("prediction_date < ?", target_date) if target_date.present?
      scope
        .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
        .limit(MAX_LOOKBACK * 2)
        .to_a
        .group_by { |row| row.event_ticker.presence || row.market_ticker }
        .values
        .map { |rows| rows.max_by(&:updated_at) }
        .first(MAX_LOOKBACK)
        .map { |row| row.observed_high_f.to_f - row.adjusted_high_f.to_f }
    rescue StandardError
      []
    end

    def distribution_for(residuals)
      count = residuals.length
      raw_bias = count.positive? ? residuals.sum / count : 0.0
      bias_weight = count / (count + PRIOR_STRENGTH)
      bias = (raw_bias * bias_weight).clamp(-4.0, 4.0)
      sample_variance = if count > 1
        residuals.sum { |value| (value - raw_bias)**2 } / (count - 1)
      else
        DEFAULT_SIGMA_F**2
      end
      shrunk_variance = ((sample_variance * count) + ((DEFAULT_SIGMA_F**2) * PRIOR_STRENGTH)) / (count + PRIOR_STRENGTH)
      spread_variance = source_spread_f.present? ? (source_spread_f.to_f / 2.0)**2 : 0.0
      sigma = Math.sqrt(shrunk_variance + spread_variance).clamp(MIN_SIGMA_F, MAX_SIGMA_F)

      { bias_f: bias, sigma_f: sigma }
    end

    def probability_for(mean:, sigma:)
      if market_floor_strike.present? && market_cap_strike.present?
        normal_cdf(market_cap_strike.to_f + 0.5, mean, sigma) -
          normal_cdf(market_floor_strike.to_f - 0.5, mean, sigma)
      elsif market_floor_strike.present?
        1.0 - normal_cdf(market_floor_strike.to_f + 0.5, mean, sigma)
      elsif market_cap_strike.present?
        normal_cdf(market_cap_strike.to_f - 0.5, mean, sigma)
      else
        0.0
      end
    end

    def normal_cdf(value, mean, sigma)
      0.5 * (1.0 + Math.erf((value - mean) / (sigma * Math.sqrt(2.0))))
    end
  end
end
