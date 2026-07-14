require "csv"
require "digest"

module Company
  class EmployeeCsvImporter
    DEFAULT_PATH = Rails.root.join("tmp/imports/employees/company")

    Result = Struct.new(:created, :updated, :held, :rows, keyword_init: true)

    def initialize(organization:, path: DEFAULT_PATH)
      @organization = organization
      @path = Pathname(path)
    end

    def call
      profiles = {}
      read_orgchart(profiles)
      read_strengths(profiles)
      read_current(profiles)

      created = 0
      updated = 0
      held = 0

      profiles.each_value do |attributes|
        attributes[:source_key] ||= source_key_for(attributes)
        attributes[:raw_payload] ||= {}
        attributes[:recommended_role], attributes[:admin_level], attributes[:admin_recommendation] = role_recommendation(attributes)
        attributes[:invitation_status] ||= invite_status_for(attributes)
        held += 1 unless attributes[:invitation_status] == "not_sent"

        profile = EmployeeProfile.find_or_initialize_by(organization: @organization, source_key: attributes[:source_key])
        profile.assign_attributes(attributes.except(:source_key))
        profile.source_key = attributes[:source_key]
        profile.new_record? ? created += 1 : updated += 1
        profile.save!
      end

      Result.new(created: created, updated: updated, held: held, rows: profiles.size)
    end

    private

    def read_orgchart(profiles)
      each_csv("orgchart.csv") do |row|
        key = key_for(row["First Name"], row["Last Name"], row["Email"])
        profile = (profiles[key] ||= base_profile(row["First Name"], row["Last Name"], row["Email"]))
        profile.merge!(
          email: clean(row["Email"])&.downcase,
          role_title: clean(row["Role"]),
          team_name: clean(row["Team"]),
          department: clean(row["Department"]),
          reports_to_name: clean(row["Reports to"]),
          location: clean(row["Location"]),
          leadership: clean(row["Leadership?"]).to_s.downcase == "leadership",
          executive: executive_row?(row),
          computer: clean(row["Computer"]),
          start_date: parse_date(row["Start Date"]),
          tenure_text: clean(row["Tenure"]),
          ten_months_plus: parse_boolean(row["10 months+"])
        )
        profile[:raw_payload][:orgchart] = row.to_h
      end
    end

    def read_strengths(profiles)
      each_csv("strengths.csv") do |row|
        key = key_for(row["First Name"], row["Last Name"], nil)
        profile = (profiles[key] ||= base_profile(row["First Name"], row["Last Name"], nil))
        strengths = (1..34).map { |index| clean(row["Theme #{index}"]) }.compact_blank
        profile.merge!(
          strengths_taken_on: parse_date(row["Strengths Date"]),
          strengths: strengths,
          strength_1: strengths[0],
          strength_2: strengths[1],
          strength_3: strengths[2],
          strength_4: strengths[3],
          strength_5: strengths[4]
        )
        profile[:wizwiki_status] ||= clean(row["WIZWIKI Status"])
        profile[:raw_payload][:strengths] = row.to_h
      end
    end

    def read_current(profiles)
      each_csv("current.csv") do |row|
        key = key_for(row["first_name"], row["last_name"], nil)
        profile = (profiles[key] ||= base_profile(row["first_name"], row["last_name"], nil))
        profile.merge!(
          employee_status: clean(row["user_status"]),
          wizwiki_status: clean(row["WIZWIKI Status"]) || profile[:wizwiki_status],
          clifton_status: clean(row["With Cilffton"]),
          strengths_taken_on: parse_date(row["strengths_date"]) || profile[:strengths_taken_on]
        )
        profile[:raw_payload][:current] = row.to_h
      end
    end

    def each_csv(file_name)
      path = @path.join(file_name)
      return unless path.exist?

      CSV.foreach(path, headers: true, encoding: "bom|utf-8") { |row| yield row }
    end

    def base_profile(first_name, last_name, email)
      {
        first_name: clean(first_name),
        last_name: clean(last_name),
        email: clean(email)&.downcase,
        raw_payload: {}
      }
    end

    def key_for(first_name, last_name, email)
      first_key = clean(first_name).to_s.downcase.scan(/[a-z0-9]+/).first.to_s
      last_key = clean(last_name).to_s.downcase.gsub(/[^a-z0-9]+/, "")
      return "name:#{first_key}:#{last_key}" if first_key.present? && last_key.present?
      return "email:#{clean(email).downcase}" if clean(email).present?

      "name:#{first_key}:#{last_key}"
    end

    def source_key_for(attributes)
      if attributes[:email].present?
        "email:#{attributes[:email].downcase}"
      else
        Digest::SHA256.hexdigest([attributes[:first_name], attributes[:last_name]].join(":"))[0, 24]
      end
    end

    def role_recommendation(attributes)
      title = attributes[:role_title].to_s.downcase
      team = attributes[:team_name].to_s.downcase
      department = attributes[:department].to_s.downcase
      executive = attributes[:executive] || attributes[:leadership]

      if executive || title.match?(/ceo|chief|director|head of|vp|president|coo|cfo|cto|founder/)
        ["leadership", 3, "Executive/leadership profile. Full approval rights should be considered after management approval."]
      elsif title.match?(/developer|engineer|technical|automation|product/) || department.include?("engineering")
        ["develop", 1, "Technical role. Can be approved for BUILD staging after management approval."]
      elsif title.match?(/designer|design|creative/) || department.include?("design")
        ["design", 0, "Design role. Good fit for design queue, front-end staging, and creative review."]
      elsif title.match?(/sales|account|growth|retention|strategist/) || department.match?(/sales|marketing|client/)
        ["sales", 0, "Customer-facing role. Good fit for opportunities, customer context, and sales notes."]
      elsif title.match?(/support|success|assistant/) || team.include?("support")
        ["support", 0, "Support role. Good fit for tickets, customer follow-up, and knowledge capture."]
      elsif title.match?(/operations|production|technician|mail|print|qc/) || department.match?(/operations|production/)
        ["operations", 0, "Operations role. Good fit for process documentation and production context."]
      else
        ["produce", 0, "Default production access until management assigns a specific lane."]
      end
    end

    def invite_status_for(attributes)
      active = !attributes[:wizwiki_status].to_s.downcase.in?(%w[terminated resigned]) && !attributes[:employee_status].to_s.downcase.in?(%w[terminate terminated resigned])
      active && attributes[:email].present? ? "not_sent" : "held"
    end

    def executive_row?(row)
      [row["Role"], row["Team"], row["Department"], row["Leadership?"]].compact.join(" ").downcase.match?(/ceo|chief|executive|leadership|director|head of|coo|cfo|cto/)
    end

    def clean(value)
      value.to_s.strip.presence
    end

    def parse_date(value)
      return if clean(value).blank?

      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_boolean(value)
      case clean(value).to_s.downcase
      when "true", "yes", "1" then true
      when "false", "no", "0" then false
      end
    end
  end
end
