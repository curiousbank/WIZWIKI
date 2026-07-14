class DuplicateCandidate < ApplicationRecord
  STATUSES = %w[open ignored merged].freeze

  belongs_to :organization
  belongs_to :crm_record
  belongs_to :duplicate_record, class_name: "CrmRecord"

  validates :status, inclusion: { in: STATUSES }
  validates :duplicate_record_id, uniqueness: { scope: [:organization_id, :crm_record_id] }
  validate :records_belong_to_same_organization

  scope :open, -> { where(status: "open") }
  scope :recent, -> { order(score: :desc, created_at: :desc) }

  private

  def records_belong_to_same_organization
    return if crm_record&.organization_id == organization_id && duplicate_record&.organization_id == organization_id

    errors.add(:base, "duplicate records must belong to this organization")
  end
end
