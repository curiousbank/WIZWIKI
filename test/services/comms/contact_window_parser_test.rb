# frozen_string_literal: true

require "test_helper"

module Comms
  class ContactWindowParserTest < ActiveSupport::TestCase
    test "normalizes an unqualified after four request to Central afternoon" do
      now = Time.find_zone(ContactWindowParser::CENTRAL_ZONE).local(2026, 7, 13, 10, 0)
      result = ContactWindowParser.parse("Call me after 4", now: now)

      assert_equal "after 4", result.raw.downcase
      assert_equal "2026-07-13", result.day
      assert_equal "2026-07-13T16:00:00-05:00", result.not_before_at.iso8601
      refute result.after_hours_rollover
    end

    test "tracks weekday time ranges and explicit timezone" do
      now = Time.find_zone(ContactWindowParser::CENTRAL_ZONE).local(2026, 7, 13, 10, 0)
      result = ContactWindowParser.parse("Text me Tuesday between 2 and 4 PM CST", now: now)

      assert_equal "2026-07-14", result.day
      assert_equal ContactWindowParser::CENTRAL_ZONE, result.time_zone
      assert_equal "2026-07-14T14:00:00-05:00", result.not_before_at.iso8601
      assert_equal "2026-07-14T16:00:00-05:00", result.not_after_at.iso8601
      assert_includes result.effective_window, "between 2 PM and 4 PM Central"
    end

    test "normalizes a recurring plural weekday" do
      now = Time.find_zone(ContactWindowParser::CENTRAL_ZONE).local(2026, 7, 13, 10, 0)
      result = ContactWindowParser.parse("This number after 4 on Wednesdays", now: now)

      assert_equal "2026-07-15", result.day
      assert_equal "2026-07-15T16:00:00-05:00", result.not_before_at.iso8601
      assert_includes result.raw.downcase, "wednesdays"
      assert_includes result.effective_window, "Wednesday, July 15 after 4 PM Central"
    end

    test "rolls an after-hours request to the next business day" do
      now = Time.find_zone(ContactWindowParser::CENTRAL_ZONE).local(2026, 7, 17, 17, 30)
      result = ContactWindowParser.parse("Call me anytime", now: now)

      assert result.after_hours_rollover
      assert_equal "2026-07-20", result.day
      assert_equal "2026-07-20T09:00:00-05:00", result.not_before_at.iso8601
      assert_includes result.effective_window, "Monday, July 20 after 9 AM Central"
    end

    test "rolls a customer-requested after-five window forward" do
      now = Time.find_zone(ContactWindowParser::CENTRAL_ZONE).local(2026, 7, 13, 10, 0)
      result = ContactWindowParser.parse("Ring me after 5 CST", now: now)

      assert result.after_hours_rollover
      assert_equal "2026-07-14", result.day
      assert_equal "2026-07-14T09:00:00-05:00", result.not_before_at.iso8601
    end
  end
end
