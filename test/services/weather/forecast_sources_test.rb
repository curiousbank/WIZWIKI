# frozen_string_literal: true

require "test_helper"

module Weather
  class ForecastSourcesTest < ActiveSupport::TestCase
    test "source timestamps are grouped in the settlement station timezone" do
      los_angeles = ForecastSources.new(
        {
          ticker: "KXHIGHLAX",
          city: "Los Angeles",
          latitude: 33.93806,
          longitude: -118.38889,
          station_id: "KLAX",
          time_zone: "America/Los_Angeles"
        },
        target_date: Date.new(2026, 7, 12)
      )

      local = los_angeles.send(:source_time, "2026-07-13T06:30:00Z")

      assert_equal Date.new(2026, 7, 12), local.to_date
      assert_equal "America/Los_Angeles", local.time_zone.tzinfo.name
    end

    test "json requests follow secure redirects" do
      source = ForecastSources.new(
        { ticker: "KXHIGHCHI", city: "Chicago", latitude: 41.78, longitude: -87.75 },
        target_date: Date.new(2026, 7, 12)
      )
      redirect = Net::HTTPMovedPermanently.new("1.1", "301", "Moved")
      redirect["location"] = "https://api.weather.gov/gridpoints/LOT/1,1/forecast"
      success = Net::HTTPOK.new("1.1", "200", "OK")
      success.instance_variable_set(:@body, '{"properties":{"periods":[]}}')
      success.instance_variable_set(:@read, true)
      responses = [redirect, success]
      source.define_singleton_method(:http_get) { |_uri, _request| responses.shift }

      payload = source.send(:request_json, URI("https://api.weather.gov/points/41.78,-87.75"))

      assert_equal({ "properties" => { "periods" => [] } }, payload)
      assert_empty responses
    end

    test "requested weather gov date never falls back to a nighttime low" do
      source = ForecastSources.new(
        {
          ticker: "KXHIGHCHI",
          city: "Chicago",
          latitude: 41.78,
          longitude: -87.75,
          time_zone: "America/Chicago"
        },
        target_date: Date.new(2026, 7, 12)
      )
      periods = [
        {
          "name" => "Tonight",
          "isDaytime" => false,
          "temperature" => 68,
          "startTime" => "2026-07-12T18:00:00-05:00"
        }
      ]

      assert_nil source.send(:forecast_period_for, periods)
    end

    test "open meteo never substitutes the first day when the target date is missing" do
      source = ForecastSources.new(
        { ticker: "KXHIGHCHI", city: "Chicago", latitude: 41.78, longitude: -87.75 },
        target_date: Date.new(2026, 7, 14)
      )
      source.define_singleton_method(:request_json) do |_uri|
        {
          "daily" => {
            "time" => ["2026-07-13"],
            "temperature_2m_max" => [91.0]
          }
        }
      end

      row = source.send(:open_meteo_source)

      assert_equal "unavailable", row[:status]
      assert_nil row[:high_f]
      assert_includes row[:reason], "target date 2026-07-14 missing"
    end

    test "consensus excludes a forecast for the wrong event date" do
      source = ForecastSources.new(
        { ticker: "KXHIGHCHI", city: "Chicago", latitude: 41.78, longitude: -87.75 },
        target_date: Date.new(2026, 7, 14)
      )
      aligned = {
        key: "weather_gov",
        label: "Weather.gov",
        high_f: 90.0,
        period: "Tuesday",
        detail: "aligned",
        forecast_date: "2026-07-14"
      }
      wrong_day = aligned.merge(
        key: "open_meteo",
        label: "Open-Meteo",
        high_f: 72.0,
        forecast_date: "2026-07-13"
      )
      source.define_singleton_method(:weather_gov_source) { aligned }
      source.define_singleton_method(:open_meteo_source) { wrong_day }
      source.define_singleton_method(:met_norway_source) { nil }
      source.define_singleton_method(:visual_crossing_source) { nil }

      consensus = source.send(:build_consensus)

      assert_equal 90, consensus[:high_f]
      assert_equal 1, consensus[:source_count]
      assert_equal true, consensus[:event_date_aligned]
      assert_equal ["Weather.gov"], consensus[:sources].map { |row| row[:label] }
      assert_includes consensus[:unavailable_sources].first[:reason], "does not match target"
    end
  end
end
