class TeamsController < ApplicationController
  before_action :require_organization!

  def index
    @profiles = team_profiles
    @profile_counts = profile_counts(@profiles)
    @domain_counts = domain_counts(@profiles)
  end

  private

  def team_profiles
    current_organization.employee_profiles.ordered_by_name.limit(500).to_a
      .group_by { |profile| name_key(profile) }
      .values
      .map { |profiles| preferred_profile(profiles) }
      .sort_by { |profile| [profile.last_name.to_s.downcase, profile.first_name.to_s.downcase, profile.email.to_s.downcase] }
  end

  def preferred_profile(profiles)
    profiles.max_by do |profile|
      [
        profile.email.present? ? 1 : 0,
        profile.top_strengths(4).present? ? 1 : 0,
        profile.active? ? 1 : 0,
        profile.updated_at.to_i
      ]
    end
  end

  def name_key(profile)
    first = profile.first_name.to_s.downcase.scan(/[a-z0-9]+/).first.to_s
    last = profile.last_name.to_s.downcase.gsub(/[^a-z0-9]+/, "")
    return "email:#{profile.email.to_s.downcase}" if first.blank? || last.blank?

    "name:#{first}:#{last}"
  end

  def profile_counts(profiles)
    {
      "profiles" => profiles.size,
      "activeish" => profiles.count(&:active?),
      "invite_ready" => profiles.count(&:invite_ready?),
      "held" => profiles.count(&:held?)
    }
  end

  def domain_counts(profiles)
    counts = Hash.new(0)
    profiles.each do |profile|
      profile.clifton_domains(5).each { |domain| counts[domain] += 1 }
    end
    counts
  end
end
