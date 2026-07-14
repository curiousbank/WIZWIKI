class QuickCartOrder < ApplicationRecord
  STATUSES = %w[created payment_pending paid payment_failed payment_unconfigured card_token_missing].freeze

  belongs_to :organization
  belongs_to :crm_record

  validates :package, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true

  before_validation :normalize_fields

  private

  def normalize_fields
    self.package = package.to_s.upcase
    self.email = email.to_s.strip.downcase.presence
    self.phone = phone.to_s.gsub(/[^\d+]/, "").presence
    self.currency = currency.to_s.upcase.presence || "USD"
    self.metadata = metadata.to_h
  end
end
