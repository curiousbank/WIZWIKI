class DesignReport < ApplicationRecord
  STATUSES = %w[imported failed archived].freeze

  belongs_to :organization
  belongs_to :user
  has_many :design_orders, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :row_count, :byte_size, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(created_at: :desc) }

  def display_title
    title.presence || file_name.presence || "Design report #{id}"
  end

  def imported_count
    metadata.to_h["created_count"].to_i + metadata.to_h["updated_count"].to_i
  end
end
