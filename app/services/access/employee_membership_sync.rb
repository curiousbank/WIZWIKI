module Access
  class EmployeeMembershipSync
    DEFAULT_ORGANIZATION_SLUG = "wizwiki-autos".freeze
    DEFAULT_ORGANIZATION_NAME = "WIZWIKI Thumper".freeze
    DEFAULT_ORGANIZATION_DOMAIN = "wizwiki.local".freeze

    Result = Struct.new(:membership, :employee_profile, :matched, :active, keyword_init: true) do
      def matched?
        matched
      end

      def active?
        active
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(user:, organization: nil, allow_bootstrap: false)
      @user = user
      @organization = organization || default_organization
      @allow_bootstrap = allow_bootstrap
    end

    def call
      profile = matching_employee_profile
      membership = @organization.memberships.find_or_initialize_by(user: @user)

      if profile&.active?
        activate_membership!(membership, profile)
        link_employee_profile!(profile)
        Result.new(membership: membership, employee_profile: profile, matched: true, active: true)
      elsif bootstrap_allowed?
        bootstrap_admin_membership!(membership)
        Result.new(membership: membership, employee_profile: profile, matched: false, active: true)
      else
        hold_membership!(membership)
        Result.new(membership: membership, employee_profile: profile, matched: profile.present?, active: false)
      end
    end

    private

    def default_organization
      Organization.find_or_create_by!(slug: DEFAULT_ORGANIZATION_SLUG) do |org|
        org.name = ENV.fetch("WIZWIKI_ORGANIZATION_NAME", DEFAULT_ORGANIZATION_NAME)
        org.domain = DEFAULT_ORGANIZATION_DOMAIN
      end
    end

    def matching_employee_profile
      email = @user.email_address.to_s.strip.downcase
      return if email.blank?

      @organization.employee_profiles
        .where("LOWER(email) = ?", email)
        .order(Arel.sql("CASE WHEN user_id = #{@user.id.to_i} THEN 0 ELSE 1 END"), updated_at: :desc)
        .first
    end

    def activate_membership!(membership, profile)
      membership.role = role_for(profile)
      membership.status = "active"
      membership.admin = admin_for?(profile) if membership.has_attribute?(:admin)
      membership.save!
    end

    def link_employee_profile!(profile)
      updates = {}
      updates[:user] = @user if profile.user_id != @user.id
      updates[:invitation_status] = "accepted" if profile.invitation_status.in?(%w[not_sent queued sent held])
      updates[:invitation_accepted_at] = Time.current if profile.invitation_accepted_at.blank?
      profile.update!(updates) if updates.any?
    end

    def hold_membership!(membership)
      membership.role = valid_role(membership.role.presence || "produce")
      membership.status = "suspended"
      membership.admin = false if membership.has_attribute?(:admin)
      membership.save!
    end

    def bootstrap_admin_membership!(membership)
      membership.role = "develop"
      membership.status = "active"
      membership.admin = true if membership.has_attribute?(:admin)
      membership.save!
    end

    def role_for(profile)
      valid_role(profile.recommended_role.presence || "produce")
    end

    def valid_role(role)
      Membership::ROLES.include?(role.to_s) ? role.to_s : "produce"
    end

    def admin_for?(profile)
      profile.admin_level.to_i >= 2 || profile.executive_profile?
    end

    def bootstrap_allowed?
      @allow_bootstrap && !@organization.memberships.exists? && !@organization.employee_profiles.exists?
    end
  end
end
