module Autos
  class ChatMemoryRecorder
    def self.record!(question)
      new(question).record!
    end

    def initialize(question)
      @question = question
    end

    def record!
      return false unless question&.status == "answered" && question.answer.present?

      surface = question.metadata.to_h["surface"].to_s
      return false if weather_surface?(surface) && !validated_weather_analysis?

      metadata = question.metadata.to_h.deep_dup
      metadata["memory"] = metadata["memory"].to_h.merge(
        "short_term" => weather_surface?(surface) ? nil : "current_user_chat_6h",
        "long_term" => "queued_for_embedding",
        "brain_type" => memory_brain_type(surface),
        "scope" => embedding_scope(surface),
        "recorded_at" => Time.current.iso8601
      ).compact
      question.update_columns(metadata: metadata, updated_at: Time.current)

      Autos::EmbeddingQueue.enqueue_source!(question, scope: embedding_scope(surface))
    rescue StandardError => error
      Rails.logger.warn("[Autos::ChatMemoryRecorder] question=#{question&.id} #{error.class}: #{error.message}")
      false
    end

    private

    attr_reader :question

    def weather_surface?(surface)
      surface == "weather_outcome_analysis"
    end

    def validated_weather_analysis?
      ActiveModel::Type::Boolean.new.cast(question.metadata.to_h.dig("weather_analysis_validation", "valid"))
    end

    def memory_brain_type(surface)
      weather_surface?(surface) ? "weather_calibration" : "wizwiki_ask"
    end

    def embedding_scope(surface)
      weather_surface?(surface) ? "weather_calibration" : Autos::EmbeddingQueue::DEFAULT_SCOPE
    end
  end
end
