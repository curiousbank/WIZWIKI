require "json"
require "net/http"
require "uri"

module Autos
  class OpenaiClient
    API_URL = "https://api.openai.com/v1/responses"

    def self.call(instructions:, input_text:, model: nil, max_output_tokens: nil, reasoning_effort: nil, text_format: nil)
      new.call(
        instructions: instructions,
        input_text: input_text,
        model: model,
        max_output_tokens: max_output_tokens,
        reasoning_effort: reasoning_effort,
        text_format: text_format
      )
    end

    def self.extract_text(payload)
      return payload["output_text"] if payload["output_text"].present?

      Array(payload["output"]).flat_map do |item|
        Array(item["content"]).filter_map do |content|
          content["text"].presence || content["output_text"].presence
        end
      end.join("\n").strip
    end

    def self.usage(payload)
      usage = payload["usage"].to_h
      {
        "input_tokens" => usage["input_tokens"].to_i,
        "output_tokens" => usage["output_tokens"].to_i,
        "total_tokens" => usage["total_tokens"].to_i
      }
    end

    def call(instructions:, input_text:, model: nil, max_output_tokens: nil, reasoning_effort: nil, text_format: nil)
      raise "OpenAI is not configured." unless WizwikiSettings.openai_configured?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{WizwikiSettings.openai_api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      payload = {
        model: model.presence || WizwikiSettings.openai_model,
        instructions: instructions,
        max_output_tokens: max_output_tokens.presence || WizwikiSettings.openai_max_output_tokens,
        input: [
          {
            role: "user",
            content: [
              {
                type: "input_text",
                text: input_text
              }
            ]
          }
        ]
      }
      selected_reasoning_effort = reasoning_effort.presence || WizwikiSettings.openai_reasoning_effort
      payload[:reasoning] = { effort: selected_reasoning_effort } if selected_reasoning_effort.present?
      payload[:text] = { format: text_format } if text_format.present?
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) do |http|
        http.request(request)
      end

      payload = JSON.parse(response.body.presence || "{}")
      raise api_error(payload) unless response.is_a?(Net::HTTPSuccess)

      payload
    rescue JSON::ParserError
      raise "OpenAI returned an unreadable response."
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise "OpenAI timed out before Thumper finished answering."
    end

    private

    def api_error(payload)
      error = payload["error"].to_h
      error["message"].presence || error["code"].presence || "OpenAI request failed."
    end
  end
end
