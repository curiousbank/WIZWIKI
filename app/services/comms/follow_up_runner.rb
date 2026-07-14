require "digest"

module Comms
 class FollowUpRunner
    DEFAULT_QUICK_NUDGE_COUNT = 2
    DEFAULT_QUICK_NUDGE_MINUTES = 15
    DEFAULT_RECOVERY_PING_MINUTES = 10

    DEFAULTS = {
      "enabled" => false,
      "frequency_hours" => 24,
      "duration_days" => 14,
      "max_per_day" => 2,
      "quick_nudge_count" => DEFAULT_QUICK_NUDGE_COUNT,
      "quick_nudge_minutes" => DEFAULT_QUICK_NUDGE_MINUTES,
      "recovery_ping_enabled" => true,
      "recovery_ping_minutes" => DEFAULT_RECOVERY_PING_MINUTES,
      "recovery_ping_max_per_day" => 1,
      "recovery_ping_max_age_hours" => 12,
      "send_window_start" => "09:00",
      "send_window_end" => "17:00",
      "timezone" => "America/Chicago"
    }.freeze
    EMAIL_FOLLOW_UP_DAY_ACTIONS = %w[none sms email both final_both].freeze
    EMAIL_FOLLOW_UP_PRESET_DAYS = {
      "normal" => {
        "1" => "both",
        "2" => "none",
        "3" => "email",
        "4" => "both",
        "5" => "none",
        "6" => "none",
        "7" => "email"
      },
      "moderate" => {
        "1" => "both",
        "2" => "both",
        "3" => "none",
        "4" => "email",
        "5" => "both",
        "6" => "none",
        "7" => "email"
      },
      "aggressive" => {
        "1" => "both",
        "2" => "both",
        "3" => "email",
        "4" => "both",
        "5" => "email",
        "6" => "email",
        "7" => "email"
      },
      "monthly" => {
        "1" => "none",
        "2" => "none",
        "3" => "email",
        "4" => "none",
        "5" => "both",
        "6" => "none",
        "7" => "none"
      }
    }.freeze
    EMAIL_DEFAULTS = {
      "enabled" => false,
      "preset" => "normal",
      "cadence" => "off",
      "schedule_mode" => "preset",
      "business_days" => true,
      "send_window_start" => "09:00",
      "send_window_end" => "17:00",
      "daily_plan" => EMAIL_FOLLOW_UP_PRESET_DAYS.fetch("normal"),
      "selected_weeks" => [],
      "subject_prompt" => "",
      "body_prompt" => ""
    }.freeze

    Result = Struct.new(:checked, :sent, :sent_sms, :sent_email, :skipped, :failed, :outside_window, :dry_run, keyword_init: true) do
      def to_h
        {
          checked: checked.to_i,
          sent: sent.to_i,
          sent_sms: sent_sms.to_i,
          sent_email: sent_email.to_i,
          skipped: skipped.to_i,
          failed: failed.to_i,
          outside_window: outside_window,
          dry_run: dry_run
        }
      end
    end

    def self.call(organization:, dry_run: false, now: Time.current)
      new(organization: organization, dry_run: dry_run, now: now).call
    end

    def initialize(organization:, dry_run: false, now: Time.current)
      @organization = organization
      @dry_run = dry_run
      @now = now
      saved_settings = organization.settings.to_h.fetch("comms_follow_up_automation", {}).to_h
      @settings = DEFAULTS.merge(saved_settings)
      @settings["email"] = EMAIL_DEFAULTS.deep_merge(saved_settings["email"].to_h)
      @zone = ActiveSupport::TimeZone[@settings["timezone"].presence || "America/Chicago"] || Time.zone
      @local_now = @now.in_time_zone(@zone)
    end

    def call
      process_delayed_completion_without_purchase!
      recovery_counts = process_recovery_pings!
      return result(**recovery_counts, outside_window: false) unless enabled?
      return result(**recovery_counts, outside_window: true) unless within_send_window?

      counts = recovery_counts
      candidate_scope.find_each do |stage|
        counts[:checked] += 1
        decision = follow_up_decision(stage)
        if decision[:send]
          delivered = @dry_run ? dry_run_delivery(decision) : send_follow_up!(stage, decision)
          if delivered.to_h.values.any?
            counts[:sent] += 1
            counts[:sent_sms] += 1 if delivered[:sms]
            counts[:sent_email] += 1 if delivered[:email]
          else
            counts[:skipped] += 1
          end
        else
          counts[:skipped] += 1
        end
      rescue StandardError => error
        counts[:failed] += 1
        mark_follow_up_error(stage, error) if defined?(stage) && stage.present?
        Rails.logger.warn("[Comms::FollowUpRunner] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
      end

      result(**counts, outside_window: false)
    end

    private

    attr_reader :organization, :settings, :local_now

    def result(checked: 0, sent: 0, sent_sms: 0, sent_email: 0, skipped: 0, failed: 0, outside_window: false)
      Result.new(
        checked: checked,
        sent: sent,
        sent_sms: sent_sms,
        sent_email: sent_email,
        skipped: skipped,
        failed: failed,
        outside_window: outside_window,
        dry_run: @dry_run
      ).to_h
    end

    def enabled?
      ActiveModel::Type::Boolean.new.cast(settings["enabled"])
    end

    def dry_run_delivery(decision)
      {
        sms: ActiveModel::Type::Boolean.new.cast(decision[:send_sms]),
        email: ActiveModel::Type::Boolean.new.cast(decision[:send_email])
      }
    end

    def candidate_scope
      organization.crm_record_artifacts
        .includes(:crm_record, :user)
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
        .where("crm_record_artifacts.metadata ->> 'sms_autopilot_enabled' = ?", "true")
    end

    def process_recovery_pings!
      counts = { checked: 0, sent: 0, sent_sms: 0, sent_email: 0, skipped: 0, failed: 0 }
      return counts unless recovery_ping_enabled?
      return counts unless within_send_window?

      candidate_scope.find_each do |stage|
        counts[:checked] += 1
        decision = recovery_ping_decision(stage)
        if decision[:send]
          delivered = @dry_run ? true : send_recovery_ping!(stage, decision)
          if delivered
            counts[:sent] += 1
            counts[:sent_sms] += 1
          else
            counts[:skipped] += 1
          end
        else
          counts[:skipped] += 1
        end
      rescue StandardError => error
        counts[:failed] += 1
        mark_recovery_ping_error(stage, error) if defined?(stage) && stage.present?
        Rails.logger.warn("[Comms::FollowUpRunner] recovery ping stage=#{stage&.id} failed: #{error.class}: #{error.message}")
      end

      counts
    end

    def process_delayed_completion_without_purchase!
      return unless defined?(Comms::SlackNotifier)

      completion_without_purchase_scope.to_a.each do |stage|
        reason = stage.metadata.to_h["sms_autopilot_slack_completion_without_purchase_reason"].presence ||
          "Thumper completed SMS discovery and no Shopify/order purchase evidence is attached after 72 hours."
        Comms::SlackNotifier.ensure_completion_without_purchase_pending!(stage: stage, reason: reason)
        next unless Comms::SlackNotifier.completion_without_purchase_due?(stage.reload)
        next if @dry_run

        owner = if defined?(DealReports::CommsLeadRouter)
          DealReports::CommsLeadRouter.route!(stage, force: true, reason: "completion_without_purchase_72h")
        end
        owner = Comms::SlackNotifier.safe_owner(owner) || Comms::SlackNotifier.safe_owner(stage.reload.user)
        Comms::SlackNotifier.post_completion_without_purchase!(
          stage: stage.reload,
          owner: owner,
          reason: reason,
          force: true
        )
      rescue StandardError => error
        Rails.logger.warn("[Comms::FollowUpRunner] delayed completion Slack failed stage=#{stage&.id} #{error.class}: #{error.message}")
      end
    end

    def completion_without_purchase_scope
      organization.crm_record_artifacts
        .includes(:crm_record, :user)
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
        .where(
          "crm_record_artifacts.metadata ? 'shopify_link_sent_at' OR crm_record_artifacts.metadata ? 'comms_link_reached_at'"
        )
        .where(
          "crm_record_artifacts.metadata ? 'sms_autopilot_completion_sent_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_completed_at' OR COALESCE(crm_record_artifacts.metadata #>> '{comms_bot_state,autopilot_complete}', 'false') = 'true'"
        )
        .where("NOT (crm_record_artifacts.metadata ? 'sms_autopilot_slack_completion_without_purchase_at')")
        .order(updated_at: :desc)
        .limit(500)
    end

    def follow_up_decision(stage)
      metadata = stage.metadata.to_h
      return skip(:do_not_contact) if do_not_contact?(metadata)
      return skip(:sending_disabled) if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
      return skip(:complete) if complete?(metadata)

      events = sms_events(metadata)
      return skip(:no_sms_thread) if events.blank?

      last_event = events.reverse.find { |event| event["status"].to_s != "failed" }
      return skip(:no_last_event) if last_event.blank?
      ready_email = ready_email_draft_decision(stage, metadata, events)
      return ready_email if ready_email.present?
      return skip(:waiting_on_operator) if last_event["direction"].to_s == "inbound"
      return skip(:not_waiting_on_customer) unless last_event["direction"].to_s == "outbound"
      return skip(:last_outbound_recovery_ping) if recovery_ping_event?(last_event)
      return skip(:last_outbound_not_question) unless outbound_question?(last_event)

      first_outbound_at = first_outbound_time(events)
      return skip(:duration_expired) if first_outbound_at.present? && first_outbound_at < duration_days.days.ago

      last_activity_at = parse_time(last_event["created_at"]) || stage.updated_at
      quick_follow_ups_sent = follow_ups_since_last_inbound(events)
      quick_phase = quick_follow_ups_sent < quick_nudge_count
      interval = quick_phase ? quick_nudge_interval : frequency_hours.hours
      return skip(:not_inactive) if last_activity_at > interval.ago

      channel_decision = follow_up_channel_decision(metadata, first_outbound_at)
      return skip(channel_decision[:reason]) unless channel_decision[:send_sms] || channel_decision[:send_email]

      phone = selected_phone(metadata)
      return skip(:missing_phone) if channel_decision[:send_sms] && phone.blank?

      email_to = selected_email(metadata)
      return skip(:missing_email) if channel_decision[:send_email] && email_to.blank?
      return skip(:daily_cap_reached) if channel_decision[:send_sms] && !quick_phase && todays_follow_up_count(metadata) >= max_per_day

      {
        send: true,
        send_sms: channel_decision[:send_sms],
        send_email: channel_decision[:send_email],
        channel_action: channel_decision[:action],
        email_day: channel_decision[:day],
        email_cadence: channel_decision[:cadence],
        phone: phone,
        email_to: email_to,
        last_activity_at: last_activity_at,
        phase: quick_phase ? "quick" : "scheduled",
        interval_seconds: interval.to_i,
        quick_follow_up_number: quick_phase ? quick_follow_ups_sent + 1 : nil,
        quick_follow_up_limit: quick_nudge_count,
        follow_up_number_today: todays_follow_up_count(metadata) + 1,
        follow_up_number_total: metadata["sms_follow_up_sent_count"].to_i + 1
      }
    end

    def recovery_ping_decision(stage)
      metadata = stage.metadata.to_h
      return skip(:do_not_contact) if do_not_contact?(metadata)
      return skip(:sending_disabled) if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
      return skip(:complete) if complete?(metadata)

      events = sms_events(metadata)
      return skip(:no_sms_thread) if events.blank?

      last_event = events.reverse.find { |event| event["status"].to_s != "failed" }
      return skip(:no_last_event) if last_event.blank?
      return skip(:waiting_on_operator) if last_event["direction"].to_s == "inbound"
      return skip(:not_waiting_on_customer) unless last_event["direction"].to_s == "outbound"
      return skip(:last_outbound_recovery_ping) if recovery_ping_event?(last_event)
      return skip(:last_outbound_not_replyable) unless recovery_ping_replyable_outbound?(last_event)

      first_outbound_at = first_outbound_time(events)
      return skip(:duration_expired) if first_outbound_at.present? && first_outbound_at < duration_days.days.ago

      last_activity_at = parse_time(last_event["created_at"]) || stage.updated_at
      return skip(:not_inactive) if last_activity_at > recovery_ping_interval.ago
      return skip(:too_old_for_recovery_ping) if last_activity_at < recovery_ping_max_age.hours.ago
      return skip(:daily_cap_reached) if recovery_ping_daily_count(metadata) >= recovery_ping_max_per_day

      phone = selected_phone(metadata)
      return skip(:missing_phone) if phone.blank?

      {
        send: true,
        send_sms: true,
        phone: phone,
        last_activity_at: last_activity_at,
        interval_seconds: recovery_ping_interval.to_i,
        recovery_ping_number_today: recovery_ping_daily_count(metadata) + 1,
        recovery_ping_number_total: metadata["sms_recovery_ping_sent_count"].to_i + 1
      }
    end

    def skip(reason)
      { send: false, reason: reason }
    end

    def send_follow_up!(stage, decision)
      delivered = {}
      delivered[:sms] = send_sms_follow_up!(stage, decision) if decision[:send_sms]
      delivered[:email] = send_email_follow_up!(stage, decision) if decision[:send_email]
      delivered
    end

    def send_recovery_ping!(stage, decision)
      stage.with_lock do
        stage.reload
        latest = recovery_ping_decision(stage)
        return false unless latest[:send] && latest[:send_sms]

        metadata = stage.metadata.to_h.deep_dup
        user = stage.user || stage.crm_record&.owner || organization.users.order(:id).first
        raise ArgumentError, "COMMS recovery ping needs a user sender profile" if user.blank?

        body = sms_delivery_body_for_stage(stage, recovery_ping_body)
        delivery = Comms::SmsProvider.deliver!(
          to: latest[:phone],
          body: body,
          from_number: user.twilio_profile.to_h["from_number"],
          messaging_service_sid: user.twilio_profile.to_h["messaging_service_sid"]
        )
        append_recovery_ping_event!(stage, metadata, body: body, to: latest[:phone], user: user, provider_result: delivery, decision: latest)
        true
      end
    end

    def send_sms_follow_up!(stage, decision)
      stage.with_lock do
        stage.reload
        latest = follow_up_decision(stage)
        return false unless latest[:send] && latest[:send_sms]

        metadata = stage.metadata.to_h.deep_dup
        user = stage.user || stage.crm_record&.owner || organization.users.order(:id).first
        raise ArgumentError, "COMMS follow-up needs a user sender profile" if user.blank?

        draft = DealReports::CommsDraftWriter.call(
          stage: stage,
          user: user,
          operator_prompt: follow_up_operator_prompt(stage, latest),
          wait_seconds: follow_up_draft_wait_seconds
        )
        raw_body = draft.to_h["body"].to_s.squish
        body = safe_customer_sms_body(raw_body)
        if raw_body.present? && body.blank?
          Rails.logger.warn("[Comms::FollowUpRunner] blocked unsafe follow-up draft stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_body)}")
        end
        if body.blank?
          draft = follow_up_guardrail_draft(stage, metadata, latest, draft)
          body = safe_customer_sms_body(draft.to_h["body"])
        end
        if body.present? && repeated_follow_up_body?(metadata, body)
          Rails.logger.info("[Comms::FollowUpRunner] replacing repeated follow-up draft stage=#{stage&.id}")
          draft = follow_up_guardrail_draft(stage, metadata, latest, draft, reason: "Alice follow-up draft repeated a recent automated nudge, so WIZWIKI used a fresh thread-aware follow-up.")
          body = safe_customer_sms_body(draft.to_h["body"])
        end
        raise ArgumentError, "COMMS follow-up draft was blank" if body.blank?
        raise ArgumentError, "COMMS follow-up draft repeated the last nudge" if repeated_follow_up_body?(metadata, body)

        body = sms_delivery_body_for_stage(stage, body)
        delivery = Comms::SmsProvider.deliver!(
          to: latest[:phone],
          body: body,
          from_number: user.twilio_profile.to_h["from_number"],
          messaging_service_sid: user.twilio_profile.to_h["messaging_service_sid"]
        )
        append_follow_up_event!(stage, metadata, body: body, to: latest[:phone], user: user, provider_result: delivery, draft: draft, decision: latest)
        true
      end
    end

    def send_email_follow_up!(stage, decision)
      stage.with_lock do
        stage.reload
        latest = follow_up_decision(stage)
        return false unless latest[:send] && latest[:send_email]
        decision = latest

        metadata = stage.metadata.to_h.deep_dup
        return false if do_not_contact?(metadata) || complete?(metadata)
        return false if email_follow_up_sent_for_day?(metadata, decision[:email_day])

        user = stage.user || stage.crm_record&.owner || organization.users.order(:id).first
        raise ArgumentError, "COMMS email follow-up needs a user sender profile" if user.blank?

        to = selected_email(metadata)
        return false if to.blank?

        draft = usable_email_follow_up_draft(metadata, decision)
        unless draft.present?
          queue_email_follow_up_draft!(stage, metadata, decision, user: user, to: to)
          return false
        end
        subject = draft.to_h["subject"].to_s.squish.presence
        body = draft.to_h["body"].to_s.strip.presence
        raise ArgumentError, "COMMS email follow-up draft was blank" if subject.blank? || body.blank?

        mail = ThumperMailer.comms_command_email(
          to: to,
          subject: subject,
          body: body,
          stage: stage,
          sender: user
        )
        provider_result = if Postmark::OutboundClient.configured?
          Postmark::OutboundClient.deliver_mail(mail, message_stream: ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound")
        else
          mail.deliver_now
          { "provider" => "action_mailer" }
        end
        append_email_follow_up_event!(stage, metadata, subject: subject, body: body, to: to, user: user, provider_result: provider_result, draft: draft, decision: decision)
        true
      end
    end

    def follow_up_draft_wait_seconds
      ENV.fetch("WIZWIKI_COMMS_FOLLOW_UP_WAIT_SECONDS", "12").to_i.clamp(2, 30)
    end

    def safe_customer_sms_body(value)
      return if value.blank?
      return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

      value.to_s.squish.presence
    end

    def sms_delivery_body_for_stage(stage, value)
      @last_sms_delivery_language_event = nil
      body = value.to_s.squish
      return body if body.blank?
      if defined?(Comms::SmsBodySafety)
        body = Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage&.metadata)
      end
      if defined?(Comms::SmsPreSendVerifier)
        verification = Comms::SmsPreSendVerifier.call(stage: stage, body: body, source: "follow_up_pre_send")
        persist_sms_pre_send_metadata!(stage, verification.to_h["metadata"])
        raise "Thumper pre-send verifier blocked SMS: #{verification.reason}" unless verification.allowed

        body = verification.body.to_s.squish.presence || body
      end
      if defined?(Comms::SmsLanguageSupport)
        result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
        @last_sms_delivery_language_event = result.to_h["event"]
        persist_sms_pre_send_metadata!(stage, result.to_h["metadata"])
        body = result.to_h["body"].presence || body
      end
      body
    end

    def sms_delivery_language_event_payload
      @last_sms_delivery_language_event.to_h.compact_blank
    end

    def persist_sms_pre_send_metadata!(stage, updates)
      return if stage.blank? || updates.to_h.blank?

      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(generated_at: Time.current, metadata: metadata.merge(updates.to_h).compact_blank)
    rescue StandardError => error
      Rails.logger.warn("[Comms::FollowUpRunner] SMS pre-send metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
    end

    def sms_body_safety_reason(value)
      return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

      "unsafe_sms_body"
    end

    def current_specials_prompt_instruction
      return unless defined?(Comms::CurrentSpecials)

      Comms::CurrentSpecials.prompt_instruction
    rescue StandardError => error
      Rails.logger.warn("[Comms::FollowUpRunner] current specials prompt unavailable #{error.class}: #{error.message}")
      nil
    end

    def append_follow_up_event!(stage, metadata, body:, to:, user:, provider_result:, draft:, decision:)
      thread = Array(metadata["sms_thread"]).last(50)
      event = {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "sent",
        "to" => to,
        "body" => body,
        "provider" => provider_result.to_h["provider"].presence || Comms::SmsProvider.provider,
        "provider_message_id" => provider_result.to_h["sid"].presence || provider_result.to_h["message_id"].presence,
        "provider_status" => provider_result.to_h["status"].presence,
        "from" => provider_result.to_h["from"].presence,
        "user_id" => user.id,
        "user_name" => user.display_name,
        "autopilot" => true,
          "follow_up" => true,
          "follow_up_phase" => decision[:phase],
          "quick_follow_up_number" => decision[:quick_follow_up_number],
          "quick_follow_up_limit" => decision[:quick_follow_up_limit],
          "follow_up_number_today" => decision[:follow_up_number_today],
          "follow_up_number_total" => decision[:follow_up_number_total],
        "follow_up_channel_action" => decision[:channel_action],
        "email_follow_up_day" => decision[:email_day],
        "email_follow_up_cadence" => decision[:email_cadence],
        "draft_provider" => draft.to_h["provider"],
        "draft_model" => draft.to_h["model"],
        "created_at" => Time.current.iso8601
      }.merge(sms_delivery_language_event_payload).compact_blank
      thread << event

      pending_metadata = metadata.merge("sms_thread" => thread)
      processing = if defined?(DealReports::CommsProcessingCode)
        DealReports::CommsProcessingCode.call(stage: stage, metadata: pending_metadata, latest_body: body)
      else
        {}
      end
      thread[-1] = thread.last.to_h.merge(
        "processing_code" => processing["processing_code"],
        "processing_label" => processing["processing_label"]
      ).compact_blank

      daily_counts = follow_up_daily_counts(metadata)
      daily_counts[local_date_key] = daily_counts[local_date_key].to_i + 1

      stage.update!(
        status: "aircall_sent",
        generated_at: Time.current,
        metadata: metadata.merge(
          "sms_thread" => thread,
          "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
          "sms_autopilot_last_sent_at" => Time.current.iso8601,
          "sms_follow_up_sent_count" => metadata["sms_follow_up_sent_count"].to_i + 1,
          "sms_follow_up_last_sent_at" => Time.current.iso8601,
          "sms_follow_up_last_status" => "sent",
          "sms_follow_up_last_body" => body,
          "sms_follow_up_last_body_fingerprint" => Digest::SHA256.hexdigest(normalize_follow_up_text(body)),
          "sms_follow_up_last_reason" => nil,
          "sms_follow_up_last_error" => nil,
          "sms_follow_up_last_error_at" => nil,
          "sms_follow_up_daily_counts" => daily_counts,
          "comms_follow_up_plan_step" => follow_up_plan_step_value(metadata, decision),
          "comms_follow_up_plan_last_action" => decision[:channel_action],
          "comms_follow_up_plan_last_cadence" => decision[:email_cadence],
          "sms_listener_active" => true,
          "sms_listener_started_at" => Time.current.iso8601,
          "sms_listener_until" => 7.days.from_now.iso8601,
          "sms_listener_to" => to,
          "sms_listener_last_outbound_sid" => event["provider_message_id"],
          "sms_listener_last_outbound_at" => Time.current.iso8601,
          "comms_command_sms_draft_body" => body,
          "comms_command_sms_draft" => draft.to_h.merge("created_at" => Time.current.iso8601),
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "follow_up_sent",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_last_error" => nil
        ).merge(processing).compact_blank
      )
    end

    def append_recovery_ping_event!(stage, metadata, body:, to:, user:, provider_result:, decision:)
      thread = Array(metadata["sms_thread"]).last(50)
      event = {
        "id" => SecureRandom.uuid,
        "channel" => "sms",
        "direction" => "outbound",
        "status" => "sent",
        "to" => to,
        "body" => body,
        "provider" => provider_result.to_h["provider"].presence || Comms::SmsProvider.provider,
        "provider_message_id" => provider_result.to_h["sid"].presence || provider_result.to_h["message_id"].presence,
        "provider_status" => provider_result.to_h["status"].presence,
        "from" => provider_result.to_h["from"].presence,
        "user_id" => user.id,
        "user_name" => user.display_name,
        "autopilot" => true,
        "recovery_ping" => true,
        "recovery_ping_number_today" => decision[:recovery_ping_number_today],
        "recovery_ping_number_total" => decision[:recovery_ping_number_total],
        "created_at" => Time.current.iso8601
      }.compact_blank
      thread << event

      pending_metadata = metadata.merge("sms_thread" => thread)
      processing = if defined?(DealReports::CommsProcessingCode)
        DealReports::CommsProcessingCode.call(stage: stage, metadata: pending_metadata, latest_body: body)
      else
        {}
      end
      thread[-1] = thread.last.to_h.merge(
        "processing_code" => processing["processing_code"],
        "processing_label" => processing["processing_label"]
      ).compact_blank

      daily_counts = recovery_ping_daily_counts(metadata)
      daily_counts[local_date_key] = daily_counts[local_date_key].to_i + 1

      stage.update!(
        status: "aircall_sent",
        generated_at: Time.current,
        metadata: metadata.merge(
          "sms_thread" => thread,
          "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
          "sms_autopilot_last_sent_at" => Time.current.iso8601,
          "sms_recovery_ping_sent_count" => metadata["sms_recovery_ping_sent_count"].to_i + 1,
          "sms_recovery_ping_last_sent_at" => Time.current.iso8601,
          "sms_recovery_ping_last_status" => "sent",
          "sms_recovery_ping_last_body" => body,
          "sms_recovery_ping_last_reason" => nil,
          "sms_recovery_ping_last_error" => nil,
          "sms_recovery_ping_last_error_at" => nil,
          "sms_recovery_ping_daily_counts" => daily_counts,
          "sms_listener_active" => true,
          "sms_listener_started_at" => Time.current.iso8601,
          "sms_listener_until" => 7.days.from_now.iso8601,
          "sms_listener_to" => to,
          "sms_listener_last_outbound_sid" => event["provider_message_id"],
          "sms_listener_last_outbound_at" => Time.current.iso8601,
          "comms_command_sms_draft_body" => body,
          "comms_command_sms_draft" => {
            "body" => body,
            "provider" => "local/recovery_ping",
            "model" => "deterministic_recovery_ping",
            "draft_source" => "recovery_ping",
            "created_at" => Time.current.iso8601
          },
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "sent",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_last_error" => nil
        ).merge(processing).compact_blank
      )
    end

    def append_email_follow_up_event!(stage, metadata, subject:, body:, to:, user:, provider_result:, draft:, decision:)
      thread = Array(metadata["email_thread"]).last(50)
      event = {
        "id" => SecureRandom.uuid,
        "channel" => "email",
        "direction" => "outbound",
        "status" => "sent",
        "to" => to,
        "subject" => subject,
        "body" => body,
        "provider" => provider_result.to_h["provider"].presence || "email",
        "provider_message_id" => provider_result.to_h["sid"].presence || provider_result.to_h["message_id"].presence,
        "provider_status" => provider_result.to_h["status"].presence || provider_result.to_h["message"].presence,
        "from" => provider_result.to_h["from"].presence,
        "user_id" => user.id,
        "user_name" => user.display_name,
        "autopilot" => true,
        "follow_up" => true,
        "follow_up_channel_action" => decision[:channel_action],
        "email_follow_up_day" => decision[:email_day],
        "email_follow_up_cadence" => decision[:email_cadence],
        "draft_provider" => draft.to_h["provider"],
        "draft_model" => draft.to_h["model"],
        "created_at" => Time.current.iso8601
      }.compact_blank
      thread << event

      daily_counts = email_follow_up_daily_counts(metadata)
      daily_counts[local_date_key] = daily_counts[local_date_key].to_i + 1
      sent_days = email_follow_up_sent_days(metadata)
      sent_days[decision[:email_day].to_s] = local_date_key if decision[:email_day].present?

      stage.update!(
        status: "aircall_sent",
        generated_at: Time.current,
        metadata: metadata.merge(
          "email_thread" => thread,
          "email_follow_up_sent_count" => metadata["email_follow_up_sent_count"].to_i + 1,
          "email_follow_up_last_sent_at" => Time.current.iso8601,
          "email_follow_up_last_status" => "sent",
          "email_follow_up_last_action" => decision[:channel_action],
          "email_follow_up_last_day" => decision[:email_day],
          "email_follow_up_last_error" => nil,
          "email_follow_up_last_error_at" => nil,
          "email_follow_up_daily_counts" => daily_counts,
          "email_follow_up_sent_days" => sent_days,
          "comms_follow_up_plan_step" => follow_up_plan_step_value(metadata, decision),
          "comms_follow_up_plan_last_action" => decision[:channel_action],
          "comms_follow_up_plan_last_cadence" => decision[:email_cadence],
          "comms_command_email_draft" => draft.to_h.merge("created_at" => Time.current.iso8601),
          "composed_email_subject" => subject,
          "composed_email_body" => body,
          "comms_command_last_channel" => "email",
          "comms_command_last_status" => "email_follow_up_sent",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_last_error" => nil
        ).compact_blank
      )
    end

    def follow_up_channel_decision(metadata, first_outbound_at)
      day = email_follow_up_day_number(metadata, first_outbound_at)
      if !email_follow_up_enabled?
        return { send_sms: false, send_email: false, action: "sms", day: day, cadence: "sms", reason: :sms_weekend_paused } if sms_weekend_paused?

        return { send_sms: true, send_email: false, action: "sms", day: day, cadence: "sms" }
      end

      return { send_sms: false, send_email: false, reason: :email_week_not_selected, day: day, cadence: email_follow_up_cadence } unless email_follow_up_week_active?

      action = email_follow_up_day_action(day)
      send_sms = %w[sms both final_both].include?(action)
      send_email = %w[email both final_both].include?(action)
      send_sms = false if send_sms && sms_weekend_paused?
      send_email = false if send_email && email_follow_up_sent_for_day?(metadata, day)

      reason = if send_sms || send_email
        nil
      elsif sms_weekend_paused? && %w[sms both final_both].include?(action)
        :sms_weekend_paused
      elsif %w[email both final_both].include?(action)
        :email_already_sent_today
      else
        :email_plan_no_send
      end
      {
        send_sms: send_sms,
        send_email: send_email,
        action: action,
        day: day,
        cadence: email_follow_up_cadence,
        reason: reason
      }
    end

    def email_follow_up_enabled?
      ActiveModel::Type::Boolean.new.cast(email_follow_up_settings["enabled"]) && %w[weekly monthly].include?(email_follow_up_cadence)
    end

    def email_follow_up_settings
      settings["email"].to_h
    end

    def email_follow_up_cadence
      return "off" unless ActiveModel::Type::Boolean.new.cast(email_follow_up_settings["enabled"])
      return "off" if email_follow_up_settings["preset"].to_s == "off"
      return "monthly" if email_follow_up_settings["preset"].to_s == "monthly" || email_follow_up_settings["cadence"].to_s == "monthly"

      "weekly"
    end

    def email_follow_up_week_active?
      return true unless email_follow_up_cadence == "monthly"

      email_follow_up_selected_weeks.include?(email_follow_up_week_key)
    end

    def email_follow_up_selected_weeks
      Array(email_follow_up_settings["selected_weeks"]).map(&:to_s)
    end

    def email_follow_up_week_key
      local_now.to_date.beginning_of_week(:monday).iso8601
    end

    def email_follow_up_day_action(day)
      plan = if email_follow_up_settings["schedule_mode"].to_s == "custom"
        email_follow_up_settings["daily_plan"].to_h
      else
        preset = email_follow_up_settings["preset"].to_s
        EMAIL_FOLLOW_UP_PRESET_DAYS[preset] || EMAIL_FOLLOW_UP_PRESET_DAYS.fetch("normal")
      end
      action = plan[day.to_i.to_s].to_s
      EMAIL_FOLLOW_UP_DAY_ACTIONS.include?(action) ? action : "none"
    end

    def ready_email_draft_decision(stage, metadata, events)
      return unless email_follow_up_enabled?
      return unless email_follow_up_week_active?

      draft = metadata["comms_command_email_draft"].to_h
      return if ActiveModel::Type::Boolean.new.cast(draft["pending"])
      return if draft["subject"].to_s.squish.blank? || draft["body"].to_s.squish.blank?
      return if draft["email_follow_up_date"].to_s != local_date_key

      day = draft["email_follow_up_day"].to_i
      return if day <= 0
      return if email_follow_up_sent_for_day?(metadata, day)

      action = draft["email_follow_up_action"].presence || email_follow_up_day_action(day)
      return unless %w[email both final_both].include?(action)

      due_at = parse_time(draft["email_follow_up_due_at"]) || local_now
      return if due_at > local_now

      created_at = parse_time(draft["created_at"])
      return if created_at.present? && sms_event_after?(events, created_at)

      email_to = selected_email(metadata)
      return if email_to.blank?

      {
        send: true,
        send_sms: false,
        send_email: true,
        channel_action: action,
        email_day: day,
        email_cadence: email_follow_up_cadence,
        phone: nil,
        email_to: email_to,
        last_activity_at: due_at,
        phase: "email_predraft",
        interval_seconds: 0,
        quick_follow_up_number: nil,
        quick_follow_up_limit: quick_nudge_count,
        follow_up_number_today: todays_follow_up_count(metadata) + 1,
        follow_up_number_total: metadata["sms_follow_up_sent_count"].to_i + 1,
        email_draft_ready: true
      }
    end

    def email_follow_up_day_number(_metadata, _first_outbound_at)
      wday = local_now.wday
      wday.zero? ? 7 : wday
    end

    def sms_weekend_paused?
      local_now.saturday? || local_now.sunday?
    end

    def business_day_number(start_date, today)
      date = start_date
      count = 0
      while date <= today
        count += 1 unless date.saturday? || date.sunday?
        date += 1.day
      end
      [count, 1].max
    end

    def email_follow_up_weekday_label(day)
      %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday][day.to_i - 1] || "Day #{day}"
    end

    def usable_email_follow_up_draft(metadata, decision)
      draft = metadata["comms_command_email_draft"].to_h
      return if ActiveModel::Type::Boolean.new.cast(draft["pending"])
      return if draft["subject"].to_s.squish.blank? || draft["body"].to_s.squish.blank?
      return if draft["email_follow_up_date"].to_s != local_date_key
      return if draft["email_follow_up_day"].to_i != decision[:email_day].to_i
      return if draft["email_follow_up_action"].to_s != decision[:channel_action].to_s

      expected_key = email_follow_up_draft_key(metadata, decision)
      return if draft["email_follow_up_draft_key"].to_s != expected_key

      draft
    end

    def queue_email_follow_up_draft!(stage, metadata, decision, user:, to:)
      draft = metadata["comms_command_email_draft"].to_h
      expected_key = email_follow_up_draft_key(metadata, decision, to: to)
      if ActiveModel::Type::Boolean.new.cast(draft["pending"]) && draft["email_follow_up_draft_key"].to_s == expected_key
        return true
      end

      pending = DealReports::CommsEmailDraftWriter.queue_background(
        stage: stage,
        user: user,
        operator_prompt: email_follow_up_operator_prompt(stage, decision),
        writer_model: email_writer_model,
        schedule_context: email_follow_up_schedule_context(stage, metadata, decision, to: to, draft_key: expected_key)
      )
      stage.update!(
        metadata: metadata.merge(
          "comms_command_email_prompt" => pending["operator_prompt"].presence,
          "comms_command_email_draft" => pending.merge("created_at" => Time.current.iso8601),
          "comms_command_email_background_question_id" => pending["autos_question_id"],
          "comms_command_email_background_status" => pending["background_queued"] ? "queued" : "failed",
          "comms_command_email_background_at" => Time.current.iso8601,
          "comms_command_email_background_error" => pending["error"].presence,
          "comms_command_email_background_due_at" => decision_due_at(metadata, decision)&.iso8601,
          "comms_command_email_background_draft_key" => expected_key
        ).compact_blank
      )
      true
    end

    def email_follow_up_schedule_context(stage, metadata, decision, to:, draft_key:)
      {
        "stage_id" => stage.id,
        "date" => local_date_key,
        "day" => decision[:email_day],
        "weekday" => email_follow_up_weekday_label(decision[:email_day]),
        "action" => decision[:channel_action],
        "cadence" => email_follow_up_cadence,
        "week" => email_follow_up_week_key,
        "due_at" => decision_due_at(metadata, decision)&.iso8601,
        "email_to" => to,
        "draft_key" => draft_key
      }.compact_blank
    end

    def email_follow_up_draft_key(metadata, decision, to: nil)
      last_event = sms_events(metadata).reverse.find { |event| event["status"].to_s != "failed" }
      due_at = decision_due_at(metadata, decision)
      Digest::SHA256.hexdigest(
        [
          local_date_key,
          decision[:email_day],
          decision[:channel_action],
          to.presence || decision[:email_to].presence || selected_email(metadata),
          due_at&.to_i,
          last_event.to_h["created_at"],
          last_event.to_h["body"].to_s.squish,
          metadata["composed_email_subject"],
          metadata["composed_email_body"]
        ].join("|")
      )
    end

    def decision_due_at(metadata, decision)
      return decision[:last_activity_at] if decision[:phase].to_s == "email_predraft"

      last_activity_at = decision[:last_activity_at] || begin
        last_event = sms_events(metadata).reverse.find { |event| event["status"].to_s != "failed" }
        parse_time(last_event.to_h["created_at"])
      end
      return if last_activity_at.blank?

      last_activity_at + decision[:interval_seconds].to_i.seconds
    end

    def email_writer_model
      if defined?(WizwikiSettings)
        WizwikiSettings.normalize_sms_writer_model_alias(ENV["WIZWIKI_COMMS_EMAIL_DRAFT_BACKGROUND_MODEL"].presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_MODEL"].presence || "qwen3:8b")
      else
        ENV["WIZWIKI_COMMS_EMAIL_DRAFT_BACKGROUND_MODEL"].presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_MODEL"].presence || "qwen3:8b"
      end
    end

    def follow_up_plan_step_value(metadata, decision)
      day = decision[:email_day].to_i
      return if day <= 0

      [metadata["comms_follow_up_plan_step"].to_i, day].max
    end

    def email_follow_up_sent_for_day?(metadata, day)
      email_follow_up_sent_days(metadata)[day.to_s] == local_date_key ||
        email_follow_up_daily_counts(metadata)[local_date_key].to_i.positive?
    end

    def email_follow_up_sent_days(metadata)
      metadata["email_follow_up_sent_days"].to_h.slice(*("1".."7").to_a)
    end

    def email_follow_up_daily_counts(metadata)
      recent_dates = (0..14).map { |days_ago| (local_now.to_date - days_ago).iso8601 }
      metadata["email_follow_up_daily_counts"].to_h.slice(*recent_dates)
    end

    def follow_up_operator_prompt(stage, decision)
      metadata = stage.metadata.to_h
      prior_messages = recent_outbound_messages(metadata)
      recent_nudges = recent_follow_up_messages(metadata)
      [
        "This is a scheduled follow-up SMS for an open WIZWIKI COMMS conversation.",
        "Only follow up because the customer has not answered the last outbound SMS.",
        "Do not restart the conversation from scratch.",
        "Use the current SMS thread, known product fit, fine training docs, Shopify links, and Thumper voice.",
        current_specials_prompt_instruction,
        Thumper::VoiceGuide.sms_prompt,
        "Write one short helpful follow-up that moves the conversation forward without pressure. Sound like Thumper: practical, plainspoken, specific, and useful.",
        "The last outbound SMS asked a question that has not been answered. Do not follow up if you are not asking one useful next question.",
        "Every automated follow-up must be materially unique in wording, opener, and angle from every prior outbound message in this thread.",
        "Never send the same nudge twice. If the last nudge asked about artwork, ask about quantity, package fit, link help, or business context instead. If it asked about quantity, ask about package fit, artwork, or whether the link helped.",
        "Uniqueness key: #{SecureRandom.hex(4)}.",
        recent_nudges.present? ? "Recent automated nudges to avoid repeating: #{recent_nudges.map.with_index(1) { |body, index| "#{index}) #{body}" }.join(" | ")}" : nil,
        prior_messages.present? ? "Prior outbound messages to avoid repeating: #{prior_messages.map.with_index(1) { |body, index| "#{index}) #{body}" }.join(" | ")}" : nil,
        follow_up_phase_instruction(decision),
        "If a Shopify link was already sent, ask if that package/deal helped or if they want help choosing a better fit.",
        "If no link was sent, ask one concrete next question that helps choose Pro Pack deal, Starter Pack deal, Yard Signs package, EDDM, or Neighborhood Blitz. Treat artwork/logo/proof needs as support context for the chosen print product.",
        "Follow-up number today: #{decision[:follow_up_number_today]} of #{max_per_day}.",
        "Total follow-ups on this block: #{decision[:follow_up_number_total]}.",
        "Current product label: #{metadata['product_interest_label'].presence || metadata['processing_label'].presence || 'pending'}."
      ].compact_blank.join(" ")
    end

    def email_follow_up_operator_prompt(stage, decision)
      metadata = stage.metadata.to_h
      [
        "This is a scheduled follow-up email for an open WIZWIKI COMMS conversation.",
        Thumper::VoiceGuide.email_prompt,
        "Use the same Thumper brain, Thumper voice, product knowledge, SMS thread, email thread, and account context as manual email drafting.",
        current_specials_prompt_instruction,
        "Email schedule: #{email_follow_up_cadence}, #{email_follow_up_weekday_label(decision[:email_day])}, action #{decision[:channel_action]}.",
        "Do not restart from scratch unless the thread has no useful context.",
        "Answer any unresolved customer question directly before asking for the next step.",
        "Keep the email useful and specific. Do not write a generic checking-in email.",
        "Do not repeat the last SMS or email follow-up. Pick a fresh angle tied to the customer's actual situation.",
        "If the customer needs proof/design help, explain that proof/design support happens after checkout/order intake and nothing prints until approval.",
        "If a link or package was already sent by SMS, reference it naturally without over-explaining.",
        "Current product label: #{metadata['product_interest_label'].presence || metadata['processing_label'].presence || 'pending'}."
      ].compact_blank.join(" ")
    end

    def follow_up_guardrail_draft(stage, metadata, decision, draft, reason: nil)
      reason ||= if ActiveModel::Type::Boolean.new.cast(draft.to_h["pending"]) || draft.to_h["draft_source"].to_s == "pending"
        "Alice follow-up draft was still pending, so WIZWIKI used a fresh thread-aware follow-up question to keep the scheduled follow-up moving."
      else
        "Alice follow-up draft was blank, so WIZWIKI used a fresh thread-aware follow-up question to keep the scheduled follow-up moving."
      end
      {
        "body" => follow_up_guardrail_body(stage, metadata, decision),
        "provider" => "local/follow_up_guardrail",
        "model" => "thread_aware_follow_up_guardrail",
        "draft_source" => "follow_up_guardrail",
        "reason" => reason,
        "fallback_from_provider" => draft.to_h["provider"].presence,
        "fallback_from_model" => draft.to_h["model"].presence,
        "fallback_from_error" => draft.to_h["error"].presence
      }.compact_blank
    end

    def follow_up_guardrail_body(stage, metadata, decision)
      follow_up_guardrail_questions(metadata).each do |question|
        next if recent_follow_up_question?(metadata, question)

        body = question.to_s.squish.truncate(300)
        return body unless repeated_follow_up_body?(metadata, body)
      end

      label = metadata["product_interest_label"].presence || metadata["processing_label"].presence || "WIZWIKI"
      "Still want help choosing the right #{label} option?".squish.truncate(300)
    end

    def follow_up_guardrail_questions(metadata)
      [
        fresh_follow_up_candidates(metadata),
        reframed_unanswered_question(metadata),
        last_unanswered_outbound_question(metadata),
        fallback_follow_up_questions(metadata)
      ].flatten.compact_blank.uniq
    end

    def unique_follow_up_question(metadata, *questions)
      questions.flatten.compact_blank.find do |question|
        !recent_follow_up_question?(metadata, question)
      end
    end

    def fallback_follow_up_question(metadata)
      unique_follow_up_question(metadata, fallback_follow_up_questions(metadata))
    end

    def fallback_follow_up_questions(metadata)
      label = metadata["product_interest_label"].presence || metadata["processing_label"].presence || "WIZWIKI"
      [
        "Are you leaning toward the Starter Pack deal, Pro Pack deal, or a more focused #{label} package?",
        "Would it help if I pointed you to the cleanest package or deal for what you are trying to promote?",
        "Do you already have artwork/logo files ready, or should WIZWIKI help with the design after checkout?",
        "Is the main goal mailbox reach, signs in the ground, or both working together?"
      ]
    end

    def fresh_follow_up_question(metadata)
      fresh_follow_up_candidates(metadata).find do |question|
        !recent_follow_up_question?(metadata, question)
      end
    end

    def fresh_follow_up_candidates(metadata)
      fit = metadata.dig("comms_bot_state", "campaign_fit").to_h
      missing = Array(fit["missing_fit_signals"]).map(&:to_s)
      route = metadata["product_interest_code"].to_s
      candidates = []

      if missing.include?("artwork_status") || fit["artwork_status"].blank?
        candidates << "Do you already have artwork or a logo ready, or should WIZWIKI help with the design after checkout?"
      end

      if route == "LAWN_SIGNS" && fit["quantity_count"].blank?
        candidates << "Are you thinking a small sign batch, a jobsite run, or a bigger Yard Signs package?"
      end

      if fit["household_count"].blank? && (truthy?(fit["wants_postcards"]) || truthy?(fit["wants_both"]) || %w[STARTER_PACK PRO_PACK EDDM NEIGHBORHOOD_BLITZ].include?(route))
        candidates << "Is this more like a small street-level test, one neighborhood, or a few mailing routes?"
      end

      if business_context_blank?(metadata)
        candidates << "Is this for home services, real estate, food or retail, or another type of business?"
      end

      if shopify_link_sent?(metadata)
        label = metadata["product_interest_label"].presence || metadata["processing_label"].presence || "WIZWIKI"
        candidates << "Did that #{label} package/deal fit, or do you want help choosing a better match?"
      end

      candidates
    end

    def reframed_unanswered_question(metadata)
      question = last_unanswered_outbound_question(metadata).to_s
      return if question.blank?

      case question
      when /\bwhat kind of business|business are we helping|business.*promot/i
        "Is this for home services, real estate, food or retail, or another type of business?"
      when /\bhow many homes|homes.*reach|households|doors/i
        "Is this more like a small street-level test, one neighborhood, or a few mailing routes?"
      when /\bpostcards?|yard signs?|both|mailboxes?|signs in the ground/i
        "Which should lead the first push: mailbox reach, yard signs, or both together?"
      when /\bartwork|logo|design|creative/i
        "Do you already have artwork or a logo ready, or should WIZWIKI help create the design?"
      else
        question
      end
    end

    def recent_follow_up_question?(metadata, question)
      normalized_question = normalize_follow_up_text(question)
      return false if normalized_question.blank?

      recent_outbound_messages(metadata).last(6).any? do |body|
        normalized_body = normalize_follow_up_text(body)
        normalized_body == normalized_question ||
          normalized_body.include?(normalized_question) ||
          normalized_question.include?(normalized_body)
      end
    end

    def repeated_follow_up_body?(metadata, body)
      normalized_body = normalize_follow_up_text(body)
      return true if normalized_body.blank?

      recent_follow_up_messages(metadata).last(6).any? do |prior|
        follow_up_texts_too_similar?(normalized_body, normalize_follow_up_text(prior))
      end
    end

    def follow_up_texts_too_similar?(current, prior)
      return false if current.blank? || prior.blank?
      return true if current == prior
      return true if current.length > 24 && prior.length > 24 && (current.include?(prior) || prior.include?(current))

      current_words = current.split.uniq
      prior_words = prior.split.uniq
      return false if current_words.length < 5 || prior_words.length < 5

      overlap = (current_words & prior_words).length.to_f / [current_words.length, prior_words.length].min
      length_ratio = [current.length, prior.length].min.to_f / [current.length, prior.length].max
      overlap >= 0.82 && length_ratio >= 0.62
    end

    def normalize_follow_up_text(value)
      value.to_s.downcase
        .sub(/\A(?:quick follow-up|checking back|no rush, one helpful detail|quick question|one question|quick practical check|one useful detail|small follow-up|small practical check|still worth asking|one clean next step)[:,]?\s*/i, "")
        .gsub(/[^a-z0-9]+/, " ")
        .squish
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end

    def business_context_blank?(metadata)
      metadata.dig("comms_bot_state", "business_context").blank? &&
        metadata["captured_industry"].blank? &&
        metadata["industry"].blank?
    end

    def shopify_link_sent?(metadata)
      metadata["shopify_link_sent_at"].present? ||
        metadata["comms_link_reached_at"].present? ||
        Array(metadata["sms_thread"]).any? { |event| event.to_h["body"].to_s.match?(%r{https?://}i) }
    end

    def last_unanswered_outbound_question(metadata)
      sms_events(metadata).reverse_each do |event|
        next unless event["direction"].to_s == "outbound"
        next if event["status"].to_s == "failed"

        body = event["body"].to_s.squish
        next unless outbound_question?(event)

        question = body.scan(/[^.!?]*\?/).last.to_s.squish.presence || body
        return question.sub(/\A(?:quick follow-up|checking back|no rush, one helpful detail|quick question|one question|quick practical check|one useful detail|small follow-up|small practical check|still worth asking|one clean next step)[:,]?\s*/i, "").squish
      end
      nil
    end

    def mark_follow_up_error(stage, error)
      metadata = stage.metadata.to_h
      stage.update!(
        metadata: metadata.merge(
          "sms_follow_up_last_status" => "failed",
          "sms_follow_up_last_error" => error.message,
          "sms_follow_up_last_error_at" => Time.current.iso8601
        )
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def within_send_window?
      start_minutes = minutes_for(settings["send_window_start"], "09:00")
      end_minutes = minutes_for(settings["send_window_end"], "17:00")
      now_minutes = (local_now.hour * 60) + local_now.min

      if start_minutes <= end_minutes
        now_minutes >= start_minutes && now_minutes <= end_minutes
      else
        now_minutes >= start_minutes || now_minutes <= end_minutes
      end
    end

    def minutes_for(value, fallback)
      text = value.to_s.match?(/\A(?:[01]?\d|2[0-3]):[0-5]\d\z/) ? value.to_s : fallback
      hour, minute = text.split(":").map(&:to_i)
      (hour * 60) + minute
    end

    def frequency_hours
      settings["frequency_hours"].to_i.clamp(2, 168)
    end

    def duration_days
      settings["duration_days"].to_i.clamp(1, 90)
    end

    def max_per_day
      settings["max_per_day"].to_i.clamp(1, 12)
    end

    def quick_nudge_count
      settings["quick_nudge_count"].to_i.clamp(0, 6)
    end

    def quick_nudge_interval
      settings["quick_nudge_minutes"].to_i.clamp(15, 240).minutes
    end

    def recovery_ping_enabled?
      env_value = ENV["WIZWIKI_COMMS_SMS_RECOVERY_PING_ENABLED"]
      return ActiveModel::Type::Boolean.new.cast(env_value) unless env_value.nil?

      ActiveModel::Type::Boolean.new.cast(settings.fetch("recovery_ping_enabled", true))
    end

    def recovery_ping_interval
      minutes = ENV.fetch("WIZWIKI_COMMS_SMS_RECOVERY_PING_MINUTES", settings["recovery_ping_minutes"].presence || DEFAULT_RECOVERY_PING_MINUTES).to_i
      minutes.clamp(5, 1_440).minutes
    end

    def recovery_ping_max_per_day
      ENV.fetch("WIZWIKI_COMMS_SMS_RECOVERY_PING_MAX_PER_DAY", settings["recovery_ping_max_per_day"].presence || 1).to_i.clamp(1, 3)
    end

    def recovery_ping_max_age
      ENV.fetch("WIZWIKI_COMMS_SMS_RECOVERY_PING_MAX_AGE_HOURS", settings["recovery_ping_max_age_hours"].presence || 12).to_i.clamp(1, 72)
    end

    def recovery_ping_body
      "Just checking in. If you replied and I missed it, please send it one more time. If you no longer want messages, reply STOP."
    end

    def recovery_ping_replyable_outbound?(event)
      return false if ActiveModel::Type::Boolean.new.cast(event.to_h["follow_up"])

      body = event.to_h["body"].to_s.squish
      outbound_question?(event) ||
        body.match?(%r{https?://}i) ||
        body.match?(/\b(?:reply|text me|send|want|need|choose|checkout|link|quantity|option)\b/i)
    end

    def recovery_ping_event?(event)
      ActiveModel::Type::Boolean.new.cast(event.to_h["recovery_ping"])
    end

    def do_not_contact?(metadata)
      metadata["comms_board_state"].to_s == "opt_out" ||
        ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) ||
        metadata["sms_do_not_contact_at"].present? ||
        metadata["comms_command_last_status"].to_s == "do_not_contact"
    end

    def complete?(metadata)
      metadata["sms_autopilot_completed_at"].present? ||
        metadata["sms_autopilot_completion_sent_at"].present? ||
        ActiveModel::Type::Boolean.new.cast(metadata.dig("comms_bot_state", "autopilot_complete"))
    end

    def selected_phone(metadata)
      selected_id = metadata["selected_phone_id"].to_s
      options = Array(metadata["phone_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first).to_h["value"].to_s.squish.presence
    end

    def selected_email(metadata)
      selected_id = metadata["selected_recipient_email_id"].to_s
      options = Array(metadata["recipient_email_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first).to_h["value"].to_s.squish.presence
    end

    def sms_events(metadata)
      Array(metadata["sms_thread"]).map(&:to_h).select { |event| event["channel"].to_s == "sms" }
    end

    def sms_event_after?(events, time)
      return false if time.blank?

      events.any? do |event|
        event_time = parse_time(event.to_h["created_at"])
        event_time.present? && event_time > time
      end
    end

    def outbound_question?(event)
      body = event.to_h["body"].to_s.squish
      return true if body.include?("?")

      body.match?(/\b(?:can you|could you|would you|do you|are you|what|which|when|where|how many|how much|want me to|should i|does that|would that|is that)\b/i)
    end

    def follow_ups_since_last_inbound(events)
      latest_inbound_at = events.reverse_each.lazy.filter_map do |event|
        next unless event["direction"].to_s == "inbound"

        parse_time(event["created_at"])
      end.first

      events.count do |event|
        next false unless event["direction"].to_s == "outbound"
        next false unless ActiveModel::Type::Boolean.new.cast(event["follow_up"])

        event_time = parse_time(event["created_at"])
        latest_inbound_at.blank? || event_time.blank? || event_time > latest_inbound_at
      end
    end

    def first_outbound_time(events)
      event = events.find { |item| item["direction"].to_s == "outbound" && item["status"].to_s != "failed" }
      parse_time(event.to_h["created_at"])
    end

    def follow_up_phase_instruction(decision)
      if decision[:phase].to_s == "quick"
        "This is post-last-message unanswered-question nudge #{decision[:quick_follow_up_number]} of #{decision[:quick_follow_up_limit]}, sent after about #{settings['quick_nudge_minutes'].to_i.clamp(5, 240)} minutes. Make it clearly different from the previous ask and use a concrete buying signal such as budget, quantity, signs vs postcards, artwork/logo, or whether they want a link with options."
      else
        "The #{quick_nudge_count} post-last-message nudges are already used. This is the configured slower follow-up cadence; make it useful, fresh, and situation-aware instead of repeating the earlier ask."
      end
    end

    def recent_outbound_messages(metadata)
      sms_events(metadata)
        .select { |event| event["direction"].to_s == "outbound" && event["status"].to_s != "failed" }
        .filter_map { |event| event["body"].to_s.squish.presence }
        .last(8)
    end

    def recent_follow_up_messages(metadata)
      sms_events(metadata)
        .select do |event|
          event["direction"].to_s == "outbound" &&
            event["status"].to_s != "failed" &&
            ActiveModel::Type::Boolean.new.cast(event["follow_up"])
        end
        .filter_map { |event| event["body"].to_s.squish.presence }
        .last(8)
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def follow_up_daily_counts(metadata)
      recent_dates = (0..14).map { |days_ago| (local_now.to_date - days_ago).iso8601 }
      metadata["sms_follow_up_daily_counts"].to_h.slice(*recent_dates)
    end

    def todays_follow_up_count(metadata)
      follow_up_daily_counts(metadata)[local_date_key].to_i
    end

    def recovery_ping_daily_counts(metadata)
      recent_dates = (0..14).map { |days_ago| (local_now.to_date - days_ago).iso8601 }
      metadata["sms_recovery_ping_daily_counts"].to_h.slice(*recent_dates)
    end

    def recovery_ping_daily_count(metadata)
      recovery_ping_daily_counts(metadata)[local_date_key].to_i
    end

    def mark_recovery_ping_error(stage, error)
      metadata = stage.metadata.to_h
      stage.update!(
        metadata: metadata.merge(
          "sms_recovery_ping_last_status" => "failed",
          "sms_recovery_ping_last_error" => error.message,
          "sms_recovery_ping_last_error_at" => Time.current.iso8601
        )
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def local_date_key
      local_now.to_date.iso8601
    end
 end
end
