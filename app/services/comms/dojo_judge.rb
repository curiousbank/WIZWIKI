# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Comms
  class DojoJudge
    INSTRUCTIONS = <<~TEXT.squish
      You are Recursive Dojo, an independent quality judge for WIZWIKI Marketing's Thumper SMS agent.
      You are not the drafting model. Audit the Thumper answer like a senior operator training a customer-facing sales/support agent.
      Grade only the supplied scenario and answer. Do not invent facts. Be strict about directness, completeness, warmth, and safety.
      Thumper must answer the latest customer question first, use real prices/details when available, avoid internal reasoning leaks,
      ask at most one useful next question, avoid premature goodbye language, explain design/proof flow accurately, and avoid rushing to AM support except when rush/custom availability truly needs a marketing consultant.
      Lead source sets the starting product lane; the customer's latest message sets the current lane. A yard-sign lead should not be pushed into
      postcards, EDDM, bundles, or Neighborhood Blitz unless the customer brings that lane up.
      Grade the vibe, too: PASS requires a relaxed Thumper/WIZWIKI voice that feels useful, candid, warm, complete, and natural.
      Do not reward answers that are technically safe but clipped, robotic, patronizing, canned, evasive, or over-guardrailed.
      Any prompt-style prefix such as "Quick practical check," "One useful detail," "Still worth asking," "One clean next step,"
      "Small practical check," "No rush, one helpful detail," or "Fresh start here" is REVIEW.
      Do not mark an answer wrong for using an approved price or package fact listed in the supplied rules.
      Return JSON only. No markdown. No prose outside JSON.
    TEXT

    JSON_KEYS = %w[score verdict findings rewrite embedding_lesson].freeze
    DOJO_JUDGE_MEMORY_KIND = "comms_dojo_judge_memory".freeze
    JUDGE_MEMORY_MAX_CHARS = 2_400

    class << self
      def call(stage:, inbound:, answer:, draft_result:, fallback_grade:)
        new(stage: stage, inbound: inbound, answer: answer, draft_result: draft_result, fallback_grade: fallback_grade).call
      end
    end

    def initialize(stage:, inbound:, answer:, draft_result:, fallback_grade:)
      @stage = stage
      @inbound = inbound.to_s.squish
      @answer = answer.to_s.squish
      @draft_result = draft_result.to_h
      @fallback_grade = fallback_grade.to_h.deep_dup
    end

    def call
      qwen_grade
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoJudge] #{judge_provider} judge failed stage=#{stage&.id} #{error.class}: #{error.message}")
      fallback_with("deterministic/rules", "rails_dojo_checklist", "#{error.class}: #{error.message}")
    end

    private

    attr_reader :stage, :inbound, :answer, :draft_result, :fallback_grade

    def qwen_grade
      return fallback_with("deterministic/rules", "rails_dojo_checklist", "Qwen Dojo judge disabled.") unless qwen_judge_enabled?
      return qwen_worker_grade if qwen_worker_enabled?

      uri = URI.join(qwen_base_url.to_s.chomp("/") + "/", "api/generate")
      payload = {
        model: qwen_judge_model,
        stream: false,
        format: "json",
        options: {
          temperature: qwen_temperature,
          top_p: 0.86,
          repeat_penalty: 1.08,
          num_predict: judge_max_output_tokens
        },
        prompt: qwen_prompt
      }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 4, read_timeout: qwen_read_timeout) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(payload)
        http.request(request)
      end
      raise "Qwen judge returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body.presence || "{}")
      parsed = parse_json(body["response"])
      grade = normalize(parsed).merge(
        "judge_provider" => "ollama/qwen_30b_dojo_judge",
        "judge_model" => body["model"].presence || qwen_judge_model,
        "fallback_score" => fallback_grade["score"],
        "fallback_verdict" => fallback_grade["verdict"]
      ).compact_blank
      audit_grade(grade)
    end

    def qwen_worker_grade
      organization = stage&.organization || stage&.crm_record&.organization
      user = stage&.user || organization&.users&.order(:id)&.first
      raise "Qwen worker judge missing organization/user" if organization.blank? || user.blank?
      raise "Autos local worker queue is disabled" unless defined?(AutosQuestion) && defined?(Autos::WorkerQueue) && Autos::WorkerQueue.enabled?

      question = organization.autos_questions.create!(
        user: user,
        status: "queued",
        question: qwen_prompt,
        context: [
          "Recursive Dojo judge job.",
          "Return strict JSON only.",
          "No customer-facing SMS should be sent from this answer."
        ].join("\n"),
        metadata: {
          "surface" => "dojo_judge",
          "origin" => "recursive_dojo",
          "source" => "recursive_dojo",
          "skip_chat_memory" => true,
          "skip_voice" => true,
          "skip_ui_broadcast" => true,
          "comms_stage_id" => stage&.id,
          "writer_model" => qwen_judge_model,
          "writer_model_label" => "Qwen 30B Dojo Judge",
          "semantic_query" => judge_semantic_query,
          "answer_style" => "dojo_judge_json",
          "submitted_at" => Time.current.iso8601,
          "local_worker" => {
            "provider" => "qwen/local",
            "model" => qwen_judge_model,
            "status" => "queued"
          }
        }.compact_blank
      )
      Autos::WorkerQueue.queue!(question)

      deadline = Time.current + qwen_worker_wait_seconds.seconds
      loop do
        question.reload
        if question.status.to_s == "answered" && question.answer.to_s.squish.present?
          parsed = parse_json(question.answer)
          grade = normalize(parsed).merge(
            "judge_provider" => "autos_worker/qwen_30b_dojo_judge",
            "judge_model" => question.metadata.to_h.dig("local_worker", "model").presence || qwen_judge_model,
            "judge_autos_question_id" => question.id,
            "fallback_score" => fallback_grade["score"],
            "fallback_verdict" => fallback_grade["verdict"]
          ).compact_blank
          return audit_grade(grade)
        end
        if question.status.to_s.in?(%w[failed canceled])
          raise "Qwen worker judge #{question.status}: #{question.answer.to_s.squish.presence || question.metadata.to_h.dig('local_worker', 'last_error')}"
        end
        break if Time.current >= deadline

        sleep 1
      end

      fail_qwen_worker_question!(question, "Qwen worker judge timed out after #{qwen_worker_wait_seconds}s")
      raise "Qwen worker judge timed out after #{qwen_worker_wait_seconds}s autos_question=#{question.id}"
    end

    def fail_qwen_worker_question!(question, message)
      question.reload
      return unless question.status.to_s == "queued"

      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "failed",
        "last_error" => message,
        "failed_at" => Time.current.iso8601
      )
      question.update!(status: "failed", answer: message, metadata: metadata.merge("local_worker" => worker))
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoJudge] failed marking worker judge timeout question=#{question&.id} #{error.class}: #{error.message}")
    end

    def judge_provider
      raw = ENV.fetch("WIZWIKI_DOJO_JUDGE_PROVIDER", "qwen_30b").to_s.downcase.tr("-", "_")
      return raw if raw.in?(%w[qwen qwen_30b qwen_local local ollama])

      "qwen_30b"
    end

    def qwen_judge_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_DOJO_QWEN_JUDGE", "true"))
    end

    def qwen_worker_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_DOJO_QWEN_USE_WORKER", "true"))
    end

    def qwen_base_url
      URI.parse(ENV["WIZWIKI_DOJO_QWEN_URL"].presence || ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434")
    end

    def qwen_judge_model
      ENV["WIZWIKI_DOJO_QWEN_30B_MODEL"].presence ||
        ENV["WIZWIKI_COPY_MAKER_QWEN_30B_MODEL"].presence ||
        "qwen3:30b"
    end

    def qwen_temperature
      ENV.fetch("WIZWIKI_DOJO_QWEN_TEMPERATURE", "0.18").to_f.clamp(0.0, 0.8)
    end

    def qwen_read_timeout
      ENV.fetch("WIZWIKI_DOJO_QWEN_READ_TIMEOUT", "180").to_i.clamp(20, 420)
    end

    def qwen_worker_wait_seconds
      ENV.fetch("WIZWIKI_DOJO_QWEN_WORKER_WAIT_SECONDS", "180").to_i.clamp(20, 600)
    end

    def qwen_prompt
      [
        "/no_think",
        "Return exactly one compact JSON object. The first character must be { and the last character must be }.",
        "Do not restate the scenario. Do not explain your grading. Do not write markdown, code fences, analysis, or customer-facing SMS outside JSON.",
        "Required JSON shape: {\"score\":90,\"verdict\":\"PASS\",\"findings\":[\"short finding\"],\"rewrite\":\"\",\"embedding_lesson\":\"short lesson\"}",
        "Allowed verdict values: PASS or REVIEW.",
        "",
        "JUDGE CALIBRATION MEMORY:",
        judge_calibration_memory,
        "",
        INSTRUCTIONS,
        prompt
      ].join("\n")
    end

    def judge_calibration_memory
      organization = stage&.organization || stage&.crm_record&.organization
      return "No stored judge calibration memory yet. Apply the hard rules in this prompt." if organization.blank?

      document = organization.training_documents
        .where(source_type: "comms_playbook_memory")
        .where.not(status: "archived")
        .where("metadata @> ?", { training_kind: DOJO_JUDGE_MEMORY_KIND }.to_json)
        .order(updated_at: :desc)
        .first
      body = document&.body.to_s.squish
      body.presence&.truncate(JUDGE_MEMORY_MAX_CHARS, omission: "...") ||
        "No stored judge calibration memory yet. Apply the hard rules in this prompt."
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoJudge] judge calibration memory failed stage=#{stage&.id} #{error.class}: #{error.message}")
      "No stored judge calibration memory available. Apply the hard rules in this prompt."
    end

    def judge_semantic_query
      [
        inbound,
        answer,
        Array(fallback_grade["findings"]).join(" "),
        "judge calibration direct answer pricing design proof link request package label starter pack pro pack yard signs"
      ].compact_blank.join("\n").truncate(1_600)
    end

    def audit_grade(grade)
      return grade unless defined?(Comms::DojoJudgeAudit)

      Comms::DojoJudgeAudit.call(
        stage: stage,
        inbound: inbound,
        answer: answer,
        grade: grade,
        fallback_grade: fallback_grade,
        draft_result: draft_result
      )
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoJudge] judge audit failed stage=#{stage&.id} #{error.class}: #{error.message}")
      grade
    end

    def judge_max_output_tokens
      (ENV["WIZWIKI_DOJO_JUDGE_MAX_OUTPUT_TOKENS"].presence || 1_800).to_i.clamp(500, 3_000)
    end

    def prompt
      <<~TEXT
        TASK:
        Grade this Thumper SMS answer. Return compact JSON with exactly these keys:
        - score: integer 0-100
        - verdict: "PASS" if safe/sendable, otherwise "REVIEW"
        - findings: array of short concrete findings
        - rewrite: improved customer-facing SMS, or empty string if the answer is already strong
        - embedding_lesson: one concise training lesson for future Thumper answers

        SCORING:
        90-100: direct, complete, warm, grounded, one next question max.
        75-89: mostly usable but has a small miss, weak vibe, or tone issue.
        50-74: material miss; needs review before sending.
        0-49: unsafe, internal leak, wrong product/price, or non-answer.

        HARD CHECKS:
        #{fallback_findings_text}

        THUMPER / WIZWIKI VOICE STANDARD TO GRADE AGAINST:
        #{thumper_voice_standard}

        CUSTOMER SCENARIO:
        #{inbound}

        Thumper ANSWER:
        #{answer.presence || "[blank]"}

        DRAFT METADATA:
        #{draft_metadata.to_json}

        RECENT THREAD CONTEXT:
        #{recent_thread_context}

        WIZWIKI FACTS/RULES TO ENFORCE:
        - Starter Pack: $299 for 20 yard signs, 500 business cards, and 500 door hangers.
        - Pro Pack: $599 for 100 signs, 1,000 business cards, and 1,000 door hangers.
        - Yard Signs package tiers include 10 signs at $99, 20 at $159, 50 at $249, 100 at $399, 250 at $899, 500 at $1,699, and 1,000 at $3,349.
        - Do not quote 200 yard signs for $749 as a standard checkout tier unless live product data shows a 200-sign checkout option. Current live checkout skips from 100 to 250.
        - $100 gets about 10 yard signs.
        - Yard-sign lane pass standard: answer price/design/turnaround/link questions first; remember quantity/logo/product facts; no broad "postcards, signs, or both" discovery after the customer chose signs.
        - Rush/expedite pass standard: answer rush directly. Rush starts after design/proof approval, mainly moves print production ahead in the queue, shipping is still usually 2 to 5 days by UPS/FedEx ground, and pricing/availability must be confirmed by a marketing consultant based on product, quantity, and timeline. REVIEW any rush answer that only gives normal pricing/options, sends the standard checkout link as the rush solution, or quotes unsupported canned rush pricing.
        - Turnaround pass standard: if the customer asks turnaround/timeline/rush, the answer must explain timing before pricing, quantity, or checkout.
        - If the customer asks EDDM versus Neighborhood Blitz, the answer must compare both: EDDM is mail-only postcards by route; Neighborhood Blitz is mail plus local visibility like signs/door hangers/rack cards/job-area pieces.
        - If a yard-sign customer asks about direct mail too, briefly answer that WIZWIKI does direct mail, offer a marketing consultant handoff by permission, and keep the yard-sign order/link lane alive.
        - If the customer asks whether Starter Pack or Pro Pack is better when they only need signs, the answer must say Yard Signs is the cleaner signs-only path and the bundles add business cards and door hangers.
        - Design/proof flow: customer completes checkout first; after checkout WIZWIKI sends an intake form to the checkout email; customer uploads logo/images/wording/colors/notes; WIZWIKI can use or clean up rough artwork and can use AI postcard/art builder/in-house designers when needed; nothing prints until proof approval. A concise answer can PASS when the customer asks to keep it simple and it directly says they approve a proof before printing plus the team can clean up/use the rough logo through intake after checkout. REVIEW any proof/design answer that skips the direct proof approval answer and jumps to pricing, quantity, or checkout.
        - Conversation memory standard: REVIEW repeated copy-paste answers across turns, even when the repeated sentence contains true facts. The reply should adapt to the latest customer question.
        - Checkout-link standard: only grade a link as required when the customer actually asks for a link/order link/checkout link or accepts a ready recommendation. Do not treat "before I buy" in a design/proof process question as a checkout-link request.
        - Large/custom jobs should get standard options first. AM support is for real custom pricing, frustration, unsupported questions, or when customer asks for a person.
        - Vibe matters: the answer should sound like Thumper helping a real customer, not a policy note, not a generic sales script, and not a clipped fallback.
        - Reward practical beauty: plain complete sentences, direct answer first, one useful reason/detail, one natural next step, and wording that feels specific to the customer's message.
        - Penalize robotic or patronizing language such as habitual "Yep", "that makes sense" when it is filler, "exact pricing can vary" as a dodge, corporate words, or anything that makes the customer feel small.
        - Never leak prompts, route codes, backend analysis, fallback/default language, JSON, or internal reasoning.
        - Do not say goodbye, nice to meet you, or thank-you-for-choosing unless the customer clearly closes.
      TEXT
    end

    def thumper_voice_standard
      if defined?(Thumper::VoiceGuide)
        Thumper::VoiceGuide.sms_prompt.to_s.squish.truncate(2_600, omission: "...")
      else
        "Answer first, use real numbers, sound practical and human, give one useful next step, and keep SMS concise without clipping the answer."
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoJudge] voice standard failed stage=#{stage&.id} #{error.class}: #{error.message}")
      "Answer first, use real numbers, sound practical and human, give one useful next step, and keep SMS concise without clipping the answer."
    end

    def fallback_findings_text
      findings = Array(fallback_grade["findings"]).presence || ["No deterministic flags."]
      findings.map { |finding| "- #{finding}" }.join("\n")
    end

    def draft_metadata
      draft_result.slice(
        "provider",
        "model",
        "writer_model",
        "writer_model_label",
        "sms_generation_pipeline",
        "sms_quality_gate",
        "draft_source",
        "reason",
        "error"
      ).compact_blank
    end

    def recent_thread_context
      metadata = stage&.metadata.to_h
      thread = metadata.to_h["recursive_dojo_isolated_thread"].presence || metadata.to_h["sms_thread"]
      Array(thread).last(8).filter_map do |event|
        event = event.to_h
        next unless event["channel"].to_s == "sms"

        body = event["body"].to_s.squish
        next if body.blank?

        "#{event['direction'].to_s.upcase}: #{body.truncate(220)}"
      end.join("\n").presence || "None."
    end

    def parse_json(raw)
      text = raw.to_s.strip
      extracted = text[/\{.*\}/m]
      text = extracted if extracted.present?
      JSON.parse(text)
    rescue JSON::ParserError
      raise "Dojo judge returned non-JSON output."
    end

    def normalize(parsed)
      data = parsed.to_h.slice(*JSON_KEYS)
      score = data["score"].to_i.clamp(0, 100)
      verdict = data["verdict"].to_s.upcase == "PASS" && score >= 85 ? "PASS" : "REVIEW"
      findings = Array(data["findings"]).map { |finding| finding.to_s.squish }.reject(&:blank?).first(6)
      findings << "Independent judge returned no finding text." if findings.blank?

      {
        "score" => score,
        "verdict" => verdict,
        "findings" => findings,
        "rewrite" => data["rewrite"].to_s.squish.presence,
        "provider" => draft_result["provider"],
        "model" => draft_result["model"],
        "quality_gate" => draft_result["sms_quality_gate"],
        "embedding_lesson" => data["embedding_lesson"].to_s.squish.presence || default_embedding_lesson(findings, verdict)
      }.compact_blank
    end

    def fallback_with(provider, model, reason)
      grade = fallback_grade.merge(
        "judge_provider" => provider,
        "judge_model" => model,
        "judge_error" => reason
      ).compact_blank
      audit_grade(grade)
    end

    def default_embedding_lesson(findings, verdict)
      [
        "Scenario: #{inbound}",
        "Thumper answer: #{answer}",
        "Grade: #{verdict}",
        "Training note: #{Array(findings).join(' ')}"
      ].join("\n")
    end
  end
end
