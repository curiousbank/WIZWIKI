module Autos
  class BuildAnswerer
    INSTRUCTIONS = <<~TEXT.squish
  You are Thumper von AUTOS, WIZWIKI's read-only build staging assistant.
  #{Autos::Voice::FRANKENSTEIN}
  You can only create a staged written build brief. You cannot edit files, write code to disk, run commands, change records beyond this saved brief, deploy, send messages, move money, or perform external actions. Use only the supplied database context. Return 3 to 5 short lines covering summary, plan, risk or missing info, and approval note. Never claim the change has been made.
TEXT

    def self.call(build_request)
      new(build_request).call
    end

    def initialize(build_request)
      @build_request = build_request
    end

    def call
      unless WizwikiSettings.openai_runtime_enabled?
        return mark!(status: "failed", answer: "Qwen-only mode is active. Build staging needs the local worker path before it can answer without OpenAI.")
      end

      context = Autos::ContextBuilder.call(build_request)
      payload = Autos::OpenaiClient.call(instructions: INSTRUCTIONS, input_text: prompt_text(context.fetch(:text)))
      answer = Autos::Voice.constrain_answer_length(Autos::OpenaiClient.extract_text(payload), max_chars: 700, max_lines: 5).presence || "Thumper returned an empty build brief."

      mark!(
        status: "answered",
        answer: answer,
        openai: {
          "response_id" => payload["id"],
          "model" => payload["model"].presence || WizwikiSettings.openai_model,
          "usage" => Autos::OpenaiClient.usage(payload),
          "answered_at" => Time.current.iso8601
        },
        context_counts: context.fetch(:counts)
      )
    rescue StandardError => error
      Rails.logger.warn("Autos build answer failed: #{error.class} - #{error.message}")
      mark!(status: "failed", answer: "Thumper build brain failed: #{error.message}")
    end

    private

    attr_reader :build_request

    def prompt_text(context_text)
      <<~TEXT
        BUILD TITLE:
        #{build_request.title}

        TARGET AREA:
        #{build_request.target_area}

        EMPLOYEE BUILD PROMPT:
        #{build_request.prompt}

        READ-ONLY DATABASE CONTEXT:
        #{context_text}
      TEXT
    end

    def mark!(status:, answer:, openai: nil, context_counts: nil)
      payload = {
        "status" => status,
        "answer" => answer,
        "generated_at" => Time.current.iso8601
      }
      payload["openai"] = openai if openai.present?
      payload["context_counts"] = context_counts if context_counts.present?

      build_request.update!(metadata: build_request.metadata.to_h.merge("autos_build" => payload))
    end
  end
end
