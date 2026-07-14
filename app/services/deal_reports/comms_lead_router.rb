module DealReports
  class CommsLeadRouter
    VirtualOwner = Struct.new(:id, :display_name, :email_address, :created_at, :hubspot_owner_id, :source, keyword_init: true)
    OwnerSpec = Struct.new(:name, :hubspot_owner_id, :source, keyword_init: true)
    DEFAULT_AM_NAMES = [
      "Adam M.",
      "Ian",
      "Maddy",
      "Charlie",
      "Dane",
      "Peyton",
      "Kristina F.",
      "Patrick O."
    ].freeze
    ROUND_ROBIN_SETTINGS_KEY = "wizwiki_comms_am_round_robin".freeze
    GENERIC_VALUES = [
      "wizwiki comms",
      "sample comms",
      "manual comms",
      "choose in lab",
      "wizwiki marketing",
      "contact",
      "customer"
    ].freeze

    def self.route!(stage, force: false, reason: nil)
      new(stage).route!(force: force, reason: reason)
    end

    def initialize(stage)
      @stage = stage
      @metadata = stage.metadata.to_h
      @record = stage.crm_record
      @organization = stage.organization || @record&.organization
    end

    def route!(force: false, reason: nil)
      return false unless @stage.present? && @record.present? && @organization.present?

      @organization.with_lock do
        @stage.reload
        @record.reload
        @metadata = @stage.metadata.to_h
        return false unless force
        return false unless human_handoff_reason?(reason)

        owner = next_round_robin_owner
        return false if owner.blank?

        now = Time.current
        owner_key = owner_round_robin_key(owner)
        @record.update!(owner: owner) if persisted_user?(owner)
        @stage.update!(
          user: persisted_user?(owner) ? owner : @stage.user,
          metadata: @metadata.merge(
            "comms_route_claimed_at" => now.iso8601,
            "comms_routed_to_user_id" => owner.id,
            "comms_routed_to_user_name" => owner.display_name,
            "comms_routed_to_user_first_name" => owner_first_name(owner.display_name),
            "comms_routed_to_user_email" => owner.email_address,
            "comms_routed_to_hubspot_owner_id" => hubspot_owner_id_for(owner),
            "hubspot_owner_property" => "hubspot_owner_id",
            "hubspot_owner_write_pending" => hubspot_owner_id_for(owner).present?,
            "contact_owner_code" => "CONTACT_OWNER",
            "contact_owner_assigned_at" => now.iso8601,
            "processing_code" => "CONTACT_OWNER",
            "processing_label" => "Contact Owner",
            "contact_owner_source" => owner.respond_to?(:source) && owner.source.present? ? owner.source : "thumper_contact_owner_ordered_round_robin",
            "comms_route_claim_reason" => reason.presence || "human_requested_round_robin",
            "comms_route_claim_load" => claim_count_for(owner),
            "comms_route_claim_order" => configured_owner_names,
            "comms_route_claim_cursor" => owner_key,
            "comms_route_previous_user_name" => @metadata["comms_routed_to_user_name"],
            "comms_route_previous_user_id" => @metadata["comms_routed_to_user_id"],
            "comms_route_claim_history" => route_claim_history(owner, owner_key, now, reason),
            "comms_route_claim_pool" => eligible_users.map { |user| { "id" => user.id, "name" => user.display_name, "hubspot_owner_id" => hubspot_owner_id_for(user), "claims" => claim_count_for(user), "round_robin_key" => owner_round_robin_key(user) }.compact_blank }
          )
        )
        advance_round_robin_cursor!(owner, assigned_at: now)
        owner
      end
    end

    private

    def human_handoff_reason?(reason)
      text = reason.to_s
      return true if text.include?("completion_without_purchase") || text.include?("manual_am_support")
      return handoff_contact_ready_for_route? if text.match?(/customer_accepted_marketing_consultant|am_support_contact_collection|consultant_handoff|marketing_consultant|rush_or_deadline/)

      text.include?("human_requested") ||
        text.include?("account_manager_answer_needed") ||
        text.include?("support_requested_or_unanswerable") ||
        text.include?("starter_pack_over_limit")
    end

    def handoff_contact_ready_for_route?
      return true if @metadata["sms_autopilot_handoff_contact_ready_at"].present? ||
        @metadata["sms_autopilot_handoff_contact_posted_at"].present?
      return false unless ActiveModel::Type::Boolean.new.cast(@metadata["sms_autopilot_handoff_contact_permission"])

      case normalize_handoff_contact_preference(@metadata["sms_autopilot_handoff_contact_preference"])
      when "email"
        @metadata["sms_autopilot_handoff_contact_email"].present?
      when "call", "phone", "text", "sms"
        @metadata["sms_autopilot_handoff_contact_phone"].present? &&
          @metadata["sms_autopilot_handoff_contact_time"].present?
      else
        false
      end
    end

    def normalize_handoff_contact_preference(value)
      body = value.to_s.downcase.squish
      return "email" if body.match?(/\b(?:email|e-mail)\b/)
      return "text" if body.match?(/\b(?:text|sms)\b/)
      return "call" if body.match?(/\b(?:call|phone|ring)\b/)

      nil
    end

    def identity_ready?
      industry = @metadata["captured_industry"].presence ||
        @metadata["industry"].presence ||
        @record.properties.to_h["sms_captured_industry"].presence
      @metadata["product_interest_code"].present? &&
        !generic_value?(selected_contact_name) &&
        !generic_value?(company_name) &&
        industry.present?
    end

    def selected_contact_name
      selected_contact["name"].presence || @metadata["captured_contact_name"].presence
    end

    def company_name
      @metadata["company_name"].presence || @metadata["captured_company_name"].presence || @record&.name
    end

    def selected_contact
      selected_id = @metadata["selected_contact_id"].to_s
      options = Array(@metadata["contact_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first || {}).to_h
    end

    def generic_value?(value)
      text = value.to_s.squish.downcase
      text.blank? || GENERIC_VALUES.include?(text) || text.match?(/\A(?:wizwiki\s*)?comms\b/) || text.match?(/\Asample\b/)
    end

    def next_round_robin_owner
      users = eligible_users
      return if users.blank?

      last_key = round_robin_state["last_key"].to_s
      last_index = users.index { |user| owner_round_robin_key(user) == last_key }
      next_index = last_index.present? ? (last_index + 1) % users.size : 0
      users[next_index]
    end

    def eligible_users
      @eligible_users ||= configured_users.presence || @organization.memberships
        .includes(:user)
        .where(status: "active")
        .map(&:user)
        .compact
        .uniq
        .reject { |user| disallowed_owner?(user) }
        .sort_by { |user| [user.display_name.to_s.downcase, user.id] }
    end

    def configured_users
      owner_specs = contact_owner_specs
      return [] if owner_specs.blank?

      name_selectors = owner_specs.flat_map { |spec| [spec.name, owner_first_name(spec.name)] }.compact_blank.map(&:downcase).uniq
      users = User.where("LOWER(name) IN (?)", name_selectors).to_a.uniq
      owner_specs.filter_map do |spec|
        user = users.find { |candidate| owner_matches_spec?(candidate, spec) }
        user || VirtualOwner.new(
          id: "virtual:#{spec.name.parameterize.presence || SecureRandom.hex(4)}",
          display_name: spec.name,
          email_address: nil,
          created_at: Time.current,
          hubspot_owner_id: spec.hubspot_owner_id,
          source: spec.source
        )
      end
    end

    def contact_owner_specs
      @contact_owner_specs ||= if defined?(DealReports::CommsContactOwnerPool)
        DealReports::CommsContactOwnerPool.call(organization: @organization, names: configured_owner_names)
      else
        configured_owner_names.map { |name| OwnerSpec.new(name: name, hubspot_owner_id: hubspot_owner_id_for_name(name), source: "configured_am_pool") }
      end
    end

    def configured_owner_names
      @configured_owner_names ||= begin
        raw_names = ENV["WIZWIKI_COMMS_AM_NAMES"].to_s.split(/[,\n]/).map(&:strip).compact_blank.presence || DEFAULT_AM_NAMES
        raw_names.filter_map { |name| canonical_owner_name(name) }.uniq.presence || DEFAULT_AM_NAMES
      end
    end

    def hubspot_owner_id_for(owner)
      return owner.hubspot_owner_id if owner.respond_to?(:hubspot_owner_id) && owner.hubspot_owner_id.present?

      hubspot_owner_id_for_name(owner&.display_name) ||
        hubspot_owner_id_for_name(owner&.email_address)
    end

    def hubspot_owner_id_for_name(value)
      key = normalize_owner_key(value)
      return if key.blank?

      hubspot_owner_id_map[key]
    end

    def hubspot_owner_id_map
      @hubspot_owner_id_map ||= ENV["WIZWIKI_COMMS_AM_HUBSPOT_OWNER_IDS"].to_s.split(/[\n,]/).filter_map do |entry|
        name, owner_id = entry.split(":", 2).map { |part| part.to_s.squish }
        next if name.blank? || owner_id.blank?

        [normalize_owner_key(name), owner_id]
      end.to_h.merge(contact_owner_specs.each_with_object({}) do |spec, map|
        map[normalize_owner_key(spec.name)] = spec.hubspot_owner_id if spec.hubspot_owner_id.present?
      end)
    end

    def normalize_owner_key(value)
      value.to_s.squish.downcase.delete(".")
    end

    def approved_owner_keys
      @approved_owner_keys ||= DEFAULT_AM_NAMES.map { |name| normalize_owner_key(name) }
    end

    def canonical_owner_name(value)
      return if disallowed_owner_name?(value)

      key = normalize_owner_key(value)
      first_key = normalize_owner_key(owner_first_name(value))
      DEFAULT_AM_NAMES.find do |name|
        normalize_owner_key(name) == key || normalize_owner_key(owner_first_name(name)) == first_key
      end
    end

    def owner_matches_spec?(user, spec)
      return false if disallowed_owner?(user)

      user_key = normalize_owner_key(user.display_name)
      user_first_key = normalize_owner_key(owner_first_name(user.display_name))
      spec_key = normalize_owner_key(spec.name)
      spec_first_key = normalize_owner_key(owner_first_name(spec.name))
      user_key == spec_key || user_first_key == spec_first_key
    end

    def disallowed_owner_name?(value)
      normalize_owner_key(value).start_with?("ethan")
    end

    def disallowed_owner?(owner)
      [
        (owner.respond_to?(:display_name) ? owner.display_name : nil),
        (owner.respond_to?(:email_address) ? owner.email_address : nil),
        (owner.respond_to?(:email) ? owner.email : nil),
        (owner.respond_to?(:id) ? owner.id : nil)
      ].any? { |value| disallowed_owner_name?(value) || normalize_owner_key(value).include?("ethan@") }
    end

    def owner_round_robin_key(owner)
      normalize_owner_key(canonical_owner_name(owner&.display_name) || owner&.display_name || owner&.id)
    end

    def round_robin_state
      state = @organization.settings.to_h[ROUND_ROBIN_SETTINGS_KEY].to_h
      state["last_key"].present? ? state : recent_route_state
    end

    def advance_round_robin_cursor!(owner, assigned_at:)
      @organization.update!(
        settings: @organization.settings.to_h.merge(
          ROUND_ROBIN_SETTINGS_KEY => {
            "last_key" => owner_round_robin_key(owner),
            "last_name" => canonical_owner_name(owner.display_name) || owner.display_name,
            "last_assigned_at" => assigned_at.iso8601,
            "order" => configured_owner_names
          }
        )
      )
    end

    def recent_route_state
      @recent_route_state ||= begin
        metadata = @organization.crm_record_artifacts
          .where(artifact_type: "comm_staging")
          .where("metadata ? :cursor", cursor: "comms_route_claim_cursor")
          .order(updated_at: :desc)
          .limit(1)
          .pick(:metadata)
          .to_h
        cursor = metadata["comms_route_claim_cursor"].to_s.presence
        cursor.present? ? { "last_key" => cursor, "last_name" => metadata["comms_routed_to_user_name"] } : {}
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.warn("[DealReports::CommsLeadRouter] recent route cursor unavailable: #{error.class}: #{error.message}")
        {}
      end
    end

    def route_claim_history(owner, owner_key, assigned_at, reason)
      Array(@metadata["comms_route_claim_history"]).last(24) + [
        {
          "assigned_at" => assigned_at.iso8601,
          "reason" => reason.presence || "human_requested_round_robin",
          "user_id" => owner.id,
          "user_name" => owner.display_name,
          "round_robin_key" => owner_key,
          "previous_user_name" => @metadata["comms_routed_to_user_name"].presence
        }.compact_blank
      ]
    end

    def claim_counts
      @claim_counts ||= @organization.crm_records
        .where.not(owner_id: nil)
        .where.not(status: "archived")
        .group(:owner_id)
        .count
    end

    def virtual_claim_counts
      @virtual_claim_counts ||= @organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where.not("metadata ->> 'comms_routed_to_user_name' IS NULL")
        .group("metadata ->> 'comms_routed_to_user_name'")
        .count
    end

    def claim_count_for(owner)
      return claim_counts.fetch(owner.id, 0) if persisted_user?(owner)

      virtual_claim_counts.fetch(owner.display_name.to_s, 0)
    end

    def persisted_user?(owner)
      defined?(User) && owner.is_a?(User) && owner.persisted?
    end

    def owner_first_name(name)
      name.to_s.squish.split(/\s+/).first.presence || name.to_s.squish
    end
  end
end
