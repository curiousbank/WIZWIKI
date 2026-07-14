class BuildRequest < ApplicationRecord
  STATUSES = %w[staged approved rejected shipped].freeze
  TARGET_AREAS = ["Front end", "Site format", "CRM workflow", "AI prompt", "Automation", "Other"].freeze

  belongs_to :organization
  belongs_to :user

  validates :title, :target_area, :prompt, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
