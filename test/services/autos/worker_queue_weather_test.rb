# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Autos
  class WorkerQueueWeatherTest < ActiveSupport::TestCase
    FakeQuestion = Struct.new(:id, :organization_id, :user_id, :question, :context, :metadata, keyword_init: true) do
      def update!(attributes)
        self.metadata = attributes.fetch(:metadata)
      end
    end

    test "weather payload is local and isolated to calibration memory" do
      question = FakeQuestion.new(
        id: 123,
        organization_id: 1,
        user_id: 2,
        question: "Return strict weather JSON.",
        context: JSON.generate(batch_digest: "abc", sample_size: 1),
        metadata: { "surface" => "weather_outcome_analysis" }
      )

      payload = WorkerQueue.payload_for(question)

      assert_equal "qwen3:30b", payload[:local_model]
      assert_equal false, payload.dig(:openai, :enabled)
      assert_equal false, payload.dig(:openai, :fallback_allowed)
      assert_equal "weather_calibration", payload.dig(:memory, :brain_type)
      assert_empty payload.dig(:memory, :shared_brain_types)
      assert_equal "weather_calibration", payload.dig(:retrieval, "scope")
      assert_equal %w[AutosQuestion TrainingDocument], payload.dig(:retrieval, "source_types")
      assert_equal 2_400, payload.dig(:answer_contract, "max_chars")
      assert_equal "dojo_judge_json", payload.dig(:answer_contract, "style")
      assert_includes payload[:prompt], "OFFICIAL-STATION EVIDENCE JSON"
      assert_empty payload[:analysis_items]
      assert_empty payload[:related_links]
    end

    test "completion rejects an unfinished weather reasoning preamble" do
      question = weather_question

      WorkerQueue.complete!(
        question,
        worker_payload: { "answer" => "Let me analyze the numbers first. 1.", "model" => "qwen3:30b", "provider" => "local_cc" }
      )

      assert_equal "failed", question.reload.status
      assert_equal false, question.metadata.dig("weather_analysis_validation", "valid")
      assert_equal "invalid_weather_analysis_contract", question.metadata.dig("local_worker", "reject_reason")
    end

    test "completion accepts strict validated weather json" do
      question = weather_question

      WorkerQueue.complete!(
        question,
        worker_payload: { "answer" => JSON.generate(valid_weather_answer), "model" => "qwen3:30b", "provider" => "local_cc" }
      )

      assert_equal "answered", question.reload.status
      assert_equal true, question.metadata.dig("weather_analysis_validation", "valid")
      assert_equal "block", JSON.parse(question.answer).fetch("risk_gate")
    end

    private

    def weather_question
      suffix = SecureRandom.hex(4)
      organization = Organization.create!(name: "Worker Weather #{suffix}", slug: "worker-weather-#{suffix}")
      organization.autos_questions.create!(
        user: users(:one),
        question: "Analyze compact official station evidence.",
        context: JSON.generate(batch_digest: "batch-123", sample_size: 8),
        status: "queued",
        metadata: {
          "surface" => "weather_outcome_analysis",
          "skip_chat_memory" => true,
          "weather_analysis_version" => Kalshi::WeatherOutcomeAnalysis::ANALYSIS_VERSION,
          "weather_schema_version" => Kalshi::WeatherAnalysisContract::SCHEMA_VERSION,
          "weather_knowledge_version" => Kalshi::WeatherAnalysisKnowledge::VERSION,
          "weather_batch_digest" => "batch-123",
          "weather_sample_size" => 8,
          "local_worker" => { "status" => "claimed" }
        }
      )
    end

    def valid_weather_answer
      {
        "schema_version" => Kalshi::WeatherAnalysisContract::SCHEMA_VERSION,
        "knowledge_version" => Kalshi::WeatherAnalysisKnowledge::VERSION,
        "batch_digest" => "batch-123",
        "sample_size" => 8,
        "analysis_complete" => true,
        "verdict" => "insufficient_data",
        "risk_gate" => "block",
        "summary" => "The exact-station sample is below the promotion minimum.",
        "findings" => [
          { "type" => "sample_size", "evidence" => "8 independent events are below 30.", "confidence" => 1.0 }
        ],
        "data_quality_flags" => ["sample below promotion minimum"],
        "next_instrumentation" => "Collect another official station outcome.",
        "rule_ack" => {
          "settlement_source" => "final_nws_daily_climate_report",
          "one_sided_strikes" => "strict",
          "between_bounds" => "inclusive",
          "objective" => "fee_adjusted_out_of_sample_ev"
        }
      }
    end
  end
end
