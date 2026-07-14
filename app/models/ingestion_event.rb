class IngestionEvent < ApplicationRecord
  STATUSES = %w[accepted duplicate rejected].freeze

  belongs_to :organization
  belongs_to :crm_record, optional: true

  validates :source, :payload_digest, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_uid, uniqueness: { scope: [:organization_id, :source], allow_blank: true }
  validates :payload_digest, uniqueness: { scope: [:organization_id, :source] }
end
