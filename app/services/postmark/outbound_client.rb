require "base64"
require "json"
require "net/http"
require "uri"

module Postmark
  class OutboundClient
    ENDPOINT = "https://api.postmarkapp.com/email".freeze

    def self.configured?
      token.present?
    end

    def self.token
      ENV["POSTMARK_API_TOKEN"].presence || ENV["POSTMARK_API_KEY"].presence || ENV["postmark_api_key"].presence
    end

    def self.deliver_mail(mail, message_stream: nil)
      new.deliver_mail(mail, message_stream: message_stream)
    end

    def deliver_mail(mail, message_stream: nil)
      raise "Postmark API token is not configured" unless self.class.configured?

      payload = payload_for(mail, message_stream: message_stream)
      response = post_json(payload)
      {
        "message_id" => response["MessageID"],
        "submitted_at" => response["SubmittedAt"],
        "to" => payload.fetch(:To),
        "message_stream" => payload.fetch(:MessageStream),
        "error_code" => response["ErrorCode"],
        "message" => response["Message"]
      }.compact
    end

    private

    def payload_for(mail, message_stream:)
      stream = message_stream.presence || ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound"
      payload = {
        From: mail[:from].to_s,
        To: Array(mail.to).join(","),
        Subject: mail.subject.to_s,
        HtmlBody: html_body(mail),
        TextBody: text_body(mail),
        MessageStream: stream,
        TrackOpens: true
      }.compact_blank
      attachments = attachments_for(mail)
      payload[:Attachments] = attachments if attachments.any?
      payload
    end

    def html_body(mail)
      if mail.html_part.present?
        mail.html_part.body.decoded
      elsif mail.mime_type.to_s.include?("html")
        mail.body.decoded
      end
    end

    def text_body(mail)
      if mail.text_part.present?
        mail.text_part.body.decoded
      elsif !mail.mime_type.to_s.include?("html")
        mail.body.decoded
      end
    end

    def attachments_for(mail)
      mail.attachments.map do |attachment|
        payload = {
          Name: attachment.filename.to_s,
          Content: Base64.strict_encode64(attachment.body.decoded),
          ContentType: attachment.mime_type.presence || "application/octet-stream"
        }
        content_id = inline_content_id(attachment)
        payload[:ContentID] = content_id if content_id.present?
        payload
      end
    end

    def inline_content_id(attachment)
      return unless attachment_inline?(attachment)

      content_id = attachment.url.to_s.presence || attachment.content_id.to_s.delete("<>").presence
      return if content_id.blank?

      content_id.start_with?("cid:") ? content_id : "cid:#{content_id}"
    end

    def attachment_inline?(attachment)
      attachment.respond_to?(:inline?) && attachment.inline? ||
        attachment.content_disposition.to_s.downcase.include?("inline")
    end

    def post_json(payload)
      uri = URI(ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request["X-Postmark-Server-Token"] = self.class.token
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |http|
        http.request(request)
      end
      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise "Postmark API request failed: #{error.class}"
    end

    def parse_response(response)
      body = response.body.to_s
      parsed = body.present? ? JSON.parse(body) : {}
      if response.is_a?(Net::HTTPSuccess) && parsed["ErrorCode"].to_i.zero?
        parsed
      else
        raise "Postmark API HTTP #{response.code}: #{parsed["Message"].presence || body.squish.truncate(240)}"
      end
    rescue JSON::ParserError => error
      raise "Postmark API response was not valid JSON: #{error.message}"
    end
  end
end
