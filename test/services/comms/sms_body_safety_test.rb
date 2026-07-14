require "test_helper"

module Comms
  class SmsBodySafetyTest < ActiveSupport::TestCase
    INTERNAL_LANE_REPLY = <<~TEXT.squish.freeze
      We are in the "LAWN_SIGNS" lane, and the customer has confirmed they want yard signs.
      According to the product decision guide, sign_quantity is missing.
      The guide says ask_if_unclear: "How many signs do you want to start with?"
      We must not include internal notes or analysis.
    TEXT

    test "blocks internal lane analysis replies" do
      assert SmsBodySafety.internal_leak?(INTERNAL_LANE_REPLY)
      assert_nil SmsBodySafety.sanitize_customer_body(INTERNAL_LANE_REPLY)
      assert Autos::WorkerQueue.send(:invalid_comms_sms_answer?, INTERNAL_LANE_REPLY)
    end

    test "allows normal yard sign pricing replies" do
      body = "For 18x24 yard signs, the smallest package is 10 for $99. How many signs do you want to start with?"

      assert_equal body, SmsBodySafety.sanitize_customer_body(body)
      refute Autos::WorkerQueue.send(:invalid_comms_sms_answer?, body)
    end

    test "polishes sentence capitalization before delivery" do
      body = "Hi Sample Contact, I'm Thumper from WIZWIKI Marketing. let's sort through the options and keep this simple. i can help with postcards or signs."

      assert_equal(
        "Hi Sample Contact, I'm Thumper from WIZWIKI Marketing. Let's sort through the options and keep this simple. I can help with postcards or signs. Reply STOP to opt out.",
        SmsBodySafety.prepare_outbound_body(body, include_opt_out_notice: true)
      )
    end

    test "strips model thinking tags before draft cleanup and delivery" do
      raw = "</think>Hi Sample Contact, I can set you up with postcards. For EDDM mailings you start at $399 for a route that reaches about 500 homes."
      expected = "Hi Sample Contact, I can set you up with postcards. For EDDM mailings you start at $399 for a route that reaches about 500 homes."

      assert_equal expected, SmsBodySafety.sanitize_customer_body(raw)
      assert_equal expected, SmsBodySafety.prepare_outbound_body(raw, include_opt_out_notice: false)
    end

    test "removes closed model thinking blocks and keeps visible sms" do
      raw = "<think>Need to answer postcards and avoid signs.</think>Hi Sample Contact, postcards are the right lane here."

      assert_equal "Hi Sample Contact, postcards are the right lane here.", SmsBodySafety.sanitize_customer_body(raw)
    end

    test "polish keeps common abbreviations and opt out text stable" do
      body = "We can check at 3 p.m. tomorrow. reply STOP to opt out."

      assert_equal(
        "We can check at 3 p.m. tomorrow. Reply STOP to opt out.",
        SmsBodySafety.prepare_outbound_body(body, include_opt_out_notice: true)
      )
    end
  end
end
