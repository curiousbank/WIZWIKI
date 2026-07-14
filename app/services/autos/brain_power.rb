module Autos
  class BrainPower
    WINDOW = 24.hours

    def self.snapshot(organization)
      new(organization).snapshot
    end

    def initialize(organization)
      @organization = organization
    end

    def snapshot
      budget = WizwikiSettings.openai_daily_token_budget
      question_token_count = question_tokens
      build_token_count = build_tokens
      report_token_count = report_tokens
      used = question_token_count + build_token_count + report_token_count
      remaining = [budget - used, 0].max
      percent_left = budget.positive? ? ((remaining.to_f / budget) * 100).round : 0
      model = WizwikiSettings.active_ai_model
      reasoning_effort = WizwikiSettings.qwen_only? ? "local" : WizwikiSettings.openai_reasoning_effort

      {
        configured: WizwikiSettings.qwen_only? || WizwikiSettings.openai_configured?,
        model: model,
        reasoning_effort: reasoning_effort,
        status_label: status_label(model, reasoning_effort),
        budget: budget,
        used: used,
        breakdown: {
          questions: question_token_count,
          builds: build_token_count,
          reports: report_token_count
        },
        remaining: remaining,
        percent_left: percent_left,
        window_hours: (WINDOW / 1.hour).to_i
      }
    end

    private

    attr_reader :organization

    def status_label(model, reasoning_effort)
      return ["qwen/local", model, reasoning_effort].compact.join(" ") if WizwikiSettings.qwen_only?
      return "openai key needed" unless WizwikiSettings.openai_configured?

      ["openai", model, reasoning_effort].compact.join(" ")
    end

    def question_tokens
      organization.autos_questions.where(updated_at: WINDOW.ago..).pluck(:metadata).sum do |metadata|
        usage_total(metadata.to_h.dig("local_worker", "usage")) || usage_total(metadata.to_h.dig("openai", "usage")) || 0
      end
    end

    def build_tokens
      organization.build_requests.where(updated_at: WINDOW.ago..).pluck(:metadata).sum do |metadata|
        usage_total(metadata.to_h.dig("autos_build", "openai", "usage")) || 0
      end
    end

    def report_tokens
      organization.crm_record_artifacts.where(artifact_type: "market_report", updated_at: WINDOW.ago..).pluck(:metadata).sum do |metadata|
        metadata = metadata.to_h
        manifest = hash_value(metadata["manifest"])
        worker_payload = hash_value(metadata["worker_payload"])
        worker_manifest = hash_value(worker_payload["manifest"])
        quality = hash_value(metadata["quality"])

        usage_total(manifest["usage"]) ||
          usage_total(worker_payload["usage"]) ||
          usage_total(worker_manifest["usage"]) ||
          quality["output_tokens"].to_i
      end
    end

    def hash_value(value)
      value.is_a?(Hash) ? value : {}
    end

    def usage_total(usage)
      usage = usage.to_h
      total = usage["total_tokens"].to_i
      return total if total.positive?

      calculated = usage["input_tokens"].to_i + usage["output_tokens"].to_i
      calculated.positive? ? calculated : nil
    end
  end
end
