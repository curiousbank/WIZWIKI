require "set"

module DealReports
  class CommsContactOwnerPool
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

    OWNER_NAME_KEYS = %w[
      contact_owner contact_owner_name contact_owner_label
      hubspot_lead_owner hubspot_owner_name hubspot_owner
      lead_owner lead_owner_name owner owner_name
      account_manager account_manager_name assigned_owner assigned_to
      comms_routed_to_user_name
    ].freeze

    OWNER_ID_KEYS = %w[
      contact_owner_id hubspot_owner_id lead_owner_id owner_id
      comms_routed_to_hubspot_owner_id
    ].freeze

    def self.call(organization:, names: nil)
      new(organization: organization, names: names).owner_specs
    end

    def initialize(organization:, names: nil)
      @organization = organization
      @names = Array(names).compact_blank.presence || env_names.presence || DEFAULT_AM_NAMES
    end

    def owner_specs
      @owner_specs ||= @names.map do |name|
        key = normalize_owner_key(name)
        OwnerSpec.new(
          name: name,
          hubspot_owner_id: owner_id_map[key],
          source: owner_id_sources[key].presence || "configured_am_pool"
        )
      end
    end

    private

    attr_reader :organization

    def env_names
      ENV["WIZWIKI_COMMS_AM_NAMES"].to_s.split(/[,\n]/).map(&:strip).compact_blank
    end

    def owner_id_map
      @owner_id_map ||= db_owner_id_map.merge(live_owner_id_map).merge(env_owner_id_map)
    end

    def owner_id_sources
      @owner_id_sources ||= db_owner_id_sources.merge(live_owner_id_sources).merge(env_owner_id_map.transform_values { "env_owner_id_map" })
    end

    def env_owner_id_map
      @env_owner_id_map ||= ENV["WIZWIKI_COMMS_AM_HUBSPOT_OWNER_IDS"].to_s.split(/[\n,]/).filter_map do |entry|
        name, owner_id = entry.split(":", 2).map { |part| part.to_s.squish }
        next if name.blank? || owner_id.blank?

        [normalize_owner_key(name), owner_id]
      end.to_h
    end

    def db_owner_id_map
      @db_owner_id_map ||= discovered_owner_rows.each_with_object({}) do |row, map|
        key = match_configured_owner_key(row[:name])
        next if key.blank? || row[:hubspot_owner_id].blank?

        map[key] ||= row[:hubspot_owner_id]
      end
    end

    def db_owner_id_sources
      @db_owner_id_sources ||= discovered_owner_rows.each_with_object({}) do |row, map|
        key = match_configured_owner_key(row[:name])
        next if key.blank? || row[:hubspot_owner_id].blank?

        map[key] ||= row[:source]
      end
    end

    def live_owner_id_map
      @live_owner_id_map ||= live_owner_rows.each_with_object({}) do |row, map|
        key = match_configured_owner_key(row[:name])
        next if key.blank? || row[:hubspot_owner_id].blank?

        map[key] ||= row[:hubspot_owner_id]
      end
    end

    def live_owner_id_sources
      @live_owner_id_sources ||= live_owner_rows.each_with_object({}) do |row, map|
        key = match_configured_owner_key(row[:name])
        next if key.blank? || row[:hubspot_owner_id].blank?

        map[key] ||= row[:source]
      end
    end

    def live_owner_rows
      @live_owner_rows ||= Rails.cache.fetch("wizwiki/comms/contact_owner_pool/#{configured_owner_keys.to_a.sort.join('-')}", expires_in: 6.hours) do
        next [] unless defined?(Hubspot::Client)

        response = Hubspot::Client.new.get("/crm/v3/owners", archived: false, limit: 500)
        Array(response["results"]).filter_map do |owner|
          name = [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence || owner["email"].presence
          next if name.blank? || owner["id"].blank?

          {
            name: name,
            hubspot_owner_id: owner["id"].to_s,
            source: "hubspot_owners_api"
          }
        end
      rescue StandardError => error
        Rails.logger.warn("[DealReports::CommsContactOwnerPool] HubSpot owners API failed #{error.class}: #{error.message}")
        []
      end
    end

    def discovered_owner_rows
      @discovered_owner_rows ||= begin
        rows = []
        organization.crm_record_artifacts.where(artifact_type: "comm_staging").order(updated_at: :desc).limit(1_000).find_each do |stage|
          rows.concat(extract_owner_rows(stage.metadata, source: "comm_stage:#{stage.id}"))
        end
        organization.crm_records.order(updated_at: :desc).limit(2_000).find_each do |record|
          rows.concat(extract_owner_rows(record.properties, source: "crm_record:#{record.id}"))
        end
        rows.compact
      end
    end

    def extract_owner_rows(value, source:)
      case value
      when Hash
        direct_row = owner_row_from_hash(value, source: source)
        nested_rows = value.values.flat_map { |item| extract_owner_rows(item, source: source) }
        [direct_row, *nested_rows].compact
      when Array
        value.flat_map { |item| extract_owner_rows(item, source: source) }
      else
        []
      end
    end

    def owner_row_from_hash(hash, source:)
      normalized = hash.to_h.transform_keys { |key| normalize_field_key(key) }
      name = OWNER_NAME_KEYS.filter_map { |key| normalized[key].to_s.squish.presence }.first
      owner_id = OWNER_ID_KEYS.filter_map { |key| normalized[key].to_s.squish.presence }.first
      return if name.blank? && owner_id.blank?

      {
        name: name,
        hubspot_owner_id: owner_id,
        source: source
      }.compact_blank
    end

    def match_configured_owner_key(value)
      key = normalize_owner_key(value)
      return key if configured_owner_keys.include?(key)

      first = key.split(/\s+/).first
      configured_owner_keys.find { |candidate| candidate.split(/\s+/).first == first } if first.present?
    end

    def configured_owner_keys
      @configured_owner_keys ||= @names.map { |name| normalize_owner_key(name) }.to_set
    end

    def normalize_owner_key(value)
      value.to_s.squish.downcase.delete(".")
    end

    def normalize_field_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end
  end
end
