class CrmPropertyDefinition < ApplicationRecord
  DATA_TYPES = %w[text textarea number money date datetime boolean select multiselect url email phone].freeze

  belongs_to :organization

  before_validation :normalize_key

  validates :record_type, inclusion: { in: CrmRecord::RECORD_TYPES }
  validates :key, :label, presence: true
  validates :key, uniqueness: { scope: [:organization_id, :record_type] }
  validates :data_type, inclusion: { in: DATA_TYPES }

  scope :active, -> { where(active: true) }
  scope :for_type, ->(type) { where(record_type: type) }

  private

  def normalize_key
    self.key = key.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    self.options = options.to_h
  end
end
