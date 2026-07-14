# frozen_string_literal: true

require "json"

module Kalshi
  class WeatherAnalysisContract
    SCHEMA_VERSION = "weather_qwen_calibration_v1".freeze
    VERDICTS = %w[insufficient_data negative uncertain promising].freeze
    RISK_GATES = %w[block clear].freeze
    MAX_FINDINGS = 5

    class << self
      def validate(answer, expected_digest: nil, expected_sample_size: nil)
        new(
          answer,
          expected_digest: expected_digest,
          expected_sample_size: expected_sample_size
        ).validate
      end

      def valid?(answer, **options)
        validate(answer, **options).fetch(:valid)
      end
    end

    def initialize(answer, expected_digest:, expected_sample_size:)
      @answer = answer.to_s.strip
      @expected_digest = expected_digest.to_s.presence
      @expected_sample_size = expected_sample_size
    end

    def validate
      payload = parse_payload
      return result(nil) if payload.blank?

      validate_fields(payload)
      result(payload)
    end

    private

    attr_reader :answer, :expected_digest, :expected_sample_size

    def errors
      @errors ||= []
    end

    def parse_payload
      if answer.blank?
        errors << "answer is blank"
        return nil
      end
      unless answer.start_with?("{") && answer.end_with?("}")
        errors << "answer must be one JSON object without prose or markdown"
        return nil
      end

      payload = JSON.parse(answer)
      unless payload.is_a?(Hash)
        errors << "answer must decode to an object"
        return nil
      end
      payload
    rescue JSON::ParserError => error
      errors << "invalid JSON: #{error.message}"
      nil
    end

    def validate_fields(payload)
      require_equal(payload, "schema_version", SCHEMA_VERSION)
      require_equal(payload, "knowledge_version", Kalshi::WeatherAnalysisKnowledge::VERSION)
      require_equal(payload, "analysis_complete", true)
      require_inclusion(payload, "verdict", VERDICTS)
      require_inclusion(payload, "risk_gate", RISK_GATES)
      require_string(payload, "summary", max: 360)
      require_string(payload, "next_instrumentation", max: 360)
      validate_digest(payload)
      validate_sample_size(payload)
      validate_findings(payload)
      validate_flags(payload)
      validate_rule_ack(payload)
      validate_conservative_gate(payload)
    end

    def validate_digest(payload)
      require_string(payload, "batch_digest", max: 128)
      return if expected_digest.blank?

      errors << "batch_digest does not match the supplied evidence" unless payload["batch_digest"].to_s == expected_digest
    end

    def validate_sample_size(payload)
      value = payload["sample_size"]
      errors << "sample_size must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
      return if expected_sample_size.nil?

      errors << "sample_size does not match the supplied evidence" unless value == expected_sample_size.to_i
    end

    def validate_findings(payload)
      findings = payload["findings"]
      minimum_findings = payload["sample_size"].to_i.zero? ? 0 : 1
      unless findings.is_a?(Array) && findings.length.between?(minimum_findings, MAX_FINDINGS)
        errors << "findings must contain #{minimum_findings} to #{MAX_FINDINGS} evidence-backed items"
        return
      end

      findings.each_with_index do |finding, index|
        unless finding.is_a?(Hash)
          errors << "finding #{index + 1} must be an object"
          next
        end
        type = finding["type"].to_s.squish
        evidence = finding["evidence"].to_s.squish
        errors << "finding #{index + 1} type is required" if type.blank?
        errors << "finding #{index + 1} type is too long" if type.length > 80
        errors << "finding #{index + 1} evidence is required" if evidence.blank?
        errors << "finding #{index + 1} evidence is too long" if evidence.length > 320
        confidence = finding["confidence"]
        errors << "finding #{index + 1} confidence must be between 0 and 1" unless confidence.is_a?(Numeric) && confidence.between?(0, 1)
      end
    end

    def validate_flags(payload)
      flags = payload["data_quality_flags"]
      unless flags.is_a?(Array)
        errors << "data_quality_flags must be an array"
        return
      end

      errors << "data_quality_flags may contain at most 8 items" if flags.length > 8
      errors << "data_quality_flags must contain short strings" unless flags.all? { |flag| flag.is_a?(String) && flag.squish.length.between?(1, 160) }
    end

    def validate_rule_ack(payload)
      acknowledgement = payload["rule_ack"]
      unless acknowledgement.is_a?(Hash)
        errors << "rule_ack is required"
        return
      end

      errors << "settlement source was not acknowledged" unless acknowledgement["settlement_source"] == "final_nws_daily_climate_report"
      errors << "one-sided strike semantics were not acknowledged" unless acknowledgement["one_sided_strikes"] == "strict"
      errors << "between strike semantics were not acknowledged" unless acknowledgement["between_bounds"] == "inclusive"
      errors << "fee-adjusted objective was not acknowledged" unless acknowledgement["objective"] == "fee_adjusted_out_of_sample_ev"
    end

    def validate_conservative_gate(payload)
      minimum = Kalshi::WeatherAnalysisKnowledge.payload.dig(:live_validation, :minimum_independent_station_events).to_i
      return unless payload["sample_size"].to_i < minimum

      errors << "risk_gate must remain blocked below the independent-sample minimum" unless payload["risk_gate"] == "block"
      errors << "verdict must be insufficient_data below the independent-sample minimum" unless payload["verdict"] == "insufficient_data"
    end

    def require_equal(payload, key, expected)
      errors << "#{key} must equal #{expected.inspect}" unless payload[key] == expected
    end

    def require_inclusion(payload, key, allowed)
      errors << "#{key} must be one of #{allowed.join(', ')}" unless payload[key].to_s.in?(allowed)
    end

    def require_string(payload, key, max:)
      value = payload[key].to_s.squish
      errors << "#{key} is required" if value.blank?
      errors << "#{key} exceeds #{max} characters" if value.length > max
    end

    def result(payload)
      {
        valid: errors.empty?,
        errors: errors,
        payload: payload,
        schema_version: SCHEMA_VERSION,
        validated_at: Time.current.iso8601
      }
    end
  end
end
