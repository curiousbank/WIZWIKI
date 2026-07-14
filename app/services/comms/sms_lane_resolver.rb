# frozen_string_literal: true

module Comms
  class SmsLaneResolver
    POSTCARD_PATTERN = /\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/i.freeze
    SIGN_PATTERN = /\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i.freeze
    BOTH_WORD_PATTERN = /\b(?:both|combo|combined?|combination|together)\b/i.freeze
    POSTCARD_ONLY_LEAD_PATTERN = /\b(?:just|only|only want|stick with|keep it|rather|prefer|switch(?:ing)? to|instead|let me get|i'?ll do|i will do|we'?ll do|we will do|need|want|get)\b.{0,45}\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/i.freeze
    POSTCARD_ONLY_TRAIL_PATTERN = /\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b.{0,35}\b(?:only|instead|rather|please)\b/i.freeze
    NO_SIGNS_PATTERN = /\b(?:no|not|without)\b.{0,25}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i.freeze
    SIGN_ONLY_LEAD_PATTERN = /\b(?:just|only|only want|stick with|keep it|rather|prefer|switch(?:ing)? to|instead|let me get|i'?ll do|i will do|we'?ll do|we will do|need|want|get)\b.{0,45}\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i.freeze
    SIGN_ONLY_TRAIL_PATTERN = /\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b.{0,35}\b(?:only|instead|rather|please)\b/i.freeze
    NO_POSTCARDS_PATTERN = /\b(?:no|not|without)\b.{0,25}\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/i.freeze

    class << self
      def latest_explicit_lane_route(events)
        Array(events).reverse_each do |event|
          event = event.to_h
          next unless event["direction"].to_s == "inbound"

          route = explicit_lane_route(event["body"])
          return route if route.present?
        end
        nil
      end

      def explicit_lane_route(text)
        body = text.to_s.downcase.squish
        return if body.blank?

        if body.match?(BOTH_WORD_PATTERN) && body.match?(POSTCARD_PATTERN) && body.match?(SIGN_PATTERN)
          return "NEIGHBORHOOD_BLITZ"
        end

        return "EDDM" if postcard_only?(body)
        return "LAWN_SIGNS" if signs_only?(body)

        nil
      end

      private

      def postcard_only?(body)
        body.match?(POSTCARD_ONLY_LEAD_PATTERN) ||
          body.match?(POSTCARD_ONLY_TRAIL_PATTERN) ||
          body.match?(NO_SIGNS_PATTERN)
      end

      def signs_only?(body)
        body.match?(SIGN_ONLY_LEAD_PATTERN) ||
          body.match?(SIGN_ONLY_TRAIL_PATTERN) ||
          body.match?(NO_POSTCARDS_PATTERN)
      end
    end
  end
end
