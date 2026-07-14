# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Kalshi
  class WeatherCalibrationHarnessTest < ActiveSupport::TestCase
    setup do
      @organization = Organization.create!(
        name: "Weather Harness Test",
        slug: "weather-harness-#{SecureRandom.hex(4)}"
      )
      @harness = WeatherCalibrationHarness.new(organization: @organization)
    end

    test "aggregate taker fees and contract sizing keep total risk at or below five dollars" do
      assert_equal 0.01, WeatherCalibrationHarness.taker_fee(price: 0.01, contracts: 1)
      assert_equal 467, WeatherCalibrationHarness.contracts_within_cap(price: 0.01)
      assert_operator WeatherCalibrationHarness.total_risk(price: 0.01, contracts: 467), :<=, 5.0
      assert_operator WeatherCalibrationHarness.total_risk(price: 0.01, contracts: 468), :>, 5.0

      contracts = WeatherCalibrationHarness.contracts_within_cap(price: 0.50)
      assert_equal 9, contracts
      assert_equal 0.16, WeatherCalibrationHarness.taker_fee(price: 0.50, contracts: contracts)
      assert_equal 4.66, WeatherCalibrationHarness.total_risk(price: 0.50, contracts: contracts)
    end

    test "training rows never include the target date or a future date" do
      start_date = Date.new(2026, 1, 1)
      26.times { |index| create_snapshot(date: start_date + index.days, won: index.even?, index: index) }

      cutoff = start_date + 20.days
      rows = @harness.send(
        :training_rows_for,
        model_version: WeatherBucketProbability::MODEL_VERSION,
        before_date: cutoff
      )

      assert_equal 20, rows.length
      assert rows.all? { |row| row.fetch(:date) < cutoff }
      assert_not_includes rows.map { |row| row.fetch(:date) }, cutoff
    end

    test "one event trains calibration once while every contract remains in policy evaluation" do
      date = Date.new(2026, 4, 7)
      create_snapshot(date: date, won: true, index: 0)
      create_snapshot(date: date, won: false, index: 1)

      policy_rows = @harness.send(:policy_rows)
      decision_rows = @harness.send(:decision_rows)

      assert_equal 2, policy_rows.length
      assert_equal 1, decision_rows.length
      assert_equal 0.48, decision_rows.first[:ask]
    end

    test "training rejects snapshots that only inherit alignment from mutable prediction metadata" do
      date = Date.new(2026, 4, 8)
      create_snapshot(date: date, won: true, index: 0)
      snapshot = KalshiWeatherPredictionSnapshot.where(organization: @organization).first
      snapshot.update!(payload: snapshot.payload.except("forecast_event_date_aligned"))
      snapshot.kalshi_weather_prediction.update!(
        metadata: snapshot.kalshi_weather_prediction.metadata.merge("forecast_event_date_aligned" => true)
      )

      assert_equal false, @harness.send(:eligible_snapshot?, snapshot.reload)
      assert_empty @harness.send(:policy_rows)
    end

    test "legacy snapshots require explicit matching dates from every immutable forecast source" do
      date = Date.new(2026, 4, 8)
      create_snapshot(date: date, won: true, index: 0)
      snapshot = KalshiWeatherPredictionSnapshot.where(organization: @organization).first
      legacy_payload = snapshot.payload.except("forecast_event_date_aligned").merge(
        "forecast_sources" => [
          { "key" => "open_meteo", "period" => date.iso8601 },
          { "key" => "met_norway", "forecast_date" => date.iso8601 }
        ]
      )
      snapshot.update!(payload: legacy_payload)

      assert_equal true, @harness.send(:eligible_snapshot?, snapshot.reload)

      snapshot.update!(payload: legacy_payload.merge(
        "forecast_sources" => [
          { "key" => "open_meteo", "period" => date.iso8601 },
          { "key" => "met_norway", "forecast_date" => (date + 1.day).iso8601 }
        ]
      ))
      assert_equal false, WeatherCalibrationHarness.new(organization: @organization).send(:eligible_snapshot?, snapshot.reload)
    end

    test "model readiness is read from the immutable snapshot" do
      date = Date.new(2026, 4, 9)
      create_snapshot(date: date, won: true, index: 0)
      snapshot = KalshiWeatherPredictionSnapshot.where(organization: @organization).first
      snapshot.kalshi_weather_prediction.update!(
        metadata: snapshot.kalshi_weather_prediction.metadata.merge("probability_model_ready" => true)
      )

      assert_equal false, @harness.send(:policy_rows).first.fetch(:model_ready)
      snapshot.update!(payload: snapshot.payload.merge("probability_model_ready" => true))
      refreshed = WeatherCalibrationHarness.new(organization: @organization)
      assert_equal true, refreshed.send(:policy_rows).first.fetch(:model_ready)
    end

    test "calibration stays anchored to market price before the minimum immutable sample" do
      estimate = @harness.send(
        :calibrated_estimate,
        raw_probability: 0.80,
        market_probability: 0.20,
        training_rows: []
      )

      assert_equal 0.20, estimate[:probability]
      assert_equal 0.20, estimate[:lower_bound]
      assert_equal "market_only_until_minimum_sample", estimate[:training_scope]
    end

    test "walk forward simulation makes no more than one allocation per strategy per day" do
      date = Date.new(2026, 5, 1)
      rows = [
        historical_row(id: 1, date: date, probability: 0.60, lower_bound: 0.56, ask: 0.30),
        historical_row(id: 2, date: date, probability: 0.70, lower_bound: 0.62, ask: 0.30),
        historical_row(id: 3, date: date + 1.day, probability: 0.65, lower_bound: 0.60, ask: 0.30)
      ]

      challenger = @harness.send(:historical_daily_allocations, rows, strategy: :challenger)
      active = @harness.send(:historical_daily_allocations, rows, strategy: :active)

      assert_equal [2, 3], challenger.map { |row| row[:id] }
      assert_equal [2, 3], active.map { |row| row[:id] }
    end

    test "live gate fails closed without settled prospective paper active days" do
      summary = @harness.call

      assert_equal false, summary.dig(:live_gate, :clear)
      assert summary.dig(:live_gate, :manual_promotion_required)
      assert_includes summary.dig(:live_gate, :reasons).join(" "), "prospective $5 paper-active"
    end

    test "fit is deterministic for the same immutable rows" do
      rows = 30.times.map do |index|
        historical_row(
          id: index,
          date: Date.new(2026, 1, 1) + index.days,
          probability: index.even? ? 0.62 : 0.38,
          lower_bound: index.even? ? 0.55 : 0.31,
          ask: index.even? ? 0.48 : 0.30,
          won: (index % 3).zero?
        )
      end

      assert_equal @harness.send(:fit, rows), @harness.send(:fit, rows)
    end

    private

    def create_snapshot(date:, won:, index:)
      event_ticker = "KXHIGHCHI-#{date.strftime('%y%b%d').upcase}"
      prediction = @organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: event_ticker,
        market_ticker: "#{event_ticker}-T#{80 + index}",
        city: "Chicago",
        state: "IL",
        action: "paper_yes",
        side: "YES",
        size_label: "paper",
        prediction_date: date,
        close_time: date.in_time_zone.end_of_day,
        confidence: index.even? ? 0.62 : 0.38,
        ask: index.even? ? 0.48 : 0.30,
        status: "settled",
        result_status: won ? "won" : "lost",
        metadata: {
          "forecast_coordinate_version" => WeatherBucketProbability::COORDINATE_VERSION,
          "forecast_event_date_aligned" => true,
          "probability_model_version" => WeatherBucketProbability::MODEL_VERSION,
          "forecast_source_count" => 3,
          "forecast_source_spread_f" => 1.0
        }
      )
      prediction.kalshi_weather_prediction_snapshots.create!(
        organization: @organization,
        series_ticker: prediction.series_ticker,
        event_ticker: event_ticker,
        market_ticker: prediction.market_ticker,
        prediction_date: date,
        captured_at: date.in_time_zone.beginning_of_day,
        action: prediction.action,
        confidence: prediction.confidence,
        ask: prediction.ask,
        forecast_source_count: 3,
        forecast_source_spread_f: 1.0,
        feature_digest: SecureRandom.hex(32),
        payload: {
          "forecast_coordinate_version" => WeatherBucketProbability::COORDINATE_VERSION,
          "forecast_event_date_aligned" => true,
          "probability_model_version" => WeatherBucketProbability::MODEL_VERSION
        }
      )
    end

    def historical_row(id:, date:, probability:, lower_bound:, ask:, won: true)
      {
        id: id,
        date: date,
        ask: ask,
        confidence: probability,
        calibrated_probability: probability,
        calibrated_lower_bound: lower_bound,
        source_count: 3,
        source_spread_f: 1.0,
        blind: false,
        won: won,
        model_version: WeatherBucketProbability::MODEL_VERSION
      }
    end
  end
end
