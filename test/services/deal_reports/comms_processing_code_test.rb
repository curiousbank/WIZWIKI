require "test_helper"
require "ostruct"

module DealReports
  class CommsProcessingCodeTest < ActiveSupport::TestCase
    test "reset stage does not infer product selection from outbound opener" do
      reset_at = Time.current
      metadata = {
        "sms_discovery_reset" => true,
        "sms_conversation_reset_at" => reset_at.iso8601,
        "product_interest_code" => "NEIGHBORHOOD_BLITZ",
        "product_interest_label" => "Neighborhood Blitz",
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "outbound",
            "body" => "Hi Sample Contact, I'm Thumper from WIZWIKI Marketing. Are you thinking postcards, yard signs, or both?",
            "created_at" => 1.minute.from_now.iso8601
          }
        ]
      }
      stage = OpenStruct.new(crm_record: nil, organization: nil, title: "Sample Contact")

      processing = CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: metadata["sms_thread"].first["body"])

      assert_nil processing["product_interest_code"]
      assert_nil processing["product_interest_label"]
      assert_nil processing.dig("sms_lane_monitor", "route_code")
      assert_nil processing.dig("comms_bot_state", "route_code")
      assert_equal "no_customer_lane", processing.dig("sms_lane_monitor", "source")
    end

    test "reset stage accepts first inbound customer product signal" do
      reset_at = Time.current
      metadata = {
        "sms_discovery_reset" => true,
        "sms_conversation_reset_at" => reset_at.iso8601,
        "comms_bot_state" => {
          "contact_name" => "Sample Contact",
          "route_code" => "NEIGHBORHOOD_BLITZ",
          "route_label" => "Neighborhood Blitz",
          "shopify_link" => "https://shop.example.invalid/products/main-course-bundle-eddm-postcards-1-deluxe-a-frames-500-rack-cards-sample_owner",
          "campaign_fit" => { "wants_both" => true }
        },
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "inbound",
            "body" => "I need yard signs for a plumbing company",
            "created_at" => 1.minute.from_now.iso8601
          }
        ]
      }
      stage = OpenStruct.new(crm_record: nil, organization: nil, title: "Sample Contact")

      processing = CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: "I need yard signs for a plumbing company")

      assert_equal "LAWN_SIGNS", processing["product_interest_code"]
      assert_equal "Lawn Signs", processing["product_interest_label"]
      assert_equal "latest_inbound", processing.dig("sms_lane_monitor", "source")
      assert_equal "LAWN_SIGNS", processing.dig("comms_bot_state", "route_code")
      assert_equal "Lawn Signs", processing.dig("comms_bot_state", "route_label")
      assert_nil processing.dig("comms_bot_state", "campaign_fit")
      assert_equal "Sample Contact", processing.dig("comms_bot_state", "contact_name")
    end

    test "bare acceptance keeps the latest lane but drops an unreviewed checkout link" do
      metadata = {
        "product_interest_code" => "BUSINESS_CARDS",
        "product_interest_label" => "Business Cards",
        "shopify_link" => "https://shop.example.invalid/products/business-cards",
        "comms_bot_state" => {
          "route_code" => "BUSINESS_CARDS",
          "route_label" => "Business Cards",
          "shopify_link" => "https://shop.example.invalid/products/business-cards"
        },
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "Can i get the business card link",
            "created_at" => 5.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "outbound",
            "status" => "delivered",
            "body" => "Yes. Business cards have a standalone option. Here is the Business Cards checkout link: https://shop.example.invalid/products/business-cards",
            "created_at" => 4.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "What about door hangers?",
            "created_at" => 3.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "outbound",
            "status" => "delivered",
            "body" => "Yes. Door hangers have a standalone 4.25x11 option. Want me to send the door-hanger checkout link?",
            "created_at" => 2.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "Yes please",
            "created_at" => 1.minute.ago.iso8601
          }
        ]
      }
      stage = OpenStruct.new(crm_record: nil, organization: nil, title: "Sample Contact")

      processing = CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: "Yes please")

      assert_equal "DOOR_HANGERS", processing["product_interest_code"]
      assert_equal "Door Hangers", processing["product_interest_label"]
      assert_equal "latest_outbound_checkout_prompt", processing.dig("sms_lane_monitor", "source")
      assert_equal "DOOR_HANGERS", processing.dig("sms_lane_monitor", "prompt_code")
      assert_equal "DOOR_HANGERS", processing.dig("comms_bot_state", "route_code")
      assert_nil processing["shopify_link"]
    end

    test "bare yes does not inherit older checkout prompt after newer discovery question" do
      metadata = {
        "product_interest_code" => "BUSINESS_CARDS",
        "product_interest_label" => "Business Cards",
        "shopify_link" => "https://shop.example.invalid/products/business-cards",
        "comms_bot_state" => {
          "route_code" => "BUSINESS_CARDS",
          "route_label" => "Business Cards",
          "shopify_link" => "https://shop.example.invalid/products/business-cards"
        },
        "sms_thread" => [
          {
            "channel" => "sms",
            "direction" => "outbound",
            "status" => "delivered",
            "body" => "Are you trying to reach mailboxes, get signs in the ground, or do both?",
            "created_at" => 8.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "Both",
            "created_at" => 7.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "Im looking for biz cards too",
            "created_at" => 6.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "outbound",
            "status" => "delivered",
            "body" => "Business Cards have a standalone checkout. Want me to send the Business Cards checkout link?",
            "created_at" => 5.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "I also need signs and postcards",
            "created_at" => 4.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "outbound",
            "status" => "delivered",
            "body" => "We can do both. Yard signs start at 10 for $99. Mailed postcards start with one EDDM route at $399. Are you mailing homes too?",
            "created_at" => 3.minutes.ago.iso8601
          },
          {
            "channel" => "sms",
            "direction" => "inbound",
            "status" => "received",
            "body" => "Yes",
            "created_at" => 2.minutes.ago.iso8601
          }
        ]
      }
      stage = OpenStruct.new(crm_record: nil, organization: nil, title: "Sample Contact")

      processing = CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: "Yes")

      refute_equal "BUSINESS_CARDS", processing["product_interest_code"]
      assert_nil processing.dig("sms_lane_monitor", "prompt_code")
      assert_equal "NEIGHBORHOOD_BLITZ", processing["product_interest_code"]
      assert_equal "fresh_thread_scan", processing.dig("sms_lane_monitor", "source")
    end
  end
end
