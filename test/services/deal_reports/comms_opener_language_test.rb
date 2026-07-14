# frozen_string_literal: true

require "test_helper"

module DealReports
  class CommsOpenerLanguageTest < ActiveSupport::TestCase
    test "rejects a mailbox and sign product choice that omits postcards" do
      writer = CommsDraftWriter.allocate

      assert writer.send(
        :mailbox_product_choice_missing_postcards?,
        "Are you trying to reach mailboxes, get signs in the ground, or do both?"
      )
      refute writer.send(
        :mailbox_product_choice_missing_postcards?,
        "Are you trying to reach mailboxes with postcards, get yard signs in the ground, or do both?"
      )
    end
  end
end
