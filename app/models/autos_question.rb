class AutosQuestion < ApplicationRecord
  STATUSES = %w[queued answered failed archived].freeze

  belongs_to :organization
  belongs_to :user

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def answer_ready?
    answer.present? && status == "answered"
  end

  def pending_answer?
    status == "queued" && answer.blank?
  end

  def autos_voice_url
    metadata.to_h["autos_voice_url"].presence
  end

  def autos_voice_status
    metadata.to_h["autos_voice_status"].presence
  end

  def autos_voice_pending?
    answer_ready? && autos_voice_url.blank? && %w[queued generating].include?(autos_voice_status)
  end

  def ask_refresh_pending?
    pending_answer? || autos_voice_pending?
  end
end
