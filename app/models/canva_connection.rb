class CanvaConnection < ApplicationRecord
  STATUSES = %w[pending connected failed revoked].freeze

  belongs_to :organization
  belongs_to :user

  encrypts :access_token
  encrypts :refresh_token
  encrypts :code_verifier

  validates :status, inclusion: { in: STATUSES }
  validates :organization_id, uniqueness: { scope: :user_id }

  scope :connected, -> { where(status: "connected") }

  def connected?
    status == "connected" && refresh_token.present?
  end

  def access_token_expired?
    access_token.blank? || access_token_expires_at.blank? || access_token_expires_at <= 2.minutes.from_now
  end
end
