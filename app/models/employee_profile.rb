class EmployeeProfile < ApplicationRecord
  ROLES = %w[design develop produce sales support operations leadership].freeze
  INVITATION_STATUSES = %w[not_sent queued sent accepted held].freeze
  INACTIVE_STATUSES = %w[terminate terminated resigned inactive].freeze

  CLIFTON_DOMAINS = {
    "executing" => {
      label: "Executing",
      color: "emerald",
      strengths: %w[Achiever Arranger Belief Consistency Deliberative Discipline Focus Responsibility Restorative]
    },
    "influencing" => {
      label: "Influencing",
      color: "pink",
      strengths: %w[Activator Command Communication Competition Maximizer Self-Assurance Significance Woo]
    },
    "relationship" => {
      label: "Relationship Building",
      color: "sky",
      strengths: ["Adaptability", "Connectedness", "Developer", "Empathy", "Harmony", "Includer", "Individualization", "Positivity", "Relator"]
    },
    "strategic" => {
      label: "Strategic Thinking",
      color: "amber",
      strengths: ["Analytical", "Context", "Futuristic", "Ideation", "Input", "Intellection", "Learner", "Strategic"]
    }
  }.freeze

  belongs_to :organization
  belongs_to :user, optional: true

  validates :source_key, presence: true, uniqueness: { scope: :organization_id }
  validates :recommended_role, inclusion: { in: ROLES }
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }
  validates :admin_level, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 3 }

  scope :activeish, -> { where("LOWER(COALESCE(wizwiki_status, employee_status, '')) NOT IN (?)", INACTIVE_STATUSES) }
  scope :with_top_strengths, -> { where.not(strength_1: [nil, ""]) }
  scope :ordered_by_name, -> { order(Arel.sql("LOWER(last_name) ASC, LOWER(first_name) ASC")) }
  scope :executives, -> { where(executive: true).or(where(leadership: true)).or(where("admin_level >= 2")) }

  def display_name
    [first_name, last_name].compact_blank.join(" ").presence || email.to_s.split("@").first.presence || "Unknown teammate"
  end

  def initials
    display_name.split.map { |part| part[0] }.compact.first(2).join.upcase
  end

  def all_strengths
    Array(strengths).compact_blank.presence || [strength_1, strength_2, strength_3, strength_4, strength_5].compact_blank
  end

  def top_strengths(limit = 5)
    all_strengths.first(limit)
  end

  def top_three_strengths
    top_strengths(3)
  end

  def active?
    !wizwiki_status.to_s.downcase.in?(INACTIVE_STATUSES) && !employee_status.to_s.downcase.in?(INACTIVE_STATUSES)
  end

  def invite_ready?
    active? && email.present? && invitation_status == "not_sent"
  end

  def held?
    invitation_status == "held"
  end

  def status_bucket
    return "held" if held?
    return "invite_ready" if invite_ready?
    return "activeish" if active?

    "profiles"
  end

  def status_label
    return "HELD" if held?
    return "INVITE READY" if invite_ready?
    return "ACTIVE-ISH" if active?

    "PROFILE"
  end

  def executive_profile?
    executive? || leadership? || admin_level.to_i >= 2
  end

  def clifton_domains(limit = 5)
    top_strengths(limit).filter_map { |strength| self.class.clifton_domain_for(strength) }.uniq
  end

  def primary_domain
    self.class.clifton_domain_for(strength_1)
  end

  def domain_counts(limit = 5)
    clifton_domains = top_strengths(limit).filter_map { |strength| self.class.clifton_domain_for(strength) }
    clifton_domains.tally
  end

  def characteristics
    {
      "Role" => role_title,
      "Team" => team_name,
      "Department" => department,
      "Reports to" => reports_to_name,
      "Location" => location,
      "Computer" => computer,
      "Start date" => start_date,
      "Tenure" => tenure_text,
      "10 months+" => ten_months_plus.nil? ? nil : (ten_months_plus? ? "yes" : "no"),
      "WIZWIKI status" => wizwiki_status,
      "Employee status" => employee_status,
      "Clifton" => clifton_status,
      "Strengths date" => strengths_taken_on,
      "Recommended role" => recommended_role,
      "Admin level" => "L#{admin_level}",
      "Invite status" => invitation_status
    }.compact_blank
  end

  def self.clifton_domain_for(strength)
    normalized = strength.to_s.strip.downcase
    return if normalized.blank?

    CLIFTON_DOMAINS.find do |_key, config|
      config[:strengths].any? { |candidate| candidate.downcase == normalized }
    end&.first
  end

  def self.clifton_domain_label(domain)
    CLIFTON_DOMAINS.dig(domain.to_s, :label) || domain.to_s.titleize
  end

  def self.strength_options(organization)
    where(organization: organization).with_top_strengths.pluck(:strength_1, :strength_2, :strength_3).flatten.compact_blank.uniq.sort
  end
end
