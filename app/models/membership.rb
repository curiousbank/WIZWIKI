class Membership < ApplicationRecord
  ROLES = %w[design develop produce].freeze
  STATUSES = %w[active invited suspended].freeze

  belongs_to :user
  belongs_to :organization

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :organization_id }

  def admin?
    if has_attribute?(:admin)
      self[:admin]
    else
      role.in?(%w[owner admin])
    end
  end

  def owner_or_admin?
    admin?
  end

  def developer?
    role.in?(%w[develop developer])
  end

  def can_build?
    admin? || developer?
  end
end
