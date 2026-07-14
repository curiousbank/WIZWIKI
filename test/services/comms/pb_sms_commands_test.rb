# frozen_string_literal: true

require "test_helper"

module Comms
  class PbSmsCommandsTest < ActiveSupport::TestCase
    test "recognizes only compact onboarding and game menu commands" do
      %w[GO HELP MENU PLAY RPS GUESS AIRDROP POWDERBALL PB].each do |command|
        assert PbSmsCommands.recognized?(command), command
      end

      refute PbSmsCommands.recognized?("please send me an airdrop")
      refute PbSmsCommands.recognized?("GO buy a ticket")
    end

    test "GO returns one secure play link and never claims a transaction" do
      reply = PbSmsCommands.reply("go!")

      assert_includes reply, "https://313.cash/play"
      assert_includes reply, "Sign in"
      refute_match(/(?:sent|transferred|claimed|entered|placed).{0,30}(?:coin|airdrop|wager|bet)/i, reply)
    end

    test "HELP explains that transactions require signed-in confirmation" do
      reply = PbSmsCommands.reply("HELP")

      assert_includes reply, "https://313.cash/guide"
      assert_includes reply, "https://313.cash/faq"
      assert_match(/signed-in confirmation/i, reply)
    end
  end
end
