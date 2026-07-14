module Hubspot
  class TicketSyncStatus
    KEY = "hubspot_ticket_sync".freeze
    ACTIVE_STATES = %w[queued running].freeze
    STALE_AFTER = 2.hours

    class << self
      def for(organization)
        new(organization).to_h
    end

    def active?(organization)
      self.for(organization)[:active]
    end

      def mark_queued!(organization:, request_id:, requested_by_user_id:, requested_by:, requested_at:, lead_source: nil, record_type: nil)
        new(organization).write!(
          "state" => "queued",
          "request_id" => request_id,
          "job_id" => nil,
          "lead_source" => lead_source,
          "record_type" => record_type,
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

      def mark_running!(organization:, request_id:, job_id:, requested_by_user_id:, requested_at:, lead_source: nil, record_type: nil)
        new(organization).write!(
          "state" => "running",
          "request_id" => request_id.presence || job_id,
          "job_id" => job_id,
          "lead_source" => lead_source,
          "record_type" => record_type,
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
          payload = result.to_h
          status.merge(
            "state" => "success",
            "request_id" => request_id.presence || status["request_id"] || job_id,
            "job_id" => job_id,
            "lead_source" => payload[:lead_source].presence || payload["lead_source"].presence || status["lead_source"],
            "record_type" => payload[:record_type].presence || payload["record_type"].presence || status["record_type"],
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
      counts = status["last_success_counts"].to_h
      lead_source = counts["lead_source"].presence || status["lead_source"].presence
      record_type = counts["record_type"].presence || status["record_type"].presence
      contact_sync_active = active && record_type == "contact"

      {
        state: stale ? "stale" : state,
        active: active,
        contact_sync_active: contact_sync_active,
        queued: state == "queued" && !stale,
        running: state == "running" && !stale,
        stale: stale,
        lead_source: lead_source,
        record_type: record_type,
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
        counts_label: counts_label(counts),
        duration_label: duration_label(status["duration_seconds"])
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
      when "queued" then "queued"
      when "running" then "sync running"
      when "success" then "last sync complete"
      when "failed" then "last sync failed"
      when "stale" then "sync status stale"
      else "sync idle"
      end
    end

    def detail_label(state, stale, status, counts)
      return "Background sync may still be running, but the last heartbeat is older than #{duration_label(STALE_AFTER.to_i)}." if stale
      return "Waiting for Solid Queue to pick up job #{status["job_id"].presence || status["request_id"]}." if state == "queued"
      return "Refreshing HubSpot #{sync_subject(status, counts)} and associations now." if state == "running"
      return status["last_error"].presence || "No successful sync yet." if state == "failed"
      return "No lead sync has been started yet." if state.blank? || state == "idle"

      counts_label(counts).presence || "#{sync_subject(status, counts).titleize} are up to date from the last completed sync."
    end

    def last_success_label(time, counts)
      return "No successful lead sync yet." if time.blank?

      "Last successful #{sync_subject({}, counts)} sync #{time.in_time_zone.strftime("%b %-d, %-I:%M %p")} // #{counts_label(counts)}"
    end

    def counts_label(counts)
      return if counts.blank?

      parts = [
        "#{counts["created"].to_i} new",
        "#{counts["updated"].to_i} updated",
        "#{counts["unchanged"].to_i} unchanged"
      ]
      parts << "#{counts["associated"].to_i} associated" if counts.key?("associated")
      parts << "#{counts["archived"].to_i} archived" if counts.key?("archived")
      parts << "#{counts["errors"].to_i} errors" if counts["errors"].to_i.positive?
      parts.join(", ")
    end

    def sync_subject(status, counts)
      source = counts["lead_source"].presence || status["lead_source"].presence
      record_type = counts["record_type"].presence || status["record_type"].presence
      return "90-day contacts" if record_type == "contact" && source == "all_contacts"
      return "#{source.to_s.titleize} contacts" if record_type == "contact" && source.present?
      return "SAM tickets" if source == "sam_tickets"

      "tickets"
    end

    def duration_label(seconds)
      value = seconds.to_i
      return nil if value <= 0
      return "#{value}s" if value < 60

      minutes = value / 60
      remainder = value % 60
      remainder.positive? ? "#{minutes}m #{remainder}s" : "#{minutes}m"
    end
  end
end
