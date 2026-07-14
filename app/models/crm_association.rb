class CrmAssociation < ApplicationRecord
  TYPES = %w[primary_company related_company buyer requester blocker collaborator].freeze

  belongs_to :organization
  belongs_to :from_record, class_name: "CrmRecord"
  belongs_to :to_record, class_name: "CrmRecord"

  validates :association_type, presence: true
  validates :from_record_id, uniqueness: { scope: [:to_record_id, :association_type] }
  validate :records_belong_to_same_organization

  private

  def records_belong_to_same_organization
    return if from_record&.organization_id == organization_id && to_record&.organization_id == organization_id

    errors.add(:base, "associated records must belong to this organization")
  end
end
