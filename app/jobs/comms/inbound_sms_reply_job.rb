module Comms
  class InboundSmsReplyJob < ApplicationJob
    queue_as :sms

    def perform(stage_id:, from:, to:, body:, sid:, provider: "twilio", generation: nil)
      stage = CrmRecordArtifact.find_by(id: stage_id)
      return if stage.blank?

      if (latest = latest_replyable_inbound_event(stage)).present?
        from = latest["from"].to_s.presence || from
        to = latest["to"].to_s.presence || to
        body = latest["body"].to_s
        sid = latest["provider_message_id"].to_s.presence || latest["id"].to_s.presence || sid
        provider = latest["provider"].to_s.presence || provider
      end

      generation = current_reply_generation(stage) if generation.to_s.blank?
      controller = TwilioWebhooksController.new
      if controller.send(:reply_generation_stale?, stage, generation)
        controller.send(:mark_reply_generation_stale!, stage, generation, provider: provider)
        return
      end

      if customer_acknowledgment_no_reply?(body)
        mark_stage!(stage, "no_reply_needed", completed_at: Time.current.iso8601, generation: generation, no_reply: true)
        return
      end

      mark_stage!(stage, "running", generation: generation)
      result = controller.send(:rebuild_next_sms!, stage, from: from.to_s, to: to.to_s, body: body.to_s, sid: sid.to_s, generation: generation)
      controller.send(:defer_stage_memory!, stage.reload)
      mark_stage!(stage.reload, "complete", completed_at: Time.current.iso8601, generation: generation) unless ActiveModel::Type::Boolean.new.cast(result.to_h["pending"])
    rescue StandardError => error
      mark_stage!(stage, "failed", error: "#{error.class}: #{error.message}", generation: generation) if stage.present?
      Rails.logger.warn("[Comms::InboundSmsReplyJob] failed stage=#{stage_id} provider=#{provider} #{error.class}: #{error.message}")
    end

    private

    def current_reply_generation(stage)
      stage.reload.metadata.to_h["sms_reply_generation"].to_s.presence
    end

    def latest_replyable_inbound_event(stage)
      Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
        channel = event["channel"].to_s
        (channel.blank? || channel == "sms") &&
          event["direction"].to_s == "inbound" &&
          event["body"].to_s.squish.present? &&
          !event["status"].to_s.in?(%w[failed canceled])
      end
    end

    def mark_stage!(stage, status, completed_at: nil, error: nil, generation: nil, no_reply: false)
      metadata = stage.metadata.to_h.deep_dup
      updates = {
        "comms_command_background_status" => status,
        "comms_command_background_at" => metadata["comms_command_background_at"].presence || Time.current.iso8601,
        "comms_command_background_completed_at" => completed_at,
        "comms_command_background_error" => error
      }
      if no_reply
        updates.merge!(
          "comms_command_sms_draft_body" => nil,
          "comms_command_sms_draft" => nil,
          "comms_command_last_status" => "listening",
          "sms_autopilot_last_status" => "listening"
        )
      end
      if generation.to_s.blank? || metadata["sms_reply_job_generation"].to_s == generation.to_s
        updates.merge!(
          "sms_reply_job_generation" => generation.to_s.presence || metadata["sms_reply_job_generation"],
          "sms_reply_job_status" => status,
          "sms_reply_job_running_at" => (status.to_s == "running" ? Time.current.iso8601 : metadata["sms_reply_job_running_at"]),
          "sms_reply_job_completed_at" => completed_at
        )
      end
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(updates).compact_blank
      )
    rescue StandardError => update_error
      Rails.logger.warn("[Comms::InboundSmsReplyJob] status update failed stage=#{stage&.id} #{update_error.class}: #{update_error.message}")
    end

    def customer_acknowledgment_no_reply?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?
      return false if body.include?("?")
      return false if body.match?(/\b(?:how|what|when|where|why|can|could|do|does|will|would|price|pricing|cost|quote|link|order|checkout|design|proof|upload|artwork|need|want|help|support|confused|understand)\b/)

      body.match?(/\A(?:thanks|thank you|thx|got it|ok|okay|sounds good|cool|perfect|great|awesome|appreciate it|i'?ll check (?:it|them) out|i will check (?:it|them) out|let me check|checking now|will do)[\s,.!]*(?:i'?ll check (?:it|them) out|i will check (?:it|them) out|checking now|will do|for now|thanks|thank you)?[\s.!]*\z/)
    end
  end
end
