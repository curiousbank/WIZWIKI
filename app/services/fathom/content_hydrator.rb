module Fathom
  class ContentHydrator
    DEFAULT_LIMIT = 4
    DEFAULT_SLEEP_SECONDS = 6
    DEFAULT_RATE_LIMIT_RETRY_MINUTES = 20

    Result = Data.define(:checked, :updated, :skipped, :rate_limited, :error_count, :remaining, :complete, :date, :next_retry_at) do
      def to_h
        {
          checked: checked,
          updated: updated,
          skipped: skipped,
          rate_limited: rate_limited,
          errors: error_count,
          remaining: remaining,
          complete: complete,
          date: date,
          next_retry_at: next_retry_at
        }
      end
    end

    def self.call(organization:, date: Time.zone.today, limit: nil, sleep_seconds: nil, client: Client.new)
      new(
        organization: organization,
        date: date,
        limit: limit,
        sleep_seconds: sleep_seconds,
        client: client
      ).call
    end

    def initialize(organization:, date:, limit:, sleep_seconds:, client:)
      @organization = organization
      @date = normalize_date(date)
      @limit = normalize_limit(limit)
      @sleep_seconds = normalize_sleep_seconds(sleep_seconds)
      @client = client
      @next_retry_at = nil
    end

    def call
      checked = 0
      updated = 0
      skipped = 0
      rate_limited = 0
      error_count = 0

      records_to_hydrate.each do |call_record|
        checked += 1
        state = hydrate_call(call_record)
        case state
        when :updated then updated += 1
        when :skipped then skipped += 1
        when :rate_limited
          rate_limited += 1
          break
        else
          error_count += 1
        end
      end

      remaining = candidate_scope.count
      Result.new(
        checked: checked,
        updated: updated,
        skipped: skipped,
        rate_limited: rate_limited,
        error_count: error_count,
        remaining: remaining,
        complete: remaining.zero? && rate_limited.zero?,
        date: date.iso8601,
        next_retry_at: next_retry_at&.iso8601
      )
    end

    private

    attr_reader :organization, :date, :limit, :sleep_seconds, :client, :next_retry_at

    def normalize_date(value)
      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.zone.today
    end

    def normalize_limit(value)
      raw = value.presence || ENV["FATHOM_CONTENT_HYDRATION_LIMIT"].presence || DEFAULT_LIMIT
      raw.to_i.clamp(0, 25)
    end

    def normalize_sleep_seconds(value)
      raw = value.presence || ENV["FATHOM_CONTENT_HYDRATION_SLEEP_SECONDS"].presence || DEFAULT_SLEEP_SECONDS
      raw.to_i.clamp(0, 60)
    end

    def records_to_hydrate
      return [] if limit.zero?

      candidate_scope
        .order(Arel.sql("COALESCE(recording_start_time, fathom_created_at, created_at) ASC"))
        .limit([limit * 5, limit].max)
        .to_a
        .select { |call_record| retry_after_elapsed?(call_record) }
        .first(limit)
    end

    def candidate_scope
      calls_for_day.where(
        "COALESCE(summary, '') = '' OR COALESCE(transcript, '') = '' OR raw_payload::text LIKE ?",
        "%fathom_content_errors%"
      )
    end

    def calls_for_day
      start_time = date.beginning_of_day
      end_time = date.tomorrow.beginning_of_day

      organization.fathom_calls
        .active
        .where(
          "(recording_start_time >= :start_time AND recording_start_time < :end_time) OR (fathom_created_at >= :start_time AND fathom_created_at < :end_time)",
          start_time: start_time,
          end_time: end_time
        )
    end

    def retry_after_elapsed?(call_record)
      retry_after = parse_time(call_record.raw_payload.to_h["fathom_hydration_retry_after"])
      retry_after.blank? || retry_after <= Time.current
    end

    def hydrate_call(call_record)
      payload = call_record.raw_payload.to_h.deep_dup
      payload["fathom_content_attempted_at"] = Time.current.iso8601
      changed = clear_resolved_content_errors(call_record, payload)

      if summary_missing?(call_record, payload)
        summary_result = fetch_summary(call_record.recording_id, payload)
        if summary_result == :rate_limited
          call_record.update!(raw_payload: payload)
          return summary_result
        end

        changed ||= summary_result == :updated
      end

      if transcript_missing?(call_record, payload)
        transcript_result = fetch_transcript(call_record.recording_id, payload)
        if transcript_result == :rate_limited
          call_record.update!(raw_payload: payload)
          return transcript_result
        end

        changed ||= transcript_result == :updated
      end

      if changed
        payload["fathom_content_hydrated_at"] = Time.current.iso8601
        call_record.assign_attributes(
          summary: summary_text(payload),
          transcript: transcript_text(payload["transcript"]),
          raw_payload: payload,
          synced_at: Time.current
        )
        call_record.save!
        enqueue_embedding_source(call_record)
        Rails.logger.info("[Fathom::ContentHydrator] hydrated call=#{call_record.recording_id} organization=#{organization.id}")
        :updated
      else
        call_record.update!(raw_payload: payload)
        :skipped
      end
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Fathom::ContentHydrator] call=#{call_record&.recording_id} save failed: #{error.class}: #{error.message}")
      :error
    end

    def fetch_summary(recording_id, payload)
      response = client.recording_summary(recording_id)
      throttle!
      summary = normalize_summary_payload(response)
      if summary.present?
        payload["default_summary"] = summary
        clear_content_error(payload, "summary")
        :updated
      else
        append_content_error(payload, "summary", "blank response")
        :skipped
      end
    rescue Fathom::Error => error
      handle_fetch_error(payload, "summary", error)
    end

    def fetch_transcript(recording_id, payload)
      response = client.recording_transcript(recording_id)
      throttle!
      transcript = normalize_transcript_payload(response)
      if transcript.present?
        payload["transcript"] = transcript
        clear_content_error(payload, "transcript")
        :updated
      else
        append_content_error(payload, "transcript", "blank response")
        :skipped
      end
    rescue Fathom::Error => error
      handle_fetch_error(payload, "transcript", error)
    end

    def handle_fetch_error(payload, kind, error)
      append_content_error(payload, kind, error.message)
      if rate_limit_error?(error)
        retry_at = rate_limit_retry_time
        payload["fathom_hydration_retry_after"] = retry_at.iso8601
        @next_retry_at = retry_at
        Rails.logger.warn("[Fathom::ContentHydrator] #{kind} rate limited; retry_after=#{retry_at.iso8601}")
        :rate_limited
      else
        Rails.logger.warn("[Fathom::ContentHydrator] #{kind} hydration failed: #{error.class}: #{error.message}")
        :error
      end
    end

    def summary_missing?(call_record, payload)
      call_record.summary.blank? && summary_text(payload).blank?
    end

    def transcript_missing?(call_record, payload)
      call_record.transcript.blank? && transcript_text(payload["transcript"]).blank?
    end

    def clear_resolved_content_errors(call_record, payload)
      changed = false
      if !summary_missing?(call_record, payload) && content_error?(payload, "summary")
        clear_content_error(payload, "summary")
        changed = true
      end
      if !transcript_missing?(call_record, payload) && content_error?(payload, "transcript")
        clear_content_error(payload, "transcript")
        changed = true
      end
      changed
    end

    def normalize_summary_payload(response)
      data = response.respond_to?(:to_h) ? response.to_h : {}
      summary = data["summary"]
      return summary if summary.is_a?(Hash)

      text = if summary.is_a?(String)
        summary
      elsif summary.respond_to?(:to_h)
        summary.to_h["markdown_formatted"].presence || summary.to_h["plain_text"].presence || summary.to_h["text"].presence
      end
      text = data["markdown_formatted"].presence || data["plain_text"].presence || data["text"].presence if text.blank?
      return if text.blank?

      { "markdown_formatted" => text.to_s }
    end

    def normalize_transcript_payload(response)
      return response if response.is_a?(Array)

      data = response.respond_to?(:to_h) ? response.to_h : {}
      value = data["transcript"].presence || data["items"].presence || data["segments"].presence
      Array(value)
    end

    def summary_text(payload)
      summary = payload["default_summary"]
      if summary.is_a?(String)
        return summary.squish if summary.present?
      elsif summary.respond_to?(:to_h)
        summary_text_value = summary.to_h["markdown_formatted"].presence || summary.to_h["plain_text"].presence || summary.to_h["text"].presence
        return summary_text_value.to_s if summary_text_value.present?
      end

      transcript_text(payload["transcript"]).squish.truncate(600, omission: "...")
    end

    def transcript_text(transcript)
      Array(transcript).filter_map do |item|
        item_hash = item.respond_to?(:to_h) ? item.to_h : {}
        text = item_hash["text"].to_s.squish
        next if text.blank?

        speaker = item_hash.dig("speaker", "display_name").presence || "Speaker"
        timestamp = item_hash["timestamp"].presence
        [timestamp, "#{speaker}: #{text}"].compact.join(" ")
      end.join("\n")
    end

    def append_content_error(payload, kind, message)
      clear_content_error(payload, kind)
      payload["fathom_content_errors"] = Array(payload["fathom_content_errors"]) + ["#{kind}: #{message}"]
    end

    def clear_content_error(payload, kind)
      errors = Array(payload["fathom_content_errors"]).reject { |entry| entry.to_s.start_with?("#{kind}:") }
      if errors.present?
        payload["fathom_content_errors"] = errors
      else
        payload.delete("fathom_content_errors")
      end
    end

    def content_error?(payload, kind)
      Array(payload["fathom_content_errors"]).any? { |entry| entry.to_s.start_with?("#{kind}:") }
    end

    def rate_limit_error?(error)
      error.message.to_s.include?("HTTP 429")
    end

    def rate_limit_retry_time
      ENV.fetch("FATHOM_CONTENT_HYDRATION_RATE_LIMIT_RETRY_MINUTES", DEFAULT_RATE_LIMIT_RETRY_MINUTES.to_s).to_i.clamp(5, 180).minutes.from_now
    end

    def throttle!
      sleep(sleep_seconds) if sleep_seconds.positive?
    end

    def parse_time(value)
      return if value.blank?

      value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def enqueue_embedding_source(call_record)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      Autos::EmbeddingQueue.enqueue_source!(call_record)
    rescue StandardError => error
      Rails.logger.warn("[Fathom::ContentHydrator] embedding enqueue failed call=#{call_record&.id}: #{error.class}: #{error.message}")
    end
  end
end
