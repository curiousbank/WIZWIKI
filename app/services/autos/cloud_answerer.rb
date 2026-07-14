# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Autos
  class CloudAnswerer
    INSTRUCTIONS = Autos::OpenaiAnswerer::INSTRUCTIONS

    def self.queue!(question)
      new(question).queue!
    end

    def self.call(question)
      new(question).call
    end

    def initialize(question)
      @question = question
      @writer_model = WizwikiSettings.normalize_sms_writer_model(question.metadata.to_h["writer_model"])
    end

    def queue!
      raise "#{writer_label} is not configured" unless WizwikiSettings.sms_writer_cloud_configured?(writer_model)
      raise "Autos::CloudAnswerJob is unavailable" unless defined?(Autos::CloudAnswerJob)

      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "queued",
        "queued_at" => Time.current.iso8601,
        "lane" => "ask_cloud_writer",
        "provider" => cloud_provider,
        "model" => cloud_model
      )
      question.update!(
        status: "queued",
        metadata: metadata.merge(
          "local_worker" => worker,
          "model_lane" => "ask_cloud_writer",
          "writer_model" => writer_model,
          "writer_model_label" => writer_label
        ).compact_blank
      )
      Autos::CloudAnswerJob.perform_later(question.id)
      question
    end

    def call
      raise "#{writer_label} is not configured" unless WizwikiSettings.sms_writer_cloud_configured?(writer_model)

      started_at = Time.current
      mark_processing!(started_at)
      context = Autos::ContextBuilder.call(question)
      raw_answer = cloud_provider == "openai" ? openai_answer(context.fetch(:text)) : nvidia_answer(context.fetch(:text))
      constrained_raw_answer = Autos::Voice.constrain_answer_length(raw_answer)
      answer = Autos::Voice.customer_visible_answer(raw_answer, question: question)
      raise "#{writer_label} returned no visible answer" if answer.blank?

      visible_answer_safety = if answer != constrained_raw_answer
        {
          "status" => "sanitized",
          "reason" => "internal_draft_leak_blocked",
          "sanitized_at" => Time.current.iso8601
        }
      end

      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "answered",
        "completed_at" => Time.current.iso8601,
        "provider" => cloud_provider,
        "model" => @actual_model.presence || cloud_model,
        "elapsed_seconds" => (Time.current - started_at).round(1)
      )

      question.update!(
        answer: answer,
        status: "answered",
        metadata: metadata.merge(
          "local_worker" => worker.compact_blank,
          "context_counts" => context.fetch(:counts),
          "visible_answer_safety" => visible_answer_safety,
          "writer_model" => writer_model,
          "writer_model_label" => writer_label,
          cloud_provider => {
            "model" => @actual_model.presence || cloud_model,
            "answered_at" => Time.current.iso8601
          }
        ).compact_blank
      )
      Autos::ChatMemoryRecorder.record!(question.reload)
      Autos::VoiceJob.perform_later(question.id) if defined?(Autos::VoiceJob)
      question
    rescue StandardError => error
      Rails.logger.warn("[Autos::CloudAnswerer] failed question=#{question&.id} #{error.class}: #{error.message}")
      fail_question!("#{writer_label} could not answer right now: #{error.message}")
    end

    private

    attr_reader :question, :writer_model

    def cloud_provider
      @cloud_provider ||= WizwikiSettings.sms_writer_cloud_provider(writer_model)
    end

    def cloud_model
      @cloud_model ||= WizwikiSettings.sms_writer_cloud_model(writer_model)
    end

    def writer_label
      @writer_label ||= WizwikiSettings.sms_writer_model_label(writer_model)
    end

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

    def openai_answer(context_text)
      payload = Autos::OpenaiClient.call(instructions: INSTRUCTIONS, input_text: prompt_text(context_text))
      @actual_model = payload["model"].presence || cloud_model
      Autos::OpenaiClient.extract_text(payload)
    end

    def nvidia_answer(context_text)
      api_key = nvidia_api_key
      raise "#{writer_label} API key is missing" if api_key.blank?

      base = URI.parse(nvidia_base_url)
      uri = URI.join(base.to_s.chomp("/") + "/", "chat/completions")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      payload = {
        model: cloud_model,
        temperature: 0.42,
        top_p: 0.9,
        max_tokens: 700,
        messages: [
          { role: "system", content: INSTRUCTIONS },
          { role: "user", content: prompt_text(context_text) }
        ]
      }
      if cloud_model.to_s.include?("nemotron")
        payload[:chat_template_kwargs] = { enable_thinking: false }
        payload[:reasoning_budget] = 0
      end
      request.body = JSON.generate(payload)

      read_timeout = nvidia_read_timeout_seconds
      open_timeout = nvidia_open_timeout_seconds
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: open_timeout, read_timeout: read_timeout) do |http|
        http.request(request)
      end
      payload = JSON.parse(response.body.presence || "{}")
      raise(payload.dig("error", "message").presence || "NVIDIA returned HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      @actual_model = payload["model"].presence || cloud_model
      payload.dig("choices", 0, "message", "content").to_s
    rescue JSON::ParserError
      raise "NVIDIA returned an unreadable response"
    end

    def nvidia_api_key
      if writer_model.to_s == "nvidia:warp"
        ENV["WIZWIKI_WARP_GPU_API_KEY"].presence ||
          ENV["WIZWIKI_WARP_NVIDIA_API_KEY"].presence ||
          ENV["NVIDIA_API_KEY"].presence ||
          ENV["WIZWIKI_NVIDIA_API_KEY"].presence
      else
        ENV["NVIDIA_API_KEY"].presence || ENV["WIZWIKI_NVIDIA_API_KEY"].presence
      end
    end

    def nvidia_base_url
      if writer_model.to_s == "nvidia:warp"
        WizwikiSettings.warp_gpu_base_url.presence || raise("WARP rented GPU base URL is not configured")
      else
        ENV["WIZWIKI_NEMOTRON_SMS_BASE_URL"].presence ||
          ENV["WIZWIKI_COMMS_NEMOTRON_BASE_URL"].presence ||
          ENV["WIZWIKI_COMMS_NVIDIA_BASE_URL"].presence ||
          ENV["NVIDIA_BASE_URL"].presence ||
          "https://integrate.api.nvidia.com/v1"
      end
    end

    def nvidia_read_timeout_seconds
      if writer_model.to_s == "nvidia:warp"
        ENV.fetch("WIZWIKI_WARP_GPU_READ_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_READ_TIMEOUT_SECONDS", "35")).to_i.clamp(8, 120)
      else
        ENV.fetch("WIZWIKI_NEMOTRON_SMS_READ_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_READ_TIMEOUT_SECONDS", "35")).to_i.clamp(8, 120)
      end
    end

    def nvidia_open_timeout_seconds
      if writer_model.to_s == "nvidia:warp"
        ENV.fetch("WIZWIKI_WARP_GPU_OPEN_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_OPEN_TIMEOUT_SECONDS", "8")).to_i.clamp(2, 30)
      else
        ENV.fetch("WIZWIKI_NEMOTRON_SMS_OPEN_TIMEOUT_SECONDS", ENV.fetch("WIZWIKI_WARP_NVIDIA_OPEN_TIMEOUT_SECONDS", "8")).to_i.clamp(2, 30)
      end
    end

    def mark_processing!(started_at)
      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "processing",
        "started_at" => started_at.iso8601,
        "provider" => cloud_provider,
        "model" => cloud_model
      )
      question.update!(status: "queued", metadata: metadata.merge("local_worker" => worker.compact_blank))
    end

    def fail_question!(message)
      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "failed",
        "failed_at" => Time.current.iso8601,
        "provider" => cloud_provider,
        "model" => cloud_model,
        "last_error" => message.to_s.truncate(500)
      )
      question.update!(
        answer: message,
        status: "failed",
        metadata: metadata.merge(
          "local_worker" => worker.compact_blank,
          "writer_model" => writer_model,
          "writer_model_label" => writer_label
        ).compact_blank
      )
      question
    end
  end
end
