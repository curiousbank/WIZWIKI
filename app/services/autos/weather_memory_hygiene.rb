# frozen_string_literal: true

module Autos
  class WeatherMemoryHygiene
    class << self
      def call(organization:, dry_run: false)
        new(organization: organization, dry_run: dry_run).call
      end
    end

    def initialize(organization:, dry_run:)
      @organization = organization
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    end

    def call
      question_ids = invalid_weather_question_ids
      chunks = AutosEmbeddingChunk.where(source_type: "AutosQuestion", source_id: question_ids).where.not(status: "stale")
      result = {
        ok: true,
        dry_run: dry_run,
        weather_questions: question_ids.length,
        chunks_to_quarantine: chunks.count,
        quarantined_chunks: 0
      }
      return result if dry_run || question_ids.blank?

      now = Time.current
      chunks.find_each do |chunk|
        chunk.update!(
          status: "stale",
          worker_id: nil,
          claimed_at: nil,
          last_error: "quarantined invalid legacy weather analysis",
          metadata: chunk.metadata.to_h.merge(
            "composition_eligible" => false,
            "retrieval_role" => "quarantined_weather_memory",
            "weather_memory_quarantined_at" => now.iso8601
          )
        )
        result[:quarantined_chunks] += 1
      end

      organization.autos_questions.where(id: question_ids).find_each do |question|
        question.update_columns(
          metadata: question.metadata.to_h.merge("weather_memory_quarantined_at" => now.iso8601),
          updated_at: question.updated_at
        )
      end
      result
    end

    private

    attr_reader :organization, :dry_run

    def invalid_weather_question_ids
      organization.autos_questions
        .where("metadata ->> 'surface' = ?", "weather_outcome_analysis")
        .pluck(:id, :metadata)
        .filter_map do |id, metadata|
          values = metadata.to_h
          valid = ActiveModel::Type::Boolean.new.cast(values.dig("weather_analysis_validation", "valid"))
          current = values["weather_analysis_version"] == Kalshi::WeatherOutcomeAnalysis::ANALYSIS_VERSION
          id unless valid && current
        end
    end
  end
end
