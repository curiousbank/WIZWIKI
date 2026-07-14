require "erb"

module Fathom
  class TrainingDigestDocument
    class << self
      def publish(organization:, date:, result:, started_at:, completed_at:, embedding_status: {}, drive_client: GoogleWorkspace::DriveClient.new)
        new(
          organization: organization,
          date: date,
          result: result,
          started_at: started_at,
          completed_at: completed_at,
          embedding_status: embedding_status,
          drive_client: drive_client
        ).publish
      end
    end

    def initialize(organization:, date:, result:, started_at:, completed_at:, embedding_status:, drive_client:)
      @organization = organization
      @date = date.respond_to?(:to_date) ? date.to_date : Time.zone.parse(date.to_s).to_date
      @result = normalize_result(result)
      @embedding_status = normalize_result(embedding_status)
      @started_at = parse_time(started_at)
      @completed_at = parse_time(completed_at) || Time.current
      @drive_client = drive_client
    end

    def publish
      drive_client.create_google_doc(
        name: document_name,
        html: html_document
      )
    end

    private

    attr_reader :organization, :date, :result, :embedding_status, :started_at, :completed_at, :drive_client

    def document_name
      "The Fathom Brain Training Digest - #{date.strftime("%Y-%m-%d")}"
    end

    def calls
      @calls ||= organization.fathom_calls
        .active
        .where(
          "(recording_start_time >= :start_time AND recording_start_time < :end_time) OR (fathom_created_at >= :start_time AND fathom_created_at < :end_time)",
          start_time: date.beginning_of_day,
          end_time: date.tomorrow.beginning_of_day
        )
        .recent
        .limit(100)
    end

    def html_document
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>#{h(document_name)}</title>
            <style>
              body { font-family: Arial, Helvetica, sans-serif; color: #172033; line-height: 1.5; }
              h1, h2, h3, h4 { color: #14182b; }
              h1 { border-bottom: 3px solid #2d6cdf; padding-bottom: 8px; }
              h2 { margin-top: 28px; border-bottom: 1px solid #d8e0f2; padding-bottom: 5px; }
              h3 { margin-top: 24px; color: #2d3f7f; }
              table { border-collapse: collapse; width: 100%; margin: 10px 0 18px; }
              th, td { border: 1px solid #d8e0f2; padding: 8px; text-align: left; vertical-align: top; }
              th { background: #eef3ff; width: 34%; }
              .readout { background: #f6f8ff; border-left: 5px solid #2d6cdf; padding: 12px 16px; margin: 16px 0; }
              .meta { color: #4d5972; }
              .call-card { page-break-inside: avoid; }
              .empty { color: #6b7280; font-style: italic; }
            </style>
          </head>
          <body>
            <h1>The Fathom Brain Training Digest 🧠</h1>
            <p><strong>Date:</strong> #{h(date.strftime("%B %-d, %Y"))}</p>
            <p>The Fathom Brain synced meeting recorder content, stored the raw call data in WIZWIKI, and waited for Qwen pgvector embeddings so Thumper can retrieve today's conversations from /ask.</p>
            #{daily_readout}

            <h2>Training Stats</h2>
            <table>
              <tr><th>Calls scanned</th><td>#{n("call_count")}</td></tr>
              <tr><th>Created</th><td>#{n("created")}</td></tr>
              <tr><th>Updated</th><td>#{n("updated")}</td></tr>
              <tr><th>Unchanged</th><td>#{n("unchanged")}</td></tr>
              <tr><th>Errors</th><td>#{n("errors")}</td></tr>
              <tr><th>Training time</th><td>#{h(duration_label)}</td></tr>
            </table>

            <h2>Vector Memory</h2>
            <table>
              <tr><th>Embedding model</th><td>#{h(embedding_status["embedding_model"].presence || "not recorded")}</td></tr>
              <tr><th>Fathom calls</th><td>#{n_embed("call_count")}</td></tr>
              <tr><th>Chunks</th><td>#{n_embed("chunk_count")}</td></tr>
              <tr><th>Embedded</th><td>#{n_embed("embedded")}</td></tr>
              <tr><th>Pending / claimed / stale</th><td>#{n_embed("pending")} / #{n_embed("claimed")} / #{n_embed("stale")}</td></tr>
              <tr><th>Failed</th><td>#{n_embed("failed")}</td></tr>
            </table>

            <h2>Calls Now Available To Thumper</h2>
            #{call_sections}
          </body>
        </html>
      HTML
    end

    def call_sections
      return "<p>No Fathom calls were found for this date.</p>" if calls.blank?

      calls.map do |call|
        link = call.share_url.presence || call.meeting_url.presence || call.url.presence
        action_items = call.action_items_text.present? ? "<h4>Action Items</h4>#{bullet_list(call.action_items_text, limit: 10)}" : "<h4>Action Items</h4><p class=\"empty\">No action items were returned.</p>"
        highlights = call.highlights_text.present? ? "<h4>Highlights</h4>#{paragraphs(call.highlights_text, limit: 1_200)}" : ""
        transcript = transcript_preview(call)
        <<~HTML
          <div class="call-card">
          <h3>#{h(call_title(call))}</h3>
          <p class="meta">
            <strong>Recorded:</strong> #{h(call.recording_start_time&.in_time_zone&.strftime("%b %-d, %-I:%M %p") || "date unknown")}<br>
            #{duration_label_for(call).present? ? "<strong>Duration:</strong> #{h(duration_label_for(call))}<br>" : ""}
            #{call.meeting_type.present? ? "<strong>Meeting type:</strong> #{h(call.meeting_type)}<br>" : ""}
            #{call.recorded_by_name.present? ? "<strong>Recorded by:</strong> #{h(call.recorded_by_name)}<br>" : ""}
            #{link.present? ? "<strong>Fathom link:</strong> <a href=\"#{h(link)}\">Open recording</a>" : ""}
          </p>
          <h4>People And CRM Context</h4>
          #{people_and_crm_table(call)}
          <h4>Summary For Thumper</h4>
          #{paragraphs(call_summary(call), limit: 1_600)}
          #{highlights}
          #{action_items}
          #{transcript}
          <hr>
          </div>
        HTML
      end.join("\n")
    end

    def paragraphs(text, limit:)
      value = text.to_s.strip
      return "<p class=\"empty\">No detail was returned.</p>" if value.blank?

      value.split(/\n{2,}/).map do |part|
        "<p>#{h(part.squish.truncate(limit, omission: "..."))}</p>"
      end.join
    end

    def bullet_list(text, limit:)
      lines = text.to_s.split(/\r?\n/).map { |line| line.gsub(/\A[-*•\d.)\s]+/, "").squish }.select(&:present?)
      lines = text.to_s.split(/(?:\.\s+|;\s+)/).map(&:squish).select(&:present?) if lines.length < 2
      lines = lines.first(limit)
      return paragraphs(text, limit: 900) if lines.blank?

      "<ul>#{lines.map { |line| "<li>#{h(line.truncate(260, omission: "..."))}</li>" }.join}</ul>"
    end

    def daily_readout
      call_rows = calls.to_a
      external_count = call_rows.sum { |call| external_participants(call).length }
      with_transcripts = call_rows.count { |call| call.transcript.present? }
      with_actions = call_rows.count { |call| call.action_items_text.present? }
      with_crm = call_rows.count { |call| crm_match_labels(call).present? }

      <<~HTML
        <div class="readout">
          <strong>Daily readout:</strong>
          #{h(call_rows.length)} call#{call_rows.length == 1 ? "" : "s"} synced.
          #{h(with_transcripts)} include transcript text, #{h(with_actions)} include action items,
          #{h(with_crm)} include CRM match context, and #{h(external_count)} external participant#{external_count == 1 ? "" : "s"} were detected.
          Use Thumper /ask to query by account, contact, objection, follow-up, market signal, or next action.
        </div>
      HTML
    end

    def people_and_crm_table(call)
      participant_text = participant_labels(call).presence || ["No participant list was returned."]
      crm_text = crm_match_labels(call).presence || ["No CRM match was recorded."]
      <<~HTML
        <table>
          <tr><th>Participants</th><td>#{participant_text.map { |label| h(label) }.join("<br>")}</td></tr>
          <tr><th>CRM matches</th><td>#{crm_text.map { |label| h(label) }.join("<br>")}</td></tr>
        </table>
      HTML
    end

    def participant_labels(call)
      Array(call.calendar_invitees).filter_map do |invitee|
        name = invitee["name"].presence || invitee["matched_speaker_display_name"].presence
        email = invitee["email"].presence
        role = invitee["is_external"] ? "external" : "internal"
        label = [name, email].compact.join(" - ")
        label.present? ? "#{label} (#{role})" : nil
      end
    end

    def external_participants(call)
      Array(call.calendar_invitees).select { |invitee| invitee["is_external"] }
    end

    def crm_match_labels(call)
      flatten_json_labels(call.crm_matches).first(12)
    end

    def flatten_json_labels(value, prefix = nil)
      result = case value
      when Array
        value.flat_map { |entry| flatten_json_labels(entry, prefix) }
      when Hash
        if value.values.any? { |entry| entry.is_a?(Hash) || entry.is_a?(Array) }
          value.flat_map { |key, entry| flatten_json_labels(entry, key.to_s.humanize) }
        else
          name = value["name"].presence || value["label"].presence || value["title"].presence || value["email"].presence || value["id"].presence
          detail = value.except("raw", "properties").values_at("type", "email", "phone", "company", "dealname").compact_blank.join(" - ")
          [[prefix, name, detail].compact_blank.join(": ").presence].compact
        end
      else
        [value.to_s.presence].compact
      end

      Array(result).flatten.compact_blank
    end

    def call_title(call)
      call.title.presence || call.meeting_title.presence || "Fathom call #{call.recording_id}"
    end

    def call_summary(call)
      return call.summary if call.summary.present?
      return "Fathom did not return a formal summary. Transcript excerpt included below for training context." if call.transcript.present?

      "No summary or transcript text was returned for this call."
    end

    def transcript_preview(call)
      return "" if call.transcript.blank?

      <<~HTML
        <h4>Transcript Preview</h4>
        #{paragraphs(call.transcript, limit: 1_000)}
      HTML
    end

    def duration_label_for(call)
      return if call.recording_start_time.blank? || call.recording_end_time.blank?

      seconds = (call.recording_end_time.to_f - call.recording_start_time.to_f).round
      return if seconds <= 0
      return "#{seconds}s" if seconds < 60

      "#{seconds / 60}m #{seconds % 60}s"
    end

    def normalize_result(value)
      value.to_h.each_with_object({}) { |(key, result_value), memo| memo[key.to_s] = result_value }
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def duration_label
      seconds = if started_at.present? && completed_at.present?
        (completed_at.to_f - started_at.to_f).round
      else
        0
      end
      return "not recorded" if seconds <= 0
      return "#{seconds}s" if seconds < 60

      "#{seconds / 60}m #{seconds % 60}s"
    end

    def n(key)
      result[key].to_i
    end

    def n_embed(key)
      embedding_status[key].to_i
    end

    def h(value)
      ERB::Util.html_escape(value.to_s)
    end
  end
end
