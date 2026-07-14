# frozen_string_literal: true

require "test_helper"

class TwilioWebhooksOpenerTest < ActiveSupport::TestCase
  Stage = Struct.new(:id, :metadata, :crm_record, keyword_init: true)
  Record = Struct.new(:name, keyword_init: true)

  test "every deterministic reset opener stays neutral" do
    controller = TwilioWebhooksController.new
    bodies = 100.times.map do |index|
      stage = Stage.new(
        id: index + 1,
        metadata: { "sms_conversation_reset_count" => index, "sms_thread" => [] },
        crm_record: Record.new(name: "Sample Contact Test")
      )
      controller.send(:auto_thumper_opening_body, stage)
    end.uniq

    assert_equal 4, bodies.length
    bodies.each do |body|
      assert_includes body, "Thumper with WIZWIKI"
      assert_operator body.scan("?").length, :<=, 1
      refute_match(/postcards|yard signs|price|discount|checkout/i, body)
    end
  end
end
