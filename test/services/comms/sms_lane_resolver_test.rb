require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "minitest/autorun"
require_relative "../../../app/services/comms/sms_lane_resolver"

module Comms
  class SmsLaneResolverTest < Minitest::Test
    def test_latest_postcards_only_message_overrides_earlier_signs
      events = [
        { "direction" => "inbound", "body" => "Signs please" },
        { "direction" => "inbound", "body" => "Just postcards" },
        { "direction" => "inbound", "body" => "Maybe 500" }
      ]

      assert_equal "EDDM", SmsLaneResolver.latest_explicit_lane_route(events)
    end

    def test_latest_signs_only_message_overrides_earlier_postcards
      events = [
        { "direction" => "inbound", "body" => "I might mail some postcards" },
        { "direction" => "inbound", "body" => "Actually keep it signs only" }
      ]

      assert_equal "LAWN_SIGNS", SmsLaneResolver.latest_explicit_lane_route(events)
    end

    def test_combined_sign_and_postcard_request_selects_neighborhood_blitz
      assert_equal "NEIGHBORHOOD_BLITZ", SmsLaneResolver.explicit_lane_route("I want postcards and signs together")
    end

    def test_ambiguous_followup_keeps_the_latest_explicit_lane
      events = [
        { "direction" => "inbound", "body" => "Just postcards" },
        { "direction" => "inbound", "body" => "What about 1000?" }
      ]

      assert_equal "EDDM", SmsLaneResolver.latest_explicit_lane_route(events)
    end

    def test_plain_stop_by_does_not_become_opt_out_or_lane_switch
      assert_nil SmsLaneResolver.explicit_lane_route("Can you stop by later and text me pricing?")
    end
  end
end
