# frozen_string_literal: true

module Comms
  class SmsCloudDraftJob < ApplicationJob
    queue_as :sms

    def perform(autos_question_id:)
      question = AutosQuestion.find_by(id: autos_question_id)
      return if question.blank?
      return unless question.metadata.to_h["surface"].to_s == "comms_sms_draft"
      return unless defined?(DealReports::CommsDraftWriter)

      DealReports::CommsDraftWriter.perform_cloud_worker_answer!(question.reload)
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsCloudDraftJob] failed question=#{autos_question_id} #{error.class}: #{error.message}")
      raise
    end
  end
end
