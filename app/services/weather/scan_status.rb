module Weather
  class ScanStatus
    KEY = "weather_storm_watch_scan".freeze
    ACTIVE_STATES = %w[queued running].freeze
    STALE_AFTER = 45.minutes

    class << self
      def for(organization)
        new(organization).to_h
      end

      def mark_queued!(organization:, request_id:, requested_by_user_id:, requested_by:, requested_at:)
        new(organization).write!(
          "state" => "queued",
          "request_id" => request_id,
          "job_id" => nil,
          "requested_by_user_id" => requested_by_user_id,
          "requested_by" => requested_by,
          "requested_at" => iso_time(requested_at),
          "queued_at" => iso_time(Time.current),
          "started_at" => nil,
          "completed_at" => nil,
          "duration_seconds" => nil,
          "last_error" => nil
        )
      end

      def mark_enqueued!(organization:, request_id:, job_id:)
        new(organization).write_if_current!(request_id) do |status|
          status.merge(
            "job_id" => job_id,
            "state" => status["state"].presence || "queued",
            "queued_at" => status["queued_at"].presence || iso_time(Time.current)
          )
        end
      end

      def mark_running!(organization:, request_id:, job_id:, requested_by_user_id: nil, requested_at: nil)
        new(organization).write!(
          "state" => "running",
          "request_id" => request_id.presence || job_id,
          "job_id" => job_id,
          "requested_by_user_id" => requested_by_user_id,
          "requested_at" => requested_at,
          "started_at" => iso_time(Time.current),
          "completed_at" => nil,
          "duration_seconds" => nil,
          "last_error" => nil
        )
      end

      def mark_success!(organization:, result:, request_id:, job_id:)
        completed_at = Time.current
        new(organization).write_if_current!(request_id.presence || job_id) do |status|
          started_at = parse_time(status["started_at"])
          payload = result.to_h.deep_stringify_keys
          status.merge(
            "state" => "success",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id,
            "completed_at" => iso_time(completed_at),
            "duration_seconds" => duration_seconds(started_at, completed_at),
            "last_successful_at" => iso_time(completed_at),
            "last_success_counts" => payload,
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
      completed_at = self.class.parse_time(status["completed_at"])
      last_successful_at = self.class.parse_time(status["last_successful_at"])
      active_since = started_at || queued_at
      stale = ACTIVE_STATES.include?(state) && active_since.present? && active_since < STALE_AFTER.ago
      active = ACTIVE_STATES.include?(state) && !stale
      fresh_today = last_successful_at.present? && last_successful_at.in_time_zone.to_date == Time.current.in_time_zone.to_date
      counts = status["last_success_counts"].to_h

      {
        state: stale ? "stale" : state,
        active: active,
        queued: state == "queued" && !stale,
        running: state == "running" && !stale,
        stale: stale,
        fresh_today: fresh_today,
        daily_locked: fresh_today || active,
        job_id: status["job_id"],
        request_id: status["request_id"],
        requested_by: status["requested_by"],
        requested_by_user_id: status["requested_by_user_id"],
        requested_at: status["requested_at"],
        queued_at: queued_at&.iso8601,
        started_at: started_at&.iso8601,
        completed_at: completed_at&.iso8601,
        duration_seconds: status["duration_seconds"],
        last_successful_at: last_successful_at&.iso8601,
        last_success_counts: counts,
        last_error: status["last_error"],
        state_label: state_label(stale ? "stale" : state),
        detail_label: detail_label(state, stale, status, counts),
        last_success_label: last_success_label(last_successful_at, counts),
        daily_lock_label: daily_lock_label(active, fresh_today, last_successful_at),
        counts_label: counts_label(counts),
        duration_label: duration_label(status["duration_seconds"]),
        progress_percent: progress_percent(state, stale)
      }
    end

    def write!(attrs)
      organization.with_lock do
        status = raw_status.merge(attrs)
        persist!(status)
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
      when "queued" then "storm watch queued"
      when "running" then "storm watch scanning"
      when "success" then "storm watch complete"
      when "failed" then "storm watch failed"
      when "stale" then "storm watch stale"
      else "storm watch idle"
      end
    end

    def detail_label(state, stale, status, counts)
      return "Weather scan may still be running, but the status is older than #{duration_label(STALE_AFTER.to_i)}." if stale
      return "Waiting for the background worker to claim job #{status["job_id"].presence || status["request_id"]}." if state == "queued"
      return "Pulling Weather.gov alerts, resolving ZIP crosswalks, and matching contractor CRM records." if state == "running"
      return status["last_error"].presence || "No successful storm scan yet." if state == "failed"
      return "No storm scan has been started yet." if state.blank? || state == "idle"

      counts_label(counts).presence || "Storm Watch lane is up to date from the last completed scan."
    end

    def last_success_label(time, counts)
      return "No successful storm scan yet." if time.blank?

      "Last successful Storm Watch scan #{time.in_time_zone.strftime("%b %-d, %-I:%M %p")} // #{counts_label(counts)}"
    end

    def daily_lock_label(active, fresh_today, time)
      return "Storm Watch scan is running." if active
      return unless fresh_today

      "Storm Watch already scanned today at #{time.in_time_zone.strftime("%-I:%M %p")}."
    end

    def counts_label(counts)
      return if counts.blank?

      parts = [
        "#{counts["states_scanned"].to_i} states",
        "#{counts["alerts_seen"].to_i} live alerts",
        "#{counts["historical_alerts_seen"].to_i} recent alerts",
        "#{counts["signals_created"].to_i} created",
        "#{counts["signals_updated"].to_i} updated",
        "#{counts["matched_lead_count"].to_i} CRM matches"
      ]
      parts << "#{counts["error_count"].to_i} errors" if counts["error_count"].to_i.positive?
      parts.join(" // ")
    end

    def duration_label(seconds)
      value = seconds.to_i
      return nil if value <= 0
      return "#{value}s" if value < 60

      minutes = value / 60
      remainder = value % 60
      remainder.positive? ? "#{minutes}m #{remainder}s" : "#{minutes}m"
    end

    def progress_percent(state, stale)
      return 0 if state.blank? || state == "idle"
      return 100 if %w[success failed].include?(state) || stale
      return 18 if state == "queued"

      58
    end
  end
end
