require "json"
require "net/http"
require "uri"

module Kalshi
  class WeatherPredictionSettler
    DEFAULT_BASE_URL = "https://external-api.kalshi.com".freeze
    RESULT_KEYS = %w[result outcome settlement_result].freeze
    TEMPERATURE_KEYS = %w[observed_high_f actual_high_f expiration_value].freeze

    class << self
      def call(organization:, limit: 12)
        new(organization: organization, limit: limit).call
      end
    end

    def initialize(organization:, limit:)
      @organization = organization
      @limit = limit.to_i.positive? ? limit.to_i : 12
      @errors = []
      @settled = 0
      @checked = 0
      @waiting = 0
    end

    def call
      return status("storage not ready") unless storage_ready?

      settlement_candidates.each do |prediction|
        @checked += 1
        settle_prediction(prediction)
      rescue StandardError => error
        @errors << "#{prediction.market_ticker}: #{error.class}: #{error.message}"
      end

      {
        checked: @checked,
        settled: @settled,
        waiting: @waiting,
        errors: @errors.first(4),
        ran_at: Time.current
      }
    end

    private

    attr_reader :organization, :limit

    def storage_ready?
      defined?(KalshiWeatherPrediction) &&
        KalshiWeatherPrediction.storage_ready? &&
        organization.respond_to?(:kalshi_weather_predictions)
    end

    def status(reason)
      { checked: 0, settled: 0, waiting: 0, errors: [reason], ran_at: Time.current }
    end

    def settlement_candidates
      organization.kalshi_weather_predictions
        .where("close_time IS NULL OR close_time <= ?", 30.minutes.ago)
        .where("result_status = 'pending' OR NOT (metadata ? 'official_market_reconciled_at')")
        .order(Arel.sql("COALESCE(close_time, created_at) ASC"))
        .limit(limit)
    end

    def settle_prediction(prediction)
      market = fetch_market(prediction.market_ticker)
      return mark_waiting(prediction, market) unless closed_market?(market)

      observed = extract_observed_high(market)
      outcome = extract_yes_outcome(market)
      if observed.present? && outcome.present?
        prediction.score_from_observed!(
          observed_high: observed,
          settlement_value: settlement_label(market),
          source: "kalshi_market_detail",
          payload: market.merge("market_snapshot" => market_price_snapshot(market)),
          official_outcome: outcome
        )
        @settled += 1
        return
      end

      if outcome.present?
        prediction.mark_settled_by_outcome!(
          outcome: outcome,
          settlement_value: settlement_label(market),
          source: "kalshi_market_detail",
          payload: market.merge("market_snapshot" => market_price_snapshot(market))
        )
        @settled += 1
        return
      end

      mark_waiting(prediction, market)
    end

    def mark_waiting(prediction, market)
      @waiting += 1
      return unless market_status(market).present?

      prediction.update_columns(
        metadata: prediction.metadata.to_h.merge(
          "last_settlement_check_at" => Time.current.iso8601,
          "last_settlement_status" => market_status(market),
          "last_settlement_payload_keys" => market.keys.sort.first(24)
        ),
        updated_at: Time.current
      )
    end

    def fetch_market(ticker)
      uri = URI("#{base_url}/trade-api/v2/markets/#{URI.encode_www_form_component(ticker)}")
      response = request_json(uri)
      response["market"].to_h.presence || response.to_h
    end

    def request_json(uri)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (read-only settlement scoring)"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 12) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def closed_market?(market)
      status = market_status(market)
      status.in?(%w[closed settled finalized expired inactive]) ||
        market.values_at("result", "settlement_value", "expiration_value", "settled_time").any?(&:present?)
    end

    def market_status(market)
      market["status"].to_s.downcase.presence || market["market_status"].to_s.downcase.presence
    end

    def extract_observed_high(market)
      TEMPERATURE_KEYS.each do |key|
        value = market[key]
        next if value.blank?

        temp = value.to_s.scan(/-?\d+(?:\.\d+)?/).map(&:to_f).find { |number| number.between?(-80, 140) }
        return temp.round if temp.present?
      end
      nil
    end

    def extract_yes_outcome(market)
      RESULT_KEYS.each do |key|
        value = market[key].to_s.downcase
        return "yes" if value.match?(/\byes\b|\btrue\b|\bwon\b/)
        return "no" if value.match?(/\bno\b|\bfalse\b|\blost\b/)
      end
      nil
    end

    def settlement_label(market)
      market.values_at("settlement_value", "expiration_value", "result", "outcome", "status").compact_blank.first.to_s
    end

    def market_price_snapshot(market)
      market.to_h.slice(
        "yes_bid", "yes_ask", "last_price",
        "yes_bid_dollars", "yes_ask_dollars", "last_price_dollars",
        "volume", "volume_24h", "volume_24h_fp", "liquidity"
      )
    end

    def base_url
      ENV.fetch("KALSHI_BASE_URL", DEFAULT_BASE_URL).to_s.delete_suffix("/").sub(%r{/trade-api/v2\z}, "")
    end
  end
end
