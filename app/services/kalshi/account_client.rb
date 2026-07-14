# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module Kalshi
  class AccountClient
    DEFAULT_BASE_URL = "https://external-api.kalshi.com".freeze

    class << self
      def status
        new.status
      end

      def market_positions
        new.market_positions
      end

      def market_positions_by_ticker
        new.market_positions_by_ticker
      end

      def settlements(limit: 100)
        new.settlements(limit: limit)
      end

      def configured?
        api_key_id.present? && private_key_source.present?
      end

      def live_orders_enabled?
        truthy?(ENV["WIZWIKI_WEATHER_LIVE_ORDERS_ENABLED"]) && truthy?(ENV["KALSHI_LIVE_ORDERS_ENABLED"])
      end

      def api_key_id
        ENV["KALSHI_API_KEY_ID"].presence || ENV["KALSHI_ACCESS_KEY"].presence || ENV["KALSHI_API_KEY"].presence
      end

      def private_key_source
        ENV["KALSHI_PRIVATE_KEY"].presence || ENV["KALSHI_PRIVATE_KEY_PATH"].presence
      end

      private

      def truthy?(value)
        value.to_s.strip.downcase.in?(%w[1 true yes y on])
      end
    end

    def status
      return disconnected("Kalshi API key/private key not configured") unless self.class.configured?

      balance_payload = request_json("/portfolio/balance")
      deposits_payload = safe_request_json("/portfolio/deposits", query: { "limit" => "5" })
      deposits = Array(deposits_payload["deposits"]).map(&:to_h)
      {
        configured: true,
        connected: true,
        read_only: !self.class.live_orders_enabled?,
        live_orders_enabled: self.class.live_orders_enabled?,
        balance_cents: cents_from(balance_payload, "balance", "cash_balance", "available_balance"),
        portfolio_value_cents: cents_from(balance_payload, "portfolio_value", "total_value", "portfolio_balance"),
        balance_payload_keys: balance_payload.keys.sort.first(16),
        deposits_count: deposits.length,
        latest_deposit_cents: cents_from(deposits.first.to_h, "amount", "amount_cents"),
        latest_deposit_status: deposits.first.to_h.values_at("status", "state").compact_blank.first,
        latest_deposit_at: deposits.first.to_h.values_at("created_time", "created_at", "updated_time", "updated_at").compact_blank.first,
        checked_at: Time.current,
        error: nil
      }
    rescue StandardError => error
      disconnected("#{error.class}: #{error.message}")
    end

    def market_positions
      return [] unless self.class.configured?

      Array(request_json("/portfolio/positions")["market_positions"]).map(&:to_h)
    rescue StandardError => error
      Rails.logger.warn("[Kalshi::AccountClient] positions unavailable: #{error.class}: #{error.message}") if defined?(Rails)
      []
    end

    def market_positions_by_ticker
      market_positions.index_by { |row| row["ticker"].to_s }
    end

    def settlements(limit: 100)
      return [] unless self.class.configured?

      Array(request_json("/portfolio/settlements", query: { "limit" => limit.to_i.positive? ? limit.to_i.to_s : "100" })["settlements"]).map(&:to_h)
    rescue StandardError => error
      Rails.logger.warn("[Kalshi::AccountClient] settlements unavailable: #{error.class}: #{error.message}") if defined?(Rails)
      []
    end

    def create_order!(payload)
      raise "Kalshi API key/private key not configured" unless self.class.configured?
      raise "Kalshi live order switches are disabled" unless self.class.live_orders_enabled?

      post_json("/portfolio/events/orders", v2_order_payload(payload))
    end

    private

    def v2_order_payload(payload)
      data = payload.to_h.with_indifferent_access
      price = data[:price].presence || data[:yes_price_dollars].presence
      price = data[:yes_price].to_f / 100.0 if price.blank? && data[:yes_price].present?
      side = data[:side].to_s == "ask" || data[:action].to_s == "sell" ? "ask" : "bid"

      {
        ticker: data.fetch(:ticker),
        client_order_id: data[:client_order_id],
        side: side,
        count: format_contract_count(data.fetch(:count)),
        price: format_fixed_price(price),
        time_in_force: data[:time_in_force].presence || "fill_or_kill",
        self_trade_prevention_type: data[:self_trade_prevention_type].presence || "taker_at_cross",
        post_only: ActiveModel::Type::Boolean.new.cast(data[:post_only]),
        cancel_order_on_pause: ActiveModel::Type::Boolean.new.cast(data[:cancel_order_on_pause]),
        reduce_only: ActiveModel::Type::Boolean.new.cast(data[:reduce_only]),
        exchange_index: data[:exchange_index].presence || 0
      }.compact
    end

    def format_contract_count(value)
      format("%.2f", value.to_f)
    end

    def format_fixed_price(value)
      price = value.to_f
      raise "order price missing" unless price.positive?

      format("%.4f", price)
    end

    def request_json(path, query: nil)
      uri = URI("#{api_root}#{path}")
      uri.query = URI.encode_www_form(query) if query.present?
      timestamp_ms = (Time.now.to_f * 1000).to_i.to_s
      request_path = "/trade-api/v2#{path}"

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (read-only account visibility)"
      request["KALSHI-ACCESS-KEY"] = self.class.api_key_id
      request["KALSHI-ACCESS-TIMESTAMP"] = timestamp_ms
      request["KALSHI-ACCESS-SIGNATURE"] = signature(timestamp_ms, "GET", request_path)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 12) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}: #{response.body.to_s.truncate(180)}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def post_json(path, payload)
      uri = URI("#{api_root}#{path}")
      body = JSON.generate(payload)
      timestamp_ms = (Time.now.to_f * 1000).to_i.to_s
      request_path = "/trade-api/v2#{path}"

      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "WIZWIKI AUTOS Weather Brain (capped live order executor)"
      request["KALSHI-ACCESS-KEY"] = self.class.api_key_id
      request["KALSHI-ACCESS-TIMESTAMP"] = timestamp_ms
      request["KALSHI-ACCESS-SIGNATURE"] = signature(timestamp_ms, "POST", request_path)
      request.body = body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 12) do |http|
        http.request(request)
      end
      raise "HTTP #{response.code}: #{response.body.to_s.truncate(240)}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise "invalid JSON: #{error.message}"
    end

    def signature(timestamp_ms, method, path)
      message = "#{timestamp_ms}#{method}#{path}"
      digest = OpenSSL::Digest::SHA256.new
      signed = private_key.sign_pss(digest, message, salt_length: :digest, mgf1_hash: "SHA256")
      Base64.strict_encode64(signed)
    end

    def private_key
      @private_key ||= OpenSSL::PKey.read(private_key_material)
    end

    def private_key_material
      inline = ENV["KALSHI_PRIVATE_KEY"].presence
      return inline if inline.present?

      path = ENV["KALSHI_PRIVATE_KEY_PATH"].to_s
      raise "KALSHI_PRIVATE_KEY_PATH missing" if path.blank?

      File.read(path)
    end

    def api_root
      "#{ENV.fetch('KALSHI_BASE_URL', DEFAULT_BASE_URL).to_s.delete_suffix('/').sub(%r{/trade-api/v2\z}, '')}/trade-api/v2"
    end

    def cents_from(hash, *keys)
      key, raw = keys.filter_map do |item|
        value = hash[item].presence || hash[item.to_sym].presence
        [item, value] if value.present?
      end.first
      return nil if raw.blank?

      value = raw.to_f
      key.to_s.include?("dollars") ? (value * 100).round : value.round
    end

    def safe_request_json(path, query: nil)
      request_json(path, query: query)
    rescue StandardError
      {}
    end

    def disconnected(reason)
      {
        configured: self.class.configured?,
        connected: false,
        read_only: !self.class.live_orders_enabled?,
        live_orders_enabled: self.class.live_orders_enabled?,
        balance_cents: nil,
        portfolio_value_cents: nil,
        deposits_count: 0,
        latest_deposit_cents: nil,
        latest_deposit_status: nil,
        latest_deposit_at: nil,
        checked_at: Time.current,
        error: reason
      }
    end
  end
end
