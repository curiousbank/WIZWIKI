# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Kalshi
  class WeatherMarketScoutTest < ActiveSupport::TestCase
    test "weighted forecast consensus favors historically lower-error sources" do
      organization = Organization.create!(
        name: "Weather Source Weight Test",
        slug: "weather-source-weight-test-#{SecureRandom.hex(4)}"
      )
      10.times do |index|
        actual = 80 + (index % 2)
        create_source_accuracy_row(
          organization,
          index: index,
          observed_high: actual,
          weather_gov_high: actual,
          open_meteo_high: actual + 6,
          met_norway_high: actual + 8
        )
      end
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      forecast = {
        high_f: 86,
        source_count: 3,
        source_spread_f: 2,
        sources: [
          { key: "weather_gov", label: "Weather.gov", high_f: 84 },
          { key: "open_meteo", label: "Open-Meteo", high_f: 86 },
          { key: "met_norway", label: "MET Norway", high_f: 86 }
        ]
      }

      weighted = scout.send(:source_weighted_forecast, forecast)

      assert_equal true, weighted[:source_weighting][:active]
      assert_operator weighted[:high_f], :<, forecast[:high_f]
      assert_equal 86, weighted[:raw_consensus_high_f]
      assert_operator weighted[:source_weights].find { |row| row[:key] == "weather_gov" }[:normalized_weight],
        :>,
        weighted[:source_weights].find { |row| row[:key] == "met_norway" }[:normalized_weight]
    end

    test "legacy blind setting is ignored and trained source weights remain active" do
      organization = Organization.create!(
        name: "Weather Blind Source Test",
        slug: "weather-blind-source-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      10.times do |index|
        actual = 80 + (index % 2)
        create_source_accuracy_row(
          organization,
          index: index,
          observed_high: actual,
          weather_gov_high: actual,
          open_meteo_high: actual + 6,
          met_norway_high: actual + 8
        )
      end
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      forecast = {
        high_f: 86,
        source_count: 3,
        source_spread_f: 8,
        sources: [
          { key: "weather_gov", label: "Weather.gov", high_f: 80 },
          { key: "open_meteo", label: "Open-Meteo", high_f: 86 },
          { key: "met_norway", label: "MET Norway", high_f: 88 }
        ]
      }

      result = scout.send(:source_weighted_forecast, forecast)

      assert_equal false, scout.send(:blind_edge_mode?)
      assert_operator result[:high_f], :<, 86
      assert_equal 86, result[:raw_consensus_high_f]
      assert_equal true, result[:source_weighting][:active]
      assert_equal "provider_abs_error_v1", result[:source_weighting][:model]
    end

    test "untrained consensus does not silently discard a disagreeing source" do
      organization = Organization.create!(
        name: "Weather Blind Robust Test",
        slug: "weather-blind-robust-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      forecast = {
        high_f: 95,
        source_count: 3,
        source_spread_f: 6.1,
        sources: [
          { key: "weather_gov", label: "Weather.gov", high_f: 92.0 },
          { key: "open_meteo", label: "Open-Meteo", high_f: 94.7 },
          { key: "met_norway", label: "MET Norway", high_f: 98.1 }
        ]
      }

      result = scout.send(:source_weighted_forecast, forecast)

      assert_equal 95, result[:high_f]
      assert_equal 3, result[:source_count]
      assert_equal 6.1, result[:source_spread_f]
      assert_equal false, result[:source_weighting][:active]
      assert_equal "fewer than 2 trained source histories", result[:source_weighting][:reason]
    end

    test "wide live-source disagreement is always gated" do
      organization = Organization.create!(
        name: "Weather Blind Spread Test",
        slug: "weather-blind-spread-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      definition = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHCHI" }
      reason = scout.send(
        :stale_forecast_gate_reason,
        definition,
        { close_time: 1.day.from_now },
        { source_count: 3, source_spread_f: 4.6, fetched_at: Time.current },
        {}
      )

      assert_match(/live source disagreement/, reason)
      assert_match(/4.6F spread/, reason)
    end

    test "raw research ranking can prefer a cheap tail but cannot authorize a ticket" do
      organization = Organization.create!(
        name: "Weather Contract Edge Test",
        slug: "weather-contract-edge-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      definition = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHCHI" }
      markets = [
        { ticker: "KXHIGHCHI-26JUL13-B79.5", event_ticker: "KXHIGHCHI-26JUL13", floor_strike: 79, cap_strike: 80, yes_ask: 0.50 },
        { ticker: "KXHIGHCHI-26JUL13-T90", event_ticker: "KXHIGHCHI-26JUL13", cap_strike: 90, yes_ask: 0.01 }
      ]

      result = scout.send(
        :best_market_probability_evaluation,
        definition,
        markets,
        { source_spread_f: 1.0 },
        80
      )

      assert_equal "KXHIGHCHI-26JUL13-T90", result.dig(:market, :ticker)
      assert_operator result[:conservative_edge], :>, 0.80

      pick = scout.send(
        :build_paper_pick,
        definition,
        markets,
        {
          high_f: 80,
          target_date: Date.new(2026, 7, 13),
          event_date_aligned: true,
          source_count: 3,
          source_spread_f: 1.0,
          sources: []
        }
      )
      assert_equal "watch", pick[:action]
      assert_equal "0 contracts", pick[:size]
      assert_equal 2, pick[:candidate_evaluations].length
    end

    test "market selection keeps every contract on one nearest open event date" do
      organization = Organization.create!(name: "Weather Event Test", slug: "weather-event-test-#{SecureRandom.hex(4)}")
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      definition = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHCHI" }
      markets = [
        { ticker: "KXHIGHCHI-26JUL12-B80.5", event_ticker: "KXHIGHCHI-26JUL12", floor_strike: 80, cap_strike: 81, close_time: "2026-07-13T05:59:00Z" },
        { ticker: "KXHIGHCHI-26JUL13-B82.5", event_ticker: "KXHIGHCHI-26JUL13", floor_strike: 82, cap_strike: 83, close_time: "2026-07-14T05:59:00Z" },
        { ticker: "KXHIGHCHI-26JUL12-T80", event_ticker: "KXHIGHCHI-26JUL12", cap_strike: 80, close_time: "2026-07-13T05:59:00Z" }
      ]

      travel_to Time.zone.parse("2026-07-12 12:00:00") do
        selected = scout.send(:active_event_markets, definition, markets)

        assert_equal 2, selected.length
        assert_equal ["KXHIGHCHI-26JUL12"], selected.map { |market| market[:event_ticker] }.uniq
      end
    end

    test "market scan advances to the next event after the local same-day cutoff" do
      organization = Organization.create!(
        name: "Weather Event Cutoff Test",
        slug: "weather-event-cutoff-test-#{SecureRandom.hex(4)}",
        settings: { "weather_autopilot" => { "blind_edge_mode" => true } }
      )
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      definition = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHCHI" }
      markets = [
        { ticker: "KXHIGHCHI-26JUL12-B80.5", event_ticker: "KXHIGHCHI-26JUL12", floor_strike: 80, cap_strike: 81, close_time: "2026-07-13T05:59:00Z" },
        { ticker: "KXHIGHCHI-26JUL13-B82.5", event_ticker: "KXHIGHCHI-26JUL13", floor_strike: 82, cap_strike: 83, close_time: "2026-07-14T05:59:00Z" }
      ]

      travel_to Time.zone.parse("2026-07-12 20:00:00") do
        selected = scout.send(:active_event_markets, definition, markets)

        assert_equal ["KXHIGHCHI-26JUL13"], selected.map { |market| market[:event_ticker] }.uniq
      end
    end

    test "market scout persists every priced strike as research without staling siblings" do
      organization = Organization.create!(name: "Weather Candidate Set Test", slug: "weather-candidate-set-#{SecureRandom.hex(4)}")
      scout = WeatherMarketScout.new(organization: organization, signals: [])
      event_date = Date.new(2026, 7, 20)
      event_ticker = "KXHIGHCHI-26JUL20"
      markets = [
        { ticker: "#{event_ticker}-B89.5", event_ticker: event_ticker, title: "89 to 90", subtitle: "89-90F", floor_strike: 89, cap_strike: 90, close_time: "2026-07-21T05:59:00Z" },
        { ticker: "#{event_ticker}-T89", event_ticker: event_ticker, title: "Below 89", subtitle: "under 89F", cap_strike: 89, close_time: "2026-07-21T05:59:00Z" }
      ]
      evaluations = markets.each_with_index.map do |market, index|
        {
          market_ticker: market[:ticker],
          event_ticker: event_ticker,
          title: market[:title],
          range: market[:subtitle],
          floor_strike: market[:floor_strike],
          cap_strike: market[:cap_strike],
          ask: index.zero? ? 0.40 : 0.20,
          confidence: index.zero? ? 0.56 : 0.30,
          confidence_lower_bound: index.zero? ? 0.50 : 0.22,
          edge: index.zero? ? 0.16 : 0.10,
          conservative_edge: index.zero? ? 0.10 : 0.02,
          probability_model_version: WeatherBucketProbability::MODEL_VERSION,
          probability_training_sample_size: 30,
          probability_min_live_sample: WeatherBucketProbability::MIN_LIVE_SAMPLE,
          probability_model_ready: true,
          probability_history_enabled: true,
          close_time: market[:close_time]
        }.compact
      end
      representative = {
        model_version: WeatherMarketScout::WEATHER_DESK_MODEL_VERSION,
        action: "watch",
        size: "0 contracts",
        side: "YES",
        market_ticker: evaluations.first[:market_ticker],
        event_ticker: event_ticker,
        forecast_high_f: 90,
        adjusted_high_f: 90,
        candidate_evaluations: evaluations,
        gate_reasons: [],
        calibration: { model_version: WeatherBucketProbability::MODEL_VERSION, training_sample_size: 30, model_ready: true },
        local_adjustment: { raw: 0, applied: 0 },
        training_note: "research"
      }
      row = {
        ticker: "KXHIGHCHI",
        city: "Chicago",
        state: "IL",
        station_id: "KMDW",
        latitude: 41.78417,
        longitude: -87.75528,
        time_zone: "America/Chicago",
        markets: markets,
        paper_pick: representative,
        forecast: {
          target_date: event_date,
          event_date_aligned: true,
          source_count: 3,
          source_spread_f: 1.0,
          sources: []
        }
      }

      scout.send(:persist_weather_study_predictions, [row])

      records = organization.kalshi_weather_predictions.where(event_ticker: event_ticker).order(:market_ticker)
      assert_equal 2, records.count
      assert_equal ["watch"], records.reorder(nil).distinct.pluck(:action)
      assert_equal ["open"], records.reorder(nil).distinct.pluck(:status)
      assert records.all? { |record| record.metadata["research_only"] == true }
      assert_equal 2, records.sum { |record| record.kalshi_weather_prediction_snapshots.count }
      assert_not records.first.metadata["gate_reasons"].any? { |reason| reason.include?("edge below") }
      assert records.last.metadata["gate_reasons"].any? { |reason| reason.include?("edge below") }
    end

    test "weather definitions use exact settlement stations" do
      chicago = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHCHI" }
      los_angeles = WeatherMarketScout::WEATHER_STUDY_SERIES.find { |row| row[:ticker] == "KXHIGHLAX" }

      assert_equal "KMDW", chicago[:station_id]
      assert_in_delta 41.78417, chicago[:latitude], 0.00001
      assert_equal "KLAX", los_angeles[:station_id]
      assert_in_delta(-118.38889, los_angeles[:longitude], 0.00001)
    end

    test "identical prediction features create one immutable snapshot" do
      organization = Organization.create!(name: "Weather Snapshot Test", slug: "weather-snapshot-test-#{SecureRandom.hex(4)}")
      prediction = organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHCHI",
        event_ticker: "KXHIGHCHI-26JUL12",
        market_ticker: "KXHIGHCHI-26JUL12-B86.5",
        city: "Chicago",
        state: "IL",
        action: "watch",
        prediction_date: Date.new(2026, 7, 12),
        forecast_high_f: 86,
        adjusted_high_f: 86,
        confidence: 0.17,
        ask: 0.50,
        edge: -0.33
      )
      pick = {
        model_version: WeatherMarketScout::WEATHER_DESK_MODEL_VERSION,
        action: "watch",
        forecast_high_f: 86,
        adjusted_high_f: 86,
        confidence: 0.17,
        confidence_lower_bound: 0.08,
        ask: 0.50,
        edge: -0.33,
        conservative_edge: -0.42,
        gate_reasons: ["edge below threshold"],
        local_adjustment: { raw: 0, applied: 0 },
        calibration: { model_version: WeatherBucketProbability::MODEL_VERSION, training_sample_size: 0 }
      }
      row = {
        station_id: "KMDW",
        latitude: 41.78417,
        longitude: -87.75528,
        forecast: { source_count: 3, source_spread_f: 1.5, sources: [] }
      }
      scout = WeatherMarketScout.new(organization: organization, signals: [])

      2.times { scout.send(:persist_prediction_snapshot, prediction, pick, row) }

      assert_equal 1, prediction.kalshi_weather_prediction_snapshots.count
    end

    private

    def create_source_accuracy_row(organization, index:, observed_high:, weather_gov_high:, open_meteo_high:, met_norway_high:)
      organization.kalshi_weather_predictions.create!(
        series_ticker: "KXHIGHAUS",
        event_ticker: "KXHIGHAUS-26JUL#{format('%02d', index + 1)}",
        market_ticker: "KXHIGHAUS-26JUL#{format('%02d', index + 1)}-B#{observed_high}.5",
        city: "Austin",
        state: "TX",
        market_title: "Austin daily high",
        market_range: "#{observed_high}-#{observed_high + 1}F",
        action: "watch",
        side: "YES",
        size_label: "0 contracts",
        prediction_date: Date.new(2026, 7, 1) + index.days,
        forecast_high_f: weather_gov_high,
        adjusted_high_f: weather_gov_high,
        observed_high_f: observed_high,
        confidence: 0.5,
        ask: 0.5,
        edge: 0.1,
        status: "settled",
        result_status: "won",
        metadata: {
          "official_market_reconciled_at" => Time.current.iso8601,
          "forecast_coordinate_version" => WeatherMarketScout::FORECAST_COORDINATE_VERSION,
          "forecast_sources" => [
            { "key" => "weather_gov", "label" => "Weather.gov", "high_f" => weather_gov_high },
            { "key" => "open_meteo", "label" => "Open-Meteo", "high_f" => open_meteo_high },
            { "key" => "met_norway", "label" => "MET Norway", "high_f" => met_norway_high }
          ]
        }
      )
    end
  end
end
