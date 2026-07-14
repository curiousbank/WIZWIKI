require "uri"

class DesignOrder < ApplicationRecord
  COMPLETE_STATUS = "COMPLETE".freeze
  STATUSES = [COMPLETE_STATUS].freeze

  belongs_to :organization
  belongs_to :design_report
  belongs_to :user

  before_validation :normalize_fields

  validates :source_uid, :item_name, presence: true
  validates :source_uid, uniqueness: { scope: :organization_id }
  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  validates :row_number, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(updated_at: :desc) }
  scope :queued, -> { where(status: nil) }
  scope :complete, -> { where(status: COMPLETE_STATUS) }
  scope :search, ->(query) {
    next all if query.blank?

    cleaned = "%#{sanitize_sql_like(query.to_s.strip)}%"
    where(
      "item_name ILIKE :q OR customer_email ILIKE :q OR order_number ILIKE :q OR designer_name ILIKE :q OR product_name ILIKE :q",
      q: cleaned
    )
  }

  def label
    [item_name, order_number.presence && "##{order_number}"].compact.join(" // ")
  end

  def customer_label
    customer_email.presence || "customer unknown"
  end

  def queue_status_label
    status.presence || "QUEUE"
  end

  def queued?
    status.blank?
  end

  def monday_host
    URI.parse(monday_url).host if monday_url.present?
  rescue URI::InvalidURIError
    nil
  end

  private

  def normalize_fields
    self.item_name = item_name.to_s.squish.presence || "Untitled design"
    self.order_number = order_number.to_s.squish.presence
    self.designer_name = designer_name.to_s.squish.presence
    self.product_name = product_name.to_s.squish.presence
    self.customer_email = customer_email.to_s.strip.downcase.presence
    self.monday_url = monday_url.to_s.strip.presence
    self.stage = stage.to_s.squish.presence || "design"
    self.status = status.to_s.squish.upcase.presence
    self.raw_payload = raw_payload.to_h
  end
end
