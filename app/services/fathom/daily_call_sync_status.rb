module Fathom
  class DailyCallSyncStatus
    KEY = "fathom_daily_call_sync".freeze
    ACTIVE_STATES = %w[queued running embedding].freeze
    STALE_AFTER = 45.minutes

    class << self
      def for(organization)
        new(organization).to_h
      end

      def active?(organization)
        self.for(organization)[:active]
      end

      def mark_queued!(organization:, request_id:, requested_by_user_id:, requested_by:, requested_at:, date:)
        new(organization).write!(
          "state" => "queued",
          "request_id" => request_id,
          "job_id" => nil,
          "requested_by_user_id" => requested_by_user_id,
          "requested_by" => requested_by,
          "requested_at" => iso_time(requested_at),
          "date" => date.to_s,
          "queued_at" => iso_time(Time.current),
          "started_at" => nil,
          "heartbeat_at" => iso_time(Time.current),
          "completed_at" => nil,
          "duration_seconds" => nil,
          "digest_job_id" => nil,
          "digest_sent_at" => nil,
          "digest_skipped" => false,
          "digest_skip_reason" => nil,
          "google_doc" => {},
          "embedding_status" => {},
          "last_error" => nil
        )
      end

      def mark_enqueued!(organization:, request_id:, job_id:)
        new(organization).write_if_current!(request_id) do |status|
          status.merge(
            "job_id" => job_id,
            "state" => status["state"].presence || "queued",
            "queued_at" => status["queued_at"].presence || iso_time(Time.current),
            "heartbeat_at" => iso_time(Time.current)
          )
        end
      end

      def mark_running!(organization:, request_id:, job_id:, requested_by_user_id:, requested_at:, date:)
        new(organization).write!(
          "state" => "running",
          "request_id" => request_id.presence || job_id,
          "job_id" => job_id,
          "requested_by_user_id" => requested_by_user_id,
          "requested_at" => requested_at,
          "date" => date.to_s,
          "started_at" => iso_time(Time.current),
          "heartbeat_at" => iso_time(Time.current),
          "completed_at" => nil,
          "duration_seconds" => nil,
          "digest_sent_at" => nil,
          "digest_skipped" => false,
          "digest_skip_reason" => nil,
          "google_doc" => {},
          "embedding_status" => {},
          "last_error" => nil
        )
      end

      def mark_success!(organization:, result:, request_id:, job_id:)
        completed_at = Time.current
        new(organization).write_if_current!(request_id.presence || job_id) do |status|
          started_at = parse_time(status["started_at"])
          counts = result.to_h
          status.merge(
            "state" => "success",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id,
            "completed_at" => iso_time(completed_at),
            "duration_seconds" => duration_seconds(started_at, completed_at),
            "last_successful_at" => iso_time(completed_at),
            "last_success_counts" => counts,
            "last_error" => nil
          )
        end
      end

      def mark_embedding!(organization:, request_id:, job_id:, digest_job_id:, embedding_status:)
        new(organization).write_if_current!(request_id.presence || job_id) do |status|
          status.merge(
            "state" => "embedding",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id.presence || status["job_id"],
            "digest_job_id" => digest_job_id,
            "embedding_status" => embedding_status.to_h,
            "heartbeat_at" => iso_time(Time.current),
            "last_error" => nil
          )
        end
      end

      def mark_delivered!(organization:, request_id:, job_id:, digest_job_id:, google_doc:, embedding_status:)
        completed_at = Time.current
        doc = (google_doc || {}).to_h
        new(organization).write_if_current!(request_id.presence || job_id || digest_job_id) do |status|
          started_at = parse_time(status["started_at"])
          status.merge(
            "state" => "success",
            "request_id" => request_id.presence || status["request_id"] || job_id || digest_job_id,
            "job_id" => job_id.presence || status["job_id"],
            "digest_job_id" => digest_job_id,
            "completed_at" => iso_time(completed_at),
            "duration_seconds" => duration_seconds(started_at, completed_at),
            "digest_sent_at" => iso_time(completed_at),
            "heartbeat_at" => iso_time(completed_at),
            "digest_skipped" => false,
            "google_doc" => doc.slice("id", "name", "webViewLink"),
            "embedding_status" => embedding_status.to_h,
            "last_error" => nil
          )
        end
      end

      def mark_no_calls!(organization:, request_id:, job_id:)
        completed_at = Time.current
        new(organization).write_if_current!(request_id.presence || job_id) do |status|
          started_at = parse_time(status["started_at"])
          status.merge(
            "state" => "success",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id,
            "completed_at" => iso_time(completed_at),
            "duration_seconds" => duration_seconds(started_at, completed_at),
            "digest_sent_at" => nil,
            "heartbeat_at" => iso_time(completed_at),
            "digest_skipped" => true,
            "digest_skip_reason" => "no_fathom_calls",
            "embedding_status" => {
              "status" => "skipped_no_calls",
              "complete" => true,
              "waiting" => false,
              "call_count" => 0,
              "chunk_count" => 0
            },
            "last_error" => nil
          )
        end
      end

      def mark_failed!(organization:, error:, request_id:, job_id:)
        completed_at = Time.current
        new(organization).write_if_current!(request_id.presence || job_id) do |status|
          started_at = parse_time(status["started_at"])
          status.merge(
            "state" => "failed",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id,
            "completed_at" => iso_time(completed_at),
            "duration_seconds" => duration_seconds(started_at, completed_at),
            "heartbeat_at" => iso_time(completed_at),
            "last_error" => "#{error.class}: #{error.message}".truncate(280)
          )
        end
      end

      def iso_time(value)
        return if value.blank?

        time = value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
        time&.iso8601
      rescue ArgumentError, TypeError
        value.to_s
      end

      def parse_time(value)
        return if value.blank?

        value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def duration_seconds(started_at, completed_at)
        return if started_at.blank? || completed_at.blank?

        (completed_at.to_f - started_at.to_f).round
      end
    end

    def initialize(organization)
      @organization = organization
    end

    def to_h
      status = raw_status
      state = status["state"].presence || "idle"
      started_at = self.class.parse_time(status["started_at"])
      queued_at = self.class.parse_time(status["queued_at"])
      heartbeat_at = self.class.parse_time(status["heartbeat_at"])
      completed_at = self.class.parse_time(status["completed_at"])
      last_successful_at = self.class.parse_time(status["last_successful_at"])
      active_since = heartbeat_at || started_at || queued_at
      stale = ACTIVE_STATES.include?(state) && active_since.present? && active_since < STALE_AFTER.ago
      counts = status.fetch("last_success_counts", {}).to_h

      {
        state: stale ? "stale" : state,
        active: ACTIVE_STATES.include?(state) && !stale,
        stale: stale,
        job_id: status["job_id"],
        request_id: status["request_id"],
        date: status["date"],
        completed_at: completed_at&.iso8601,
        heartbeat_at: heartbeat_at&.iso8601,
        duration_seconds: status["duration_seconds"],
        last_successful_at: last_successful_at&.iso8601,
        last_success_counts: counts,
        digest_job_id: status["digest_job_id"],
        digest_sent_at: status["digest_sent_at"],
        digest_skipped: ActiveModel::Type::Boolean.new.cast(status["digest_skipped"]),
        digest_skip_reason: status["digest_skip_reason"],
        google_doc: status["google_doc"].to_h,
        embedding_status: status["embedding_status"].to_h,
        last_error: status["last_error"],
        state_label: state_label(stale ? "stale" : state),
        detail_label: detail_label(state, stale, status, counts),
        last_success_label: last_success_label(last_successful_at, counts),
        duration_label: duration_label(status["duration_seconds"])
      }
    end

    def write!(attrs)
      organization.with_lock do
        persist!(raw_status.merge(attrs))
      end
    end

    def write_if_current!(request_id)
      organization.with_lock do
        status = raw_status
        current = status["request_id"].presence || status["job_id"].presence
        return status if request_id.present? && current.present? && current != request_id

        persist!(yield(status))
      end
    end

    private

    attr_reader :organization

    def raw_status
      organization.reload.settings.to_h.fetch(KEY, {}).to_h
    end

    def persist!(status)
      settings = organization.settings.to_h.deep_dup
      settings[KEY] = status
      organization.update!(settings: settings)
      status
    end

    def state_label(state)
      case state
      when "queued" then "queued"
      when "running" then "Fathom sync running"
      when "embedding" then "Fathom Brain embedding calls"
      when "success" then "last Fathom sync complete"
      when "failed" then "last Fathom sync failed"
      when "stale" then "Fathom sync status stale"
      else "Fathom sync idle"
      end
    end

    def detail_label(state, stale, status, counts)
      return "Background sync may still be running, but the last heartbeat is older than #{duration_label(STALE_AFTER.to_i)}." if stale
      return "Waiting for Solid Queue to pick up Fathom job #{status["job_id"].presence || status["request_id"]}." if state == "queued"
      return "Reading today's Fathom call summaries, transcripts, action items, and CRM matches." if state == "running"
      return embedding_label(status["embedding_status"].to_h) if state == "embedding"
      return status["last_error"].presence || "No successful Fathom sync yet." if state == "failed"
      return "No Fathom sync has been started yet." if state.blank? || state == "idle"
      return "No Fathom calls found for that day; Google Doc and email were skipped." if ActiveModel::Type::Boolean.new.cast(status["digest_skipped"])

      counts_label(counts).presence || "Fathom calls are up to date from the last completed sync."
    end

    def last_success_label(time, counts)
      return "No successful Fathom sync yet." if time.blank?

      "Last successful Fathom sync #{time.in_time_zone.strftime("%b %-d, %-I:%M %p")} // #{counts_label(counts)}"
    end

    def counts_label(counts)
      return if counts.blank?

      "#{counts["created"].to_i} new, #{counts["updated"].to_i} updated, #{counts["unchanged"].to_i} unchanged, #{counts["call_count"].to_i} calls scanned"
    end

    def duration_label(seconds)
      value = seconds.to_i
      return if value <= 0
      return "#{value}s" if value < 60

      "#{value / 60}m #{value % 60}s"
    end

    def embedding_label(status)
      return "Waiting for Fathom call chunks to enter the vector queue." if status.blank?
      if status["status"] == "queued_for_content_hydration"
        scheduled_for = self.class.parse_time(status["scheduled_for"])
        scheduled_label = scheduled_for&.in_time_zone("Central Time (US & Canada)")&.strftime("%b %-d, %-I:%M %p %Z")
        return "Fathom calls are saved. Summary/transcript hydration is queued#{scheduled_label.present? ? " for #{scheduled_label}" : ""}."
      end

      if status["status"] == "hydrating_fathom_content"
        hydration = status["hydration"].to_h
        return "Hydrating Fathom summaries/transcripts // #{hydration["updated"].to_i} updated this pass // #{hydration["remaining"].to_i} remaining // attempt #{status["attempt"].to_i}."
      end

      if status["status"] == "content_hydration_complete" || status["status"] == "content_hydration_partial"
        hydration = status["hydration"].to_h
        label = status["status"] == "content_hydration_complete" ? "complete" : "partial"
        return "Fathom content hydration #{label} // #{hydration["updated"].to_i} updated this pass // #{hydration["remaining"].to_i} remaining. Waiting for vector embedding and digest delivery."
      end

      if status["status"] == "queued_for_midnight_embedding" || status["status"] == "queued_for_embedding_digest"
        scheduled_for = self.class.parse_time(status["scheduled_for"])
        scheduled_label = scheduled_for&.in_time_zone("Central Time (US & Canada)")&.strftime("%b %-d, %-I:%M %p %Z")
        return "Fathom calls are saved. Vector embedding and digest delivery are queued#{scheduled_label.present? ? " for #{scheduled_label}" : ""}."
      end

      pending = %w[pending claimed stale].sum { |key| status[key].to_i }
      embedded = status["embedded"].to_i
      failed = status["failed"].to_i
      chunks = status["chunk_count"].to_i
      missing = status["missing_sources"].to_i
      missing_label = missing.positive? ? " // #{missing} call(s) waiting for embedding" : ""
      "Embedding Fathom Brain memory // #{embedded}/#{chunks} embedded // #{pending} waiting // #{failed} failed#{missing_label}"
    end
  end
end
