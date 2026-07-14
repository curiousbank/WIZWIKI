# frozen_string_literal: true

module Comms
  class PbSmsCommands
    PLAY_URL = ENV.fetch("PB_SMS_PLAY_URL", "https://313.cash/play").freeze
    GUIDE_URL = ENV.fetch("PB_SMS_GUIDE_URL", "https://313.cash/guide").freeze
    FAQ_URL = ENV.fetch("PB_SMS_FAQ_URL", "https://313.cash/faq").freeze

    COMMAND_PATTERN = /\A\s*(?:GO|HELP|MENU|PLAY|RPS|ROCK\s+PAPER\s+SCISSORS|GUESS|GUESS\s+THE\s+NUMBER|AIRDROP|POWDERBALL|PB)\s*[.!?]*\s*\z/i.freeze

    class << self
      def recognized?(body)
        body.to_s.match?(COMMAND_PATTERN)
      end

      def reply(body)
        command = normalize(body)
        case command
        when "GO", "PLAY", "MENU"
          "Welcome to 313.cash. Sign in once, then play airdrops, RPS, Guess, or Powderball here: #{PLAY_URL} Reply HELP for the guide."
        when "RPS", "ROCK PAPER SCISSORS"
          "Play Rock Paper Scissors from your secure 313.cash game hub: #{PLAY_URL}#rps"
        when "GUESS", "GUESS THE NUMBER"
          "Play Guess the Number from your secure 313.cash game hub: #{PLAY_URL}#guess"
        when "AIRDROP"
          "Claim an airdrop from your secure 313.cash game hub: #{PLAY_URL}#airdrop"
        when "POWDERBALL", "PB"
          "Play Powderball from your secure 313.cash game hub: #{PLAY_URL}#powderball"
        when "HELP"
          "313.cash help: #{GUIDE_URL} FAQ: #{FAQ_URL} Commands: GO, RPS, GUESS, AIRDROP, POWDERBALL. Transactions still require your signed-in confirmation."
        end
      end

      private

      def normalize(body)
        body.to_s.upcase.gsub(/[^A-Z ]/, " ").squish
      end
    end
  end
end
