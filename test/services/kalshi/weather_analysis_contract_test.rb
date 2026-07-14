# frozen_string_literal: true

require "test_helper"

module Kalshi
  class WeatherAnalysisContractTest < ActiveSupport::TestCase
    test "accepts a complete conservative analysis" do
      validation = WeatherAnalysisContract.validate(
        JSON.generate(valid_payload),
        expected_digest: "batch-123",
        expected_sample_size: 8
      )

      assert_equal true, validation[:valid]
      assert_empty validation[:errors]
    end

    test "rejects prose wrapped around json" do
      validation = WeatherAnalysisContract.validate("Here is my analysis: #{JSON.generate(valid_payload)}")

      assert_equal false, validation[:valid]
      assert_includes validation[:errors], "answer must be one JSON object without prose or markdown"
    end

    test "rejects a clear risk gate below the independent sample minimum" do
      payload = valid_payload.merge("risk_gate" => "clear", "verdict" => "promising")
      validation = WeatherAnalysisContract.validate(JSON.generate(payload), expected_sample_size: 8)

      assert_equal false, validation[:valid]
      assert validation[:errors].any? { |error| error.include?("risk_gate must remain blocked") }
      assert validation[:errors].any? { |error| error.include?("verdict must be insufficient_data") }
    end

    test "rejects a mismatched evidence digest" do
      validation = WeatherAnalysisContract.validate(
        JSON.generate(valid_payload),
        expected_digest: "different-batch",
        expected_sample_size: 8
      )

      assert_equal false, validation[:valid]
      assert_includes validation[:errors], "batch_digest does not match the supplied evidence"
    end

    test "allows an empty findings list only when no evidence exists" do
      payload = valid_payload.merge(
        "sample_size" => 0,
        "findings" => [],
        "summary" => "No officially settled exact-station evidence exists yet."
      )
      validation = WeatherAnalysisContract.validate(JSON.generate(payload), expected_sample_size: 0)

      assert_equal true, validation[:valid]
    end

    private

    def valid_payload
      {
        "schema_version" => WeatherAnalysisContract::SCHEMA_VERSION,
        "knowledge_version" => WeatherAnalysisKnowledge::VERSION,
        "batch_digest" => "batch-123",
        "sample_size" => 8,
        "analysis_complete" => true,
        "verdict" => "insufficient_data",
        "risk_gate" => "block",
        "summary" => "Eight independent station events are not enough to promote this model.",
        "findings" => [
          {
            "type" => "sample_size",
            "evidence" => "The evidence contains 8 independent events and the minimum is 30.",
            "confidence" => 1.0
          }
        ],
        "data_quality_flags" => ["sample below promotion minimum"],
        "next_instrumentation" => "Collect exact-station forecast residuals for another settled event.",
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
