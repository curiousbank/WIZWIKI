class ThumperMailer < ApplicationMailer
  DEFAULT_FATHOM_DIGEST_RECIPIENTS = ["operator@example.invalid"].freeze

  default from: -> { ENV["WIZWIKI_MAIL_FROM"].presence || "Thumper von AUTOS <no-reply@example.invalid>" }

  def fathom_training_digest(organization:, date:, result:, started_at:, completed_at:, embedding_status: {}, dojo_scrolls: [])
    @organization = organization
    @date = date.respond_to?(:to_date) ? date.to_date : Time.zone.parse(date.to_s).to_date
    @result = normalize_result(result)
    @operations_note = operations_note_from(@result)
    @embedding_status = normalize_result(embedding_status)
    @dojo_scrolls = normalize_dojo_scrolls(dojo_scrolls)
    @started_at = parse_time(started_at)
    @completed_at = parse_time(completed_at) || Time.current
    @duration_seconds = duration_seconds(@started_at, @completed_at)
    @duration_label = duration_label(@duration_seconds)
    @calls = calls_for_day.to_a
    @call_cards = call_cards(@calls)
    @synopsis_lines = synopsis_lines(@calls)
    @thumper_image_url = attach_thumper_image

    headers["X-PM-Message-Stream"] = ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound"

    mail(
      to: digest_recipients,
      subject: "🧠 Fathom Brain digest - #{@date.strftime("%b %-d, %Y")}"
    )
  end

  def fathom_training_doc_ready(organization:, date:, result:, started_at:, completed_at:, google_doc:, embedding_status: {}, dojo_scrolls: [])
    @organization = organization
    @date = date.respond_to?(:to_date) ? date.to_date : Time.zone.parse(date.to_s).to_date
    @result = normalize_result(result)
    @operations_note = operations_note_from(@result)
    @embedding_status = normalize_result(embedding_status)
    @dojo_scrolls = normalize_dojo_scrolls(dojo_scrolls)
    @google_doc = google_doc.to_h
    @started_at = parse_time(started_at)
    @completed_at = parse_time(completed_at) || Time.current
    @duration_seconds = duration_seconds(@started_at, @completed_at)
    @duration_label = duration_label(@duration_seconds)
    @calls = calls_for_day.to_a
    @call_cards = call_cards(@calls)
    @synopsis_lines = synopsis_lines(@calls)
    @thumper_image_url = attach_thumper_image

    headers["X-PM-Message-Stream"] = ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound"

    mail(
      to: digest_recipients,
      subject: "🧠 Fathom Brain Google Doc ready - #{@date.strftime("%b %-d, %Y")}"
    )
  end

  def comms_command_email(to:, subject:, body:, stage:, sender:)
    @stage = stage
    @sender = sender
    @company_name = stage.metadata.to_h["company_name"].presence || stage.crm_record&.name.to_s.presence || "your business"
    @body = body.to_s.strip

    headers["X-PM-Message-Stream"] = ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound"

    mail(
      to: to,
      reply_to: sender&.email_address,
      subject: subject.to_s.squish.presence || "A practical next step"
    ) do |format|
      format.text { render plain: @body }
      format.html { render html: ActionController::Base.helpers.simple_format(@body) }
    end
  end

  private

  def normalize_result(result)
    result.to_h.each_with_object({}) do |(key, value), memo|
      memo[key.to_s] = value
    end
  end

  def normalize_dojo_scrolls(scrolls)
    Array(scrolls).map do |scroll|
      normalized = scroll.to_h.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
      normalized["url"] ||= normalized["doc_url"]
      normalized["full_day_url"] ||= normalized["url"]
      normalized["full_day_title"] ||= normalized["doc_name"]
      normalized["session_url"] ||= normalized["session_doc_url"]
      normalized["session_title"] ||= normalized["session_doc_name"]
      normalized["date_label"] ||= dojo_date_label(normalized["date"])
      normalized.with_indifferent_access
    end
  end

  def dojo_date_label(value)
    return if value.blank?

    Date.parse(value.to_s).strftime("%b %-d, %Y")
  rescue ArgumentError, TypeError
    value.to_s
  end

  def digest_recipients
    configured = ENV["WIZWIKI_FATHOM_DIGEST_TO"].to_s.split(/[,;\s]+/).filter_map(&:presence)
    configured.presence || DEFAULT_FATHOM_DIGEST_RECIPIENTS
  end

  def operations_note_from(result)
    result["operations_note"].presence ||
      result["digest_note"].presence ||
      ENV["WIZWIKI_FATHOM_DIGEST_NOTE"].presence
  end

  def attach_thumper_image
    path = Rails.root.join("app/assets/images/autos.png")
    return unless File.exist?(path)

    image = File.binread(path)
    attachments.inline["thumper_inline.png"] = {
      mime_type: "image/png",
      content: image
    }
    attachments["thumper_attachment.png"] = {
      mime_type: "image/png",
      content: image
    }
    attachments.inline["thumper_inline.png"].url
  rescue StandardError => error
    Rails.logger.warn("[ThumperMailer] Thumper image attach failed: #{error.class}: #{error.message}")
    nil
  end

  def calls_for_day
    start_time = @date.beginning_of_day
    end_time = @date.tomorrow.beginning_of_day

    @organization.fathom_calls
      .active
      .where(
        "(recording_start_time >= :start_time AND recording_start_time < :end_time) OR (fathom_created_at >= :start_time AND fathom_created_at < :end_time)",
        start_time: start_time,
        end_time: end_time
      )
      .recent
      .limit(75)
  end

  def synopsis_lines(calls)
    call_cards(calls, limit: 6).map do |card|
      "#{card[:title]}: #{card[:summary]}"
    end
  end

  def call_cards(calls, limit: 10)
    calls.first(limit).map do |call|
      primary_url = call.share_url.presence || call.meeting_url.presence || call.url.presence
      meeting_url = call.meeting_url.presence
      {
        title: call_title(call),
        time: call_time_label(call),
        recorded_by: call_recorded_by(call),
        people: call.respond_to?(:participant_label) ? call.participant_label.to_s.squish.presence : nil,
        summary: call_summary(call, max_chars: 420),
        action_items: clean_excerpt(call.action_items_text, max_chars: 320),
        highlights: clean_excerpt(call.highlights_text, max_chars: 260),
        primary_url: primary_url,
        meeting_url: meeting_url.present? && meeting_url != primary_url ? meeting_url : nil
      }.compact
    end
  end

  def call_title(call)
    call.title.presence || call.meeting_title.presence || "Fathom call #{call.recording_id}"
  end

  def call_time_label(call)
    value = call.recording_start_time || call.fathom_created_at || call.synced_at
    value&.in_time_zone&.strftime("%b %-d, %-I:%M %p %Z")
  end

  def call_recorded_by(call)
    [call.recorded_by_name, call.recorded_by_email].filter_map(&:presence).join(" / ").presence
  end

  def call_summary(call, max_chars:)
    clean_excerpt(call.summary, max_chars: max_chars).presence ||
      clean_excerpt(call.highlights_text, max_chars: max_chars).presence ||
      clean_excerpt(call.action_items_text, max_chars: max_chars).presence ||
      "No summary text was returned."
  end

  def clean_excerpt(value, max_chars:)
    value.to_s.squish.truncate(max_chars, omission: "...").presence
  end

  def parse_time(value)
    return value.to_time if value.respond_to?(:to_time)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def duration_seconds(started_at, completed_at)
    return if started_at.blank? || completed_at.blank?

    (completed_at.to_f - started_at.to_f).round
  end

  def duration_label(seconds)
    value = seconds.to_i
    return "not recorded" if value <= 0
    return "#{value}s" if value < 60

    "#{value / 60}m #{value % 60}s"
  end
end
