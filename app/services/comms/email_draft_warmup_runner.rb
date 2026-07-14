require "digest"

module Comms
  class EmailDraftWarmupRunner
    EMAIL_ACTIONS = %w[email both final_both].freeze
    DEFAULT_LIMIT = 5
    DEFAULT_LEAD_TIME_MINUTES = 180
    DEFAULT_MAX_QUEUED_EMAIL_DRAFTS = 12

    Result = Struct.new(:checked, :queued, :skipped, :failed, :dry_run, :reasons, keyword_init: true) do
      def to_h
        {
          checked: checked.to_i,
          queued: queued.to_i,
          skipped: skipped.to_i,
          failed: failed.to_i,
          dry_run: dry_run,
          reasons: reasons.to_h
        }
      end
    end

    def self.call(organization:, now: Time.current, limit: nil, dry_run: false)
      new(organization: organization, now: now, limit: limit, dry_run: dry_run).call
    end

    def initialize(organization:, now: Time.current, limit: nil, dry_run: false)
      @organization = organization
      @now = now
      @settings = follow_up_defaults.deep_merge(organization.settings.to_h.fetch("comms_follow_up_automation", {}).to_h)
      @settings["email"] = email_defaults.deep_merge(@settings["email"].to_h)
      @zone = ActiveSupport::TimeZone[@settings["timezone"].presence || "America/Chicago"] || Time.zone
      @local_now = @now.in_time_zone(@zone)
      @limit = (limit.presence || ENV.fetch("WIZWIKI_COMMS_EMAIL_DRAFT_WARMUP_LIMIT", DEFAULT_LIMIT.to_s)).to_i.clamp(1, 50)
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    end

    def call
      counts = { checked: 0, queued: 0, skipped: 0, failed: 0 }
      reasons = Hash.new(0)

      unless email_follow_up_enabled?
        reasons[:email_scheduler_off] += 1
        return result(**counts, reasons: reasons)
      end

      unless defined?(Autos::WorkerQueue) && Autos::WorkerQueue.enabled?
        reasons[:alice_worker_disabled] += 1
        return result(**counts, reasons: reasons)
      end

      if queued_email_draft_backlog >= max_queued_email_drafts
        reasons[:email_draft_backlog_full] += 1
        return result(**counts, reasons: reasons)
      end

      candidate_scope.find_each do |stage|
        break if counts[:queued] >= @limit
        break if queued_email_draft_backlog >= max_queued_email_drafts

        counts[:checked] += 1
        decision = warmup_decision(stage)
        unless decision[:queue]
          counts[:skipped] += 1
          reasons[decision[:reason] || :skipped] += 1
          next
        end

        if @dry_run
          counts[:queued] += 1
          next
        end

        queue_stage_draft!(stage, decision)
        counts[:queued] += 1
      rescue StandardError => error
        counts[:failed] += 1
        reasons[:failed] += 1
        Rails.logger.warn("[Comms::EmailDraftWarmupRunner] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
      end

      result(**counts, reasons: reasons)
    end

    private

    attr_reader :organization, :settings, :local_now

    def result(checked: 0, queued: 0, skipped: 0, failed: 0, reasons: {})
      Result.new(
        checked: checked,
        queued: queued,
        skipped: skipped,
        failed: failed,
        dry_run: @dry_run,
        reasons: reasons
      ).to_h
    end

    def follow_up_defaults
      if defined?(Comms::FollowUpRunner::DEFAULTS)
        Comms::FollowUpRunner::DEFAULTS.merge("email" => email_defaults)
      else
        {
          "enabled" => false,
          "frequency_hours" => 24,
          "duration_days" => 14,
          "max_per_day" => 2,
          "quick_nudge_count" => 2,
          "quick_nudge_minutes" => 15,
          "send_window_start" => "09:00",
          "send_window_end" => "17:00",
          "timezone" => "America/Chicago",
          "email" => email_defaults
        }
      end
    end

    def email_defaults
      if defined?(Comms::FollowUpRunner::EMAIL_DEFAULTS)
        Comms::FollowUpRunner::EMAIL_DEFAULTS
      else
        {
          "enabled" => false,
          "preset" => "normal",
          "cadence" => "off",
          "schedule_mode" => "preset",
          "daily_plan" => preset_days.fetch("normal")
        }
      end
    end

    def preset_days
      if defined?(Comms::FollowUpRunner::EMAIL_FOLLOW_UP_PRESET_DAYS)
        Comms::FollowUpRunner::EMAIL_FOLLOW_UP_PRESET_DAYS
      else
        {
          "normal" => { "1" => "both", "2" => "none", "3" => "email", "4" => "both", "5" => "none", "6" => "none", "7" => "both" },
          "moderate" => { "1" => "both", "2" => "both", "3" => "none", "4" => "email", "5" => "both", "6" => "none", "7" => "both" },
          "aggressive" => { "1" => "both", "2" => "both", "3" => "email", "4" => "both", "5" => "email", "6" => "both", "7" => "both" },
          "monthly" => { "1" => "none", "2" => "none", "3" => "email", "4" => "none", "5" => "both", "6" => "none", "7" => "none" }
        }
      end
    end

    def candidate_scope
      organization.crm_record_artifacts
        .includes(:crm_record, :user)
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
        .where("crm_record_artifacts.metadata ->> 'sms_autopilot_enabled' = ?", "true")
        .order(updated_at: :desc)
        .limit(250)
    end

    def warmup_decision(stage)
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
      return skip(:last_outbound_not_question) unless outbound_question?(last_event)

      first_outbound_at = first_outbound_time(events)
      return skip(:duration_expired) if first_outbound_at.present? && first_outbound_at < duration_days.days.ago

      day = email_follow_up_day_number
      return skip(:email_week_not_selected) unless email_follow_up_week_active?

      action = email_follow_up_day_action(day)
      return skip(:email_plan_no_send) unless EMAIL_ACTIONS.include?(action)
      return skip(:email_already_sent_today) if email_follow_up_sent_for_day?(metadata, day)

      email_to = selected_email(metadata)
      return skip(:missing_email) if email_to.blank?

      last_activity_at = parse_time(last_event["created_at"]) || stage.updated_at
      quick_follow_ups_sent = follow_ups_since_last_inbound(events)
      quick_phase = quick_follow_ups_sent < quick_nudge_count
      interval = quick_phase ? quick_nudge_interval : frequency_hours.hours
      due_at = last_activity_at + interval
      return skip(:not_in_warmup_window) if due_at > local_now + lead_time_minutes.minutes

      draft_key = email_follow_up_draft_key(stage: stage, metadata: metadata, day: day, action: action, last_event: last_event, email_to: email_to, due_at: due_at)
      return skip(:draft_ready) if usable_email_follow_up_draft?(metadata, draft_key)
      return skip(:draft_already_queued) if pending_email_follow_up_draft?(metadata, draft_key)

      {
        queue: true,
        day: day,
        weekday: email_follow_up_weekday_label(day),
        action: action,
        email_to: email_to,
        due_at: due_at,
        draft_key: draft_key,
        last_activity_at: last_activity_at,
        quick_phase: quick_phase
      }
    end

    def skip(reason)
      { queue: false, reason: reason }
    end

    def queue_stage_draft!(stage, decision)
      stage.with_lock do
        stage.reload
        latest = warmup_decision(stage)
        return false unless latest[:queue]

        user = stage.user || stage.crm_record&.owner || organization.users.order(:id).first
        raise ArgumentError, "COMMS email warmup needs a user sender profile" if user.blank?

        schedule_context = schedule_context_for(stage, latest)
        pending = DealReports::CommsEmailDraftWriter.queue_background(
          stage: stage,
          user: user,
          operator_prompt: email_follow_up_operator_prompt(stage, latest),
          writer_model: email_writer_model,
          schedule_context: schedule_context
        )
        metadata = stage.metadata.to_h.deep_dup
        stage.update!(
          metadata: metadata.merge(
            "comms_command_email_prompt" => pending["operator_prompt"].presence,
            "comms_command_email_draft" => pending.merge("created_at" => Time.current.iso8601),
            "comms_command_email_background_question_id" => pending["autos_question_id"],
            "comms_command_email_background_status" => pending["background_queued"] ? "queued" : "failed",
            "comms_command_email_background_at" => Time.current.iso8601,
            "comms_command_email_background_error" => pending["error"].presence,
            "comms_command_email_background_due_at" => latest[:due_at]&.iso8601,
            "comms_command_email_background_draft_key" => latest[:draft_key]
          ).compact_blank
        )
      end
      true
    end

    def schedule_context_for(stage, decision)
      {
        "stage_id" => stage.id,
        "date" => local_date_key,
        "day" => decision[:day],
        "weekday" => decision[:weekday],
        "action" => decision[:action],
        "cadence" => email_follow_up_cadence,
        "week" => email_follow_up_week_key,
        "due_at" => decision[:due_at]&.iso8601,
        "email_to" => decision[:email_to],
        "draft_key" => decision[:draft_key],
        "lead_time_minutes" => lead_time_minutes,
        "quick_phase" => decision[:quick_phase]
      }.compact_blank
    end

    def email_follow_up_operator_prompt(stage, decision)
      metadata = stage.metadata.to_h
      [
        "This is a low-priority scheduled email pre-draft for WIZWIKI COMMS.",
        Thumper::VoiceGuide.email_prompt,
        "Do not send the email. Write the draft so Rails can send it later if the thread is still eligible.",
        "Email schedule: #{email_follow_up_cadence}, #{decision[:weekday]}, action #{decision[:action]}, due around #{decision[:due_at]&.in_time_zone(@zone)&.strftime('%l:%M %p %Z')}.",
        "Use Thumper's latest voice guide, product docs, fine-training context, SMS thread, email thread, and account context.",
        "Answer any unresolved customer question directly before asking for the next step.",
        "Keep the email useful and specific. Do not write a generic checking-in email.",
        "Do not repeat the last SMS or email follow-up. Pick a fresh angle tied to the customer's actual situation.",
        "If proof/design help is relevant, explain that proof/design support happens after checkout/order intake and nothing prints until approval.",
        "Current product label: #{metadata['product_interest_label'].presence || metadata['processing_label'].presence || 'pending'}."
      ].compact_blank.join(" ")
    end

    def email_writer_model
      if defined?(WizwikiSettings)
        WizwikiSettings.normalize_sms_writer_model_alias(ENV["WIZWIKI_COMMS_EMAIL_DRAFT_BACKGROUND_MODEL"].presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_MODEL"].presence || "qwen3:8b")
      else
        ENV["WIZWIKI_COMMS_EMAIL_DRAFT_BACKGROUND_MODEL"].presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_MODEL"].presence || "qwen3:8b"
      end
    end

    def queued_email_draft_backlog
      return 0 unless defined?(AutosQuestion)

      AutosQuestion
        .where(status: "queued", answer: [nil, ""])
        .where("metadata ->> 'surface' = ?", "comms_email_draft")
        .where("COALESCE(metadata -> 'local_worker' ->> 'status', '') IN ('queued', 'retry', 'claimed')")
        .count
    end

    def max_queued_email_drafts
      ENV.fetch("WIZWIKI_COMMS_EMAIL_DRAFT_MAX_BACKLOG", DEFAULT_MAX_QUEUED_EMAIL_DRAFTS.to_s).to_i.clamp(1, 100)
    end

    def lead_time_minutes
      ENV.fetch("WIZWIKI_COMMS_EMAIL_DRAFT_LEAD_MINUTES", DEFAULT_LEAD_TIME_MINUTES.to_s).to_i.clamp(15, 1_440)
    end

    def email_follow_up_enabled?
      email_settings = settings["email"].to_h
      ActiveModel::Type::Boolean.new.cast(email_settings["enabled"]) && email_settings["preset"].to_s != "off"
    end

    def email_follow_up_cadence
      email_settings = settings["email"].to_h
      return "off" unless ActiveModel::Type::Boolean.new.cast(email_settings["enabled"])
      return "off" if email_settings["preset"].to_s == "off"
      return "monthly" if email_settings["preset"].to_s == "monthly" || email_settings["cadence"].to_s == "monthly"

      "weekly"
    end

    def email_follow_up_week_active?
      return true unless email_follow_up_cadence == "monthly"

      Array(settings["email"].to_h["selected_weeks"]).map(&:to_s).include?(email_follow_up_week_key)
    end

    def email_follow_up_week_key
      local_now.to_date.beginning_of_week(:monday).iso8601
    end

    def email_follow_up_day_action(day)
      email_settings = settings["email"].to_h
      plan = if email_settings["schedule_mode"].to_s == "custom"
        email_settings["daily_plan"].to_h
      else
        preset_days[email_settings["preset"].to_s] || preset_days.fetch("normal")
      end
      action = plan[day.to_i.to_s].to_s
      Comms::FollowUpRunner::EMAIL_FOLLOW_UP_DAY_ACTIONS.include?(action) ? action : "none"
    end

    def email_follow_up_day_number
      wday = local_now.wday
      wday.zero? ? 7 : wday
    end

    def email_follow_up_weekday_label(day)
      %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday][day.to_i - 1] || "Day #{day}"
    end

    def usable_email_follow_up_draft?(metadata, draft_key)
      draft = metadata["comms_command_email_draft"].to_h
      return false if ActiveModel::Type::Boolean.new.cast(draft["pending"])
      return false if draft["subject"].to_s.squish.blank? || draft["body"].to_s.squish.blank?

      draft["email_follow_up_draft_key"].to_s == draft_key.to_s
    end

    def pending_email_follow_up_draft?(metadata, draft_key)
      draft = metadata["comms_command_email_draft"].to_h
      return false unless ActiveModel::Type::Boolean.new.cast(draft["pending"])
      return false unless draft["email_follow_up_draft_key"].to_s == draft_key.to_s

      created_at = parse_time(draft["created_at"])
      created_at.blank? || created_at > 45.minutes.ago
    end

    def email_follow_up_draft_key(stage:, metadata:, day:, action:, last_event:, email_to:, due_at:)
      Digest::SHA256.hexdigest(
        [
          local_date_key,
          day,
          action,
          email_to,
          due_at&.to_i,
          last_event.to_h["created_at"],
          last_event.to_h["body"].to_s.squish,
          metadata["composed_email_subject"],
          metadata["composed_email_body"]
        ].join("|")
      )
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

    def frequency_hours
      settings["frequency_hours"].to_i.clamp(2, 168)
    end

    def duration_days
      settings["duration_days"].to_i.clamp(1, 90)
    end

    def quick_nudge_count
      settings["quick_nudge_count"].to_i.clamp(0, 6)
    end

    def quick_nudge_interval
      settings["quick_nudge_minutes"].to_i.clamp(5, 240).minutes
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

    def selected_email(metadata)
      selected_id = metadata["selected_recipient_email_id"].to_s
      options = Array(metadata["recipient_email_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first).to_h["value"].to_s.squish.presence
    end

    def sms_events(metadata)
      Array(metadata["sms_thread"]).map(&:to_h).select { |event| event["channel"].to_s == "sms" }
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

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def local_date_key
      local_now.to_date.iso8601
    end
  end
end
