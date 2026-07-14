module Kalshi
  class WeatherDivergenceEngine
    DEFAULT_LIMIT = 12
    MAX_LOOKBACK = 240
    MIN_SOURCE_SPREAD_F = 1.5
    MIN_MARKET_GAP_F = 1.0
    MIN_WEAKNESS_GAP = 0.08

    class << self
      def call(organization:, limit: DEFAULT_LIMIT)
        new(organization: organization, limit: limit).call
      end
    end

    def initialize(organization:, limit:)
      @organization = organization
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
    end

    def call
      return empty_result("prediction storage not ready") unless storage_ready?

      source_stats = build_source_stats(scored_rows)
      open_rows = organization.kalshi_weather_predictions
        .open_predictions
        .order(Arel.sql("COALESCE(close_time, updated_at) ASC"))
        .limit(80)
        .to_a

      rows = open_rows.filter_map { |prediction| divergence_row(prediction, source_stats) }
        .sort_by { |row| [-row[:alert_score].to_f, row[:close_time].to_s, row[:city].to_s] }
        .first(limit)

      {
        generated_at: Time.current,
        status: rows.present? ? "watching_divergence" : "waiting_for_live_divergence",
        rows: rows,
        source_weights: source_weight_rows(source_stats).first(8),
        thresholds: {
          min_source_spread_f: MIN_SOURCE_SPREAD_F,
          min_market_gap_f: MIN_MARKET_GAP_F,
          min_weakness_gap: MIN_WEAKNESS_GAP
        }
      }
    end

    private

    attr_reader :organization, :limit

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        organization.respond_to?(:kalshi_weather_predictions)
    end

    def empty_result(status)
      {
        generated_at: Time.current,
        status: status,
        rows: [],
        source_weights: [],
        thresholds: {
          min_source_spread_f: MIN_SOURCE_SPREAD_F,
          min_market_gap_f: MIN_MARKET_GAP_F,
          min_weakness_gap: MIN_WEAKNESS_GAP
        }
      }
    end

    def scored_rows
      organization.kalshi_weather_predictions
        .where(result_status: %w[won lost])
        .where.not(observed_high_f: nil)
        .order(Arel.sql("COALESCE(close_time, updated_at) DESC"))
        .limit(MAX_LOOKBACK)
        .to_a
    end

    def build_source_stats(rows)
      stats = Hash.new { |hash, key| hash[key] = { label: key, seen: 0, wins: 0, losses: 0, errors: [] } }
      rows.each do |row|
        forecast_sources(row).each do |source|
          high = source[:high_f]
          next if high.blank?

          label = source[:label]
          stats[label][:seen] += 1
          stats[label][row.result_status == "won" ? :wins : :losses] += 1
          stats[label][:errors] << (high.to_f - row.observed_high_f.to_f).abs
        end
      end
      stats
    end

    def divergence_row(prediction, source_stats)
      sources = forecast_sources(prediction)
      return nil if sources.length < 2

      readings = sources.filter_map do |source|
        high = source[:high_f]
        next if high.blank?

        reliability = reliability_for(source[:label], source_stats)
        source.merge(
          high_f: high.to_f,
          reliability_score: reliability[:score],
          avg_abs_error_f: reliability[:avg_abs_error_f],
          hit_rate: reliability[:hit_rate],
          sample_size: reliability[:seen],
          weight: reliability[:weight]
        )
      end
      return nil if readings.length < 2

      source_spread = readings.map { |source| source[:high_f] }.max - readings.map { |source| source[:high_f] }.min
      market_midpoint = market_midpoint_for(prediction)
      consensus = weighted_consensus(readings)
      return nil if market_midpoint.blank? || consensus.blank?

      closest_to_market = readings.min_by { |source| (source[:high_f] - market_midpoint).abs }
      strongest_source = readings.max_by { |source| source[:reliability_score].to_f }
      weakest_outlier = readings.max_by { |source| (source[:high_f] - consensus).abs }
      weakness_gap = strongest_source[:reliability_score].to_f - closest_to_market[:reliability_score].to_f
      market_gap = (consensus - market_midpoint).abs
      market_closer_to_weaker = closest_to_market[:label] != strongest_source[:label] &&
        weakness_gap >= MIN_WEAKNESS_GAP &&
        market_gap >= MIN_MARKET_GAP_F
      actionable_divergence = source_spread >= MIN_SOURCE_SPREAD_F && market_closer_to_weaker
      direction = consensus >= market_midpoint ? "consensus warmer than Kalshi" : "consensus cooler than Kalshi"
      band_position = market_band_position(prediction, consensus)
      alert_score = [
        (source_spread * 11.0) +
          (market_gap * 14.0) +
          (weakness_gap * 100.0) +
          (actionable_divergence ? 20.0 : 0.0),
        99.0
      ].min.round

      {
        id: prediction.id,
        city: prediction.city,
        state: prediction.state,
        prediction_date: prediction.prediction_date,
        close_time: prediction.close_time,
        market: prediction.market_band_label,
        market_midpoint_f: market_midpoint.round(1),
        consensus_high_f: consensus.round(1),
        autos_adjusted_high_f: prediction.adjusted_high_f,
        source_spread_f: source_spread.round(1),
        market_gap_f: market_gap.round(1),
        direction: direction,
        band_position: band_position,
        closest_market_source: source_payload(closest_to_market),
        strongest_source: source_payload(strongest_source),
        weakest_outlier_source: source_payload(weakest_outlier),
        market_closer_to_weaker_source: market_closer_to_weaker,
        paper_signal: actionable_divergence ? paper_signal_for(direction, band_position) : "watch only",
        alert_score: alert_score,
        explanation: explanation_for(
          actionable: actionable_divergence,
          closest: closest_to_market,
          strongest: strongest_source,
          source_spread: source_spread,
          market_gap: market_gap,
          direction: direction
        ),
        sources: readings.sort_by { |source| -source[:reliability_score].to_f }.map { |source| source_payload(source) }
      }
    end

    def source_weight_rows(source_stats)
      source_stats.values.map do |row|
        reliability = reliability_for(row[:label], source_stats)
        {
          label: row[:label],
          seen: row[:seen],
          wins: row[:wins],
          losses: row[:losses],
          hit_rate: reliability[:hit_rate],
          avg_abs_error_f: reliability[:avg_abs_error_f],
          reliability_score: reliability[:score]
        }
      end.sort_by { |row| [-row[:reliability_score].to_f, -(row[:seen] || 0).to_i] }
    end

    def forecast_sources(row)
      Array(row.metadata.to_h["forecast_sources"]).filter_map do |source|
        data = source.to_h
        high = data["high_f"].presence || data[:high_f].presence
        next if high.blank?

        {
          key: data["key"].presence || data[:key].presence,
          label: data["label"].presence || data[:label].presence || data["key"].presence || "Unknown source",
          high_f: high.to_f,
          summary: data["summary"].presence || data[:summary].presence,
          period: data["period"].presence || data[:period].presence
        }
      end
    end

    def reliability_for(label, source_stats)
      row = source_stats[label.to_s]
      seen = row&.fetch(:seen, 0).to_i
      wins = row&.fetch(:wins, 0).to_i
      losses = row&.fetch(:losses, 0).to_i
      errors = Array(row&.fetch(:errors, [])).compact.map(&:to_f)
      avg_error = errors.present? ? (errors.sum / errors.length) : nil
      hit_rate = (wins + losses).positive? ? ((wins.to_f / (wins + losses)) * 100).round(1) : nil
      error_component = avg_error.present? ? 1.0 / (avg_error + 1.0) : 0.18
      hit_component = hit_rate.present? ? (0.55 + (hit_rate / 100.0)) : 0.82
      sample_component = [[seen / 8.0, 1.0].min, 0.35].max
      score = (error_component * hit_component * sample_component).round(4)
      {
        seen: seen,
        hit_rate: hit_rate,
        avg_abs_error_f: avg_error&.round(1),
        score: score,
        weight: [score, 0.04].max
      }
    end

    def weighted_consensus(readings)
      total_weight = readings.sum { |source| source[:weight].to_f }
      return nil unless total_weight.positive?

      readings.sum { |source| source[:high_f].to_f * source[:weight].to_f } / total_weight
    end

    def market_midpoint_for(prediction)
      return prediction.market_midpoint_f.to_f if prediction.market_midpoint_f.present?
      return ((prediction.market_floor_strike.to_f + prediction.market_cap_strike.to_f) / 2.0) if prediction.market_floor_strike.present? && prediction.market_cap_strike.present?
      return prediction.market_floor_strike.to_f if prediction.market_floor_strike.present?
      return prediction.market_cap_strike.to_f if prediction.market_cap_strike.present?

      nil
    end

    def market_band_position(prediction, consensus)
      return "inside Kalshi band" if prediction.market_floor_strike.present? && prediction.market_cap_strike.present? && consensus >= prediction.market_floor_strike.to_f && consensus <= prediction.market_cap_strike.to_f
      return "above Kalshi band" if prediction.market_cap_strike.present? && consensus > prediction.market_cap_strike.to_f
      return "below Kalshi band" if prediction.market_floor_strike.present? && consensus < prediction.market_floor_strike.to_f

      "against market midpoint"
    end

    def paper_signal_for(direction, band_position)
      if band_position == "above Kalshi band"
        "paper warmer watch"
      elsif band_position == "below Kalshi band"
        "paper cooler watch"
      elsif direction.include?("warmer")
        "paper warmer lean"
      else
        "paper cooler lean"
      end
    end

    def explanation_for(actionable:, closest:, strongest:, source_spread:, market_gap:, direction:)
      if actionable
        "Kalshi is closest to #{closest[:label]}, but the stronger historical source is #{strongest[:label]}; source spread is #{source_spread.round(1)}F and #{direction} by #{market_gap.round(1)}F."
      else
        "Watch only: source spread is #{source_spread.round(1)}F and #{direction} by #{market_gap.round(1)}F, but the weak-source gap is not strong enough yet."
      end
    end

    def source_payload(source)
      {
        key: source[:key],
        label: source[:label],
        high_f: source[:high_f]&.round(1),
        reliability_score: source[:reliability_score]&.round(3),
        avg_abs_error_f: source[:avg_abs_error_f],
        hit_rate: source[:hit_rate],
        sample_size: source[:sample_size],
        summary: source[:summary],
        period: source[:period]
      }
    end
  end
end
