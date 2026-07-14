# frozen_string_literal: true

require "test_helper"

module Comms
  class ConsultantVoiceTest < ActiveSupport::TestCase
    test "polishes canned framing and Thumper-forbidden dashes" do
      review = ConsultantVoice.review(
        body: "Absolutely! 50 yard signs are $249 — design, stakes, and shipping are included. Let me know if you need anything else.",
        inbound: "How much are 50 yard signs?"
      )

      refute review.blocked?
      assert_includes review.issue_codes, "consultant_voice_canned_opener"
      assert_includes review.issue_codes, "consultant_voice_em_dash"
      assert_includes review.issue_codes, "consultant_voice_generic_closer"
      assert_equal "50 yard signs are $249. Design, stakes, and shipping are included.", review.body
    end

    test "blocks policy narration instead of sending it to a customer" do
      review = ConsultantVoice.review(
        body: "According to our policy, I cannot safely quote that from the available context.",
        inbound: "What would 750 signs cost?"
      )

      assert review.blocked?
      assert_equal "consultant_voice_policy_language", review.reason
      assert_nil review.body
    end

    test "blocks capability-only and multi-question replies" do
      capability = ConsultantVoice.review(body: "I can help explain and compare the available options.")
      questions = ConsultantVoice.review(body: "How many signs? What is your budget?")

      assert_equal "consultant_voice_meta_capability", capability.reason
      assert_equal "consultant_voice_multiple_questions", questions.reason
    end

    test "allows a grounded consultant-style reply" do
      review = ConsultantVoice.review(
        body: "50 yard signs are $249 with design, stakes, and shipping included. That is a practical jobsite run. Want the checkout link?",
        inbound: "How much are 50 signs?"
      )

      refute review.blocked?
      assert_empty review.issue_codes
    end

    test "public SMS examples contain guidance rather than a private answer corpus" do
      path = Rails.root.join("config", "autos", "sms_examples.md")
      contents = path.read

      assert_includes contents, "neutral examples"
      assert_includes contents, "verified price from the configured catalog"
      refute_includes contents, "Good Thumper answer:"
      refute_match(%r{https?://|\$\d}, contents)
    end
  end
end
