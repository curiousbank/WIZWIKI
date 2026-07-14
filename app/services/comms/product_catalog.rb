# frozen_string_literal: true

require "yaml"

module Comms
  module ProductCatalog
    PATH = Rails.root.join("config", "autos", "product_catalog.yml")
    UNAVAILABLE_STATUSES = %w[sold_out sold-out unavailable disabled inactive archived expired unconfigured].freeze

    module_function

    def data
      Rails.cache.fetch(["wizwiki/comms/product_catalog", file_version], expires_in: 10.minutes) do
        load_data
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::ProductCatalog] load failed #{error.class}: #{error.message}")
      {}
    end

    def version
      data["version"].to_s
    end

    def products
      data.fetch("products", {}).to_h
    end

    def product(route)
      products.fetch(route.to_s, {}).to_h
    end

    def label(route)
      product(route)["label"].presence || route.to_s.tr("_", " ").titleize
    end

    def route_labels
      products.transform_values { |payload| payload.to_h["label"].presence }.compact_blank
    end

    def checkout_url(route)
      product(route)["checkout_url"].presence
    end

    def product_status(route)
      return "unconfigured" if product(route).blank?

      product(route)["status"].presence || "active"
    end

    def available?(route)
      product(route).present? && !sold_out?(route)
    end

    def sold_out?(route)
      UNAVAILABLE_STATUSES.include?(product_status(route).to_s.downcase)
    end

    def shopify_links
      products.each_with_object({}) do |(route, payload), links|
        url = payload.to_h["checkout_url"].presence
        links[route] = url if url.present?
      end
    end

    def checkout_urls
      shopify_links.values.compact_blank + current_specials_payload.values.filter_map { |payload| payload.to_h["checkout_url"].presence }
    end

    def known_checkout_url?(url)
      normalized = normalize_url(url)
      normalized.present? && checkout_urls.any? { |known| normalize_url(known) == normalized }
    end

    def route_for_checkout_url(url)
      normalized = normalize_url(url)
      return if normalized.blank?

      shopify_links.find { |_route, known_url| normalize_url(known_url) == normalized }&.first ||
        special_route_for_checkout_url(normalized)
    end

    def fixed_price(route)
      product(route)["price"].presence
    end

    def contents(route)
      product(route).fetch("contents", {}).to_h.transform_values { |value| value.to_i }
    end

    def included(route)
      Array(product(route)["included"]).map(&:to_s).compact_blank
    end

    def shipping_note(route)
      product(route)["shipping_note"].presence
    end

    def planning_quantity(route)
      product(route)["planning_quantity"].presence
    end

    def price_table(route)
      raw = product(route)["price_table"]
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(quantity, values), table|
        table[quantity.to_i] = values.to_h.compact_blank if quantity.to_i.positive?
      end
    end

    def price_for_quantity(route, quantity, field: nil)
      values = price_table(route).fetch(quantity.to_i, {})
      return if values.blank?

      field.present? ? values[field.to_s].presence : values["price"].presence || values.values.find(&:present?)
    end

    def quantity_options(route)
      price_table(route).keys.sort
    end

    def minimum_quantity(route)
      quantity_options(route).first
    end

    def starting_price_line(route)
      quantity = minimum_quantity(route)
      price = price_for_quantity(route, quantity)
      return if quantity.blank? || price.blank?

      "#{ActiveSupport::NumberHelper.number_to_delimited(quantity)} for #{price}"
    end

    def route_for_text(text)
      routes_for_text(text).first
    end

    def routes_for_text(text)
      body = normalized_match_text(text)
      return [] if body.blank?

      products.filter_map do |route, payload|
        route if product_match_terms(route, payload).any? { |term| body.match?(/\b#{Regexp.escape(term)}\b/i) }
      end
    end

    def product_details(route)
      payload = product(route)
      return {} if payload.blank?

      {
        source: "wizwiki_product_catalog",
        title: payload["label"].presence,
        url: payload["checkout_url"].presence,
        fixed_price: payload["price"].presence,
        included: included(route),
        shipping_note: shipping_note(route),
        price_table: price_table(route)
      }.compact_blank
    end

    def default_special_key
      ENV["WIZWIKI_COMMS_FEATURED_SPECIAL_KEY"].presence || data.fetch("current_specials", {}).keys.first
    end

    def current_special(key = nil)
      selected = key.to_s.presence || default_special_key
      return {} if selected.blank?

      data.fetch("current_specials", {}).fetch(selected, {}).to_h
    end

    def special_active_until(key = nil)
      value = current_special(key)["active_until"].presence
      value.present? ? Date.iso8601(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def special_checkout_url(key = nil)
      current_special(key)["checkout_url"].presence
    end

    def special_status(key = nil)
      payload = current_special(key)
      return "unconfigured" if payload.blank?

      payload["status"].presence || "active"
    end

    def special_available?(key = nil, date: Time.zone.today)
      return false if current_special(key).blank?
      return false if UNAVAILABLE_STATUSES.include?(special_status(key).to_s.downcase)

      active_until = special_active_until(key)
      active_until.blank? || date <= active_until
    end

    def special_sms_line(key = nil)
      current_special(key)["sms_line"].presence
    end

    def special_full_sms_line(key = nil)
      current_special(key)["full_sms_line"].presence
    end

    def special_pricing(key = nil)
      Array(current_special(key)["pricing"]).map do |row|
        row.to_h.slice("quantity", "unit_price", "total").compact_blank
      end
    end

    def special_price_for_quantity(quantity, key = nil)
      requested = quantity.to_i
      return if requested <= 0

      rows = special_pricing(key)
      exact = rows.find { |row| row["quantity"].to_i == requested }
      return exact["total"] if exact.present?

      rows.select { |row| row["quantity"].to_i >= requested }.min_by { |row| row["quantity"].to_i }&.[]("total") ||
        rows.max_by { |row| row["quantity"].to_i }&.[]("total")
    end

    def current_specials_payload(date: Time.zone.today)
      data.fetch("current_specials", {}).select do |key, _payload|
        special_available?(key, date: date)
      end.transform_values do |payload|
        payload.to_h.slice("label", "active_until", "checkout_url", "offer_type", "usage_rule", "sms_line", "full_sms_line", "pricing")
      end
    end

    def sms_summary
      return "No reviewed product catalog is configured." if products.blank? && current_specials_payload.blank?

      lines = ["Catalog source-of-truth version #{version}."]
      products.each { |route, payload| lines << "#{payload['label'].presence || route}: #{catalog_product_line(route, payload)}" }
      current_specials_payload.each_value { |payload| lines << payload["sms_line"].presence }
      lines.compact_blank.join(" ")
    end

    def canonical_resource_body
      lines = [
        "## Canonical product catalog",
        "Catalog version: #{version.presence || 'unconfigured'}",
        "",
        "Only reviewed facts in the configured catalog may be used for prices, package contents, checkout links, or specials."
      ]

      if products.blank?
        lines << ""
        lines << "No products are configured. Do not infer or invent product facts."
      else
        lines << ""
        lines << "### Products"
        products.each { |route, payload| lines << "- #{payload['label'] || route}: #{catalog_product_line(route, payload)}" }
      end

      if current_specials_payload.present?
        lines << ""
        lines << "### Current specials"
        current_specials_payload.each_value do |special|
          lines << "- #{special['label']}: #{special['sms_line']} Checkout: #{special['checkout_url']} Rule: #{special['usage_rule']}".squish
          Array(special["pricing"]).each { |row| lines << "  - Quantity #{row['quantity']}: #{row['total']} (#{row['unit_price']} each)" }
        end
      end

      process = data.fetch("process", {}).to_h
      if process.present?
        lines << ""
        lines << "### Process"
        process.each do |name, value|
          Array(value).each { |step| lines << "- #{name.to_s.tr('_', ' ').titleize}: #{step}" }
        end
      end

      lines.join("\n")
    end

    def load_data
      return {} unless PATH.exist?

      YAML.safe_load(PATH.read, aliases: true).to_h
    end

    def file_version
      return "missing" unless PATH.exist?

      "#{PATH.mtime.to_i}-#{PATH.size}"
    end

    def normalize_url(url)
      url.to_s.squish.sub(%r{[.,;:!?]+\z}, "").presence
    end

    def special_route_for_checkout_url(normalized_url)
      current_specials_payload.find do |_key, payload|
        normalize_url(payload.to_h["checkout_url"]) == normalized_url
      end&.first
    end

    def normalized_match_text(text)
      text.to_s.downcase.squish.tr("_-", " ")
    end

    def product_match_terms(route, payload)
      [route.to_s.tr("_-", " "), payload.to_h["label"], *Array(payload.to_h["aliases"])]
        .filter_map { |term| normalized_match_text(term).presence }
        .uniq
    end

    def contents_line(route)
      contents(route).filter_map do |name, quantity|
        next unless quantity.to_i.positive?

        "#{ActiveSupport::NumberHelper.number_to_delimited(quantity)} #{name.to_s.tr('_', ' ')}"
      end.to_sentence
    end

    def catalog_product_line(route, payload)
      pieces = []
      pieces << "price #{payload['price']}" if payload["price"].present?
      pieces << "contents #{contents_line(route)}" if payload["contents"].present?
      pieces << "pricing #{price_table(route).map { |quantity, values| "#{quantity}: #{values.values.compact_blank.first}" }.join(', ')}" if price_table(route).present?
      pieces << "checkout #{payload['checkout_url']}" if payload["checkout_url"].present?
      pieces << "use when #{payload['use_when']}" if payload["use_when"].present?
      pieces.join("; ").presence || "configured without public sales facts"
    end
  end
end
