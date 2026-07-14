module Comms
  class InboundSmsRecoverySweep
    DEFAULT_LIMIT = 60
    MAX_LIMIT = 200
    MIN_INBOUND_AGE = 90.seconds
    MAX_INBOUND_AGE = 36.hours
    REQUEUE_COOLDOWN = 3.minutes
    BACKGROUND_REPLY_STALE_AFTER = ENV.fetch("WIZWIKI_SMS_BACKGROUND_REPLY_STALE_SECONDS", "240").to_i.clamp(90, 900).seconds
    ACTIVE_BACKGROUND_STATUSES = %w[queued running drafting pending claimed processing draft_pending].freeze
    RECOVERABLE_DRAFT_STATUSES = %w[
      autopilot_blocked
      draft_failed
      draft_pending
      failed
      late_send_failed
      no_body
      queued
      reply_blank
      reply_blocked
      reply_drafted
      running
      stale
    ].freeze
    MAX_RECOVERIES_PER_INBOUND = ENV.fetch("WIZWIKI_SMS_NO_GHOST_MAX_RECOVERIES_PER_INBOUND", "3").to_i.clamp(1, 10)

    Result = Struct.new(:checked, :recovered, :skipped, :failed, :dry_run, :errors, keyword_init: true) do
      def to_h
        {
          checked: checked.to_i,
          recovered: recovered.to_i,
          skipped: skipped.to_i,
          failed: failed.to_i,
          dry_run: dry_run,
          errors: Array(errors)
        }
      end
    end

    def self.call(organization:, limit: nil, dry_run: false)
      new(organization: organization, limit: limit, dry_run: dry_run).call
    end

    def initialize(organization:, limit: nil, dry_run: false)
      @organization = organization
      @limit = normalized_limit(limit)
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    end

    def call
      counts = { checked: 0, recovered: 0, skipped: 0, failed: 0 }
      errors = []

      candidate_scope.each do |stage|
        counts[:checked] += 1
        decision = recovery_decision(stage)
        unless decision[:recover]
          counts[:skipped] += 1
          next
        end

        if dry_run
          counts[:recovered] += 1
        elsif enqueue_recovery!(stage)
          counts[:recovered] += 1
        else
          counts[:skipped] += 1
        end
      rescue StandardError => error
        counts[:failed] += 1
        errors << "stage=#{stage&.id} #{error.class}: #{error.message}"
        mark_recovery_error(stage, error) if defined?(stage) && stage.present?
        Rails.logger.warn("[Comms::InboundSmsRecoverySweep] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
      end

      Result.new(**counts, dry_run: dry_run, errors: errors).to_h
    end

    private

    attr_reader :organization, :limit, :dry_run

    def normalized_limit(value)
      value = value.to_i
      value = DEFAULT_LIMIT if value <= 0
      [value, MAX_LIMIT].min
    end

    def candidate_scope
      organization.crm_record_artifacts
        .includes(:crm_record, :user)
        .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
        .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
        .where("crm_record_artifacts.metadata ->> 'sms_autopilot_enabled' = ?", "true")
        .where("crm_record_artifacts.metadata ->> 'sms_listener_last_inbound_at' IS NOT NULL")
        .where("COALESCE(crm_record_artifacts.metadata ->> 'sms_sending_disabled', 'false') != ?", "true")
        .where("COALESCE(crm_record_artifacts.metadata ->> 'sms_do_not_contact', 'false') != ?", "true")
        .where(
          "COALESCE(crm_record_artifacts.metadata ->> 'comms_command_last_status', '') NOT IN (?)",
          %w[do_not_contact human_requested account_manager_support am_support]
        )
        .order(Arel.sql("(crm_record_artifacts.metadata ->> 'sms_listener_last_inbound_at') DESC NULLS LAST"))
        .limit(limit)
    end

    def recovery_decision(stage)
      metadata = stage.metadata.to_h
      return skip(:autopilot_off) unless truthy?(metadata["sms_autopilot_enabled"])
      return skip(:sending_disabled) if truthy?(metadata["sms_sending_disabled"])
      return skip(:do_not_contact) if truthy?(metadata["sms_do_not_contact"])
      return skip(:complete) if metadata["comms_command_last_status"].to_s == "autopilot_complete"

      inbound = latest_inbound_event(metadata)
      return skip(:no_inbound) if inbound.blank?

      inbound_at = parse_time(inbound["created_at"]) || parse_time(metadata["sms_listener_last_inbound_at"])
      return skip(:too_new) if inbound_at.present? && inbound_at > MIN_INBOUND_AGE.ago
      return skip(:too_old) if inbound_at.present? && inbound_at < MAX_INBOUND_AGE.ago
      return skip(:outbound_after_inbound) if outbound_after_inbound?(metadata, inbound, inbound_at)

      reply_key = Comms::AutopilotReplyLock.key(
        inbound_sid: inbound_sid(inbound),
        inbound_body: inbound["body"],
        from: inbound["from"]
      )
      return skip(:missing_key) if reply_key.blank?
      return skip(:already_answered) if Comms::AutopilotReplyLock.answered?(metadata, key: reply_key)

      terminal_failure = terminal_draft_failure(metadata, inbound_at)
      if terminal_failure.present?
        return no_ghost_attention(
          stage,
          metadata,
          reply_key,
          inbound,
          terminal_failure[:draft],
          reason: "terminal_quality_gate:#{terminal_failure[:reason]}"
        )
      end

      stale_draft = stale_recoverable_draft_after_inbound(metadata, inbound_at)
      return skip(:draft_after_inbound) if stale_draft.blank? && draft_after_inbound?(metadata, inbound_at)
      return skip(:reply_job_active) if active_background_reply?(metadata, inbound_at)

      reservation = metadata["sms_autopilot_reply_reservation"].to_h
      if reservation["key"].to_s == reply_key && Comms::AutopilotReplyLock.reservation_active?(reservation)
        return skip(:reply_reserved)
      end

      recovery = metadata["sms_inbound_recovery"].to_h
      recovery_queued_at = parse_time(recovery["queued_at"])
      if recovery["key"].to_s == reply_key && recovery_queued_at.present? && recovery_queued_at > REQUEUE_COOLDOWN.ago
        return skip(:recently_queued)
      end
      if recovery_attempts_for_key(metadata, reply_key) >= MAX_RECOVERIES_PER_INBOUND
        return no_ghost_attention(stage, metadata, reply_key, inbound, stale_draft, reason: "max_recoveries_reached")
      end

      {
        recover: true,
        reason: stale_draft.present? ? :stale_draft_after_inbound : :unanswered_inbound,
        inbound: inbound,
        reply_key: reply_key,
        stale_draft: stale_draft
      }
    end

    def skip(reason)
      { recover: false, reason: reason }
    end

    def enqueue_recovery!(stage)
      decision = nil
      generation = nil

      stage.with_lock do
        stage.reload
        decision = recovery_decision(stage)
        return false unless decision[:recover]

        metadata = stage.metadata.to_h.deep_dup
        generation = metadata["sms_reply_generation"].presence ||
          decision.dig(:inbound, "reply_generation").presence ||
          SecureRandom.uuid
        canceled_question_id = cancel_stale_worker_question!(metadata)
        metadata["sms_inbound_recovery"] = {
          "key" => decision[:reply_key],
          "inbound_sid" => inbound_sid(decision[:inbound]),
          "generation" => generation,
          "queued_at" => Time.current.iso8601,
          "inbound_created_at" => decision.dig(:inbound, "created_at"),
          "source" => "recovery_sweep",
          "reason" => decision[:reason],
          "job" => "Comms::InboundSmsReplyJob",
          "canceled_question_id" => canceled_question_id
        }.compact_blank
        metadata["sms_no_ghost_watchdog"] = watchdog_payload(
          status: "requeued",
          reason: decision[:reason],
          reply_key: decision[:reply_key],
          inbound: decision[:inbound],
          stale_draft: decision[:stale_draft]
        )
        metadata["sms_no_ghost_watchdog_history"] = watchdog_history(metadata, metadata["sms_no_ghost_watchdog"])
        metadata["sms_no_ghost_watchdog_count"] = metadata["sms_no_ghost_watchdog_count"].to_i + 1
        metadata["sms_inbound_recovery_count"] = metadata["sms_inbound_recovery_count"].to_i + 1
        metadata["sms_inbound_recovery_attempts_by_key"] = increment_recovery_attempt(metadata, decision[:reply_key])
        metadata["sms_reply_generation"] = generation
        metadata["sms_reply_job_generation"] = generation
        metadata["sms_reply_job_status"] = "queued"
        metadata["sms_reply_job_queued_at"] = Time.current.iso8601
        metadata["comms_command_last_status"] = "reply_recovery_queued"
        metadata["comms_command_last_at"] = Time.current.iso8601
        stage.update!(generated_at: Time.current, metadata: metadata)
      end

      inbound = decision[:inbound]
      # Client-initiated replies are transactional, so this intentionally ignores follow-up send windows.
      Comms::InboundSmsReplyJob.perform_later(
        stage_id: stage.id,
        from: inbound["from"].to_s,
        to: inbound["to"].to_s,
        body: inbound["body"].to_s,
        sid: inbound_sid(inbound).to_s,
        provider: inbound["provider"].presence || "twilio",
        generation: generation
      )
      true
    rescue StandardError => error
      mark_recovery_error(stage, error)
      raise
    end

    def mark_recovery_error(stage, error)
      return if stage.blank?

      metadata = stage.metadata.to_h.deep_dup
      metadata["sms_inbound_recovery_last_error"] = "#{error.class}: #{error.message}"
      metadata["sms_inbound_recovery_last_error_at"] = Time.current.iso8601
      stage.update!(generated_at: Time.current, metadata: metadata)
    rescue StandardError => update_error
      Rails.logger.warn("[Comms::InboundSmsRecoverySweep] error mark failed stage=#{stage&.id} #{update_error.class}: #{update_error.message}")
    end

    def latest_inbound_event(metadata)
      sms_events(metadata).reverse.find do |event|
        event = event.to_h
        event["direction"].to_s == "inbound" &&
          ["", "sms"].include?(event["channel"].to_s) &&
          event["body"].to_s.squish.present? &&
          !%w[failed canceled undelivered].include?(event["status"].to_s)
      end&.to_h
    end

    def outbound_after_inbound?(metadata, inbound, inbound_at)
      events = sms_events(metadata)
      inbound_index = event_index(events, inbound)
      later_events = inbound_index ? Array(events[(inbound_index + 1)..]) : events

      later_events.any? do |event|
        event = event.to_h
        next false unless event["direction"].to_s == "outbound"
        next false unless ["", "sms"].include?(event["channel"].to_s)
        next false if %w[failed canceled undelivered].include?(event["status"].to_s)

        event_time = parse_time(event["created_at"])
        inbound_index.present? || (inbound_at.present? && event_time.present? && event_time > inbound_at)
      end
    end

    def draft_after_inbound?(metadata, inbound_at)
      return false if inbound_at.blank?

      draft = metadata["comms_command_sms_draft"].to_h
      body = metadata["comms_command_sms_draft_body"].presence || draft["body"].presence
      return false if body.blank?
      return false if stale_rejected_draft_after_inbound?(metadata, draft)
      return false if stale_recoverable_draft_after_inbound(metadata, inbound_at).present?

      draft_at = parse_time(draft["created_at"]) ||
        parse_time(metadata["comms_command_background_at"]) ||
        parse_time(metadata["comms_command_last_at"])
      draft_at.present? && draft_at > inbound_at
    end

    def stale_rejected_draft_after_inbound?(metadata, draft)
      background_status = metadata["comms_command_background_status"].to_s
      last_status = metadata["comms_command_last_status"].to_s
      return true if background_status.match?(/\A(?:rejected|rejected_quality_gate|rejected_sms_quality_gate|late_send_failed|failed|no_body)\b/)
      return true if last_status.in?(%w[reply_blocked draft_failed])

      ActiveModel::Type::Boolean.new.cast(draft["fallback_after_worker_rejection"]) ||
        ActiveModel::Type::Boolean.new.cast(draft["guardrail_after_worker_rejection"]) ||
        draft["rejected_question_id"].present?
    end

    def terminal_draft_failure(metadata, inbound_at)
      draft = metadata["comms_command_sms_draft"].to_h
      draft_at = parse_time(draft["created_at"]) || parse_time(metadata["sms_reply_job_failed_at"])
      return if draft_at.blank?
      return if inbound_at.present? && draft_at <= inbound_at

      background_status = metadata["comms_command_background_status"].to_s
      draft_source = draft["draft_source"].to_s
      return unless background_status.match?(/\Arejected(?:_|$)/) || draft_source.in?(%w[quality_rejected guardrail_rejected])

      reason = metadata["sms_guardrail_retry_reason"].to_s.presence ||
        draft["reason"].to_s[/\b([a-z][a-z0-9_]{3,})\z/, 1].presence ||
        "quality_gate_rejected"
      {
        reason: reason,
        draft: {
          "draft_created_at" => draft_at.iso8601,
          "draft_age_seconds" => (Time.current - draft_at).round,
          "recoverable_statuses" => [background_status, draft_source].compact_blank,
          "terminal_failure" => true
        }
      }
    end

    def stale_recoverable_draft_after_inbound(metadata, inbound_at)
      return if inbound_at.blank?

      draft = metadata["comms_command_sms_draft"].to_h
      body = metadata["comms_command_sms_draft_body"].presence || draft["body"].presence
      draft_at = parse_time(draft["created_at"]) ||
        parse_time(metadata["comms_command_background_at"]) ||
        parse_time(metadata["comms_command_last_at"])
      return if draft_at.blank? || draft_at <= inbound_at
      return if draft_at > BACKGROUND_REPLY_STALE_AFTER.ago

      statuses = [
        metadata["sms_reply_job_status"],
        metadata["comms_command_background_status"],
        metadata["comms_command_last_status"],
        draft["draft_source"],
        draft["sms_quality_gate"]
      ].map { |value| value.to_s.downcase.presence }.compact
      pending_placeholder = ActiveModel::Type::Boolean.new.cast(draft["pending"]) || body.blank?
      recoverable_status = statuses.any? do |status|
        RECOVERABLE_DRAFT_STATUSES.any? { |prefix| status == prefix || status.start_with?("#{prefix}_") }
      end
      recoverable_rejection = stale_rejected_draft_after_inbound?(metadata, draft)
      return unless pending_placeholder || recoverable_status || recoverable_rejection

      {
        "draft_created_at" => draft_at.iso8601,
        "draft_age_seconds" => (Time.current - draft_at).round,
        "pending_placeholder" => pending_placeholder,
        "recoverable_statuses" => statuses,
        "body_present" => body.present?
      }.compact_blank
    end

    def active_background_reply?(metadata, inbound_at)
      return false unless ACTIVE_BACKGROUND_STATUSES.include?(metadata["comms_command_background_status"].to_s)

      background_at = parse_time(metadata["comms_command_background_at"])
      return true if background_at.blank?
      return false if background_at < BACKGROUND_REPLY_STALE_AFTER.ago

      inbound_at.blank? || background_at > inbound_at
    end

    def sms_events(metadata)
      Array(metadata["sms_thread"]).map(&:to_h)
    end

    def recovery_attempts_for_key(metadata, reply_key)
      persisted = metadata["sms_inbound_recovery_attempts_by_key"].to_h[reply_key.to_s].to_i
      return persisted if persisted.positive?

      history = Array(metadata["sms_no_ghost_watchdog_history"]).map(&:to_h)
      history.count { |entry| entry["reply_key"].to_s == reply_key.to_s && entry["status"].to_s == "requeued" }
    end

    def increment_recovery_attempt(metadata, reply_key)
      attempts = metadata["sms_inbound_recovery_attempts_by_key"].to_h.transform_values(&:to_i)
      attempts[reply_key.to_s] = attempts[reply_key.to_s].to_i + 1
      attempts.to_a.last(30).to_h
    end

    def no_ghost_attention(stage, metadata, reply_key, inbound, stale_draft, reason:)
      current = metadata["sms_no_ghost_watchdog"].to_h
      if current["status"].to_s == "needs_attention" &&
          current["reply_key"].to_s == reply_key.to_s &&
          metadata["sms_reply_job_status"].to_s == "needs_attention"
        return skip(:already_needs_attention)
      end

      payload = watchdog_payload(
        status: "needs_attention",
        reason: reason,
        reply_key: reply_key,
        inbound: inbound,
        stale_draft: stale_draft
      )
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.deep_dup.merge(
          "sms_no_ghost_watchdog" => payload,
          "sms_no_ghost_watchdog_history" => watchdog_history(metadata, payload),
          "sms_reply_job_status" => "needs_attention",
          "sms_reply_job_completed_at" => Time.current.iso8601,
          "comms_command_last_status" => "reply_needs_attention",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_background_completed_at" => Time.current.iso8601
        ).compact_blank
      )
      skip(:max_recoveries_reached)
    end

    def cancel_stale_worker_question!(metadata)
      question_id = metadata["comms_command_background_question_id"].presence ||
        metadata.dig("comms_command_sms_draft", "autos_question_id").presence
      return if question_id.blank? || !defined?(AutosQuestion)

      question = AutosQuestion.find_by(id: question_id)
      return if question.blank? || question.status.to_s.in?(%w[answered failed canceled complete completed])
      return if question.created_at > BACKGROUND_REPLY_STALE_AFTER.ago

      now = Time.current
      question.update_columns(
        status: "canceled",
        metadata: question.metadata.to_h.deep_merge(
          "local_worker" => {
            "status" => "canceled",
            "canceled_at" => now.iso8601,
            "cancel_reason" => "stale_sms_generation_recovery"
          }
        ),
        updated_at: now
      )
      question.id
    rescue StandardError => error
      Rails.logger.warn("[Comms::InboundSmsRecoverySweep] stale question cancel failed question=#{question_id}: #{error.class}: #{error.message}")
      nil
    end

    def watchdog_payload(status:, reason:, reply_key:, inbound:, stale_draft: nil)
      {
        "status" => status.to_s,
        "reason" => reason.to_s,
        "reply_key" => reply_key.to_s.presence,
        "inbound_sid" => inbound_sid(inbound.to_h),
        "inbound_created_at" => inbound.to_h["created_at"].presence,
        "stale_draft" => stale_draft.presence,
        "checked_at" => Time.current.iso8601
      }.compact_blank
    end

    def watchdog_history(metadata, payload)
      (Array(metadata["sms_no_ghost_watchdog_history"]).last(9) + [payload]).compact_blank
    end

    def event_index(events, target)
      target_key = event_key(target)
      events.rindex { |event| event_key(event) == target_key } if target_key.present?
    end

    def event_key(event)
      event = event.to_h
      inbound_sid(event).presence ||
        event["id"].presence ||
        [event["direction"], event["created_at"], event["body"]].join(":")
    end

    def inbound_sid(event)
      event["provider_message_id"].presence || event["sid"].presence || event["id"].presence
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
