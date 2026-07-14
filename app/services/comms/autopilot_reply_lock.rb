require "digest"

module Comms
  class AutopilotReplyLock
    TTL = 5.minutes

    def self.key(inbound_sid:, inbound_body:, from:)
      sid = inbound_sid.to_s.squish
      return sid if sid.present?

      body = inbound_body.to_s.squish
      sender = from.to_s.squish
      return nil if body.blank? && sender.blank?

      Digest::SHA1.hexdigest([sender, body].join(":"))
    end

    def self.answered?(metadata, key:)
      key = key.to_s
      return false if key.blank?

      Array(metadata.to_h["sms_thread"]).any? do |event|
        event = event.to_h
        event["autopilot_reply_to_sid"].to_s == key ||
          event["autopilot_reply_key"].to_s == key
      end
    end

    def self.reserve!(stage, inbound_sid:, inbound_body:, from:, source:)
      reply_key = key(inbound_sid: inbound_sid, inbound_body: inbound_body, from: from)
      return nil if reply_key.blank?

      stage.with_lock do
        stage.reload
        metadata = stage.metadata.to_h.deep_dup
        return nil if answered?(metadata, key: reply_key)

        reservation = metadata["sms_autopilot_reply_reservation"].to_h
        if reservation["key"].to_s == reply_key && reservation_active?(reservation)
          return nil
        end

        metadata["sms_autopilot_reply_reservation"] = {
          "key" => reply_key,
          "source" => source.to_s.presence,
          "inbound_sid" => inbound_sid.to_s.presence,
          "reserved_at" => Time.current.iso8601
        }.compact_blank
        stage.update!(generated_at: Time.current, metadata: metadata)
      end

      reply_key
    end

    def self.clear!(stage, key:)
      key = key.to_s
      return true if stage.blank? || key.blank?

      stage.with_lock do
        stage.reload
        metadata = stage.metadata.to_h.deep_dup
        reservation = metadata["sms_autopilot_reply_reservation"].to_h
        return true unless reservation["key"].to_s == key

        metadata.delete("sms_autopilot_reply_reservation")
        stage.update!(generated_at: Time.current, metadata: metadata)
      end
      true
    rescue StandardError => error
      Rails.logger.warn("[Comms::AutopilotReplyLock] clear failed stage=#{stage&.id} key=#{key} #{error.class}: #{error.message}")
      false
    end

    def self.reservation_active?(reservation)
      reserved_at = Time.zone.parse(reservation.to_h["reserved_at"].to_s)
      reserved_at.present? && reserved_at > TTL.ago
    rescue ArgumentError, TypeError
      false
    end
  end
end
