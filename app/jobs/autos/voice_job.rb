module Autos
  class VoiceJob < ApplicationJob
    queue_as :default

    def perform(autos_question_id)
      question = AutosQuestion.find_by(id: autos_question_id)
      return unless question&.answer.present?

      Autos::Voice.generate_for_question(question)
    end
  end
end
