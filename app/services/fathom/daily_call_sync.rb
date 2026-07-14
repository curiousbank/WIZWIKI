require "digest"

module Fathom
  class DailyCallSync
    DEFAULT_PAGE_SIZE = 50

    Result = Data.define(:created_count, :updated_count, :unchanged_count, :call_count, :error_count, :date) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          total: total_count,
          call_count: call_count,
          errors: error_count,
          date: date
        }
      end
    end

    def self.call(organization:, date: Time.zone.today, limit: nil, client: Client.new)
      new(organization: organization, date: date, limit: limit, client: client).call
    end

    def initialize(organization:, date:, limit:, client:)
      @organization = organization
      @date = normalize_date(date)
      @limit = normalize_limit(limit)
      @client = client
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      error_count = 0
      seen = 0
      cursor = nil
      sync_started_at = Time.current

      loop do
        response = client.list_meetings(meeting_params(cursor))
        Array(response["items"]).each do |payload|
          break if limit.present? && seen >= limit

          call_record, state = upsert_call(payload, sync_started_at: sync_started_at)
          enqueue_embedding_source(call_record)
          seen += 1
          case state
          when :created then created_count += 1
          when :updated then updated_count += 1
          else unchanged_count += 1
          end
          Rails.logger.info("[Fathom::DailyCallSync] call=#{call_record.recording_id} state=#{state} organization=#{organization.id}")
        rescue ActiveRecord::ActiveRecordError, Fathom::Error => error
          error_count += 1
          Rails.logger.warn("[Fathom::DailyCallSync] call sync failed: #{error.class}: #{error.message}")
        end

        break if limit.present? && seen >= limit

        cursor = response["next_cursor"].presence
        break if cursor.blank?
      end

      Result.new(
        created_count: created_count,
        updated_count: updated_count,
        unchanged_count: unchanged_count,
        call_count: seen,
        error_count: error_count,
        date: date.iso8601
      )
    end

    private

    attr_reader :organization, :date, :limit, :client

    def normalize_date(value)
      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.zone.today
    end

    def normalize_limit(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s == "all"

      value.to_i.clamp(1, 2_000)
    end

    def meeting_params(cursor)
      params = {
        created_after: date.beginning_of_day.iso8601,
        created_before: date.tomorrow.beginning_of_day.iso8601,
        include_action_items: true,
        include_crm_matches: true,
        include_highlights: true,
        limit: [limit || DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE].min
      }
      params[:cursor] = cursor if cursor.present?
      params
    end

    def upsert_call(payload, sync_started_at:)
      recording_id = payload["recording_id"].presence || payload["id"].presence || Digest::SHA256.hexdigest(payload.to_json).first(16)
      payload = payload.deep_dup
      call_record = organization.fathom_calls.find_or_initialize_by(recording_id: recording_id.to_s)
      created = call_record.new_record?
      before = call_record.attributes.except("updated_at", "created_at")

      attributes = attributes_for(payload, sync_started_at: sync_started_at)
      preserve_hydrated_content!(attributes, call_record)
      call_record.assign_attributes(attributes)
      call_record.save!

      state = if created
        :created
      elsif before != call_record.reload.attributes.except("updated_at", "created_at")
        :updated
      else
        :unchanged
      end

      [call_record, state]
    end

    def enqueue_embedding_source(call_record)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      Autos::EmbeddingQueue.enqueue_source!(call_record)
    rescue StandardError => error
      Rails.logger.warn("[Fathom::DailyCallSync] embedding enqueue failed call=#{call_record&.id}: #{error.class}: #{error.message}")
    end

    def attributes_for(payload, sync_started_at:)
      recorded_by = payload.fetch("recorded_by", {}).to_h
      {
        status: "synced",
        title: payload["title"].presence || payload["meeting_title"].presence,
        meeting_title: payload["meeting_title"],
        meeting_type: payload["meeting_type"],
        url: payload["url"],
        share_url: payload["share_url"],
        meeting_url: payload["meeting_url"],
        transcript_language: payload["transcript_language"],
        recorded_by_name: recorded_by["name"],
        recorded_by_email: recorded_by["email"],
        recorded_by_team: recorded_by["team"],
        fathom_created_at: parse_time(payload["created_at"]),
        scheduled_start_time: parse_time(payload["scheduled_start_time"]),
        scheduled_end_time: parse_time(payload["scheduled_end_time"]),
        recording_start_time: parse_time(payload["recording_start_time"]),
        recording_end_time: parse_time(payload["recording_end_time"]),
        summary: summary_text(payload),
        transcript: transcript_text(payload["transcript"]),
        action_items_text: action_items_text(payload["action_items"]),
        highlights_text: highlights_text(payload["highlights"]),
        calendar_invitees: Array(payload["calendar_invitees"]),
        crm_matches: payload.fetch("crm_matches", {}).to_h,
        raw_payload: payload,
        synced_at: sync_started_at
      }
    end

    def preserve_hydrated_content!(attributes, call_record)
      return if call_record.new_record?

      if attributes[:summary].blank? && call_record.summary.present?
        attributes[:summary] = call_record.summary
      end

      if attributes[:transcript].blank? && call_record.transcript.present?
        attributes[:transcript] = call_record.transcript
      end
    end

    def summary_text(payload)
      summary = payload.fetch("default_summary", {}).to_h["markdown_formatted"].presence
      return summary if summary.present?

      transcript_text(payload["transcript"]).squish.truncate(600, omission: "...")
    end

    def transcript_text(transcript)
      Array(transcript).filter_map do |item|
        text = item["text"].to_s.squish
        next if text.blank?

        speaker = item.dig("speaker", "display_name").presence || "Speaker"
        timestamp = item["timestamp"].presence
        [timestamp, "#{speaker}: #{text}"].compact.join(" ")
      end.join("\n")
    end

    def action_items_text(items)
      Array(items).filter_map do |item|
        description = item["description"].to_s.squish
        next if description.blank?

        assignee = item["assignee"].to_h
        owner = assignee["name"].presence || assignee["email"].presence
        [description, owner.present? ? "(#{owner})" : nil].compact.join(" ")
      end.join("\n")
    end

    def highlights_text(items)
      Array(items).filter_map do |item|
        summary = item["summary"].presence || item["text"].presence
        next if summary.blank?

        [item["type"].presence, summary.to_s.squish].compact.join(": ")
      end.join("\n")
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
