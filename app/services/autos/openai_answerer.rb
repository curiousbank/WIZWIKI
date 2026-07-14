module Autos
  class OpenaiAnswerer
    INSTRUCTIONS = <<~TEXT.squish
  You are Thumper von AUTOS, WIZWIKI's read-only company-memory assistant for the active organization.
  #{Thumper::VoiceGuide.ask_prompt}
  You may answer questions using only the database context supplied in this request. You cannot edit files, write code, change records, send messages, move money, or perform external actions. Keep answers clearly tied to the supplied company context.
TEXT

    def self.call(question)
      new(question).call
    end

    def initialize(question)
      @question = question
    end

    def call
      if Autos::WorkerQueue.enabled_for?(question)
        Autos::WorkerQueue.queue!(question)
        return
      end

      unless WizwikiSettings.openai_runtime_enabled?
        return fail_question!("Qwen-only mode is active. Alice local worker must answer this prompt; OpenAI fallback is disabled.")
      end

      context = Autos::ContextBuilder.call(question)
      payload = Autos::OpenaiClient.call(instructions: INSTRUCTIONS, input_text: prompt_text(context.fetch(:text)))
      raw_answer = Autos::OpenaiClient.extract_text(payload)
      constrained_raw_answer = Autos::Voice.constrain_answer_length(raw_answer)
      answer = Autos::Voice.customer_visible_answer(raw_answer, question: question)
      raise "OpenAI returned no visible answer. Output budget may have been spent on reasoning." if answer.blank?

      visible_answer_safety = if answer != constrained_raw_answer
        {
          "status" => "sanitized",
          "reason" => "internal_draft_leak_blocked",
          "sanitized_at" => Time.current.iso8601
        }
      end

      question.update!(
        answer: answer.presence || "Thumper returned an empty answer.",
        status: "answered",
        metadata: question.metadata.to_h.merge(
          "openai" => {
            "response_id" => payload["id"],
            "model" => payload["model"].presence || WizwikiSettings.openai_model,
            "usage" => Autos::OpenaiClient.usage(payload),
            "answered_at" => Time.current.iso8601
          },
          "context_counts" => context.fetch(:counts),
          "visible_answer_safety" => visible_answer_safety
        ).compact
      )
      Autos::ChatMemoryRecorder.record!(question.reload)
    rescue StandardError => error
      Rails.logger.warn("Thumper OpenAI answer failed: #{error.class} - #{error.message}")
      fail_question!("Thumper could not answer right now: #{error.message}")
    end

    private

    attr_reader :question

    def prompt_text(context_text)
      <<~TEXT
        USER QUESTION:
        #{question.question}

        OPTIONAL USER CONTEXT:
        #{question.context.presence || "None provided."}

        READ-ONLY DATABASE CONTEXT:
        #{context_text}
      TEXT
    end

    def fail_question!(message)
      question.update!(
        answer: message,
        status: "failed",
        metadata: question.metadata.to_h.merge("openai_error" => { "message" => message, "failed_at" => Time.current.iso8601 })
      )
    end
  end
end
