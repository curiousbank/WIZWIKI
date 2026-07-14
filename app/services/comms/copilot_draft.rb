module Comms
  class CopilotDraft
    Result = Data.define(:queued, :drafted, :question_id, :body, :result) do
      def to_h
        {
          queued: queued,
          drafted: drafted,
          question_id: question_id,
          body: body,
          result: result
        }
      end
    end

    def self.call(stage:, user:, operator_prompt:, writer_model: nil, challenger_model: nil, user_prompt: nil)
      new(
        stage: stage,
        user: user,
        operator_prompt: operator_prompt,
        writer_model: writer_model,
        challenger_model: challenger_model,
        user_prompt: user_prompt
      ).call
    end

    def initialize(stage:, user:, operator_prompt:, writer_model:, challenger_model:, user_prompt:)
      @stage = stage
      @user = user
      @operator_prompt = operator_prompt.to_s.squish.presence || default_operator_prompt
      @user_prompt = user_prompt.to_s.strip.presence
      @writer_model = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.sms_writer_model_from_metadata(stage.metadata))
      @challenger_model = WizwikiSettings.normalize_challenger_model(challenger_model.presence || stage.metadata.to_h["sms_challenger_model"].presence || WizwikiSettings.default_challenger_model)
    end

    def call
      result = if reset_conversation_opening_needed?
        reset_conversation_opening_result
      else
        DealReports::CommsDraftWriter.queue_background(
          stage: stage,
          user: user,
          operator_prompt: operator_prompt,
          writer_model: writer_model,
          challenger_model: challenger_model,
          copilot: true
        )
      end
      save_result!(result.to_h)
    end

    private

    attr_reader :stage, :user, :operator_prompt, :user_prompt, :writer_model, :challenger_model

    def reset_conversation_opening_needed?
      return false unless operator_prompt.include?("CONVERSATION RESET MODE")

      metadata = stage.metadata.to_h
      reset_at = parse_time(metadata["sms_conversation_reset_at"])
      return false if reset_at.blank?

      Array(metadata["sms_thread"]).map(&:to_h).none? do |event|
        next false unless event["direction"].to_s == "inbound"

        event_time = parse_time(
          event["created_at"].presence ||
            event["at"].presence ||
            event["timestamp"].presence ||
            event["date_created"].presence
        )
        event_time.present? && event_time >= reset_at
      end
    end

    def reset_conversation_opening_result
      body = DealReports::CommsDraftWriter.new(
        stage: stage,
        user: user,
        operator_prompt: operator_prompt,
        writer_model: writer_model,
        challenger_model: challenger_model,
        copilot: true
      ).reset_conversation_opening_body
      {
        "body" => body,
        "provider" => "wizwiki/reset_starter",
        "model" => "deterministic_reset_opener",
        "writer_model" => writer_model,
        "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
        "challenger_model" => challenger_model,
        "challenger_model_label" => WizwikiSettings.challenger_model_label(challenger_model),
        "draft_source" => "reset_conversation_opener",
        "draft_mode" => "copilot",
        "copilot" => true,
        "reason" => "Reset conversation opener staged immediately for manual approval. No SMS sent.",
        "operator_prompt" => operator_prompt,
        "sms_generation_pipeline" => "reset_conversation_starter",
        "sms_quality_gate" => "passed",
        "background_queued" => false,
        "pending" => false
      }.compact_blank
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def save_result!(result)
      metadata = stage.reload.metadata.to_h.deep_dup
      writer_label = result["writer_model_label"].presence || WizwikiSettings.sms_writer_model_label(writer_model)
      challenger_label = result["challenger_model_label"].presence || WizwikiSettings.challenger_model_label(challenger_model)
      now = Time.current

      if ActiveModel::Type::Boolean.new.cast(result["pending"])
        current_draft_source = metadata.dig("comms_command_sms_draft", "draft_source").to_s
        pending_body = current_draft_source == "fallback" ? nil : safe_customer_sms_body(metadata["comms_command_sms_draft_body"])
        stage.update!(
          generated_at: now,
          metadata: metadata.merge(
            "comms_command_sms_draft_body" => pending_body,
            "comms_command_sms_prompt" => user_prompt,
            "comms_command_sms_default_objective" => user_prompt.blank? ? operator_prompt : nil,
            "comms_command_sms_draft" => result.merge(
              "writer_model" => result["writer_model"].presence || writer_model,
              "writer_model_label" => writer_label,
              "challenger_model" => result["challenger_model"].presence || challenger_model,
              "challenger_model_label" => challenger_label,
              "draft_source" => "pending",
              "draft_mode" => "copilot",
              "copilot" => true,
              "created_at" => now.iso8601
            ),
            "sms_writer_model" => writer_model,
            "sms_writer_model_label" => writer_label,
            "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(writer_model),
            "sms_challenger_model" => challenger_model,
            "sms_challenger_model_label" => challenger_label,
            "sms_copilot_requested_at" => now.iso8601,
            "sms_copilot_requested_by_user_id" => user.id,
            "sms_copilot_requested_by" => user.display_name,
            "sms_copilot_last_question_id" => result["autos_question_id"],
            "comms_command_last_channel" => "sms",
            "comms_command_last_status" => "drafting",
            "comms_command_last_at" => now.iso8601,
            "comms_command_background_question_id" => result["autos_question_id"],
            "comms_command_background_status" => "queued",
            "comms_command_background_at" => now.iso8601
          ).compact_blank
        )
        return Result.new(queued: true, drafted: false, question_id: result["autos_question_id"], body: pending_body, result: result)
      end

      raw_body = result["body"].to_s.strip.presence
      body = safe_customer_sms_body(raw_body)
      blocked_body = raw_body.present? && body.blank?
      if blocked_body
        reason = defined?(Comms::SmsBodySafety) ? Comms::SmsBodySafety.leak_reason(raw_body) : "unsafe_sms_body"
        Rails.logger.warn("[Comms::CopilotDraft] blocked unsafe draft stage=#{stage&.id} reason=#{reason}")
        result = result.except("body").merge(
          "error" => [result["error"], "sms_body_safety_rejected: #{reason}"].compact_blank.join(" | "),
          "sms_quality_gate" => "blocked",
          "draft_source" => "safety_rejected"
        )
      end

      preserved_body = blocked_body ? safe_customer_sms_body(metadata["comms_command_sms_draft_body"]) : nil
      active_body = body || preserved_body
      history = Array(metadata["sms_draft_history"]).last(24)
      if body.present?
        history << {
          "id" => SecureRandom.uuid,
          "body" => body,
          "provider" => result["provider"],
          "model" => result["model"],
          "writer_model" => result["writer_model"].presence || writer_model,
          "writer_model_label" => writer_label,
          "challenger_model" => result["challenger_model"].presence || challenger_model,
          "challenger_model_label" => challenger_label,
          "draft_source" => result["draft_source"].presence || "copilot",
          "draft_mode" => "copilot",
          "copilot" => true,
          "reason" => result["reason"],
          "operator_prompt" => result["operator_prompt"],
          "error" => result["error"],
          "user_id" => user.id,
          "user_name" => user.display_name,
          "created_at" => now.iso8601
        }.compact_blank
      end

      processing = body.present? ? processing_payload(metadata, body) : {}
      stage.update!(
        generated_at: now,
        metadata: metadata.merge(
          "comms_command_sms_draft_body" => active_body,
          "comms_command_sms_prompt" => user_prompt,
          "comms_command_sms_default_objective" => user_prompt.blank? ? operator_prompt : nil,
          "comms_command_sms_draft" => result.except("body").merge(
            "body" => active_body,
            "writer_model" => result["writer_model"].presence || writer_model,
            "writer_model_label" => writer_label,
            "challenger_model" => result["challenger_model"].presence || challenger_model,
            "challenger_model_label" => challenger_label,
            "draft_source" => result["draft_source"].presence || "copilot",
            "draft_mode" => "copilot",
            "copilot" => true,
            "created_at" => now.iso8601
          ),
          "sms_writer_model" => writer_model,
          "sms_writer_model_label" => writer_label,
          "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(writer_model),
          "sms_challenger_model" => challenger_model,
          "sms_challenger_model_label" => challenger_label,
          "sms_draft_history" => history,
          "comms_bot_state" => result["conversation_state"].presence,
          "sms_copilot_requested_at" => now.iso8601,
          "sms_copilot_requested_by_user_id" => user.id,
          "sms_copilot_requested_by" => user.display_name,
          "sms_copilot_last_question_id" => result["autos_question_id"],
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => body.present? ? "copilot_drafted" : "copilot_failed",
          "comms_command_last_at" => now.iso8601,
          "comms_command_background_question_id" => result["autos_question_id"],
          "comms_command_background_status" => result["background_queued"] ? "queued" : nil,
          "comms_command_background_at" => result["background_queued"] ? now.iso8601 : nil,
          "comms_command_background_error" => result["error"].presence
        ).compact_blank.merge(processing)
      )
      Result.new(queued: false, drafted: body.present?, question_id: result["autos_question_id"], body: active_body, result: result)
    end

    def safe_customer_sms_body(value)
      return if value.blank?
      return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

      value.to_s.strip.presence
    end

    def processing_payload(metadata, body)
      return {} unless defined?(DealReports::CommsProcessingCode)

      DealReports::CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: body)
    rescue StandardError => error
      Rails.logger.warn("[Comms::CopilotDraft] processing failed stage=#{stage&.id} #{error.class}: #{error.message}")
      {}
    end

    def default_operator_prompt
      [
        "Copilot mode: generate the next SMS from the current SMS thread and Thumper objective.",
        "Draft only; save the answer for human review in the NEXT TEXT box and do not send automatically.",
        Comms::SmsOperatorPrompt.manual_next_text(
          objective: "Keep the SMS conversation helpful and short. Answer WIZWIKI Marketing questions from product data, discover product interest and one practical fit signal, recommend the best checkout link when clear, and use account-manager handoff only when needed."
        )
      ].join(" ")
    end
  end
end
