# frozen_string_literal: true

module Autos
  class CloudAnswerJob < ApplicationJob
    queue_as :default

    def perform(autos_question_id)
      question = AutosQuestion.find_by(id: autos_question_id)
      return if question.blank?
      return unless question.metadata.to_h["surface"].to_s == "ask"

      Autos::CloudAnswerer.call(question.reload)
    rescue StandardError => error
      Rails.logger.warn("[Autos::CloudAnswerJob] failed question=#{autos_question_id} #{error.class}: #{error.message}")
      raise
    end
  end
end
