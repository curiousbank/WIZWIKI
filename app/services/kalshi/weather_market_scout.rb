require "json"
require "net/http"
require "uri"
require "digest"

module Kalshi
  class WeatherMarketScout
    MARKET_STATUS = "open".freeze
    SERIES_CACHE_TTL = 10.minutes
    MARKET_CACHE_TTL = 5.minutes
    FORECAST_CACHE_TTL = 20.minutes
    MARKET_REQUEST_PAUSE = 0.35
    DEFAULT_BASE_URL = "https://external-api.kalshi.com".freeze
    WEATHER_DESK_MODEL_VERSION = "station_bucket_probability_v2".freeze
    FORECAST_COORDINATE_VERSION = "settlement_station_v1".freeze
    CALIBRATION_LOOKBACK = 240
    CALIBRATION_MIN_SAMPLE = 8
    ACTION_EDGE_THRESHOLD = 0.08
    MAX_ACTION_ASK = 0.85
    CHEAP_LONGSHOT_ASK_CEILING = 0.20
    CHEAP_LONGSHOT_MIN_CONFIDENCE = 0.40
    CHEAP_LONGSHOT_MAX_SPREAD_F = 2.0
    CITY_HARD_BENCH_HIT_RATE = 0.20
    CITY_PROBATION_HIT_RATE = 0.30
    STALE_FORECAST_MAX_AGE_MINUTES = 45
    STALE_FORECAST_CLOSE_WINDOW_HOURS = 8
    SOURCE_WEIGHT_MIN_SAMPLE = 8
    SOURCE_WEIGHT_LOOKBACK = 240
    SOURCE_WEIGHT_ERROR_FLOOR = 0.75
    SOURCE_WEIGHT_EQUAL_BLEND = 0.35
    RISK_SETTINGS_KEY = "weather_autopilot".freeze
    MAX_SOURCE_SPREAD_F = 3.0
    SAME_DAY_CUTOFF_HOUR = 15

    WEATHER_STUDY_SERIES = [
      {
        ticker: "KXHIGHNY",
        city: "New York City",
        state: "NY",
        latitude: 40.78333,
        longitude: -73.96667,
        station_id: "KNYC",
        climate_location: "NYC",
        time_zone: "America/New_York",
        label: "NYC daily high",
        why: "Highest weather volume and a tight settlement source. Good first calibration city."
      },
      {
        ticker: "KXHIGHLAX",
        city: "Los Angeles",
        state: "CA",
        latitude: 33.93806,
        longitude: -118.38889,
        station_id: "KLAX",
        climate_location: "LAX",
        time_zone: "America/Los_Angeles",
        label: "LA daily high",
        why: "High volume, marine-layer sensitivity, and frequent narrow ranges."
      },
      {
        ticker: "KXHIGHCHI",
        city: "Chicago",
        state: "IL",
        latitude: 41.78417,
        longitude: -87.75528,
        station_id: "KMDW",
        climate_location: "MDW",
        time_zone: "America/Chicago",
        label: "Chicago daily high",
        why: "High volume and strong frontal/weather-regime swings."
      },
      {
        ticker: "KXHIGHMIA",
        city: "Miami",
        state: "FL",
        latitude: 25.79056,
        longitude: -80.31639,
        station_id: "KMIA",
        climate_location: "MIA",
        time_zone: "America/New_York",
        label: "Miami daily high",
        why: "High volume with humidity, sea breeze, and storm timing effects."
      },
      {
        ticker: "KXHIGHAUS",
        city: "Austin",
        state: "TX",
        latitude: 30.18304,
        longitude: -97.67987,
        station_id: "KAUS",
        climate_location: "AUS",
        time_zone: "America/Chicago",
        label: "Austin daily high",
        why: "High heat-market volume and useful summer edge testing."
      },
      {
        ticker: "KXHIGHDEN",
        city: "Denver",
        state: "CO",
        latitude: 39.84658,
        longitude: -104.65622,
        station_id: "KDEN",
        climate_location: "DEN",
        time_zone: "America/Denver",
        label: "Denver daily high",
        why: "Elevation, dry air, and fast pattern changes make it a useful model challenge."
      },
      {
        ticker: "KXHIGHPHIL",
        city: "Philadelphia",
        state: "PA",
        latitude: 39.87327,
        longitude: -75.22678,
        station_id: "KPHL",
        climate_location: "PHL",
        time_zone: "America/New_York",
        label: "Philadelphia daily high",
        why: "Good Northeast comparison market against NYC."
      },
      {
        ticker: "KXHIGHTBOS",
        city: "Boston",
        state: "MA",
        latitude: 42.36056,
        longitude: -71.01056,
        station_id: "KBOS",
        climate_location: "BOS",
        time_zone: "America/New_York",
        label: "Boston daily high",
        why: "Rounds out the initial set with a coastal Northeast city and active daily contracts."
      }
    ].freeze

    CATEGORY_DEFINITIONS = {
      hurricane: {
        label: "Hurricane / tropical",
        regex: /hurricane|tropical|storm surge|landfall|hurpath|hurcat|named storm/i,
        data_regex: /hurricane|tropical|storm surge/i,
        signal_source: "Weather.gov hurricane/tropical warnings, storm surge alerts, and coastal CRM exposure.",
        edge: "Best when active warnings and forecast-zone text are fresh near Gulf, Florida, and Atlantic coastal markets."
      },
      precipitation: {
        label: "Rain / flood",
        regex: /rain|precip|flood/i,
        data_regex: /rain|flood|flash flood|precip/i,
        signal_source: "Weather.gov flood warnings, recent rain/flood alert history, and affected ZIP crosswalks.",
        edge: "Good fit for daily/monthly rain contracts when our alert history shows local precipitation pressure."
      },
      temperature: {
        label: "High / low temperature",
        regex: /temperature|temp|highest|lowest|daily max|daily high|daily low|heat|cold|\bhigh\b|\blow\b/i,
        data_regex: /temperature|temp|heat|cold|excessive heat|freeze|frost|wind chill/i,
        signal_source: "Forecast-zone outlooks, heat/cold warnings, and recurring city temperature markets.",
        edge: "Best with city-level forecast extraction. Current AUTOS data has direction but needs richer hourly temperature capture for serious sizing."
      },
      snow_winter: {
        label: "Snow / winter",
        regex: /snow|winter|blizzard|ice|freez/i,
        data_regex: /snow|winter|blizzard|ice|freez/i,
        signal_source: "Winter storm, ice, blizzard, and snow signals plus 30-day warning history.",
        edge: "Strong seasonal category when active winter alerts exist; lower priority outside winter windows."
      },
      severe_storm: {
        label: "Tornado / severe storm",
        regex: /tornado|severe storm|severe thunderstorm|hail|damaging wind|high wind|natural disaster|emergency/i,
        data_regex: /tornado|severe thunderstorm|hail|damaging wind|high wind|natural disaster|emergency/i,
        signal_source: "Weather.gov tornado/severe thunderstorm/high-wind warnings and recent alert counts.",
        edge: "Strongest current AUTOS fit because Storm Watch already tracks the alert types that move these markets."
      },
      climate_long: {
        label: "Long-horizon climate",
        regex: /climate|co2|carbon|arctic|sea ice|el ni.?o|temperature deviation|lake mead|earthquake|volcano|eruption|fema/i,
        data_regex: /climate|co2|arctic|sea ice|earthquake|volcano|eruption|fema/i,
        signal_source: "Mostly outside current local Weather.gov alert data; useful as watchlist context, not a near-term edge.",
        edge: "Lowest immediate fit unless we add specialized long-horizon datasets."
      }
    }.freeze

    class << self
      def call(organization:, signals:)
        new(organization: organization, signals: signals).call
      end
    end

    def initialize(organization:, signals:)
      @organization = organization
      @signals = Array(signals)
      @errors = []
    end

    def call
      weather_series = fetch_weather_series
      buckets = CATEGORY_DEFINITIONS.map do |key, definition|
        build_opportunity(key, definition, weather_series)
      end.sort_by { |bucket| -bucket[:score] }
      study_series = build_weather_study_series(weather_series)
      persist_weather_study_predictions(study_series)

      {
        generated_at: Time.current,
        base_url: base_url,
        errors: @errors,
        total_series: weather_series.length,
        top_opportunities: buckets,
        best_opportunities: buckets.select { |bucket| bucket[:score] >= 45 }.first(4),
        watchlist: buckets.first(6),
        study_series: study_series,
        prediction_storage: prediction_storage_status
      }
    end

    private

    attr_reader :organization, :signals

    def build_opportunity(key, definition, weather_series)
      matched_series = weather_series.select { |series| series[:category_key] == key }
      signal_count = signal_count_for(definition.fetch(:data_regex))
      recent_count = recent_signal_count_for(definition.fetch(:data_regex))
      forecast_count = forecast_count_for(definition.fetch(:data_regex))
      representative = matched_series.first(4)
      markets = []
      short_term_count = matched_series.count { |series| series[:frequency].in?(%w[daily hourly weekly monthly custom]) }
      score = score_category(signal_count: signal_count, recent_count: recent_count, forecast_count: forecast_count, series_count: matched_series.length, short_term_count: short_term_count)

      {
        key: key,
        label: definition.fetch(:label),
        score: score,
        verdict: verdict_for(score),
        signal_count: signal_count,
        recent_count: recent_count,
        forecast_count: forecast_count,
        series_count: matched_series.length,
        short_term_count: short_term_count,
        signal_source: definition.fetch(:signal_source),
        edge: definition.fetch(:edge),
        series: representative,
        markets: markets
      }
    end

    def score_category(signal_count:, recent_count:, forecast_count:, series_count:, short_term_count:)
      return 0 if series_count.zero?

      signal_score = [[signal_count * 8, 36].min, 0].max
      recency_score = [[recent_count * 5, 18].min, 0].max
      forecast_score = [[forecast_count * 5, 16].min, 0].max
      market_score = [[series_count * 2, 18].min, 0].max
      timing_score = [[short_term_count * 2, 12].min, 0].max
      [signal_score + recency_score + forecast_score + market_score + timing_score, 100].min
    end

    def verdict_for(score)
      return "compete first" if score >= 70
      return "watch closely" if score >= 45
      return "research only" if score >= 25

      "weak fit"
    end

    def fetch_weather_series
      Rails.cache.fetch(["kalshi_weather_series", organization.id], expires_in: SERIES_CACHE_TTL) do
        fetch_series
          .filter_map { |series| normalize_weather_series(series) }
          .sort_by { |series| [series[:priority], series[:title].to_s] }
      end
    rescue StandardError => error
      @errors << "Kalshi series unavailable: #{error.class}: #{error.message}"
      []
    end

    def fetch_series
      uri = URI("#{base_url}/trade-api/v2/series")
      uri.query = URI.encode_www_form(category: "Climate and Weather", include_volume: true, include_product_metadata: true)
      response = request_json(uri)
      Array(response["series"])
    end

    def fetch_markets_for_series(series_ticker)
      return [] if series_ticker.blank?

      Rails.cache.fetch(["kalshi_weather_markets_v2", organization.id, series_ticker], expires_in: MARKET_CACHE_TTL) do
        sleep MARKET_REQUEST_PAUSE
        uri = URI("#{base_url}/trade-api/v2/markets")
        uri.query = URI.encode_www_form(limit: 100, status: MARKET_STATUS, series_ticker: series_ticker)
        response = request_json(uri)
        Array(response["markets"])
          .map { |market| normalize_market(market) }
      end
    rescue StandardError => error
      @errors << "Kalshi markets unavailable for #{series_ticker}: #{error.class}: #{error.message}"
      []
    end

    def request_json(uri)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (read-only market research)"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 18) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def normalize_weather_series(series)
      category = series["category"].to_s
      title = series["title"].to_s
      ticker = series["ticker"].to_s
      text = [ticker, title].join(" ")
      key = category_key_for(text)
      return nil unless key
      return nil unless category == "Climate and Weather" || category == "World" || text.match?(/rain|snow|temp|temperature|hurricane|tornado|flood|heat/i)

      {
        ticker: ticker,
        title: title,
        category: category.presence || "Kalshi",
        frequency: series["frequency"].to_s.presence || "custom",
        contract_terms_url: series["contract_terms_url"],
        category_key: key,
        priority: priority_for(key, series["frequency"])
      }
    end

    def normalize_market(market)
      {
        ticker: market["ticker"],
        event_ticker: market["event_ticker"],
        title: market["title"],
        subtitle: market["subtitle"].presence || market["yes_sub_title"],
        yes_bid: market["yes_bid_dollars"].presence || market["yes_bid"],
        yes_ask: market["yes_ask_dollars"].presence || market["yes_ask"],
        last_price: market["last_price_dollars"].presence || market["last_price"],
        volume: market["volume_24h_fp"].presence || market["volume_fp"].presence || market["volume"],
        liquidity: market["liquidity_dollars"],
        close_time: market["close_time"],
        floor_strike: market["floor_strike"],
        cap_strike: market["cap_strike"]
      }.compact
    end

    def build_weather_study_series(weather_series)
      WEATHER_STUDY_SERIES.map.with_index(1) do |definition, index|
        series = weather_series.find { |item| item[:ticker] == definition.fetch(:ticker) } || definition.merge(frequency: "daily", category: "Climate and Weather", category_key: :temperature)
        markets = active_event_markets(definition, fetch_markets_for_series(definition.fetch(:ticker)))
        best_market = select_best_market(markets)
        forecast_target_date = weather_event_date_for(Array(markets).first&.dig(:event_ticker))
        forecast = fetch_city_forecast(definition, target_date: forecast_target_date)
        paper_pick = build_paper_pick(definition, markets, forecast)

        definition.merge(
          rank: index,
          title: series[:title].presence || definition.fetch(:label),
          frequency: series[:frequency].presence || "daily",
          contract_terms_url: series[:contract_terms_url],
          markets: markets,
          best_market: best_market,
          midpoint_degrees: midpoint_degrees_for(best_market),
          price_note: price_note_for(best_market),
          study_focus: study_focus_for(definition, best_market),
          forecast: forecast,
          paper_pick: paper_pick
        )
      end
    end

    def active_event_markets(definition, markets)
      grouped = Array(markets).group_by { |market| market[:event_ticker].to_s.presence }
      grouped.delete(nil)
      now = Time.current
      active = grouped.values.select do |event_markets|
        event_date = weather_event_date_for(event_markets.first[:event_ticker])
        next false if event_date.present? && event_date < minimum_event_date(definition)

        event_markets.any? do |market|
          close_time = parse_time(market[:close_time])
          close_time.blank? || close_time > now
        end
      end
      selected = active.min_by do |event_markets|
        event_date = weather_event_date_for(event_markets.first[:event_ticker])
        close_time = event_markets.filter_map { |market| parse_time(market[:close_time]) }.min
        [close_time || 10.years.from_now, event_date || Date.new(9999, 12, 31)]
      end

      Array(selected).sort_by { |market| market_temperature_sort_key(market) }
    end

    def minimum_event_date(definition)
      zone = ActiveSupport::TimeZone[definition[:time_zone]] || Time.zone
      local_now = Time.current.in_time_zone(zone)
      local_now.hour >= SAME_DAY_CUTOFF_HOUR ? local_now.to_date + 1.day : local_now.to_date
    end

    def market_temperature_sort_key(market)
      floor = market[:floor_strike]
      cap = market[:cap_strike]
      return [-Float::INFINITY, cap.to_f] if floor.blank?
      return [floor.to_f, Float::INFINITY] if cap.blank?

      [floor.to_f, cap.to_f]
    end

    def select_best_market(markets)
      Array(markets)
        .select { |market| market[:yes_bid].present? || market[:yes_ask].present? || market[:last_price].present? }
        .max_by { |market| [balanced_price_score(market), market_value(market[:volume])] } ||
        Array(markets).first
    end

    def balanced_price_score(market)
      prices = [market[:yes_bid], market[:yes_ask], market[:last_price]].filter_map { |value| decimal_value(value) }
      return 0 if prices.blank?

      midpoint = prices.sum / prices.length
      1.0 - [(midpoint - 0.5).abs * 2.0, 1.0].min
    end

    def market_value(value)
      value.to_s.delete(",").to_f
    end

    def decimal_value(value)
      return nil if value.blank?

      value.to_s.delete(",").to_f
    end

    def midpoint_degrees_for(market)
      return nil if market.blank?

      floor = market[:floor_strike]
      cap = market[:cap_strike]
      if floor.present? && cap.present?
        ((floor.to_f + cap.to_f) / 2.0).round(1)
      elsif floor.present?
        ">#{floor}"
      elsif cap.present?
        "<#{cap}"
      end
    end

    def numeric_midpoint_degrees_for(market)
      return nil if market.blank?

      floor = market[:floor_strike]
      cap = market[:cap_strike]
      if floor.present? && cap.present?
        ((floor.to_f + cap.to_f) / 2.0).round(2)
      elsif floor.present?
        (floor.to_f + 1.0).round(2)
      elsif cap.present?
        (cap.to_f - 1.0).round(2)
      end
    end

    def price_note_for(market)
      return "waiting for active contracts" if market.blank?

      bid = market[:yes_bid].presence || "n/a"
      ask = market[:yes_ask].presence || "n/a"
      last = market[:last_price].presence || "n/a"
      "bid #{bid} // ask #{ask} // last #{last}"
    end

    def study_focus_for(definition, market)
      target = midpoint_degrees_for(market)
      target_label = target.present? ? " Current live focus: #{target} degrees." : ""
      "#{definition.fetch(:why)}#{target_label}"
    end

    def fetch_city_forecast(definition, target_date: nil)
      weighting_cache_key = source_accuracy_cache_key
      Rails.cache.fetch(["weather_city_forecast_consensus_weighted_v6", organization.id, definition.fetch(:ticker), FORECAST_COORDINATE_VERSION, target_date&.iso8601, weighting_cache_key], expires_in: FORECAST_CACHE_TTL) do
        source_weighted_forecast(Weather::ForecastSources.call(definition, target_date: target_date))
      end
    rescue StandardError => error
      @errors << "Forecast consensus unavailable for #{definition.fetch(:city)}: #{error.class}: #{error.message}"
      {}
    end

    def source_weighted_forecast(raw_forecast)
      forecast = raw_forecast.to_h.deep_symbolize_keys
      sources = Array(forecast[:sources]).filter_map do |source|
        row = source.to_h.deep_symbolize_keys
        row if row[:high_f].present?
      end
      raw_high = forecast[:high_f]
      weighting = source_weighting_for(sources)
      return forecast.merge(source_weighting: weighting, raw_consensus_high_f: raw_high) unless weighting[:active]

      weighted_high = weighting.fetch(:weighted_high_f).to_f
      rounded_high = weighted_high.round
      forecast.merge(
        high_f: rounded_high,
        raw_consensus_high_f: raw_high,
        source_weighted_high_f: weighted_high.round(2),
        source_weighted_adjustment_f: raw_high.present? ? (rounded_high - raw_high.to_f).round(2) : nil,
        source_weights: weighting.fetch(:sources),
        source_weighting: weighting.except(:sources)
      )
    end

    def source_weighting_for(sources)
      sources = Array(sources)
      return inactive_source_weighting("fewer than 2 live forecast sources", sources) if sources.length < 2

      stats_by_key = source_accuracy_stats
      rows = sources.map do |source|
        stats = stats_by_key[source_key(source)].to_h
        source_weight_row(source, stats)
      end
      trained_rows = rows.select { |row| row[:sample_size].to_i >= SOURCE_WEIGHT_MIN_SAMPLE }
      return inactive_source_weighting("fewer than 2 trained source histories", sources, rows: rows) if trained_rows.length < 2

      normalized = normalize_source_weights(rows)
      weighted_high = normalized.sum { |row| row.fetch(:high_f).to_f * row.fetch(:normalized_weight).to_f }
      {
        active: true,
        model: "provider_abs_error_v1",
        weighted_high_f: weighted_high.round(2),
        trained_sources: trained_rows.length,
        source_count: sources.length,
        min_sample: SOURCE_WEIGHT_MIN_SAMPLE,
        equal_blend: SOURCE_WEIGHT_EQUAL_BLEND,
        sources: normalized
      }
    end

    def inactive_source_weighting(reason, sources, rows: nil)
      {
        active: false,
        model: "provider_abs_error_v1",
        reason: reason,
        source_count: Array(sources).length,
        min_sample: SOURCE_WEIGHT_MIN_SAMPLE,
        sources: rows || Array(sources).map { |source| source_weight_row(source, {}) }
      }
    end

    def source_weight_row(source, stats)
      high = source[:high_f].to_f
      sample_size = stats[:sample_size].to_i
      avg_error = stats[:avg_abs_error_f]
      trained = sample_size >= SOURCE_WEIGHT_MIN_SAMPLE && avg_error.present?
      learned_weight = if trained
        reliability = sample_size.to_f / (sample_size + SOURCE_WEIGHT_MIN_SAMPLE)
        reliability / [avg_error.to_f, SOURCE_WEIGHT_ERROR_FLOOR].max
      else
        0.0
      end

      {
        key: source_key(source),
        label: source[:label].presence || source[:key].presence || "Unknown source",
        high_f: high,
        sample_size: sample_size,
        avg_abs_error_f: avg_error&.round(2),
        trained: trained,
        learned_weight: learned_weight.round(4)
      }
    end

    def normalize_source_weights(rows)
      rows = Array(rows)
      trained_total = rows.sum { |row| row[:learned_weight].to_f }
      equal = rows.length.positive? ? (1.0 / rows.length) : 0.0
      rows.map do |row|
        learned_share = trained_total.positive? ? (row[:learned_weight].to_f / trained_total) : equal
        normalized = ((1.0 - SOURCE_WEIGHT_EQUAL_BLEND) * learned_share) + (SOURCE_WEIGHT_EQUAL_BLEND * equal)
        row.merge(normalized_weight: normalized.round(4))
      end
    end

    def build_paper_pick(definition, markets, forecast)
      high = forecast.to_h[:high_f].presence
      return empty_paper_pick("waiting for multi-source high forecast") if high.blank?

      local_adjustment = local_signal_adjustment_payload(definition)
      adjusted_high = high.to_i + local_adjustment.fetch(:applied).to_i
      evaluations = market_probability_evaluations(definition, markets, forecast, adjusted_high)
      evaluation = evaluations.max_by { |row| [row.fetch(:conservative_edge), row.dig(:probability, :confidence).to_f] }
      return empty_paper_pick("no priced Kalshi contract is available for #{adjusted_high}F") if evaluation.blank?

      market = evaluation.fetch(:market)
      ask = evaluation.fetch(:ask)
      probability = evaluation.fetch(:probability)
      confidence = probability.fetch(:confidence)
      confidence_lower_bound = probability.fetch(:confidence_lower_bound)
      edge = ask ? (confidence - ask) : nil
      conservative_edge = ask ? (confidence_lower_bound - ask) : nil
      calibration = calibration_context(definition, forecast, ask, local_adjustment).merge(probability)
      gate_reasons = paper_pick_gate_reasons(
        definition,
        market,
        forecast,
        confidence_lower_bound,
        ask,
        conservative_edge,
        local_adjustment,
        calibration
      )
      action = "watch"
      size = "0 contracts"

      {
        model_version: WEATHER_DESK_MODEL_VERSION,
        action: action,
        size: size,
        side: "YES",
        market_ticker: market[:ticker],
        market_title: market[:title],
        event_ticker: market[:event_ticker],
        market_range: market[:subtitle].presence || midpoint_degrees_for(market),
        market_floor_strike: market[:floor_strike],
        market_cap_strike: market[:cap_strike],
        market_midpoint_f: numeric_midpoint_degrees_for(market),
        close_time: parse_time(market[:close_time]),
        forecast_high_f: high.to_i,
        adjusted_high_f: adjusted_high,
        base_confidence: confidence,
        confidence: confidence,
        confidence_lower_bound: confidence_lower_bound,
        ask: ask,
        edge: edge,
        conservative_edge: conservative_edge,
        candidate_evaluations: evaluations.map { |row| compact_probability_evaluation(row) },
        gate_reasons: gate_reasons,
        calibration: calibration.except(:confidence),
        local_adjustment: local_adjustment,
        rationale: paper_pick_rationale(definition, market, forecast, adjusted_high, confidence, ask, edge, local_adjustment, calibration, gate_reasons),
        training_note: "Raw scout ranking is research-only. The versioned calibration harness independently decides every fee-correct paper ticket."
      }
    end

    def best_market_probability_evaluation(definition, markets, forecast, adjusted_high)
      market_probability_evaluations(definition, markets, forecast, adjusted_high)
        .max_by { |row| [row.fetch(:conservative_edge), row.dig(:probability, :confidence).to_f] }
    end

    def market_probability_evaluations(definition, markets, forecast, adjusted_high)
      Array(markets).filter_map do |market|
        ask = decimal_value(market[:yes_ask]) || decimal_value(market[:last_price])
        next if ask.blank?

        probability = Kalshi::WeatherBucketProbability.call(
          organization: organization,
          series_ticker: definition.fetch(:ticker),
          target_date: weather_event_date_for(market[:event_ticker]),
          forecast_high_f: adjusted_high,
          market_floor_strike: market[:floor_strike],
          market_cap_strike: market[:cap_strike],
          source_spread_f: forecast.to_h[:source_spread_f],
          use_history: !blind_edge_mode?
        )
        {
          market: market,
          ask: ask,
          probability: probability,
          conservative_edge: probability.fetch(:confidence_lower_bound).to_f - ask
        }
      end
    end

    def compact_probability_evaluation(row)
      market = row.fetch(:market)
      probability = row.fetch(:probability)
      {
        market_ticker: market[:ticker],
        event_ticker: market[:event_ticker],
        title: market[:title],
        range: market[:subtitle],
        floor_strike: market[:floor_strike],
        cap_strike: market[:cap_strike],
        ask: row[:ask],
        confidence: probability[:confidence],
        confidence_lower_bound: probability[:confidence_lower_bound],
        edge: probability[:confidence].to_f - row[:ask].to_f,
        conservative_edge: row[:conservative_edge],
        probability_model_version: probability[:model_version],
        probability_training_sample_size: probability[:training_sample_size],
        probability_min_live_sample: probability[:min_live_sample],
        probability_model_ready: probability[:model_ready],
        probability_history_enabled: probability[:history_enabled],
        probability_residual_bias_f: probability[:residual_bias_f],
        probability_residual_sigma_f: probability[:residual_sigma_f],
        probability_coordinate_version: probability[:coordinate_version],
        close_time: market[:close_time]
      }.compact
    end

    def empty_paper_pick(reason)
      {
        action: "watch",
        size: "0 contracts",
        side: "YES",
        gate_reasons: [reason],
        rationale: reason,
        training_note: "No paper wager until AUTOS has a date-aligned forecast, a matching contract, and a fee-adjusted edge."
      }
    end

    def matching_market_for_temperature(markets, temperature)
      Array(markets).find { |market| market_contains_temperature?(market, temperature) } ||
        Array(markets).min_by { |market| temperature_distance(market, temperature) }
    end

    def market_contains_temperature?(market, temperature)
      floor = market[:floor_strike]
      cap = market[:cap_strike]
      return temperature >= floor.to_f && temperature <= cap.to_f if floor.present? && cap.present?
      return temperature > floor.to_f if floor.present?
      return temperature < cap.to_f if cap.present?

      false
    end

    def temperature_distance(market, temperature)
      floor = market[:floor_strike]
      cap = market[:cap_strike]
      return (temperature - midpoint_degrees_for(market).to_f).abs if floor.present? && cap.present?
      return [(floor.to_f + 1) - temperature, 0].max if floor.present?
      return [temperature - (cap.to_f - 1), 0].max if cap.present?

      99
    end

    def rule_paper_confidence_for(market, temperature, _definition, forecast, local_adjustment)
      base = market_contains_temperature?(market, temperature) ? 0.62 : 0.46
      range_bonus = market[:floor_strike].present? && market[:cap_strike].present? ? 0.04 : 0.02
      signal_bonus = local_adjustment.fetch(:applied).to_i.abs.positive? ? 0.02 : 0.0
      source_bonus = source_confidence_adjustment(forecast)
      cap = forecast.to_h[:source_spread_f].to_f >= 5.0 ? 0.68 : 0.78
      [[base + range_bonus + signal_bonus + source_bonus, cap].min, 0.30].max.round(2)
    end

    def paper_pick_rationale(definition, market, forecast, adjusted_high, confidence, ask, edge, local_adjustment, calibration, gate_reasons)
      price = ask ? "#{(ask * 100).round}c ask" : "no ask"
      edge_text = edge ? "#{(edge * 100).round} pts model edge" : "edge unavailable"
      lower_bound = calibration.to_h[:confidence_lower_bound]
      lower_text = lower_bound ? "Conservative confidence #{(lower_bound.to_f * 100).round}%." : nil
      forecast_text = [forecast[:period], forecast[:short_forecast]].compact_blank.join(" // ")
      source_count = forecast.to_h[:source_count].to_i
      weighting_text = forecast.to_h[:source_weighting].to_h[:active] ? ", weighted from raw #{forecast[:raw_consensus_high_f]}F" : ""
      source_text = "Sources #{source_count.positive? ? source_count : 'pending'}, #{forecast[:agreement_label].presence || 'pending'}, spread #{format_temperature(forecast[:source_spread_f])}#{weighting_text}."
      local_text = if local_adjustment.fetch(:raw).to_i.zero?
        "No local adjustment applied."
      elsif local_adjustment.fetch(:applied).to_i.zero?
        "Local #{local_adjustment.fetch(:raw).positive? ? 'up' : 'down'} signal ignored until it proves out."
      else
        "Local signal moved the forecast #{local_adjustment.fetch(:applied).positive? ? 'up' : 'down'} #{local_adjustment.fetch(:applied).abs}F."
      end
      calibration_text = calibration_summary_sentence(calibration)
      gate_text = gate_reasons.present? ? "Watch gates: #{gate_reasons.join(' ')}" : "Paper gates clear."
      "#{definition.fetch(:city)} settlement-station consensus high is #{forecast[:high_f]}F; AUTOS targets #{adjusted_high}F. #{local_text} #{source_text} Best conservative-edge contract is #{market[:subtitle].presence || market[:ticker]} at #{price}. Confidence #{(confidence * 100).round}%, #{edge_text}. #{lower_text} #{calibration_text} #{gate_text} #{forecast_text}".squish
    end

    def source_confidence_adjustment(forecast)
      count = forecast.to_h[:source_count].to_i
      spread = forecast.to_h[:source_spread_f]
      return -0.04 if count.zero?
      return -0.03 if count == 1
      return 0.03 if count >= 3 && spread.to_f <= 2.0
      return 0.01 if count >= 2 && spread.to_f <= 3.0
      return -0.05 if spread.to_f >= 5.0

      0.0
    end

    def local_signal_adjustment_payload(definition)
      raw = raw_local_signal_adjustment(definition)
      stats = weather_calibration.dig(:local_adjustments, local_adjustment_direction(raw))
      applied = if raw.zero?
        0
      elsif trained_bucket_good_enough?(stats, minimum_hit_rate: 0.45)
        raw
      else
        0
      end

      {
        raw: raw,
        applied: applied,
        direction: local_adjustment_direction(raw),
        status: applied == raw ? "applied" : "ignored",
        reason: local_adjustment_reason(raw, applied, stats),
        stats: compact_stats(stats)
      }
    end

    def raw_local_signal_adjustment(definition)
      relevant = signals.select do |signal|
        Array(signal.affected_states).map(&:to_s).include?(definition.fetch(:state)) ||
          signal_text(signal).match?(/#{Regexp.escape(definition.fetch(:city))}|#{Regexp.escape(definition.fetch(:state))}/i)
      end
      text = relevant.map { |signal| signal_text(signal) }.join(" ")
      return 1 if text.match?(/excessive heat|heat advisory|heat warning|record heat/i)
      return -1 if text.match?(/thunderstorm|rain|flood|cold|freeze|frost|wind chill/i)

      0
    end

    def local_adjustment_reason(raw, applied, stats)
      return "no relevant local heat/cold/storm signal" if raw.to_i.zero?
      return "historical local signal bucket cleared the hit-rate gate" if applied.to_i == raw.to_i

      if stats.to_h[:sample_size].to_i >= CALIBRATION_MIN_SAMPLE
        "historical local signal bucket is not strong enough yet"
      else
        "not enough settled local signal samples yet"
      end
    end

    def local_adjustment_direction(value)
      value = value.to_i
      return "up" if value.positive?
      return "down" if value.negative?

      "none"
    end

    def calibrated_confidence_for(market, temperature, definition, forecast, ask, rule_confidence:, local_adjustment:)
      context = calibration_context(definition, forecast, ask, local_adjustment)
      components = [{ name: "live_rule", value: rule_confidence.to_f, weight: trained_rows.present? ? 3.0 : 10.0 }]
      components << calibration_component("global", context[:global], max_weight: 18.0)
      components << calibration_component("city", context[:city], max_weight: 18.0)
      components << calibration_component("ask_bucket", context[:ask_bucket], max_weight: 18.0)
      components << calibration_component("source_spread", context[:source_spread], max_weight: 12.0)
      components << calibration_component("local_adjustment", context[:local_adjustment], max_weight: 10.0) if local_adjustment.fetch(:applied).to_i.nonzero?
      components = components.compact

      confidence = if components.sum { |component| component[:weight].to_f }.positive?
        weighted_average(components)
      else
        rule_confidence.to_f
      end

      confidence -= 0.04 if city_on_probation?(context[:city])
      confidence -= 0.03 if weak_source_spread_bucket?(context[:source_spread])
      confidence = [confidence, cheap_longshot_confidence_ceiling(context, ask)].min if ask.present? && ask.to_f < CHEAP_LONGSHOT_ASK_CEILING
      confidence = [[confidence, 0.05].max, 0.85].min

      context.merge(
        confidence: confidence.round(2),
        rule_confidence: rule_confidence,
        components: components.map { |component| component.except(:weight).merge(weight: component[:weight].round(2), value: component[:value].round(3)) },
        selected_market_contains_forecast: market_contains_temperature?(market, temperature)
      )
    end

    def calibration_context(definition, forecast, ask, local_adjustment)
      calibration = weather_calibration
      city = city_key_for(definition)
      ask_bucket = ask_bucket_for_value(ask)
      source_spread_bucket = source_spread_bucket_for(forecast)
      local_direction = local_adjustment_direction(local_adjustment.fetch(:applied).to_i)

      {
        model_version: WEATHER_DESK_MODEL_VERSION,
        trained_sample_size: calibration.dig(:global, :sample_size).to_i,
        city_key: city,
        ask_bucket_key: ask_bucket,
        source_spread_bucket_key: source_spread_bucket,
        local_adjustment_key: local_direction,
        global: calibration[:global],
        city: calibration.dig(:cities, city),
        ask_bucket: calibration.dig(:ask_buckets, ask_bucket),
        source_spread: calibration.dig(:source_spread_buckets, source_spread_bucket),
        local_adjustment: calibration.dig(:local_adjustments, local_direction),
        city_miss_causes: calibration.dig(:city_miss_causes, city) || {}
      }
    end

    def blind_calibration_context(definition, forecast, ask, local_adjustment)
      {
        model_version: Kalshi::WeatherBucketProbability::BLIND_MODEL_VERSION,
        trained_sample_size: 0,
        city_key: city_key_for(definition),
        ask_bucket_key: ask_bucket_for_value(ask),
        source_spread_bucket_key: source_spread_bucket_for(forecast),
        local_adjustment_key: local_adjustment_direction(local_adjustment.fetch(:applied).to_i),
        global: {},
        city: {},
        ask_bucket: {},
        source_spread: {},
        local_adjustment: {},
        city_miss_causes: {},
        history_enabled: false,
        blind_edge_mode: true
      }
    end

    def calibration_component(name, stats, max_weight:)
      stats = stats.to_h
      return nil if stats[:sample_size].to_i < CALIBRATION_MIN_SAMPLE

      {
        name: name,
        value: stats.fetch(:smoothed_hit_rate).to_f,
        weight: [[stats.fetch(:sample_size).to_f / 2.0, max_weight].min, 2.0].max,
        sample_size: stats.fetch(:sample_size),
        hit_rate: stats[:hit_rate]
      }
    end

    def weighted_average(components)
      total_weight = components.sum { |component| component[:weight].to_f }
      return 0.0 unless total_weight.positive?

      components.sum { |component| component[:value].to_f * component[:weight].to_f } / total_weight
    end

    def weather_calibration
      @weather_calibration ||= begin
        rows = trained_rows
        {
          global: bucket_stats(rows),
          cities: rows.group_by { |row| city_key_for(row) }.transform_values { |bucket| bucket_stats(bucket) },
          ask_buckets: rows.group_by { |row| ask_bucket_for_value(row.ask) }.transform_values { |bucket| bucket_stats(bucket) },
          source_spread_buckets: rows.group_by { |row| source_spread_bucket_for(row) }.transform_values { |bucket| bucket_stats(bucket) },
          local_adjustments: rows.group_by { |row| local_adjustment_direction(local_adjustment_for_row(row)) }.transform_values { |bucket| bucket_stats(bucket) },
          source_accuracy: source_accuracy_stats,
          city_miss_causes: city_miss_cause_stats(rows)
        }
      end
    end

    def source_accuracy_stats
      @source_accuracy_stats ||= begin
        return {} unless prediction_storage_ready?

        stats = Hash.new { |hash, key| hash[key] = { errors: [], label: key } }
        source_accuracy_rows.each do |row|
          observed = row.observed_high_f
          next if observed.blank?

          Array(row.metadata.to_h["forecast_sources"]).each do |source|
            source = source.to_h
            high = source["high_f"].presence || source[:high_f].presence
            key = source["key"].presence || source[:key].presence || source["label"].presence || source[:label].presence
            next if high.blank? || key.blank?

            bucket = stats[key.to_s]
            bucket[:label] = source["label"].presence || source[:label].presence || key.to_s
            bucket[:errors] << (high.to_f - observed.to_f).abs
          end
        end
        stats.transform_values do |row|
          errors = row[:errors]
          {
            label: row[:label],
            sample_size: errors.length,
            avg_abs_error_f: errors.present? ? (errors.sum / errors.length).round(3) : nil
          }
        end
      rescue StandardError => error
        @errors << "Weather source accuracy unavailable: #{error.class}: #{error.message}"
        {}
      end
    end

    def source_accuracy_rows
      organization.kalshi_weather_predictions
        .where.not(observed_high_f: nil)
        .where("metadata ? 'forecast_sources'")
        .where("metadata ? 'official_market_reconciled_at'")
        .where("metadata ->> 'forecast_coordinate_version' = ?", FORECAST_COORDINATE_VERSION)
        .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
        .limit(SOURCE_WEIGHT_LOOKBACK)
        .to_a
        .group_by { |row| row.event_ticker.presence || row.market_ticker }
        .values
        .map { |rows| rows.max_by(&:updated_at) }
    end

    def source_accuracy_cache_key
      return "source-accuracy-unavailable" unless prediction_storage_ready?

      latest = organization.kalshi_weather_predictions
        .where.not(observed_high_f: nil)
        .where("metadata ? 'forecast_sources'")
        .where("metadata ? 'official_market_reconciled_at'")
        .where("metadata ->> 'forecast_coordinate_version' = ?", FORECAST_COORDINATE_VERSION)
        .maximum(:updated_at)
      "source-accuracy-#{latest&.to_i || 0}"
    rescue StandardError
      "source-accuracy-error"
    end

    def source_key(source)
      source.to_h[:key].presence || source.to_h["key"].presence || source.to_h[:label].presence || source.to_h["label"].presence || "unknown"
    end

    def blind_edge_mode?
      false
    end

    def trained_rows
      @trained_rows ||= begin
        return [] unless prediction_storage_ready?

        organization.kalshi_weather_predictions
          .where(action: "paper_yes", result_status: %w[won lost])
          .where("metadata ? 'official_market_reconciled_at'")
          .where("metadata ->> 'forecast_coordinate_version' = ?", FORECAST_COORDINATE_VERSION)
          .recent_first
          .limit(CALIBRATION_LOOKBACK)
          .to_a
          .group_by { |row| row.event_ticker.presence || row.market_ticker }
          .values
          .map { |rows| rows.max_by(&:updated_at) }
      rescue StandardError => error
        @errors << "Weather calibration unavailable: #{error.class}: #{error.message}"
        []
      end
    end

    def bucket_stats(rows)
      rows = Array(rows)
      wins = rows.count { |row| row.result_status.to_s == "won" }
      losses = rows.count { |row| row.result_status.to_s == "lost" }
      total = wins + losses
      {
        sample_size: total,
        wins: wins,
        losses: losses,
        hit_rate: total.positive? ? (wins.to_f / total).round(3) : nil,
        smoothed_hit_rate: total.positive? ? ((wins + 2.0) / (total + 4.0)).round(3) : nil
      }
    end

    def compact_stats(stats)
      stats.to_h.slice(:sample_size, :wins, :losses, :hit_rate, :smoothed_hit_rate).compact
    end

    def city_miss_cause_stats(rows)
      Array(rows).group_by { |row| city_key_for(row) }.transform_values do |city_rows|
        losses = city_rows.select { |row| row.result_status.to_s == "lost" }
        total = city_rows.length
        losses
          .map { |row| row.metadata.to_h["miss_cause"].presence || "unclassified" }
          .tally
          .transform_values { |count| { count: count, rate: total.positive? ? (count.to_f / total).round(3) : nil } }
      end
    end

    def paper_pick_gate_reasons(definition, market, forecast, confidence, ask, edge, local_adjustment, calibration)
      reasons = []
      event_date = weather_event_date_for(market[:event_ticker])
      forecast_target_date = normalize_date(forecast.to_h[:target_date])
      unless forecast.to_h[:event_date_aligned] == true && event_date.present? && forecast_target_date == event_date
        reasons << "forecast source dates do not align to the market event"
      end
      unless blind_edge_mode?
        city_stats = calibration[:city].to_h
        city_reason = city_bench_reason(definition, city_stats)
        reasons << city_reason if city_reason.present?
      end
      stale_reason = stale_forecast_gate_reason(definition, market, forecast, calibration)
      reasons << stale_reason if stale_reason.present?
      unless blind_edge_mode?
        longshot_reason = cheap_longshot_gate_reason(definition, forecast, ask, confidence, local_adjustment, calibration)
        reasons << longshot_reason if longshot_reason.present?
      end
      reasons << "price unavailable" if ask.blank?
      reasons << "ask above #{(MAX_ACTION_ASK * 100).round}c paper limit" if ask.present? && ask.to_f > MAX_ACTION_ASK
      reasons << "edge unavailable" if edge.blank?
      reasons << "edge below #{(ACTION_EDGE_THRESHOLD * 100).round} pt paper threshold" if edge.present? && edge < ACTION_EDGE_THRESHOLD
      reasons.compact_blank.uniq
    end

    def city_bench_reason(definition, city_stats)
      return nil if city_stats.blank? || city_stats[:sample_size].to_i < 10

      hit_rate = city_stats[:hit_rate].to_f
      city = definition.fetch(:city)
      if hit_rate <= CITY_HARD_BENCH_HIT_RATE
        "#{city} benched: #{percent(hit_rate)} hit rate over #{city_stats[:sample_size]} paper picks"
      elsif hit_rate < CITY_PROBATION_HIT_RATE
        "#{city} on probation: #{percent(hit_rate)} hit rate needs a stronger proof stack"
      end
    end

    def stale_forecast_gate_reason(definition, market, forecast, calibration)
      source_count = forecast.to_h[:source_count].to_i
      return "stale forecast protection: fewer than 2 live forecast sources" if source_count < 2

      spread = forecast.to_h[:source_spread_f]
      return "live source spread unavailable" if spread.blank?
      if spread.to_f > MAX_SOURCE_SPREAD_F
        return "live source disagreement: #{spread.to_f.round(1)}F spread exceeds #{MAX_SOURCE_SPREAD_F.round(1)}F"
      end

      fetched_at = forecast_fetched_at(forecast)
      close_time = parse_time(market[:close_time])
      if fetched_at.present? && close_time.present?
        age_minutes = ((Time.current - fetched_at) / 60.0).round
        hours_to_close = ((close_time - Time.current) / 1.hour).round(1)
        if age_minutes > STALE_FORECAST_MAX_AGE_MINUTES && hours_to_close <= STALE_FORECAST_CLOSE_WINDOW_HOURS
          return "stale forecast protection: newest source is #{age_minutes} minutes old with close in #{hours_to_close}h"
        end
      end

      stale_stats = calibration.to_h.dig(:city_miss_causes, "stale_forecast").to_h
      if stale_stats[:rate].to_f >= 0.35 && (source_count < 3 || spread.blank? || spread.to_f > 3.0)
        "#{definition.fetch(:city)} stale-forecast losses are elevated; require a fresher/tighter source stack"
      end
    end

    def cheap_longshot_gate_reason(_definition, forecast, ask, confidence, local_adjustment, calibration)
      return nil if ask.blank? || ask.to_f >= CHEAP_LONGSHOT_ASK_CEILING
      return nil if cheap_longshot_exception?(forecast, ask, confidence, local_adjustment, calibration)

      "cheap long-shot blocked: <#{(CHEAP_LONGSHOT_ASK_CEILING * 100).round}c asks have underperformed the paper book"
    end

    def cheap_longshot_exception?(forecast, _ask, confidence, local_adjustment, calibration)
      city_stats = calibration[:city].to_h
      spread = forecast.to_h[:source_spread_f]
      source_count = forecast.to_h[:source_count].to_i

      confidence.to_f >= CHEAP_LONGSHOT_MIN_CONFIDENCE &&
        source_count >= 3 &&
        spread.present? &&
        spread.to_f <= CHEAP_LONGSHOT_MAX_SPREAD_F &&
        local_adjustment.fetch(:applied).to_i.zero? &&
        city_stats[:sample_size].to_i >= 10 &&
        city_stats[:hit_rate].to_f >= 0.45
    end

    def cheap_longshot_confidence_ceiling(calibration, _ask)
      stats = calibration[:ask_bucket].to_h
      return 0.30 if stats[:sample_size].to_i < CALIBRATION_MIN_SAMPLE

      [[stats[:smoothed_hit_rate].to_f + 0.06, CHEAP_LONGSHOT_MIN_CONFIDENCE].min, 0.18].max
    end

    def city_on_probation?(city_stats)
      stats = city_stats.to_h
      stats[:sample_size].to_i >= 10 && stats[:hit_rate].to_f < CITY_PROBATION_HIT_RATE
    end

    def weak_source_spread_bucket?(stats)
      stats = stats.to_h
      stats[:sample_size].to_i >= CALIBRATION_MIN_SAMPLE && stats[:hit_rate].to_f < 0.25
    end

    def trained_bucket_good_enough?(stats, minimum_hit_rate:)
      stats = stats.to_h
      stats[:sample_size].to_i >= CALIBRATION_MIN_SAMPLE && stats[:hit_rate].to_f >= minimum_hit_rate
    end

    def calibration_summary_sentence(calibration)
      city_stats = compact_stats(calibration[:city])
      ask_stats = compact_stats(calibration[:ask_bucket])
      global_stats = compact_stats(calibration[:global])
      parts = []
      parts << "global #{percent(global_stats[:hit_rate])}/#{global_stats[:sample_size]}" if global_stats[:sample_size].to_i.positive?
      parts << "city #{percent(city_stats[:hit_rate])}/#{city_stats[:sample_size]}" if city_stats[:sample_size].to_i.positive?
      parts << "price bucket #{percent(ask_stats[:hit_rate])}/#{ask_stats[:sample_size]}" if ask_stats[:sample_size].to_i.positive?
      return "Calibration sample still building." if parts.blank?

      "Calibration: #{parts.join(', ')}."
    end

    def percent(value)
      return "n/a" if value.blank?

      "#{(value.to_f * 100).round}%"
    end

    def forecast_fetched_at(forecast)
      timestamps = [forecast.to_h[:fetched_at]] +
        Array(forecast.to_h[:sources]).map { |source| source.to_h[:fetched_at] || source.to_h["fetched_at"] }
      timestamps.filter_map { |value| parse_time(value) }.max
    end

    def ask_bucket_for_value(value)
      return "unknown" if value.blank?

      ask = value.to_f
      return "<20c" if ask < 0.20
      return "20-39c" if ask < 0.40
      return "40-59c" if ask < 0.60
      return "60-79c" if ask < 0.80

      "80c+"
    end

    def source_spread_bucket_for(source)
      spread = if source.respond_to?(:metadata)
        source.metadata.to_h["forecast_source_spread_f"]
      elsif source.respond_to?(:to_h)
        source.to_h[:source_spread_f] || source.to_h["source_spread_f"]
      end
      return "unknown" if spread.blank?

      spread = spread.to_f
      return "<2F" if spread < 2.0
      return "2-4F" if spread < 4.0
      return "4-6F" if spread < 6.0

      "6F+"
    end

    def city_key_for(source)
      city = source.respond_to?(:city) ? source.city : source.fetch(:city)
      state = source.respond_to?(:state) ? source.state : source.fetch(:state)
      [city.to_s.squish, state.to_s.squish.presence].compact_blank.join(", ")
    end

    def local_adjustment_for_row(row)
      if row.adjusted_high_f.present? && row.forecast_high_f.present?
        (row.adjusted_high_f.to_f - row.forecast_high_f.to_f).round
      else
        row.metadata.to_h["local_signal_adjustment_applied"].to_i
      end
    end

    def persist_weather_study_predictions(study_series)
      return unless prediction_storage_ready?

      active_contexts = []
      Array(study_series).each do |row|
        representative = row[:paper_pick].to_h
        prediction_picks_for(row, representative).each do |pick|
          record = persist_weather_prediction(row, pick)
          next if record.blank?

          if pick[:market_ticker].to_s == representative[:market_ticker].to_s
            representative[:persisted_id] = record.id
            representative[:persisted_at] = record.updated_at&.iso8601
          end
          active_contexts << {
            series_ticker: row[:ticker],
            event_ticker: pick[:event_ticker],
            market_ticker: pick[:market_ticker]
          }
        rescue StandardError => error
          @errors << "Kalshi prediction persistence failed for #{pick[:market_ticker] || row[:ticker]}: #{error.class}: #{error.message}"
        end
      end
      retire_stale_weather_study_predictions(active_contexts)
    end

    def prediction_picks_for(row, representative)
      evaluations = Array(representative[:candidate_evaluations]).map { |item| item.to_h.symbolize_keys }
      return [representative] if evaluations.blank?

      markets = Array(row[:markets]).index_by { |market| market[:ticker].to_s }
      evaluations.map do |evaluation|
        market = markets[evaluation[:market_ticker].to_s].to_h
        calibration = representative[:calibration].to_h.merge(
          model_version: evaluation[:probability_model_version],
          training_sample_size: evaluation[:probability_training_sample_size],
          min_live_sample: evaluation[:probability_min_live_sample],
          model_ready: evaluation[:probability_model_ready],
          history_enabled: evaluation[:probability_history_enabled],
          residual_bias_f: evaluation[:probability_residual_bias_f],
          residual_sigma_f: evaluation[:probability_residual_sigma_f],
          blind_edge_mode: false
        )
        gate_reasons = paper_pick_gate_reasons(
          row,
          market.presence || evaluation,
          row[:forecast].to_h,
          evaluation[:confidence_lower_bound],
          evaluation[:ask],
          evaluation[:conservative_edge],
          representative[:local_adjustment].to_h,
          calibration
        )
        representative.merge(
          action: "watch",
          size: "0 contracts",
          market_ticker: evaluation[:market_ticker],
          market_title: evaluation[:title].presence || market[:title],
          event_ticker: evaluation[:event_ticker].presence || market[:event_ticker],
          market_range: evaluation[:range].presence || market[:subtitle].presence || midpoint_degrees_for(market),
          market_floor_strike: evaluation[:floor_strike],
          market_cap_strike: evaluation[:cap_strike],
          market_midpoint_f: numeric_midpoint_degrees_for(market.presence || evaluation),
          close_time: parse_time(evaluation[:close_time].presence || market[:close_time]),
          base_confidence: evaluation[:confidence],
          confidence: evaluation[:confidence],
          confidence_lower_bound: evaluation[:confidence_lower_bound],
          ask: evaluation[:ask],
          edge: evaluation[:edge],
          conservative_edge: evaluation[:conservative_edge],
          gate_reasons: gate_reasons,
          calibration: calibration,
          rationale: candidate_research_rationale(row, evaluation),
          training_note: "Research snapshot only. A versioned calibration policy must select this contract before any paper or live ticket exists."
        )
      end
    end

    def candidate_research_rationale(row, evaluation)
      range = evaluation[:range].presence || evaluation[:market_ticker]
      price = evaluation[:ask].present? ? "#{(evaluation[:ask].to_f * 100).round}c" : "price unavailable"
      raw = evaluation[:confidence].present? ? "#{(evaluation[:confidence].to_f * 100).round}%" : "unavailable"
      "#{row[:city]} candidate #{range} at #{price}; raw station-model probability #{raw}. Stored independently for chronological calibration; raw ranking never authorizes a wager."
    end

    def persist_weather_prediction(row, pick)
      market_ticker = pick[:market_ticker].to_s.presence
      return if market_ticker.blank?

      record = organization.kalshi_weather_predictions.find_or_initialize_by(market_ticker: market_ticker)
      return record if record.persisted? && record.result_status != "pending"

      close_time = pick[:close_time]
      prediction_date = weather_event_date_for(market_ticker) || weather_event_date_for(pick[:event_ticker]) || close_time&.in_time_zone&.to_date || Date.current
      record.assign_attributes(
        series_ticker: row[:ticker],
        event_ticker: pick[:event_ticker],
        city: row[:city],
        state: row[:state],
        market_title: pick[:market_title],
        market_range: pick[:market_range],
        action: "watch",
        side: pick[:side],
        size_label: "0 contracts",
        forecast_high_f: pick[:forecast_high_f],
        adjusted_high_f: pick[:adjusted_high_f],
        market_floor_strike: pick[:market_floor_strike],
        market_cap_strike: pick[:market_cap_strike],
        market_midpoint_f: pick[:market_midpoint_f],
        confidence: pick[:confidence],
        ask: pick[:ask],
        edge: pick[:edge],
        close_time: close_time,
        prediction_date: prediction_date,
        rationale: pick[:rationale],
        training_note: pick[:training_note],
        status: "open",
        result_status: "pending",
        raw_payload: {
          study_row: row.except(:markets, :best_market, :paper_pick),
          research_candidate: pick.except(:candidate_evaluations),
          candidate_evaluations: Array(pick[:candidate_evaluations]),
          markets: Array(row[:markets]).first(20)
        },
        metadata: weather_prediction_metadata(row, pick, prediction_date)
      )
      record.save! if record.new_record? || record.changed?
      persist_prediction_snapshot(record, pick, row)
      record
    end

    def weather_prediction_metadata(row, pick, prediction_date)
      {
        source: "probability_lab",
        research_only: true,
        weather_desk_model_version: pick[:model_version],
        forecast_coordinate_version: FORECAST_COORDINATE_VERSION,
        forecast_station_id: row[:station_id],
        forecast_station_latitude: row[:latitude],
        forecast_station_longitude: row[:longitude],
        forecast_station_time_zone: row[:time_zone],
        forecast_target_date: normalize_date(row.dig(:forecast, :target_date))&.iso8601,
        forecast_event_date_aligned: row.dig(:forecast, :event_date_aligned) == true && normalize_date(row.dig(:forecast, :target_date)) == prediction_date,
        scout_generated_at: Time.current.iso8601,
        forecast_source: row.dig(:forecast, :source),
        forecast_period: row.dig(:forecast, :period),
        forecast_short: row.dig(:forecast, :short_forecast),
        forecast_source_count: row.dig(:forecast, :source_count),
        forecast_source_spread_f: row.dig(:forecast, :source_spread_f),
        forecast_raw_source_count: row.dig(:forecast, :raw_source_count),
        forecast_raw_source_spread_f: row.dig(:forecast, :raw_source_spread_f),
        forecast_agreement_label: row.dig(:forecast, :agreement_label),
        forecast_raw_consensus_high_f: row.dig(:forecast, :raw_consensus_high_f),
        forecast_source_weighted_high_f: row.dig(:forecast, :source_weighted_high_f),
        forecast_source_weighted_adjustment_f: row.dig(:forecast, :source_weighted_adjustment_f),
        forecast_source_weighting: row.dig(:forecast, :source_weighting),
        forecast_source_weights: Array(row.dig(:forecast, :source_weights)),
        forecast_sources: Array(row.dig(:forecast, :sources)).map { |source| source.to_h.slice(:key, :label, :high_f, :period, :forecast_date, :summary, :fetched_at, :consensus_included) },
        forecast_excluded_consensus_sources: Array(row.dig(:forecast, :excluded_consensus_sources)).map { |source| source.to_h.slice(:key, :label, :high_f, :consensus_included) },
        forecast_unavailable_sources: Array(row.dig(:forecast, :unavailable_sources)).map { |source| source.to_h.slice(:key, :label, :reason, :fetched_at) },
        polling_guidance: row.dig(:forecast, :polling_guidance),
        gate_reasons: Array(pick[:gate_reasons]),
        calibration_summary: pick[:calibration],
        base_confidence: pick[:base_confidence],
        confidence_lower_bound: pick[:confidence_lower_bound],
        conservative_edge: pick[:conservative_edge],
        probability_model_version: pick.dig(:calibration, :model_version),
        probability_training_sample_size: pick.dig(:calibration, :training_sample_size),
        probability_min_live_sample: pick.dig(:calibration, :min_live_sample),
        probability_model_ready: pick.dig(:calibration, :model_ready),
        probability_history_enabled: pick.dig(:calibration, :history_enabled),
        blind_edge_mode: false,
        probability_residual_bias_f: pick.dig(:calibration, :residual_bias_f),
        probability_residual_sigma_f: pick.dig(:calibration, :residual_sigma_f),
        local_signal_adjustment_raw: pick.dig(:local_adjustment, :raw),
        local_signal_adjustment_applied: pick.dig(:local_adjustment, :applied),
        local_signal_adjustment_status: pick.dig(:local_adjustment, :status),
        local_signal_summary: pick.dig(:local_adjustment, :reason)
      }.compact
    end

    def persist_prediction_snapshot(prediction, pick, row)
      return unless defined?(KalshiWeatherPredictionSnapshot) && KalshiWeatherPredictionSnapshot.storage_ready?

      payload = {
        "weather_desk_model_version" => pick[:model_version],
        "probability_model_version" => pick.dig(:calibration, :model_version),
        "probability_training_sample_size" => pick.dig(:calibration, :training_sample_size),
        "probability_model_ready" => pick.dig(:calibration, :model_ready) == true,
        "probability_history_enabled" => pick.dig(:calibration, :history_enabled),
        "blind_edge_mode" => pick.dig(:calibration, :blind_edge_mode) == true,
        "forecast_coordinate_version" => FORECAST_COORDINATE_VERSION,
        "forecast_station_id" => row[:station_id],
        "forecast_station_latitude" => row[:latitude],
        "forecast_station_longitude" => row[:longitude],
        "forecast_target_date" => normalize_date(row.dig(:forecast, :target_date))&.iso8601,
        "forecast_event_date_aligned" => row.dig(:forecast, :event_date_aligned) == true &&
          normalize_date(row.dig(:forecast, :target_date)) == prediction.prediction_date,
        "forecast_sources" => Array(row.dig(:forecast, :sources)).map { |source| source.to_h.slice(:key, :label, :high_f, :period, :forecast_date, :fetched_at) },
        "gate_reasons" => Array(pick[:gate_reasons]),
        "local_adjustment" => pick[:local_adjustment],
        "candidate_evaluations" => Array(pick[:candidate_evaluations])
      }
      digest = Digest::SHA256.hexdigest(JSON.generate(payload.merge(
        "action" => pick[:action],
        "forecast_high_f" => pick[:forecast_high_f],
        "adjusted_high_f" => pick[:adjusted_high_f],
        "confidence" => pick[:confidence],
        "confidence_lower_bound" => pick[:confidence_lower_bound],
        "ask" => pick[:ask],
        "edge" => pick[:edge],
        "conservative_edge" => pick[:conservative_edge]
      )))

      prediction.kalshi_weather_prediction_snapshots.find_or_create_by!(feature_digest: digest) do |snapshot|
        snapshot.organization = organization
        snapshot.series_ticker = prediction.series_ticker
        snapshot.event_ticker = prediction.event_ticker
        snapshot.market_ticker = prediction.market_ticker
        snapshot.prediction_date = prediction.prediction_date
        snapshot.captured_at = Time.current
        snapshot.action = prediction.action
        snapshot.forecast_high_f = prediction.forecast_high_f
        snapshot.adjusted_high_f = prediction.adjusted_high_f
        snapshot.market_floor_strike = prediction.market_floor_strike
        snapshot.market_cap_strike = prediction.market_cap_strike
        snapshot.confidence = prediction.confidence
        snapshot.confidence_lower_bound = pick[:confidence_lower_bound]
        snapshot.ask = prediction.ask
        snapshot.edge = prediction.edge
        snapshot.conservative_edge = pick[:conservative_edge]
        snapshot.forecast_source_count = row.dig(:forecast, :source_count)
        snapshot.forecast_source_spread_f = row.dig(:forecast, :source_spread_f)
        snapshot.payload = payload
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def weather_event_date_for(ticker)
      return nil unless defined?(KalshiWeatherPrediction)

      KalshiWeatherPrediction.event_date_from_ticker(ticker)
    end

    def retire_stale_weather_study_predictions(active_contexts)
      Array(active_contexts).group_by do |context|
        [context[:series_ticker].to_s.presence, context[:event_ticker].to_s.presence]
      end.each do |(series_ticker, event_ticker), contexts|
        market_tickers = contexts.filter_map { |context| context[:market_ticker].to_s.presence }.uniq
        next if series_ticker.blank? || event_ticker.blank? || market_tickers.blank?

        organization.kalshi_weather_predictions
          .open_predictions
          .where(series_ticker: series_ticker, event_ticker: event_ticker)
          .where.not(market_ticker: market_tickers)
          .find_each do |prediction|
            prediction.update_columns(
              status: "stale",
              metadata: prediction.metadata.to_h.merge(
                "staled_at" => Time.current.iso8601,
                "stale_reason" => "not_in_latest_weather_market_set",
                "active_market_tickers" => market_tickers
              ),
              updated_at: Time.current
            )
          end
      end
    end

    def prediction_storage_ready?
      defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready? && organization.respond_to?(:kalshi_weather_predictions)
    rescue StandardError
      false
    end

    def prediction_storage_status
      prediction_storage_ready? ? "persisting" : "not_ready"
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def normalize_date(value)
      return value if value.is_a?(Date)
      return value.to_date if value.respond_to?(:to_date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def format_temperature(value)
      return "n/a" if value.blank?

      number = value.to_f
      "#{number == number.round ? number.round : number.round(1)}F"
    end

    def category_key_for(text)
      CATEGORY_DEFINITIONS.find { |_key, definition| text.match?(definition.fetch(:regex)) }&.first
    end

    def priority_for(key, frequency)
      category_rank = {
        severe_storm: 0,
        hurricane: 1,
        precipitation: 2,
        temperature: 3,
        snow_winter: 4,
        climate_long: 8
      }.fetch(key, 9)
      frequency_rank = {
        "hourly" => 0,
        "daily" => 1,
        "weekly" => 2,
        "monthly" => 3,
        "custom" => 4,
        "annual" => 7,
        "one_off" => 8
      }.fetch(frequency.to_s, 5)
      category_rank * 10 + frequency_rank
    end

    def signal_count_for(regex)
      signals.count { |signal| signal_text(signal).match?(regex) }
    end

    def recent_signal_count_for(regex)
      cutoff = 7.days.ago
      signals.count do |signal|
        signal_time = signal.started_at || signal.created_at
        signal_time.present? && signal_time >= cutoff && signal_text(signal).match?(regex)
      end
    end

    def forecast_count_for(regex)
      signals.count do |signal|
        signal.signal_type.to_s == "forecast" && signal_text(signal).match?(regex)
      end
    end

    def signal_text(signal)
      [
        signal.event,
        signal.headline,
        signal.description,
        signal.area_desc,
        signal.severity,
        signal.urgency,
        signal.certainty
      ].join(" ")
    end

    def base_url
      ENV.fetch("KALSHI_BASE_URL", DEFAULT_BASE_URL).to_s.delete_suffix("/").sub(%r{/trade-api/v2\z}, "")
    end
  end
end
