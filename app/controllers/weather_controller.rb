require "open3"

class WeatherController < ApplicationController
  WEATHER_SNIFFER_SERVICE = "wizwiki-weather-machine.service".freeze
  WEATHER_SNIFFER_TIMER = "wizwiki-weather-machine.timer".freeze
  WEATHER_RISK_SETTINGS_KEY = "weather_autopilot".freeze
  WEATHER_RISK_MIN_DAILY_SPEND_RANGE = (0.0..0.0).freeze
  WEATHER_RISK_DAILY_CAP_RANGE = (5.0..5.0).freeze
  WEATHER_RISK_PRESETS = {
    "locked" => { label: "locked", min_daily_spend: 0.0, daily_cap: 5.0 }
  }.freeze
  WEATHER_STATION_MARKERS = {
    "austin|TX" => { code: "AUS", x: 51.0, y: 74.0 },
    "boston|MA" => { code: "BOS", x: 88.0, y: 31.0 },
    "chicago|IL" => { code: "CHI", x: 62.5, y: 38.5 },
    "denver|CO" => { code: "DEN", x: 38.0, y: 49.5 },
    "los angeles|CA" => { code: "LAX", x: 14.0, y: 58.5 },
    "miami|FL" => { code: "MIA", x: 80.5, y: 83.0 },
    "new york city|NY" => { code: "NYC", x: 85.0, y: 36.5 },
    "philadelphia|PA" => { code: "PHL", x: 83.2, y: 40.5 }
  }.freeze

  before_action :require_organization!

  def index
    @storage_ready = WeatherLeadSignal.storage_ready?
    @summary = Weather::LeadMatcher.signal_summary_for(current_organization)
    @signals = @storage_ready ? current_organization.weather_lead_signals.actionable.recent_first.limit(80).to_a : []
    @recent_signals = @storage_ready ? current_organization.weather_lead_signals.where("created_at >= ?", 30.days.ago).recent_first.limit(500).to_a : []
    @weather_scan_status = Weather::ScanStatus.for(current_organization)
    @weather_sniffer_active = weather_sniffer_active?
    @weather_sniffer_status = weather_sniffer_status(active: @weather_sniffer_active)
    @pattern_counts = build_pattern_counts(@recent_signals)
    @prediction_signals = @signals
      .select { |signal| signal.signal_type == "forecast" || signal.metadata.to_h["prediction_signal"].present? }
      .sort_by { |signal| -signal.urgency_score }
      .first(12)
    @kalshi_weather_scout = cached_kalshi_weather_scout
    @kalshi_actual_backfill_status = backfill_kalshi_actuals
    @kalshi_settlement_status = settle_kalshi_predictions
    @kalshi_outcome_analysis_status = enqueue_kalshi_outcome_analysis
    @kalshi_autopilot_status = run_kalshi_weather_autopilot
    @kalshi_calibration_harness = kalshi_calibration_harness
    @kalshi_paper_strategy_summary = kalshi_paper_strategy_summary
    @kalshi_risk_controls = kalshi_weather_risk_controls
    @kalshi_prediction_summary = kalshi_prediction_summary
    @kalshi_accuracy_summary = kalshi_accuracy_summary
    @kalshi_miss_cause_summary = kalshi_miss_cause_summary
    @kalshi_latest_outcome_analysis = latest_kalshi_outcome_analysis
    @kalshi_recent_predictions = kalshi_recent_predictions
    @kalshi_winning_cities = kalshi_winning_cities
    @kalshi_paper_performance = kalshi_paper_performance
    @kalshi_live_dashboard = kalshi_live_dashboard
    @kalshi_profitability_summary = kalshi_profitability_summary
    @kalshi_opportunity_board = kalshi_opportunity_board
    @kalshi_market_weather_station = kalshi_market_weather_station(@kalshi_live_dashboard, @kalshi_opportunity_board)
    @kalshi_buy_journal = kalshi_buy_journal
    @kalshi_account_status = kalshi_account_status
    @kalshi_source_learning = kalshi_source_learning
    @kalshi_divergence_watch = kalshi_divergence_watch
    @market_api_status = {
      kalshi: kalshi_configured?,
      polymarket: configured?(%w[POLYMARKET_API_KEY POLYMARKET_PRIVATE_KEY POLYMARKET_FUNDER POLYMARKET_SIGNATURE_TYPE])
    }
  rescue ActiveRecord::StatementInvalid => error
    @storage_ready = false
    @summary = {}
    @signals = []
    @recent_signals = []
    @weather_scan_status = {}
    @weather_sniffer_active = false
    @weather_sniffer_status = {}
    @pattern_counts = empty_pattern_counts
    @prediction_signals = []
    @kalshi_weather_scout = empty_kalshi_weather_scout
    @kalshi_actual_backfill_status = {}
    @kalshi_settlement_status = {}
    @kalshi_outcome_analysis_status = {}
    @kalshi_autopilot_status = {}
    @kalshi_calibration_harness = empty_kalshi_calibration_harness
    @kalshi_paper_strategy_summary = []
    @kalshi_risk_controls = {}
    @kalshi_prediction_summary = {}
    @kalshi_accuracy_summary = {}
    @kalshi_miss_cause_summary = {}
    @kalshi_latest_outcome_analysis = nil
    @kalshi_recent_predictions = []
    @kalshi_winning_cities = []
    @kalshi_paper_performance = empty_kalshi_paper_performance
    @kalshi_live_dashboard = empty_kalshi_live_dashboard
    @kalshi_profitability_summary = empty_kalshi_profitability_summary
    @kalshi_opportunity_board = []
    @kalshi_market_weather_station = empty_kalshi_market_weather_station("weather tables unavailable")
    @kalshi_buy_journal = []
    @kalshi_account_status = empty_kalshi_account_status("weather tables unavailable")
    @kalshi_source_learning = { sources: [], agreements: [], source_counts: [] }
    @kalshi_divergence_watch = empty_kalshi_divergence_watch("weather tables unavailable")
    @market_api_status = { kalshi: false, polymarket: false }
    @weather_error = error.message
  end

  def sniff
    if weather_sniffer_active?
      return redirect_to weather_path, notice: "Thumper's weather scan is already running. The next automatic tick will reset after this run finishes."
    end

    result = start_weather_sniffer
    if result[:ok]
      redirect_to weather_path, notice: "Thumper's weather scan started. It is refreshing the market scout and paper harness now; the timer resets when this run completes."
    else
      redirect_to weather_path, alert: "Thumper's weather scan could not start: #{result[:error]}"
    end
  end

  def manual_buy
    amount = params[:amount].to_f
    prediction_id = params[:prediction_id].presence
    result = Kalshi::WeatherAutopilot.new(
      organization: current_organization,
      limit: ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_LIMIT", Kalshi::WeatherAutopilot::DEFAULT_LIMIT).to_i
    ).manual_buy(
      prediction_id: prediction_id,
      amount: amount,
      user: current_user
    )

    if result[:ok]
      redirect_to weather_path, notice: "Manual weather buy placed for #{result[:market_ticker]}: #{helpers.number_to_currency(result[:max_cost])} across #{result[:contracts]} contracts."
    else
      redirect_to weather_path, alert: "Manual weather buy blocked: #{result[:error]}"
    end
  end

  def update_risk
    settings = normalize_weather_risk_settings
    save_weather_risk_settings!(settings)
    scan_started = weather_sniffer_active? || start_weather_sniffer[:ok]

    mode = "Walk-forward calibration is enforced; legacy uncalibrated probabilities are disabled."
    scan_note = scan_started ? "Allocation scan started." : "The scheduled scan will apply the change."
    redirect_to weather_path, notice: "Daily weather exposure capped at #{helpers.number_to_currency(settings.fetch('daily_cap'), precision: 0)}. #{mode} #{scan_note} No minimum deployment is required."
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather risk update failed: #{error.class}: #{error.message}")
    redirect_to weather_path, alert: "Weather risk settings were not saved: #{error.message}"
  end

  private

  def normalize_weather_risk_settings
    raw = params.fetch(:weather_risk, ActionController::Parameters.new).permit(:preset, :min_daily_spend, :daily_cap, :blind_edge_mode)
    preset = WEATHER_RISK_PRESETS[raw[:preset].to_s]
    current = kalshi_weather_risk_controls

    {
      "min_daily_spend" => 0.0,
      "daily_cap" => Kalshi::WeatherAutopilot::HARD_LIVE_DAILY_CAP,
      "blind_edge_mode" => false
    }
  end

  def weather_risk_boolean(value)
    value == true || value.to_s.strip.downcase.in?(%w[1 true yes on enabled])
  end

  def clamp_weather_risk_dollars(value, fallback:, range:)
    raw = value.to_s.delete("$,").squish
    amount = raw.present? ? raw.to_f : fallback.to_f
    amount = fallback.to_f unless amount.finite?
    amount.clamp(range.begin, range.end).round(2)
  end

  def save_weather_risk_settings!(settings)
    org_settings = current_organization.settings.to_h.deep_dup
    existing = org_settings.fetch(WEATHER_RISK_SETTINGS_KEY, {}).to_h
    org_settings[WEATHER_RISK_SETTINGS_KEY] = existing.merge(settings).merge(
      "updated_at" => Time.current.iso8601,
      "updated_by_id" => current_user&.id
    )
    current_organization.update!(settings: org_settings)
  end

  def kalshi_weather_risk_controls
    return empty_kalshi_weather_risk_controls unless defined?(Kalshi::WeatherAutopilot)

    autopilot = weather_autopilot
    settings = current_organization.settings.to_h.fetch(WEATHER_RISK_SETTINGS_KEY, {}).to_h
    {
      min_daily_spend: 0.0,
      minimum_enforced: false,
      blind_edge_mode: autopilot.send(:blind_edge_mode?),
      daily_cap: autopilot.send(:daily_cap).round(2),
      per_order_cap: autopilot.send(:per_order_cap).round(2),
      manual_buy_max: autopilot.send(:manual_buy_max).round(2),
      reserved_today: autopilot.send(:budgeted_spend, Date.current).round(2),
      remaining_today: autopilot.send(:remaining_budget, Date.current).round(2),
      total_credited: autopilot.send(:accrued_budget, Date.current).round(2),
      updated_at: settings["updated_at"].presence,
      persisted: settings.present?,
      daily_cap_min: WEATHER_RISK_DAILY_CAP_RANGE.begin,
      daily_cap_max: WEATHER_RISK_DAILY_CAP_RANGE.end,
      min_daily_spend_min: WEATHER_RISK_MIN_DAILY_SPEND_RANGE.begin,
      min_daily_spend_max: WEATHER_RISK_MIN_DAILY_SPEND_RANGE.end,
      step: 5,
      presets: WEATHER_RISK_PRESETS.map do |key, preset|
        preset.merge(key: key)
      end
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather risk controls skipped: #{error.class}: #{error.message}")
    empty_kalshi_weather_risk_controls
  end

  def empty_kalshi_weather_risk_controls
    {
      min_daily_spend: 0.0,
      minimum_enforced: false,
      blind_edge_mode: false,
      daily_cap: 5.0,
      per_order_cap: 5.0,
      manual_buy_max: 5.0,
      reserved_today: 0.0,
      remaining_today: 5.0,
      total_credited: 5.0,
      persisted: false,
      daily_cap_min: WEATHER_RISK_DAILY_CAP_RANGE.begin,
      daily_cap_max: WEATHER_RISK_DAILY_CAP_RANGE.end,
      min_daily_spend_min: WEATHER_RISK_MIN_DAILY_SPEND_RANGE.begin,
      min_daily_spend_max: WEATHER_RISK_MIN_DAILY_SPEND_RANGE.end,
      step: 5,
      presets: WEATHER_RISK_PRESETS.map { |key, preset| preset.merge(key: key) }
    }
  end

  def weather_autopilot
    @weather_autopilot ||= Kalshi::WeatherAutopilot.new(
      organization: current_organization,
      limit: ENV.fetch("WIZWIKI_WEATHER_AUTOPILOT_LIMIT", Kalshi::WeatherAutopilot::DEFAULT_LIMIT).to_i
    )
  end

  def weather_sniffer_active?
    _stdout, _stderr, status = Open3.capture3(systemd_env, "systemctl", "--user", "is-active", "--quiet", WEATHER_SNIFFER_SERVICE)
    status.success?
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather sniffer active check skipped: #{error.class}: #{error.message}")
    false
  end

  def weather_sniffer_status(active:)
    show = systemctl_show(
      WEATHER_SNIFFER_SERVICE,
      %w[ActiveState SubState InactiveEnterTimestamp ExecMainStatus Result]
    )
    timer = weather_sniffer_timer_status
    {
      active: active,
      state: show["ActiveState"].presence || (active ? "active" : "inactive"),
      sub_state: show["SubState"].presence,
      last_finished_at: show["InactiveEnterTimestamp"].presence,
      exit_status: show["ExecMainStatus"].presence,
      result: show["Result"].presence
    }.merge(timer)
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather sniffer status skipped: #{error.class}: #{error.message}")
    { active: active }
  end

  def weather_sniffer_timer_status
    show = systemctl_show(WEATHER_SNIFFER_TIMER, %w[ActiveState SubState LastTriggerUSec])
    stdout, _stderr, status = Open3.capture3(
      systemd_env,
      "systemctl",
      "--user",
      "list-timers",
      WEATHER_SNIFFER_TIMER,
      "--all",
      "--no-legend",
      "--no-pager"
    )
    {
      timer_state: show["ActiveState"].presence,
      timer_sub_state: show["SubState"].presence,
      next_tick_at: parse_systemd_timer_at(list_timer_next_at(stdout, status)),
      last_tick_at: parse_systemd_timer_at(show["LastTriggerUSec"])
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather sniffer timer status skipped: #{error.class}: #{error.message}")
    {}
  end

  def list_timer_next_at(stdout, status)
    return nil unless status.success?

    line = stdout.lines.find { |item| item.include?(WEATHER_SNIFFER_TIMER) }.to_s.squish
    return nil if line.blank? || line.start_with?("n/a")

    line.split(/\s+/).first(4).join(" ")
  end

  def parse_systemd_timer_at(value)
    return nil if value.blank? || value.to_s == "n/a"

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    value
  end

  def systemctl_show(unit, properties)
    args = ["systemctl", "--user", "show", unit]
    Array(properties).each { |property| args << "-p" << property }
    stdout, _stderr, status = Open3.capture3(systemd_env, *args)
    return {} unless status.success?

    stdout.lines.each_with_object({}) do |line, values|
      key, value = line.strip.split("=", 2)
      values[key] = value if key.present?
    end
  end

  def start_weather_sniffer
    stdout, stderr, status = Open3.capture3(systemd_env, "systemctl", "--user", "start", "--no-block", WEATHER_SNIFFER_SERVICE)
    if status.success?
      Rails.logger.info("[WeatherController] manual weather sniffer started user=#{current_user&.id} organization=#{current_organization.id}")
      { ok: true }
    else
      error = stderr.presence || stdout.presence || "systemctl exited #{status.exitstatus}"
      Rails.logger.warn("[WeatherController] manual weather sniffer failed: #{error}")
      { ok: false, error: error.to_s.squish }
    end
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] manual weather sniffer failed: #{error.class}: #{error.message}")
    { ok: false, error: "#{error.class}: #{error.message}" }
  end

  def systemd_env
    { "XDG_RUNTIME_DIR" => ENV["XDG_RUNTIME_DIR"].presence || "/run/user/#{Process.uid}" }
  end

  def configured?(keys)
    keys.any? { |key| ENV[key].present? }
  end

  def kalshi_configured?
    configured?(%w[KALSHI_API_KEY_ID KALSHI_ACCESS_KEY KALSHI_API_KEY]) &&
      configured?(%w[KALSHI_PRIVATE_KEY_PATH KALSHI_PRIVATE_KEY])
  end

  def build_pattern_counts(signals)
    {
      events: signals.map(&:event).compact_blank.tally.sort_by { |_key, count| -count }.first(12),
      states: signals.flat_map { |signal| Array(signal.affected_states) }.compact_blank.tally.sort_by { |_key, count| -count }.first(12),
      zips: signals.flat_map { |signal| Array(signal.affected_postal_codes) }.compact_blank.tally.sort_by { |_key, count| -count }.first(12),
      signal_types: signals.map(&:signal_type).compact_blank.tally.sort_by { |_key, count| -count },
      urgency: signals.map { |signal| signal.urgency.presence || "unknown" }.tally.sort_by { |_key, count| -count },
      certainty: signals.map { |signal| signal.certainty.presence || "unknown" }.tally.sort_by { |_key, count| -count }
    }
  end

  def empty_pattern_counts
    {
      events: [],
      states: [],
      zips: [],
      signal_types: [],
      urgency: [],
      certainty: []
    }
  end

  def empty_kalshi_weather_scout
    {
      generated_at: Time.current,
      errors: [],
      total_series: 0,
      top_opportunities: [],
      best_opportunities: [],
      watchlist: [],
      study_series: [],
      prediction_storage: "not_ready"
    }
  end

  def cached_kalshi_weather_scout
    return empty_kalshi_weather_scout unless defined?(Weather::MarketScoutJob)

    Rails.cache.read(Weather::MarketScoutJob.result_cache_key(current_organization.id)) || empty_kalshi_weather_scout
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] cached market scout unavailable: #{error.class}: #{error.message}")
    empty_kalshi_weather_scout.merge(errors: ["cached market scout unavailable"])
  end

  def kalshi_prediction_summary
    return {} unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    scope = current_organization.kalshi_weather_predictions
    wins = scope.where(result_status: "won").count
    losses = scope.where(result_status: "lost").count
    decided = wins + losses
    {
      total: scope.count,
      open: scope.open_predictions.count,
      paper_yes: scope.paper_yes.count,
      settled: scope.where.not(result_status: "pending").count,
      wins: wins,
      losses: losses,
      actual_backfilled: scope.where.not(observed_high_f: nil).where("metadata ->> 'actual_high_source' = ?", "weather.gov_station_observation").count,
      hit_rate: decided.positive? ? ((wins.to_f / decided) * 100).round(1) : nil,
      last_updated_at: scope.maximum(:updated_at)
    }
  end

  def kalshi_accuracy_summary
    return {} unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    scored = current_organization.kalshi_weather_predictions
      .where.not(observed_high_f: nil)
      .where.not(adjusted_high_f: nil)
      .recent_first
      .limit(80)
      .to_a

    market_distances = scored.filter_map(&:market_distance_f)
    adjusted_errors = scored.filter_map { |prediction| prediction.adjusted_error_f&.abs }
    forecast_errors = scored.filter_map { |prediction| prediction.forecast_error_f&.abs }
    {
      scored: scored.length,
      avg_market_distance_f: average(market_distances),
      avg_adjusted_error_f: average(adjusted_errors),
      avg_forecast_error_f: average(forecast_errors),
      source_counts: scored.map(&:actual_high_source_label).tally.sort_by { |_source, count| -count },
      last_scored_at: scored.filter_map { |prediction| prediction.metadata.to_h["scored_at"].presence }.max
    }
  end

  def kalshi_miss_cause_summary
    return {} unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    scope = current_organization.kalshi_weather_predictions.where(result_status: "lost")
    rows = scope.group(Arel.sql("COALESCE(metadata ->> 'miss_cause_label', metadata ->> 'miss_cause', 'Unclassified')")).count
    rows.sort_by { |_label, count| -count }.to_h
  end

  def kalshi_recent_predictions
    return [] unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    current_organization.kalshi_weather_predictions.recent_first.limit(80).to_a
  end

  def kalshi_winning_cities
    return [] unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    rows = current_organization.kalshi_weather_predictions
      .where(result_status: %w[won lost])
      .pluck(:city, :state, :result_status)
    rows
      .group_by { |city, state, _result| [city.to_s.squish.presence || "Unknown", state.to_s.squish.presence] }
      .map do |(city, state), city_rows|
        wins = city_rows.count { |_city, _state, result| result.to_s == "won" }
        decided = city_rows.length
        {
          city: city,
          state: state,
          wins: wins,
          losses: decided - wins,
          decided: decided,
          hit_rate: decided.positive? ? ((wins.to_f / decided) * 100).round(1) : nil
        }
      end
      .sort_by { |row| [-row[:wins].to_i, -(row[:hit_rate] || 0).to_f, -row[:decided].to_i, row[:city].to_s] }
      .first(8)
  end

  def kalshi_market_weather_station(live_dashboard = {}, opportunity_board = [])
    return empty_kalshi_market_weather_station("prediction storage not ready") unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    predictions = current_organization.kalshi_weather_predictions
      .includes(:kalshi_weather_wagers)
      .where("created_at >= ?", 45.days.ago)
      .recent_first
      .limit(300)
      .to_a
    rows = predictions
      .group_by { |prediction| weather_station_city_key(prediction.city, prediction.state) }
      .filter_map.with_index do |(_key, city_predictions), index|
        prediction = select_weather_station_prediction(city_predictions)
        weather_station_row_for(prediction, live_dashboard, opportunity_board, index)
      end
      .sort_by { |row| weather_station_row_sort(row) }

    {
      callsign: "cyborg forecasting by Alice of Qwen",
      generated_at: Time.current,
      rows: rows,
      summary: {
        cities: rows.length,
        active: rows.count { |row| row[:status].in?(%w[live ticket candidate]) },
        open: rows.count { |row| row[:result_status].to_s == "pending" },
        wins: rows.count { |row| row[:result_status].to_s == "won" },
        losses: rows.count { |row| row[:result_status].to_s == "lost" }
      }
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] market weather station skipped: #{error.class}: #{error.message}")
    empty_kalshi_market_weather_station("#{error.class}: #{error.message}")
  end

  def empty_kalshi_market_weather_station(error = nil)
    {
      callsign: "cyborg forecasting by Alice of Qwen",
      generated_at: Time.current,
      rows: [],
      summary: { cities: 0, active: 0, open: 0, wins: 0, losses: 0 },
      error: error
    }
  end

  def select_weather_station_prediction(predictions)
    Array(predictions).max_by do |prediction|
      [
        prediction.result_status.to_s == "pending" ? 1 : 0,
        prediction.prediction_date || Date.new(1970, 1, 1),
        prediction.updated_at || Time.at(0)
      ]
    end
  end

  def weather_station_row_for(prediction, live_dashboard, opportunity_board, fallback_index)
    return nil if prediction.blank?

    key = weather_station_city_key(prediction.city, prediction.state)
    marker = WEATHER_STATION_MARKERS[key] || weather_station_fallback_marker(fallback_index)
    opportunity = weather_station_opportunity_for(prediction, opportunity_board, key)
    positions = weather_station_positions_for(live_dashboard, key)
    wager = prediction.primary_weather_wager
    metadata = prediction.metadata.to_h
    stake = positions.sum { |row| row[:stake].to_f }
    stake = (wager.actual_cost.presence || wager.max_cost.presence || 0).to_f if stake.zero? && wager.present?
    contracts = positions.sum { |row| row[:contracts].to_i }
    contracts = wager.contracts.to_i if contracts.zero? && wager.present?

    {
      id: prediction.id,
      code: marker[:code],
      x: marker[:x],
      y: marker[:y],
      city: prediction.city,
      state: prediction.state,
      label: [prediction.city, prediction.state].compact_blank.join(", "),
      market: prediction.market_band_label,
      market_ticker: prediction.market_ticker,
      action: prediction.action,
      status: weather_station_status_for(prediction, wager, positions, opportunity),
      result_status: prediction.result_status,
      side: prediction.side.presence || "YES",
      confidence: prediction.confidence,
      edge: prediction.edge,
      ask: prediction.ask,
      forecast_high_f: prediction.forecast_high_f,
      adjusted_high_f: prediction.adjusted_high_f,
      predicted_high_f: prediction.adjusted_high_f.presence || prediction.forecast_high_f,
      observed_high_f: prediction.observed_high_f,
      prediction_date: prediction.prediction_date,
      close_time: prediction.close_time,
      source_count: metadata["forecast_source_count"],
      source_spread_f: metadata["forecast_source_spread_f"],
      recommendation: opportunity.to_h[:recommendation].to_h,
      wager_status: wager&.status,
      wager_mode: wager&.execution_mode,
      contracts: contracts,
      stake: stake.round(2)
    }
  end

  def weather_station_city_key(city, state)
    "#{city.to_s.squish.downcase}|#{state.to_s.squish.upcase}"
  end

  def weather_station_fallback_marker(index)
    offset = index.to_i % 8
    {
      code: "WX#{offset + 1}",
      x: 28 + (offset % 4) * 12,
      y: 46 + (offset / 4) * 14
    }
  end

  def weather_station_opportunity_for(prediction, opportunity_board, city_key)
    rows = Array(opportunity_board)
    rows.find { |row| row[:prediction_id].to_i == prediction.id } ||
      rows.find { |row| weather_station_city_key(row[:city], row[:state]) == city_key }
  end

  def weather_station_positions_for(live_dashboard, city_key)
    Array(live_dashboard.to_h[:open_positions]).select do |row|
      weather_station_city_key(row[:city], row[:state]) == city_key
    end
  end

  def weather_station_status_for(prediction, wager, positions, opportunity)
    wager_open = wager&.status.to_s.in?(%w[pending placed filled])
    return "live" if wager_open && wager&.execution_mode.to_s == "live"
    return "ticket" if wager_open || positions.present?

    recommendation = opportunity.to_h[:recommendation].to_h
    return "candidate" if recommendation[:amount].to_f.positive? || recommendation[:label].to_s == "eligible"
    return prediction.result_status if prediction.result_status.to_s.in?(%w[won lost pushed void])
    return "watch" if prediction.result_status.to_s == "pending"

    "settled"
  end

  def weather_station_row_sort(row)
    status_rank = {
      "live" => 0,
      "ticket" => 1,
      "candidate" => 2,
      "watch" => 3,
      "won" => 4,
      "lost" => 5,
      "pushed" => 6,
      "void" => 7,
      "settled" => 8
    }
    [
      status_rank.fetch(row[:status].to_s, 9),
      -row[:edge].to_f,
      row[:city].to_s
    ]
  end

  def kalshi_paper_performance
    return empty_kalshi_paper_performance unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    simulation = paper_bankroll_simulation
    rows_by_id = paper_bankroll_rows.index_by(&:id)
    entries = simulation[:entries].to_a.filter_map do |entry|
      row = rows_by_id[entry[:id]]
      next if row.blank? || !row.result_status.in?(%w[won lost pushed void])
      next unless entry[:contracts].to_i.positive?

      total_risk = entry[:total_risk].presence || entry[:stake]
      payout = entry[:profit].to_f.positive? ? entry[:profit].to_f + total_risk.to_f : 0.0
      {
        id: row.id,
        city: row.city,
        state: row.state,
        date: entry[:date] || row.prediction_date || row.close_time&.to_date || row.created_at.to_date,
        result: row.result_status,
        price: entry[:price],
        contracts: entry[:contracts].to_i,
        stake: entry[:stake].to_f.round(2),
        estimated_fees: entry[:estimated_fees].to_f.round(2),
        total_risk: total_risk.to_f.round(2),
        payout: payout.round(2),
        profit: entry[:profit].to_f.round(2),
        market: row.market_band_label,
        opportunity_tier: entry[:opportunity_tier],
        allocation_reason: entry[:allocation_reason]
      }
    end

    cumulative = 0.0
    daily = entries
      .group_by { |entry| entry[:date] }
      .sort_by { |date, _items| date || Date.current }
      .map do |date, items|
        daily_profit = items.sum { |item| item[:profit].to_f }
        daily_stake = items.sum { |item| item[:total_risk].to_f }
        wins = items.count { |item| item[:result] == "won" }
        losses = items.count { |item| item[:result] == "lost" }
        cumulative += daily_profit
        {
          date: date,
          daily_profit: daily_profit.round(2),
          cumulative_profit: cumulative.round(2),
          stake: daily_stake.round(2),
          wins: wins,
          losses: losses,
          count: items.length
        }
      end

    wins = entries.count { |entry| entry[:result] == "won" }
    losses = entries.count { |entry| entry[:result] == "lost" }
    staked = entries.sum { |entry| entry[:total_risk].to_f }
    fees = entries.sum { |entry| entry[:estimated_fees].to_f }
    profit = entries.sum { |entry| entry[:profit].to_f }
    {
      entries: entries,
      daily: daily,
      bankroll: paper_bankroll_summary(simulation),
      wins: wins,
      losses: losses,
      decided: wins + losses,
      total_staked: staked.round(2),
      total_fees: fees.round(2),
      fees_included: true,
      total_profit: profit.round(2),
      roi_percent: staked.positive? ? ((profit / staked) * 100).round(1) : nil,
      hit_rate: (wins + losses).positive? ? ((wins.to_f / (wins + losses)) * 100).round(1) : nil,
      best_day: daily.max_by { |row| row[:daily_profit].to_f },
      worst_day: daily.min_by { |row| row[:daily_profit].to_f }
    }
  end

  def kalshi_live_dashboard
    return empty_kalshi_live_dashboard unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    simulation = paper_bankroll_simulation
    live_scope = current_organization.kalshi_weather_predictions.where(action: "paper_yes")
    live_scope = live_scope.where("created_at >= ?", live_bankroll_tracking_started_at) if live_bankroll_tracking_started_at.present?
    open_rows = live_scope
      .where(result_status: "pending")
      .order(Arel.sql("COALESCE(close_time, updated_at) ASC"))
      .limit(160)
      .to_a
    paper_positions = open_rows
      .filter_map { |row| paper_position_row(row) }
    settled_scope = live_scope.where(result_status: %w[won lost pushed void])
    recent_settled_rows = settled_scope
      .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
      .limit(12)
      .to_a
    today = Time.zone.today
    today_settled_profit = simulation[:entries].to_a
      .select { |entry| entry[:date] == today && entry[:contracts].to_i.positive? && entry[:result].to_s.in?(%w[won lost pushed void]) }
      .sum { |entry| entry[:profit].to_f }
    settled_profit = simulation[:total_profit].to_f
    today_open_unrealized = paper_positions
      .select { |row| row[:date] == today }
      .sum { |row| row[:unrealized_profit].to_f }
    open_unrealized = paper_positions.sum { |row| row[:unrealized_profit].to_f }
    dashboard = {
      refreshed_at: Time.current,
      bankroll: paper_bankroll_summary(simulation),
      position_source: "paper_tracker",
      position_label: "paper tracker",
      open_predictions: open_rows.length,
      open_positions: paper_positions,
      outcome_exposure: weather_outcome_exposure_for(paper_positions),
      open_contracts: paper_positions.sum { |row| row[:contracts].to_i },
      open_stake: paper_positions.sum { |row| row[:stake].to_f }.round(2),
      open_unrealized_profit: open_unrealized.round(2),
      today_settled_profit: today_settled_profit.round(2),
      today_live_profit: (today_settled_profit + today_open_unrealized).round(2),
      overall_live_profit: (settled_profit + open_unrealized).round(2),
      next_close_at: paper_positions.filter_map { |row| row[:close_time] }.min,
      recent_closed: recent_settled_rows.filter_map { |row| paper_closed_row(row) }
    }
    live_scope_for_orders = live_wager_scope
    live_positions = live_wager_position_rows
    live_order_count = live_scope_for_orders.count
    return dashboard if live_order_count.zero?

    live_settled_scope = live_scope_for_orders.where(status: %w[won lost pushed void])
    closed_live_wagers = live_settled_scope
      .includes(:kalshi_weather_prediction)
      .order(Arel.sql("COALESCE(settled_at, kalshi_weather_wagers.updated_at) DESC"))
      .limit(120)
      .to_a
    today_range = today.beginning_of_day..today.end_of_day
    live_today_settled_profit = live_settled_scope
      .where("COALESCE(settled_at, updated_at) BETWEEN ? AND ?", today_range.begin, today_range.end)
      .sum(:realized_profit)
      .to_f
    live_settled_profit = live_settled_scope.sum(:realized_profit).to_f
    live_today_open_unrealized = live_positions
      .select { |row| row[:date] == today }
      .sum { |row| row[:unrealized_profit].to_f }
    live_open_unrealized = live_positions.sum { |row| row[:unrealized_profit].to_f }
    live_budget = live_weather_budget_summary

    dashboard.merge(
      bankroll: dashboard[:bankroll].merge(live_budget),
      position_source: "live_orders",
      position_label: "live Kalshi orders",
      open_predictions: live_positions.length,
      open_positions: live_positions,
      outcome_exposure: weather_outcome_exposure_for(live_positions),
      open_contracts: live_positions.sum { |row| row[:contracts].to_i },
      open_stake: live_positions.sum { |row| row[:stake].to_f }.round(2),
      open_unrealized_profit: live_open_unrealized.round(2),
      today_settled_profit: live_today_settled_profit.round(2),
      today_live_profit: (live_today_settled_profit + live_today_open_unrealized).round(2),
      overall_live_profit: (live_settled_profit + live_open_unrealized).round(2),
      next_close_at: live_positions.filter_map { |row| row[:close_time] }.min,
      recent_closed: closed_live_wagers.first(12).filter_map { |wager| live_wager_closed_row(wager) },
      daily: live_wager_daily_rows(closed_live_wagers.reverse),
      live_order_count: live_order_count
    )
  end

  def kalshi_account_status
    return empty_kalshi_account_status("Kalshi account client unavailable") unless defined?(Kalshi::AccountClient)

    Rails.cache.fetch(["kalshi_account_status", current_organization.id], expires_in: 60.seconds) do
      Kalshi::AccountClient.status
    end
  rescue StandardError => error
    empty_kalshi_account_status("#{error.class}: #{error.message}")
  end

  def kalshi_source_learning
    return { sources: [], agreements: [], source_counts: [] } unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    rows = current_organization.kalshi_weather_predictions
      .where(result_status: %w[won lost])
      .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
      .limit(240)
      .to_a

    source_stats = Hash.new { |hash, key| hash[key] = { label: key, seen: 0, wins: 0, losses: 0, errors: [] } }
    agreement_stats = Hash.new { |hash, key| hash[key] = { label: key, seen: 0, wins: 0, losses: 0, avg_spreads: [] } }
    source_count_stats = Hash.new { |hash, key| hash[key] = { label: key, seen: 0, wins: 0, losses: 0 } }

    rows.each do |row|
      metadata = row.metadata.to_h
      won = row.result_status == "won"
      sources = Array(metadata["forecast_sources"]).presence || [{ "label" => metadata["forecast_source"].presence || "Unknown source" }]
      sources.each do |source|
        label = source["label"].presence || source[:label].presence || source["key"].presence || source[:key].presence || "Unknown source"
        stats = source_stats[label]
        stats[:seen] += 1
        stats[won ? :wins : :losses] += 1
        high = source["high_f"].presence || source[:high_f].presence
        stats[:errors] << (high.to_f - row.observed_high_f.to_f).abs if high.present? && row.observed_high_f.present?
      end

      agreement_label = metadata["forecast_agreement_label"].presence || "unknown agreement"
      agreement = agreement_stats[agreement_label]
      agreement[:seen] += 1
      agreement[won ? :wins : :losses] += 1
      agreement[:avg_spreads] << metadata["forecast_source_spread_f"].to_f if metadata["forecast_source_spread_f"].present?

      source_count = metadata["forecast_source_count"].presence || sources.length
      count_key = "#{source_count.to_i} live source#{source_count.to_i == 1 ? '' : 's'}"
      count_stats = source_count_stats[count_key]
      count_stats[:seen] += 1
      count_stats[won ? :wins : :losses] += 1
    end

    {
      sources: source_stats.values.map { |row| finalize_source_learning_row(row) }
        .sort_by { |row| [row[:avg_abs_error_f] || 99, -row[:hit_rate].to_f, -row[:seen].to_i] }
        .first(8),
      agreements: agreement_stats.values.map { |row| finalize_source_learning_row(row.merge(errors: row[:avg_spreads])) }
        .sort_by { |row| [-row[:seen].to_i, -row[:hit_rate].to_f] }
        .first(6),
      source_counts: source_count_stats.values.map { |row| finalize_source_learning_row(row.merge(errors: [])) }
        .sort_by { |row| [-row[:seen].to_i, -row[:hit_rate].to_f] }
        .first(5)
    }
  end

  def kalshi_divergence_watch
    return empty_kalshi_divergence_watch("prediction storage not ready") unless defined?(Kalshi::WeatherDivergenceEngine)

    Kalshi::WeatherDivergenceEngine.call(organization: current_organization, limit: 12)
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather divergence watch skipped: #{error.class}: #{error.message}")
    empty_kalshi_divergence_watch("#{error.class}: #{error.message}")
  end

  def settle_kalshi_predictions
    cached_weather_calibration_result[:settlement].to_h
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] cached Kalshi settlement status unavailable: #{error.class}: #{error.message}")
    { checked: 0, settled: 0, waiting: 0, errors: ["#{error.class}: #{error.message}"], ran_at: Time.current }
  end

  def backfill_kalshi_actuals
    cached_weather_calibration_result[:backfill].to_h
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] cached actual-high backfill status unavailable: #{error.class}: #{error.message}")
    { checked: 0, backfilled: 0, waiting: 0, sources: {}, errors: ["#{error.class}: #{error.message}"], ran_at: Time.current }
  end

  def enqueue_kalshi_outcome_analysis
    cached_weather_calibration_result[:analysis].to_h
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] cached outcome-analysis status unavailable: #{error.class}: #{error.message}")
    { reason: "#{error.class}: #{error.message}", ran_at: Time.current }
  end

  def cached_weather_calibration_result
    return {} unless defined?(Weather::PredictionCalibrationJob)

    @cached_weather_calibration_result ||= Rails.cache.read(
      Weather::PredictionCalibrationJob.result_cache_key(current_organization.id)
    ).to_h.deep_symbolize_keys
  end

  def run_kalshi_weather_autopilot
    return {} unless defined?(Kalshi::WeatherAutopilot)

    autopilot = weather_autopilot
    latest_wager = if defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?
      current_organization.kalshi_weather_wagers.recent_first.first
    end
    latest_error = if defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?
      current_organization.kalshi_weather_wagers.where(status: "error").recent_first.first
    end
    portfolio_guard = autopilot.send(:portfolio_guard_status)
    execution_gate_allowed = autopilot.send(:live_execution_allowed?)
    {
      status_source: "read_only_dashboard",
      daily_cap: autopilot.send(:daily_cap),
      min_daily_spend: autopilot.send(:min_daily_spend),
      target_spend_today: autopilot.send(:target_spend_today),
      per_order_cap: autopilot.send(:per_order_cap),
      qualified_daily_cap: autopilot.send(:qualified_daily_cap),
      exploration_daily_cap: autopilot.send(:exploration_daily_cap),
      review_auto_daily_cap: autopilot.send(:review_auto_daily_cap),
      manual_buy_max: autopilot.send(:manual_buy_max),
      max_scan_spend: autopilot.send(:max_scan_spend),
      qualified_max_scan_spend: autopilot.send(:qualified_max_scan_spend),
      exploration_max_scan_spend: autopilot.send(:exploration_max_scan_spend),
      min_scale_interval_minutes: autopilot.send(:min_scale_interval_minutes),
      exploration_min_confidence: autopilot.send(:exploration_min_confidence),
      exploration_longshot_min_confidence: autopilot.send(:exploration_longshot_min_confidence),
      live_orders_enabled: Kalshi::WeatherAutopilot.live_orders_enabled?,
      execution_allowed: execution_gate_allowed && portfolio_guard[:allowed] == true,
      live_blocked_reason: portfolio_guard[:allowed] == true ? autopilot.send(:live_blocked_reason) : portfolio_guard[:reason],
      blind_edge_mode: autopilot.send(:blind_edge_mode?),
      blind_live_enabled: Kalshi::WeatherAutopilot.blind_live_enabled?,
      qwen_ready: autopilot.send(:qwen_ready?),
      budget_start_date: autopilot.send(:budget_start_date)&.iso8601,
      accrued_budget: autopilot.send(:accrued_budget, Date.current).round(2),
      reserved_budget: autopilot.send(:budgeted_spend, Date.current).round(2),
      reserve_balance: autopilot.send(:remaining_budget, Date.current).round(2),
      remaining_today: autopilot.send(:remaining_budget, Date.current).round(2),
      errors: latest_error.present? ? [latest_error.reason] : [],
      ran_at: latest_wager&.updated_at
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] weather autopilot skipped: #{error.class}: #{error.message}")
    { errors: ["#{error.class}: #{error.message}"], ran_at: Time.current }
  end

  def kalshi_calibration_harness
    return empty_kalshi_calibration_harness unless defined?(Kalshi::WeatherCalibrationHarness)

    snapshot_version = KalshiWeatherPredictionSnapshot.where(organization_id: current_organization.id).maximum(:updated_at)&.to_i
    outcome_version = current_organization.kalshi_weather_predictions.where(result_status: %w[won lost]).maximum(:updated_at)&.to_i
    Rails.cache.fetch(
      ["weather_calibration_harness_v2", current_organization.id, snapshot_version, outcome_version],
      expires_in: 5.minutes,
      race_condition_ttl: 20.seconds
    ) do
      Kalshi::WeatherCalibrationHarness.call(organization: current_organization)
    end
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] calibration harness skipped: #{error.class}: #{error.message}")
    empty_kalshi_calibration_harness(error.message)
  end

  def empty_kalshi_calibration_harness(error = nil)
    {
      version: defined?(Kalshi::WeatherCalibrationHarness) ? Kalshi::WeatherCalibrationHarness::VERSION : "unavailable",
      stake_cap: 5.0,
      training_events: 0,
      training_dates: 0,
      walk_forward: {
        events: 0,
        dates: 0,
        calibrated: {},
        market: {},
        challenger: { trades: 0, profit: 0.0, roi_percent: nil },
        active_shadow: { trades: 0, profit: 0.0, roi_percent: nil }
      },
      live_gate: {
        clear: false,
        status: "blocked",
        reasons: [error.presence || "immutable calibration sample is not ready"].compact,
        manual_promotion_required: true
      },
      error: error
    }
  end

  def kalshi_paper_strategy_summary
    return [] unless defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?

    current_organization.kalshi_weather_wagers.paper
      .where.not(strategy_key: "legacy")
      .includes(:kalshi_weather_prediction)
      .to_a
      .group_by(&:strategy_key)
      .map do |strategy_key, wagers|
        decided = wagers.select { |wager| wager.display_result_status.in?(%w[won lost]) }
        risk = decided.sum { |wager| wager.max_cost.to_f + wager.metadata.to_h["estimated_taker_fee"].to_f }
        profit = decided.sum { |wager| wager.realized_profit.to_f }
        {
          strategy_key: strategy_key,
          strategy_version: wagers.filter_map(&:strategy_version).last,
          label: strategy_key.to_s.sub("paper_", "").tr("_", " "),
          total: wagers.length,
          open: wagers.count(&:pending?),
          decided: decided.length,
          wins: decided.count { |wager| wager.display_result_status == "won" },
          losses: decided.count { |wager| wager.display_result_status == "lost" },
          risk: risk.round(2),
          profit: profit.round(2),
          roi_percent: risk.positive? ? ((profit / risk) * 100).round(1) : nil,
          latest_at: wagers.map(&:updated_at).compact.max
        }
      end
      .sort_by { |row| row[:strategy_key] }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] paper strategy summary skipped: #{error.class}: #{error.message}")
    []
  end

  def kalshi_buy_journal
    return [] unless defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?

    current_organization.kalshi_weather_wagers
      .includes(:kalshi_weather_prediction)
      .recent_first
      .to_a
  rescue StandardError
    []
  end

  def latest_kalshi_outcome_analysis
    return nil unless defined?(AutosQuestion)

    current_organization.autos_questions
      .where("metadata ->> 'surface' = ?", Kalshi::WeatherOutcomeAnalysis::SURFACE)
      .order(created_at: :desc)
      .first
  rescue StandardError
    nil
  end

  def average(values)
    values = Array(values).compact.map(&:to_f)
    return nil if values.blank?

    (values.sum / values.length).round(1)
  end

  def empty_kalshi_paper_performance
    {
      entries: [],
      daily: [],
      bankroll: empty_kalshi_paper_bankroll,
      wins: 0,
      losses: 0,
      decided: 0,
      total_staked: 0.0,
      total_profit: 0.0,
      roi_percent: nil,
      hit_rate: nil,
      best_day: nil,
      worst_day: nil
    }
  end

  def empty_kalshi_live_dashboard
    {
      refreshed_at: Time.current,
      bankroll: empty_kalshi_paper_bankroll,
      open_predictions: 0,
      open_positions: [],
      outcome_exposure: [],
      open_contracts: 0,
      open_stake: 0.0,
      open_unrealized_profit: 0.0,
      today_settled_profit: 0.0,
      today_live_profit: 0.0,
      overall_live_profit: 0.0,
      next_close_at: nil,
      recent_closed: [],
      daily: []
    }
  end

  def empty_kalshi_profitability_summary(error = nil)
    {
      guard: {
        allowed: false,
        status: "unavailable",
        reason: error.presence || "portfolio safety status unavailable",
        consecutive_losses: nil,
        max_consecutive_losses: nil,
        cooldown_until: nil
      },
      live: {
        decided: 0,
        wins: 0,
        losses: 0,
        hit_rate: nil,
        risk: 0.0,
        open_risk: 0.0,
        realized_profit: 0.0,
        realized_roi: nil
      },
      paper: {
        decided: 0,
        wins: 0,
        losses: 0,
        hit_rate: nil,
        average_confidence: nil,
        calibration_gap: nil,
        brier_score: nil,
        fee_adjusted_roi: nil
      },
      review_auto: {
        decided: 0,
        wins: 0,
        losses: 0,
        hit_rate: nil,
        risk: 0.0,
        realized_profit: 0.0,
        realized_roi: nil
      },
      generated_at: Time.current
    }
  end

  def empty_kalshi_account_status(error = nil)
    {
      configured: false,
      connected: false,
      read_only: true,
      live_orders_enabled: false,
      autopilot_live_orders_enabled: false,
      balance_cents: nil,
      portfolio_value_cents: nil,
      deposits_count: 0,
      latest_deposit_cents: nil,
      latest_deposit_status: nil,
      latest_deposit_at: nil,
      checked_at: Time.current,
      error: error
    }
  end

  def empty_kalshi_divergence_watch(status)
    {
      generated_at: Time.current,
      status: status,
      rows: [],
      source_weights: [],
      thresholds: {}
    }
  end

  def paper_entry_price(row)
    value = row.ask.presence ||
      row.metadata.to_h["ask"].presence ||
      row.raw_payload.to_h.dig("paper_pick", "ask").presence ||
      row.raw_payload.to_h.dig("paper_pick", :ask).presence
    return nil if value.blank?

    price = value.to_f
    price = price / 100.0 if price > 1.0
    return nil unless price.positive?

    [price, 1.0].min
  end

  def paper_contract_count(row)
    entry = paper_bankroll_entry_for(row)
    return entry[:contracts].to_i if entry.present?

    count = row.size_label.to_s[/\d+/].to_i
    count.positive? ? count : 1
  end

  def paper_profit(result_status, price, contracts)
    case result_status.to_s
    when "won"
      (1.0 - price.to_f) * contracts.to_i
    when "lost"
      -price.to_f * contracts.to_i
    else
      0.0
    end
  end

  def paper_position_row(row)
    entry_price = paper_entry_price(row)
    contracts = paper_contract_count(row)
    return nil unless contracts.positive?

    current_price = paper_current_price(row) || entry_price
    stake = entry_price.to_f * contracts
    unrealized_profit = if entry_price.present? && current_price.present?
      (current_price.to_f - entry_price.to_f) * contracts
    else
      0.0
    end

    {
      id: row.id,
      market_ticker: row.market_ticker,
      title: row.market_title,
      city: row.city,
      state: row.state,
      outcome: row.market_band_label,
      side: row.side.presence || "YES",
      contracts: contracts,
      stake: stake.round(2),
      entry_price: entry_price,
      current_price: current_price,
      unrealized_profit: unrealized_profit.round(2),
      opportunity_tier: paper_bankroll_entry_for(row).to_h[:opportunity_tier],
      allocation_reason: paper_bankroll_entry_for(row).to_h[:allocation_reason],
      confidence: row.confidence,
      edge: row.edge,
      forecast_high_f: row.forecast_high_f,
      adjusted_high_f: row.adjusted_high_f,
      close_time: row.close_time,
      date: row.prediction_date || row.close_time&.in_time_zone&.to_date || row.created_at.to_date,
      rationale: row.rationale
    }
  end

  def kalshi_profitability_summary
    return empty_kalshi_profitability_summary unless defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?

    settled_live = live_wager_scope
      .where(status: %w[won lost pushed void])
      .order(Arel.sql("COALESCE(settled_at, kalshi_weather_wagers.updated_at) DESC"))
      .limit(120)
      .to_a
    live = weather_wager_performance(settled_live)
    review_auto = weather_wager_performance(settled_live.select { |wager| wager.opportunity_tier == "autopilot_review_auto" })

    paper_rows = current_organization.kalshi_weather_predictions
      .where(action: "paper_yes", result_status: %w[won lost])
      .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
      .limit(160)
      .to_a
    paper_wins = paper_rows.count { |row| row.result_status == "won" }
    paper_hit_rate = paper_rows.any? ? paper_wins.to_f / paper_rows.length : nil
    confidence_rows = paper_rows.select { |row| row.confidence.present? }
    average_confidence = confidence_rows.any? ? confidence_rows.sum { |row| row.confidence.to_f } / confidence_rows.length : nil
    brier_score = if confidence_rows.any?
      confidence_rows.sum do |row|
        outcome = row.result_status == "won" ? 1.0 : 0.0
        (row.confidence.to_f - outcome)**2
      end / confidence_rows.length
    end
    paper_risk = paper_rows.sum { |row| row.ask.to_f + weather_estimated_taker_fee(row.ask) }
    paper_profit = paper_rows.sum do |row|
      gross = row.result_status == "won" ? 1.0 - row.ask.to_f : -row.ask.to_f
      gross - weather_estimated_taker_fee(row.ask)
    end
    calibration_gap = if average_confidence.present? && paper_hit_rate.present?
      ((average_confidence - paper_hit_rate) * 100).round(1)
    end

    {
      guard: weather_autopilot.send(:portfolio_guard_status),
      live: live.merge(
        open_risk: live_wager_scope.open_journal.to_a.sum { |wager| wager.max_cost.to_f + live_wager_fee_paid(wager).to_f }.round(2)
      ),
      paper: {
        decided: paper_rows.length,
        wins: paper_wins,
        losses: paper_rows.length - paper_wins,
        hit_rate: paper_hit_rate&.*(100)&.round(1),
        average_confidence: average_confidence&.*(100)&.round(1),
        calibration_gap: calibration_gap,
        brier_score: brier_score&.round(3),
        fee_adjusted_roi: paper_risk.positive? ? ((paper_profit / paper_risk) * 100).round(1) : nil
      },
      review_auto: review_auto,
      generated_at: Time.current
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] profitability summary skipped: #{error.class}: #{error.message}")
    empty_kalshi_profitability_summary(error.message)
  end

  def weather_wager_performance(wagers)
    rows = Array(wagers)
    decided = rows.select { |wager| wager.display_result_status.in?(%w[won lost]) }
    wins = decided.count { |wager| wager.display_result_status == "won" }
    risk = decided.sum do |wager|
      cost = wager.actual_cost.to_f.positive? ? wager.actual_cost.to_f : wager.max_cost.to_f
      cost + live_wager_fee_paid(wager).to_f
    end
    profit = decided.sum { |wager| wager.realized_profit.to_f }

    {
      decided: decided.length,
      wins: wins,
      losses: decided.length - wins,
      hit_rate: decided.any? ? ((wins.to_f / decided.length) * 100).round(1) : nil,
      risk: risk.round(2),
      realized_profit: profit.round(2),
      realized_roi: risk.positive? ? ((profit / risk) * 100).round(1) : nil
    }
  end

  def kalshi_opportunity_board
    return [] unless defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?

    scope = current_organization.kalshi_weather_predictions
      .open_predictions
      .where("close_time IS NULL OR close_time > ?", 15.minutes.from_now)
    scope = scope.where("created_at >= ?", live_bankroll_tracking_started_at) if live_bankroll_tracking_started_at.present?

    rows = scope
      .order(Arel.sql("confidence DESC NULLS LAST, edge DESC NULLS LAST, ask ASC NULLS LAST, created_at DESC"))
      .limit(240)
      .to_a
      .map do |prediction|
        metadata = prediction.metadata.to_h
        gates = Array(metadata["gate_reasons"]).compact_blank
        recommendation = weather_opportunity_recommendation(prediction, metadata, gates)
        {
          prediction_id: prediction.id,
          city: prediction.city,
          state: prediction.state,
          market_ticker: prediction.market_ticker,
          side: prediction.side.presence || "YES",
          action: prediction.action,
          ask: prediction.ask,
          edge: prediction.edge,
          fee_per_contract: recommendation[:fee_per_contract].presence || weather_estimated_taker_fee(prediction.ask),
          net_edge: recommendation[:display_edge].presence || weather_fee_adjusted_edge(prediction.confidence, prediction.ask),
          confidence: recommendation[:calibrated_probability].presence || prediction.confidence,
          raw_confidence: prediction.confidence,
          source_count: metadata["forecast_source_count"],
          source_spread_f: metadata["forecast_source_spread_f"],
          gates: gates,
          recommendation: recommendation
        }
      end
    rows
      .sort_by { |row| [-row[:net_edge].to_f, -row[:confidence].to_f, row[:ask].to_f] }
      .first(14)
      .map.with_index(1) { |row, rank| row.merge(rank: rank) }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] opportunity board skipped: #{error.class}: #{error.message}")
    []
  end

  def weather_opportunity_recommendation(prediction, metadata, gates)
    guard = @kalshi_profitability_summary.to_h[:guard].to_h
    active = weather_calibration_engine.evaluate(prediction, strategy: :active, enforce_live_gate: false)
    challenger = weather_calibration_engine.evaluate(prediction, strategy: :challenger)
    display = active[:calibrated_probability].present? ? active : challenger
    shared = {
      calibrated_probability: display[:calibrated_probability],
      display_edge: display[:conservative_edge].presence || display[:point_edge],
      fee_per_contract: if display[:contracts].to_i.positive?
                          display[:estimated_fee].to_f / display[:contracts].to_i
                        end,
      training_events: display[:training_events]
    }.compact

    live_gate_allowed = weather_autopilot.send(:live_execution_allowed?)
    portfolio_allowed = guard.fetch(:allowed, false)
    if active[:ok] && live_gate_allowed && portfolio_allowed
      return shared.merge(
        label: "eligible",
        amount: Kalshi::WeatherAutopilot::HARD_LIVE_DAILY_CAP,
        tone: "green",
        reason: active.fetch(:reason)
      )
    end

    if active[:ok]
      live_reason = if !portfolio_allowed
        guard[:reason].presence || "portfolio safety pause"
      else
        weather_autopilot.send(:live_blocked_reason).presence || "live execution gate blocked"
      end
      return shared.merge(
        label: "paper-ready",
        amount: 0,
        tone: "cyan",
        reason: "Active-policy shadow qualifies; live remains blocked: #{live_reason}"
      )
    end

    if challenger[:ok]
      return shared.merge(
        label: "paper",
        amount: 0,
        tone: "cyan",
        reason: "paper challenger: #{challenger.fetch(:reason)}"
      )
    end

    shared.merge(
      label: "blocked",
      amount: 0,
      tone: "red",
      reason: active[:reason].presence || challenger[:reason].presence || gates.first.presence || "walk-forward calibration gate blocked"
    )
  end

  def weather_calibration_engine
    @weather_calibration_engine ||= Kalshi::WeatherCalibrationHarness.new(organization: current_organization)
  end

  def weather_execution_thresholds
    @weather_execution_thresholds ||= {
      min_edge: weather_autopilot.send(:min_edge),
      qualified_min_edge: weather_autopilot.send(:qualified_min_edge),
      min_confidence: weather_autopilot.send(:min_confidence),
      max_ask: weather_autopilot.send(:max_ask),
      max_source_spread_f: weather_autopilot.send(:max_source_spread_f)
    }
  end

  def weather_estimated_taker_fee(price)
    return 0.0 if price.blank?
    return Kalshi::WeatherAutopilot.estimated_taker_fee_per_contract(price) if defined?(Kalshi::WeatherAutopilot)

    price = price.to_f.clamp(0.0, 1.0)
    (0.07 * price * (1.0 - price)).round(4)
  end

  def weather_fee_adjusted_edge(confidence, price)
    confidence.to_f - price.to_f - weather_estimated_taker_fee(price)
  end

  def live_wager_scope
    scope = current_organization.kalshi_weather_wagers.where(execution_mode: "live")
    scope = scope.where("kalshi_weather_wagers.created_at >= ?", live_bankroll_tracking_started_at) if live_bankroll_tracking_started_at.present?
    scope
  end

  def live_weather_budget_summary
    return {} unless defined?(Kalshi::WeatherAutopilot)

    autopilot = weather_autopilot
    {
      daily_budget: autopilot.send(:daily_cap),
      min_daily_spend: autopilot.send(:min_daily_spend),
      reserve_balance: autopilot.send(:remaining_budget, Date.current).round(2),
      total_credited: autopilot.send(:accrued_budget, Date.current).round(2),
      total_simulated_staked: autopilot.send(:budgeted_spend, Date.current).round(2),
      tracking_started_at: autopilot.send(:tracking_started_at)&.iso8601,
      live_tracking: true,
      paper_only: false,
      execution_policy: "Live Kalshi order tracker. Today gets one daily budget; unused dollars do not roll into tomorrow."
    }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] live budget summary skipped: #{error.class}: #{error.message}")
    {}
  end

  def live_wager_position_rows
    return [] unless defined?(KalshiWeatherWager) && KalshiWeatherWager.storage_ready?

    live_wager_scope
      .open_journal
      .includes(:kalshi_weather_prediction)
      .order(Arel.sql("COALESCE(filled_at, placed_at, kalshi_weather_wagers.updated_at) DESC"))
      .limit(160)
      .filter_map { |wager| live_wager_position_row(wager) }
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] live wager positions skipped: #{error.class}: #{error.message}")
    []
  end

  def live_wager_position_row(wager)
    prediction = wager.kalshi_weather_prediction
    kalshi_position = live_kalshi_positions_by_ticker[wager.market_ticker].to_h
    position_contracts = live_position_number(kalshi_position, "position_fp", "position").to_i
    wager_contracts = [wager.filled_contracts.to_i, wager.contracts.to_i].max
    contracts = [position_contracts, wager_contracts].max
    return nil unless contracts.positive?

    entry_price = wager.price.presence || prediction&.ask
    return nil if entry_price.blank?

    entry_price = entry_price.to_f
    live_position_synced = kalshi_position.present? && position_contracts >= [wager_contracts, 1].max
    live_position_pending = kalshi_position.present? && position_contracts.positive? && !live_position_synced
    raw_kalshi_mark = live_position_number(kalshi_position, "market_exposure_dollars", "market_value_dollars")
    kalshi_mark = raw_kalshi_mark if live_position_synced
    fees_paid = (live_position_number(kalshi_position, "fees_paid_dollars", "fees_paid") || live_wager_fee_paid(wager)).to_f
    current_price = if kalshi_mark.present? && position_contracts.positive?
      kalshi_mark.to_f / position_contracts
    elsif live_position_pending || kalshi_position.blank?
      entry_price
    elsif prediction.present?
      paper_current_price(prediction) || entry_price
    else
      entry_price
    end
    stake = (wager.actual_cost.presence || wager.max_cost.presence || live_position_number(kalshi_position, "total_traded_dollars") || (entry_price * contracts)).to_f
    unrealized_profit = if kalshi_mark.present?
      kalshi_mark.to_f - stake - fees_paid
    elsif live_position_pending || kalshi_position.blank?
      -fees_paid
    else
      (current_price.to_f * contracts) - stake - fees_paid
    end
    mark_source = if kalshi_mark.present?
      "kalshi_position"
    elsif live_position_pending
      "pending_kalshi_position_sync"
    elsif kalshi_position.blank?
      "kalshi_position_unavailable"
    else
      "stored_market_quote"
    end

    {
      id: "W#{wager.id}",
      market_ticker: wager.market_ticker,
      title: prediction&.market_title,
      city: prediction&.city,
      state: prediction&.state,
      outcome: prediction&.market_band_label || "range pending",
      side: wager.side.presence || prediction&.side.presence || "YES",
      contracts: contracts,
      stake: stake.round(2),
      fees_paid: fees_paid.round(2),
      entry_price: entry_price,
      current_price: current_price,
      unrealized_profit: unrealized_profit.round(2),
      opportunity_tier: wager.opportunity_tier,
      allocation_reason: wager.reason,
      confidence: prediction&.confidence,
      edge: prediction&.edge,
      forecast_high_f: prediction&.forecast_high_f,
      adjusted_high_f: prediction&.adjusted_high_f,
      close_time: prediction&.close_time,
      date: wager.budget_date || prediction&.prediction_date || prediction&.close_time&.in_time_zone&.to_date || wager.created_at.to_date,
      rationale: wager.reason,
      source: "live_order",
      status: wager.status,
      mark_source: mark_source
    }
  end

  def live_kalshi_positions_by_ticker
    @live_kalshi_positions_by_ticker ||= if defined?(Kalshi::AccountClient)
      Kalshi::AccountClient.market_positions_by_ticker
    else
      {}
    end
  rescue StandardError => error
    Rails.logger.warn("[WeatherController] Kalshi live positions skipped: #{error.class}: #{error.message}")
    {}
  end

  def live_position_number(position, *keys)
    raw = keys.filter_map { |key| position[key].presence || position[key.to_sym].presence }.first
    return nil if raw.blank?

    raw.to_f
  end

  def live_wager_fee_paid(wager)
    metadata_fee = live_position_number(wager.metadata.to_h, "live_fees_paid", "fees_paid_dollars", "fees_paid")
    return metadata_fee if metadata_fee.present?

    Array(wager.raw_payload.to_h["order_responses"]).sum { |response| live_order_response_fee(response) }.round(2)
  end

  def live_order_response_fee(response)
    response = response.to_h
    total_fee = live_position_number(response, "fees_paid_dollars", "fee_paid_dollars", "total_fee_paid", "fee_paid")
    return total_fee if total_fee.present?

    average_fee = live_position_number(response, "average_fee_paid", "avg_fee_paid")
    return 0.0 if average_fee.blank?

    fill_count = live_position_number(response, "fill_count", "filled_count", "fill_count_fp", "filled_count_fp").to_f
    (average_fee.to_f * fill_count).round(4)
  end

  def live_wager_closed_row(wager)
    prediction = wager.kalshi_weather_prediction
    contracts = [wager.filled_contracts.to_i, wager.contracts.to_i].max
    stake = (wager.actual_cost.presence || wager.max_cost.presence || 0).to_f
    {
      id: "W#{wager.id}",
      city: prediction&.city,
      state: prediction&.state,
      outcome: prediction&.market_band_label || wager.market_ticker,
      result: wager.status,
      profit: wager.realized_profit.to_f.round(2),
      contracts: contracts,
      stake: stake.round(2),
      opportunity_tier: wager.opportunity_tier,
      date: wager.settled_at&.in_time_zone&.to_date || wager.updated_at.to_date
    }
  end

  def live_wager_daily_rows(wagers)
    cumulative = 0.0
    Array(wagers)
      .group_by { |wager| wager.settled_at&.in_time_zone&.to_date || wager.updated_at.to_date }
      .sort_by { |date, _rows| date || Date.current }
      .map do |date, rows|
        daily_profit = rows.sum { |wager| wager.realized_profit.to_f }
        cumulative += daily_profit
        {
          date: date,
          daily_profit: daily_profit.round(2),
          cumulative_profit: cumulative.round(2),
          stake: rows.sum { |wager| (wager.actual_cost.presence || wager.max_cost.presence || 0).to_f }.round(2),
          count: rows.sum { |wager| [wager.filled_contracts.to_i, wager.contracts.to_i].max },
          wins: rows.count { |wager| wager.status.to_s == "won" },
          losses: rows.count { |wager| wager.status.to_s == "lost" }
        }
      end
  end

  def weather_outcome_exposure_for(positions)
    Array(positions)
      .group_by { |row| [row[:city], row[:state], row[:outcome], row[:side]] }
      .map do |(city, state, outcome, side), rows|
        {
          city: city,
          state: state,
          outcome: outcome,
          side: side,
          contracts: rows.sum { |row| row[:contracts].to_i },
          stake: rows.sum { |row| row[:stake].to_f }.round(2),
          fees_paid: rows.sum { |row| row[:fees_paid].to_f }.round(2),
          unrealized_profit: rows.sum { |row| row[:unrealized_profit].to_f }.round(2),
          next_close_at: rows.filter_map { |row| row[:close_time] }.min,
          rows: rows.length
        }
      end
      .sort_by { |row| [row[:next_close_at] || 10.years.from_now, -row[:contracts].to_i, row[:city].to_s] }
  end

  def paper_closed_row(row)
    price = paper_entry_price(row)
    return nil if price.blank?

    contracts = paper_contract_count(row)
    {
      id: row.id,
      city: row.city,
      state: row.state,
      outcome: row.market_band_label,
      result: row.result_status,
      profit: paper_profit(row.result_status, price, contracts).round(2),
      contracts: contracts,
      stake: (price * contracts).round(2),
      opportunity_tier: paper_bankroll_entry_for(row).to_h[:opportunity_tier],
      date: row.prediction_date || row.close_time&.in_time_zone&.to_date || row.updated_at.to_date
    }
  end

  def paper_bankroll_simulation
    @paper_bankroll_simulation ||= if defined?(Kalshi::PaperBankrollSimulator) && defined?(KalshiWeatherPrediction) && KalshiWeatherPrediction.storage_ready?
      Kalshi::PaperBankrollSimulator.call(
        rows: paper_bankroll_rows,
        start_date: live_bankroll_tracking_started_at&.to_date,
        tracking_started_at: live_bankroll_tracking_started_at,
        seed_bankroll: Kalshi::PaperBankrollSimulator.live_seed_bankroll
      )
    else
      empty_kalshi_paper_bankroll.merge(entries: [], entries_by_id: {}, daily: [])
    end
  end

  def paper_bankroll_rows
    @paper_bankroll_rows ||= begin
      scope = current_organization.kalshi_weather_predictions.where(action: "paper_yes")
      scope = scope.where("created_at >= ?", live_bankroll_tracking_started_at) if live_bankroll_tracking_started_at.present?
      scope
      .order(:prediction_date, :close_time, :id)
      .limit(720)
      .to_a
    end
  end

  def live_bankroll_tracking_started_at
    @live_bankroll_tracking_started_at ||= if defined?(Kalshi::PaperBankrollSimulator)
      Kalshi::PaperBankrollSimulator.live_tracking_started_at
    end
  end

  def paper_bankroll_entry_for(row)
    return {} if row.blank?

    paper_bankroll_simulation[:entries_by_id].to_h[row.id] || {}
  end

  def paper_bankroll_summary(simulation)
    simulation.to_h.slice(
      :daily_budget,
      :half_day_budget,
      :reserve_deploy_threshold,
      :reserve_balance,
      :tracking_started_at,
      :seed_bankroll,
      :total_credited,
      :strong_edge,
      :strong_confidence,
      :strong_source_spread_f,
      :strong_max_ask,
      :paper_only,
      :live_tracking,
      :execution_policy
    ).merge(
      recent_days: Array(simulation[:daily]).last(7),
      total_simulated_staked: (simulation[:total_risk].presence || simulation[:total_staked]).to_f.round(2),
      total_simulated_fees: simulation[:total_fees].to_f.round(2),
      fees_included: simulation[:fees_included] == true,
      total_simulated_profit: simulation[:total_profit].to_f.round(2),
      roi_percent: simulation[:roi_percent]
    )
  end

  def empty_kalshi_paper_bankroll
    {
      daily_budget: 20.0,
      half_day_budget: 0.0,
      qualified_budget: 0.0,
      reserve_deploy_threshold: 20.0,
      reserve_balance: 0.0,
      tracking_started_at: defined?(Kalshi::PaperBankrollSimulator) ? Kalshi::PaperBankrollSimulator.live_tracking_started_at&.iso8601 : nil,
      seed_bankroll: defined?(Kalshi::PaperBankrollSimulator) ? Kalshi::PaperBankrollSimulator.live_seed_bankroll : 100.0,
      total_credited: 0.0,
      strong_edge: nil,
      strong_confidence: nil,
      strong_source_spread_f: nil,
      strong_max_ask: nil,
      recent_days: [],
      total_simulated_staked: 0.0,
      total_simulated_fees: 0.0,
      fees_included: true,
      total_simulated_profit: 0.0,
      roi_percent: nil,
      paper_only: true,
      live_tracking: true,
      execution_policy: "Tracking simulation only. No deposits, orders, or real-money wagers are created by this code."
    }
  end

  def paper_current_price(row)
    market = paper_market_snapshot(row)
    value = market_value_for(market, "yes_bid", :yes_bid) ||
      market_value_for(market, "last_price", :last_price) ||
      market_value_for(market, "yes_ask", :yes_ask) ||
      row.metadata.to_h["yes_bid"].presence ||
      row.metadata.to_h["last_price"].presence ||
      row.ask.presence
    normalize_paper_price(value)
  end

  def paper_market_snapshot(row)
    payload = row.raw_payload.to_h
    markets = Array(payload["markets"] || payload[:markets])
    markets.find do |market|
      market_value_for(market, "ticker", :ticker).to_s == row.market_ticker.to_s
    end || payload["paper_pick"] || payload[:paper_pick] || {}
  end

  def market_value_for(hash, *keys)
    hash = hash.to_h
    keys.each do |key|
      value = hash[key]
      return value if value.present?
    end
    nil
  end

  def normalize_paper_price(value)
    return nil if value.blank?

    price = value.to_f
    price = price / 100.0 if price > 1.0
    return nil unless price.positive?

    [price, 1.0].min
  end

  def finalize_source_learning_row(row)
    seen = row[:seen].to_i
    wins = row[:wins].to_i
    losses = row[:losses].to_i
    errors = Array(row[:errors]).compact.map(&:to_f)
    {
      label: row[:label],
      seen: seen,
      wins: wins,
      losses: losses,
      hit_rate: (wins + losses).positive? ? ((wins.to_f / (wins + losses)) * 100).round(1) : nil,
      avg_abs_error_f: errors.present? ? (errors.sum / errors.length).round(1) : nil
    }
  end
end
