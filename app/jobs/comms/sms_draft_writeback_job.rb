module Comms
  class SmsDraftWritebackJob < ApplicationJob
    queue_as :sms

    def perform(autos_question_id:, reason: nil)
      question = AutosQuestion.find_by(id: autos_question_id)
      return if question.blank?
      return unless question.metadata.to_h["surface"].to_s == "comms_sms_draft"
      return if question.status.to_s.in?(%w[canceled cancelled archived ignored])
      return unless defined?(DealReports::CommsDraftWriter)

      if question.status.to_s == "failed" || reason.present?
        DealReports::CommsDraftWriter.apply_worker_rejection!(
          question.reload,
          reason: reason.presence || question.metadata.to_h.dig("local_worker", "reject_reason").presence
        )
      else
        DealReports::CommsDraftWriter.apply_worker_answer!(question.reload)
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsDraftWritebackJob] failed question=#{autos_question_id} #{error.class}: #{error.message}")
      raise
    end
  end
end
