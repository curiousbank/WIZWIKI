module Comms
  class SlackHandoffJob < ApplicationJob
    queue_as :default

    def perform(stage_id:, reason: "manual_am_support")
      stage = CrmRecordArtifact.includes(:crm_record, :user).find_by(id: stage_id)
      return if stage.blank?

      owner = route_owner(stage, reason)
      owner = safe_owner(owner) || safe_owner(existing_routed_owner(stage.reload)) || safe_owner(stage.reload.user)
      posted = defined?(Comms::SlackNotifier) &&
        Comms::SlackNotifier.post_handoff!(
          stage: stage.reload,
          owner: owner,
          reason: "Manual AM help requested from WIZWIKI COMMS."
        )

      mark_handoff_status!(stage.reload, posted ? "posted" : "failed")
    rescue ActiveRecord::ActiveRecordError, StandardError => error
      Rails.logger.warn("[Comms::SlackHandoffJob] failed stage=#{stage_id} #{error.class}: #{error.message}")
      mark_handoff_status!(stage.reload, "failed", error.message) if defined?(stage) && stage.present?
    end

    private

    def route_owner(stage, reason)
      return unless defined?(DealReports::CommsLeadRouter)

      DealReports::CommsLeadRouter.route!(stage.reload, force: true, reason: reason)
    rescue ActiveRecord::ActiveRecordError, StandardError => error
      Rails.logger.warn("[Comms::SlackHandoffJob] route failed stage=#{stage&.id} #{error.class}: #{error.message}")
      nil
    end

    def existing_routed_owner(stage)
      metadata = stage.metadata.to_h
      name = metadata["comms_routed_to_user_name"].to_s.squish.presence
      return if name.blank?

      routed_id = metadata["comms_routed_to_user_id"].to_s.squish.presence
      if routed_id.present? && !routed_id.start_with?("virtual:")
        routed_user = User.find_by(id: routed_id)
        return routed_user if routed_user.present?
      end

      Struct.new(:id, :display_name, :email_address, :hubspot_owner_id, :source, keyword_init: true).new(
        id: routed_id || "virtual:#{name.parameterize}",
        display_name: name,
        email_address: metadata["comms_routed_to_user_email"].to_s.squish.presence,
        hubspot_owner_id: metadata["comms_routed_to_hubspot_owner_id"].to_s.squish.presence,
        source: metadata["contact_owner_source"].to_s.squish.presence || "comms_route_metadata"
      )
    end

    def safe_owner(owner)
      return owner unless defined?(Comms::SlackNotifier)

      Comms::SlackNotifier.safe_owner(owner)
    end

    def mark_handoff_status!(stage, status, error = nil)
      metadata = stage.metadata.to_h.deep_dup
      stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_slack_handoff_status" => status,
          "sms_autopilot_slack_handoff_status_at" => Time.current.iso8601,
          "sms_autopilot_slack_handoff_error" => error.to_s.squish.presence
        ).compact_blank
      )
    rescue ActiveRecord::ActiveRecordError => update_error
      Rails.logger.warn("[Comms::SlackHandoffJob] status update failed stage=#{stage&.id} #{update_error.class}: #{update_error.message}")
    end
  end
end
