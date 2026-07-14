class KalshiWeatherPrediction < ApplicationRecord
  ACTIONS = %w[paper_yes watch].freeze
  STATUSES = %w[open closed settled stale].freeze
  RESULT_STATUSES = %w[pending won lost pushed void error].freeze
  MISS_CAUSE_LABELS = {
    "won" => "Inside market band",
    "pending_actual" => "Actual high missing",
    "stale_forecast" => "Stale forecast",
    "bad_local_adjustment" => "Bad local adjustment",
    "storm_or_heat_signal_wrong" => "Storm/heat signal wrong",
    "bad_market_band" => "Wrong market band",
    "market_moved_untracked" => "Market moved / price untracked",
    "small_weather_variance" => "Small weather variance",
    "kalshi_outcome_no_actual" => "Kalshi outcome without actual high"
  }.freeze

  belongs_to :organization
  has_many :kalshi_weather_wagers, dependent: :destroy
  has_many :kalshi_weather_prediction_snapshots, dependent: :destroy

  before_validation :normalize_fields

  validates :series_ticker, :market_ticker, :city, :prediction_date, presence: true
  validates :market_ticker, uniqueness: { scope: :organization_id }
  validates :action, inclusion: { in: ACTIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :result_status, inclusion: { in: RESULT_STATUSES }

  scope :recent_first, -> { order(Arel.sql("COALESCE(close_time, created_at) DESC")) }
  scope :open_predictions, -> { where(status: "open", result_status: "pending") }
  scope :paper_yes, -> { where(action: "paper_yes") }
  scope :watch, -> { where(action: "watch") }

  def self.storage_ready?
    table_exists?
  rescue ActiveRecord::StatementInvalid
    false
  end

  def self.event_date_from_ticker(ticker)
    match = ticker.to_s.upcase.match(/-(\d{2})([A-Z]{3})(\d{2})\b/)
    return nil unless match

    month = Date::ABBR_MONTHNAMES.index(match[2].capitalize)
    return nil if month.blank?

    Date.new(2000 + match[1].to_i, month, match[3].to_i)
  rescue ArgumentError
    nil
  end

  def action_label
    action.to_s.tr("_", " ")
  end

  def primary_weather_wager
    kalshi_weather_wagers.live.recent_first.first || kalshi_weather_wagers.paper.recent_first.first
  end

  def edge_points
    return nil if edge.blank?

    (edge.to_d * 100).round(1)
  end

  def market_band_label
    if market_floor_strike.present? && market_cap_strike.present?
      "#{format_temperature(market_floor_strike)}-#{format_temperature(market_cap_strike)}F"
    elsif market_floor_strike.present?
      "above #{format_temperature(market_floor_strike)}F"
    elsif market_cap_strike.present?
      "under #{format_temperature(market_cap_strike)}F"
    else
      market_range.presence || "range pending"
    end
  end

  def observed_inside_market?
    return nil if observed_high_f.blank?

    high = observed_high_f.to_f
    return high >= market_floor_strike.to_f && high <= market_cap_strike.to_f if market_floor_strike.present? && market_cap_strike.present?
    return high > market_floor_strike.to_f if market_floor_strike.present?
    return high < market_cap_strike.to_f if market_cap_strike.present?

    nil
  end

  def adjusted_error_f
    return nil if observed_high_f.blank? || adjusted_high_f.blank?

    (observed_high_f.to_f - adjusted_high_f.to_f).round(1)
  end

  def forecast_error_f
    return nil if observed_high_f.blank? || forecast_high_f.blank?

    (observed_high_f.to_f - forecast_high_f.to_f).round(1)
  end

  def market_distance_f
    return nil if observed_high_f.blank?

    high = observed_high_f.to_f
    if market_floor_strike.present? && market_cap_strike.blank? && high <= market_floor_strike.to_f
      ((market_floor_strike.to_f + 1.0) - high).round(1)
    elsif market_cap_strike.present? && market_floor_strike.blank? && high >= market_cap_strike.to_f
      (high - (market_cap_strike.to_f - 1.0)).round(1)
    elsif market_floor_strike.present? && high < market_floor_strike.to_f
      (market_floor_strike.to_f - high).round(1)
    elsif market_cap_strike.present? && high > market_cap_strike.to_f
      (high - market_cap_strike.to_f).round(1)
    else
      0.0
    end
  end

  def miss_cause
    metadata.to_h["miss_cause"].presence
  end

  def miss_cause_label
    metadata.to_h["miss_cause_label"].presence || MISS_CAUSE_LABELS[miss_cause] || "Unscored"
  end

  def actual_high_source_label
    metadata.to_h["actual_high_source"].presence ||
      metadata.to_h["scoring_source"].presence ||
      "pending"
  end

  def score_from_observed!(observed_high:, settlement_value: nil, source: nil, payload: {}, official_outcome: nil)
    self.observed_high_f = observed_high.to_i
    inside = observed_inside_market?
    normalized_outcome = official_outcome.to_s.downcase
    official_result = if normalized_outcome.in?(%w[yes won true])
      "won"
    elsif normalized_outcome.in?(%w[no lost false])
      "lost"
    end
    self.status = "settled"
    self.result_status = official_result || (inside.nil? ? "pushed" : inside ? "won" : "lost")
    self.settlement_value = settlement_value.to_s.squish.presence || "#{observed_high_f}F"
    miss = classify_miss_cause
    scoring_metadata = {
      "scored_at" => Time.current.iso8601,
      "scoring_source" => source.to_s.presence || "probability_lab",
      "actual_high_source" => source.to_s.presence || "probability_lab",
      "forecast_error_f" => forecast_error_f,
      "adjusted_error_f" => adjusted_error_f,
      "market_distance_f" => market_distance_f,
      "observed_inside_market" => inside,
      "miss_cause" => miss.fetch(:key),
      "miss_cause_label" => miss.fetch(:label),
      "miss_cause_reason" => miss.fetch(:reason),
      "scoring_payload" => payload.to_h.slice(
        "status", "result", "settlement_value", "expiration_value", "settled_time",
        "station_id", "station_name", "observed_at", "high_f", "features_checked",
        "yes_bid", "yes_ask", "last_price", "last_price_dollars", "market_snapshot"
      )
    }
    if official_result.present?
      scoring_metadata.merge!(
        "official_market_reconciled_at" => Time.current.iso8601,
        "official_market_result" => normalized_outcome,
        "official_result_status" => official_result,
        "observed_inside_market" => official_result == "won"
      )
    end
    self.metadata = metadata.to_h.merge(scoring_metadata)
    self.training_note = training_note_for_score
    save!
  end

  def mark_settled_by_outcome!(outcome:, settlement_value: nil, source: nil, payload: {})
    normalized = outcome.to_s.downcase
    return false unless normalized.in?(%w[yes no won lost true false])

    yes_won = normalized.in?(%w[yes won true])
    self.status = "settled"
    self.result_status = yes_won ? "won" : "lost"
    self.settlement_value = settlement_value.to_s.squish.presence || normalized
    self.metadata = metadata.to_h.merge(
      "scored_at" => Time.current.iso8601,
      "scoring_source" => source.to_s.presence || "kalshi_market_outcome",
      "official_market_reconciled_at" => Time.current.iso8601,
      "official_market_result" => normalized,
      "official_result_status" => yes_won ? "won" : "lost",
      "observed_inside_market" => yes_won,
      "miss_cause" => yes_won ? "won" : "kalshi_outcome_no_actual",
      "miss_cause_label" => yes_won ? MISS_CAUSE_LABELS.fetch("won") : MISS_CAUSE_LABELS.fetch("kalshi_outcome_no_actual"),
      "miss_cause_reason" => yes_won ? "Kalshi settled YES without an observed high value." : "Kalshi settled NO without a usable observed high; backfill actual temperature before trusting the miss distance.",
      "scoring_payload" => payload.to_h.slice(
        "status", "result", "settlement_value", "expiration_value", "settled_time",
        "yes_bid", "yes_ask", "last_price", "last_price_dollars", "market_snapshot"
      )
    )
    self.training_note = training_note_for_score
    save!
  end

  def refresh_score_metadata!
    return false if result_status == "pending"

    miss = if observed_high_f.present?
      classify_miss_cause
    elsif result_status == "won"
      cause("won", "Kalshi settled YES without an observed high value.")
    else
      cause("kalshi_outcome_no_actual", "Kalshi settled without a usable observed high; backfill actual temperature before trusting the miss distance.")
    end

    self.metadata = metadata.to_h.merge(
      "score_metadata_refreshed_at" => Time.current.iso8601,
      "forecast_error_f" => forecast_error_f,
      "adjusted_error_f" => adjusted_error_f,
      "market_distance_f" => market_distance_f,
      "observed_inside_market" => observed_inside_market?,
      "miss_cause" => miss.fetch(:key),
      "miss_cause_label" => miss.fetch(:label),
      "miss_cause_reason" => miss.fetch(:reason)
    )
    self.training_note = training_note_for_score
    save!
  end

  private

  def format_temperature(value)
    number = value.to_f
    number == number.round ? number.round.to_s : number.round(1).to_s
  end

  def training_note_for_score
    if observed_high_f.present?
      distance = market_distance_f.to_f
      if result_status == "won"
        "Paper thesis won. Actual high #{observed_high_f}F landed inside #{market_band_label}; AUTOS forecast error #{adjusted_error_f || 'n/a'}F."
      else
        cause = miss_cause_label
        reason = metadata.to_h["miss_cause_reason"].presence
        "Paper thesis missed by #{distance}F from #{market_band_label}. Cause: #{cause}. #{reason} Store this gap against Weather.gov forecast, AUTOS adjustment, and Kalshi pricing before sizing future wagers.".squish
      end
    elsif result_status == "won"
      "Paper thesis won by Kalshi settlement. Store as positive calibration, but prefer actual high capture for temperature-distance training."
    else
      "Paper thesis lost by Kalshi settlement. Cause: #{miss_cause_label}. Prefer actual high capture for temperature-distance training."
    end
  end

  def classify_miss_cause
    return cause("won", "Actual high landed inside the selected market band.") if result_status == "won"
    return cause("pending_actual", "No actual observed high is available yet.") if observed_high_f.blank?

    adjusted_error = adjusted_error_f&.abs
    forecast_error = forecast_error_f&.abs
    local_adjustment = local_adjustment_f
    signal_text = [
      metadata.to_h["forecast_short"],
      metadata.to_h["forecast_period"],
      metadata.to_h["local_signal_summary"],
      raw_payload.to_h.dig("study_row", "forecast", "short_forecast"),
      raw_payload.to_h.dig("study_row", "forecast", "detailed_forecast")
    ].compact.join(" ")

    if local_adjustment.to_f.nonzero? && adjusted_error.present? && forecast_error.present? && adjusted_error >= forecast_error + 1.0
      return cause(
        signal_text.match?(/heat|storm|thunder|rain|flood|cold|freeze|frost/i) ? "storm_or_heat_signal_wrong" : "bad_local_adjustment",
        "The local #{local_adjustment.positive? ? 'upward' : 'downward'} adjustment moved the forecast farther from the actual high."
      )
    end

    if forecast_error.present? && forecast_error >= 4.0 && adjusted_error.present? && adjusted_error >= 3.0
      return cause("stale_forecast", "The base Weather.gov forecast was #{forecast_error.round(1)}F away from the observed high.")
    end

    if adjusted_error.present? && adjusted_error <= 2.0 && market_distance_f.to_f >= 2.0
      return cause("bad_market_band", "AUTOS' adjusted high was close, but the selected market band was still outside the actual result.")
    end

    if metadata.to_h["market_price_moved"].present?
      return cause("market_moved_untracked", metadata.to_h["market_price_moved"].to_s)
    end

    cause("small_weather_variance", "The miss is scored, but no dominant cause is proven yet; keep it in the calibration sample.")
  end

  def cause(key, reason)
    { key: key, label: MISS_CAUSE_LABELS.fetch(key, key.to_s.humanize), reason: reason.to_s.squish }
  end

  def local_adjustment_f
    return 0.0 if adjusted_high_f.blank? || forecast_high_f.blank?

    adjusted_high_f.to_f - forecast_high_f.to_f
  end

  def normalize_fields
    self.series_ticker = series_ticker.to_s.strip.upcase
    self.event_ticker = event_ticker.to_s.strip.upcase.presence
    self.market_ticker = market_ticker.to_s.strip.upcase
    self.city = city.to_s.squish
    self.state = state.to_s.strip.upcase.presence
    self.market_title = market_title.to_s.squish.presence
    self.market_range = market_range.to_s.squish.presence
    self.action = action.to_s.strip.downcase.tr(" ", "_").presence || "watch"
    self.action = "watch" unless ACTIONS.include?(action)
    self.side = side.to_s.strip.upcase.presence || "YES"
    self.size_label = size_label.to_s.squish.presence || "0 contracts"
    self.rationale = rationale.to_s.squish.presence
    self.training_note = training_note.to_s.squish.presence
    self.status = status.to_s.strip.downcase.presence || "open"
    self.status = "open" unless STATUSES.include?(status)
    self.result_status = result_status.to_s.strip.downcase.presence || "pending"
    self.result_status = "pending" unless RESULT_STATUSES.include?(result_status)
    self.raw_payload = raw_payload.to_h
    self.metadata = metadata.to_h
    self.prediction_date ||= self.class.event_date_from_ticker(event_ticker.presence || market_ticker) || close_time&.in_time_zone&.to_date || Date.current
  end
end
