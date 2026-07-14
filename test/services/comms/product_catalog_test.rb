# frozen_string_literal: true

require "test_helper"

module Comms
  class ProductCatalogTest < ActiveSupport::TestCase
    test "public catalog is empty and safe by default" do
      assert_empty ProductCatalog.products
      assert_empty ProductCatalog.current_specials_payload
      assert_empty ProductCatalog.checkout_urls
      assert_equal "No reviewed product catalog is configured.", ProductCatalog.sms_summary
      assert_includes ProductCatalog.canonical_resource_body, "Do not infer or invent product facts"
    end

    test "unconfigured routes never produce prices or checkout authority" do
      refute ProductCatalog.available?("EXAMPLE_PRODUCT")
      assert ProductCatalog.sold_out?("EXAMPLE_PRODUCT")
      assert_nil ProductCatalog.fixed_price("EXAMPLE_PRODUCT")
      assert_nil ProductCatalog.checkout_url("EXAMPLE_PRODUCT")
      assert_nil ProductCatalog.route_for_checkout_url("https://example.invalid/products/example")
      refute ProductCatalog.known_checkout_url?("https://example.invalid/products/example")
    end

    test "unconfigured text cannot infer a product route" do
      assert_empty ProductCatalog.routes_for_text("Please send pricing and a checkout link.")
      assert_nil ProductCatalog.route_for_text("Please send pricing and a checkout link.")
    end
  end
end
