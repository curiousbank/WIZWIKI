require "digest"
require "json"
require "set"
require "uri"

module Hubspot
  class CompanyAddressSync
    DEFAULT_PAGE_SIZE = 100
    DEFAULT_COMPANY_PROPERTIES = %w[
      name domain website phone industry lifecyclestage
      address address2 address_2 city state state_dd zip postal_code country
      hs_object_id createdate hs_lastmodifieddate hubspot_owner_id
      hs_analytics_source hs_analytics_source_data_1 hs_analytics_source_data_2
      hs_latest_source hs_latest_source_data_1 hs_latest_source_data_2
      hs_object_source_label hs_object_source_detail_1 hs_object_source_detail_2 hs_object_source_detail_3
    ].freeze
    DEFAULT_ADDRESS_FILTER_PROPERTIES = %w[zip postal_code].freeze

    Result = Data.define(:created_count, :updated_count, :unchanged_count, :error_count, :records, :properties_searched, :started_at, :finished_at) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          record_type: "company",
          source: "hubspot_company_address_sync",
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          errors: error_count,
          total: total_count,
          properties_searched: properties_searched,
          started_at: started_at&.iso8601,
          finished_at: finished_at&.iso8601
        }
      end
    end

    def self.call(organization:, limit: nil, client: Client.new)
      new(organization:, limit:, client:).call
    end

    def initialize(organization:, limit:, client:)
      @organization = organization
      @limit = normalize_limit(limit)
      @page_size = [@limit || DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE].min
      @client = client
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      error_count = 0
      records = []
      started_at = Time.current

      each_company do |payload|
        record, state = upsert_company(payload, sync_started_at: started_at)
        records << record
        case state
        when :created then created_count += 1
        when :updated then updated_count += 1
        else unchanged_count += 1
        end
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError, URI::InvalidURIError => error
        error_count += 1
        Rails.logger.warn("[Hubspot::CompanyAddressSync] company failed: #{error.class}: #{error.message}")
      end

      Result.new(
        created_count:,
        updated_count:,
        unchanged_count:,
        error_count:,
        records: records,
        properties_searched: address_filter_properties,
        started_at:,
        finished_at: Time.current
      )
    end

    private

    attr_reader :organization, :limit, :page_size, :client

    def normalize_limit(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s == "all"

      value.to_i.clamp(1, 100_000)
    end

    def each_company
      seen = Set.new
      yielded = 0
      search_had_error = false

      address_filter_properties.each do |property_name|
        after = nil
        loop do
          response = client.post("/crm/v3/objects/companies/search", search_body(property_name, after))
          Array(response["results"]).each do |payload|
            hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
            next if hubspot_id.blank? || seen.include?(hubspot_id)
            break if limit.present? && yielded >= limit

            seen << hubspot_id
            yield payload
            yielded += 1
          end
          break if limit.present? && yielded >= limit

          after = response.dig("paging", "next", "after")
          break if after.blank?
        end
        break if limit.present? && yielded >= limit
      rescue Hubspot::Error => error
        search_had_error = true
        Rails.logger.warn("[Hubspot::CompanyAddressSync] property=#{property_name} failed: #{error.message}")
      end

      return if limit.present? && yielded >= limit
      return unless full_list_fallback_enabled? && (search_had_error || yielded >= search_window_fallback_threshold)

      Rails.logger.info("[Hubspot::CompanyAddressSync] search fallback scanning company list seen=#{seen.length} yielded=#{yielded}")
      each_company_from_list(seen) do |payload|
        break if limit.present? && yielded >= limit

        yield payload
        yielded += 1
      end
    end

    def each_company_from_list(seen)
      after = nil
      loop do
        params = {
          archived: false,
          properties: company_property_names.join(","),
          limit: page_size
        }
        params[:after] = after if after.present?
        response = client.get("/crm/v3/objects/companies", params)
        Array(response["results"]).each do |payload|
          hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
          next if hubspot_id.blank? || seen.include?(hubspot_id)

          properties = payload.fetch("properties", {}).to_h
          next unless company_has_zip?(properties)

          seen << hubspot_id
          yield payload
        end

        after = response.dig("paging", "next", "after")
        break if after.blank?
      end
    rescue Hubspot::Error => error
      Rails.logger.warn("[Hubspot::CompanyAddressSync] company list fallback failed: #{error.message}")
    end

    def company_has_zip?(properties)
      properties.to_h.any? do |key, value|
        key.to_s.match?(/zip|postal/i) && value.to_s.match?(/\d{5}/)
      end
    end

    def full_list_fallback_enabled?
      ENV.fetch("WIZWIKI_HUBSPOT_COMPANY_ZIP_FULL_LIST_FALLBACK", "1") != "0"
    end

    def search_window_fallback_threshold
      ENV.fetch("WIZWIKI_HUBSPOT_COMPANY_SEARCH_FALLBACK_THRESHOLD", "9000").to_i
    end

    def search_body(property_name, after)
      body = {
        "filterGroups" => [
          {
            "filters" => [
              {
                "propertyName" => property_name,
                "operator" => "HAS_PROPERTY"
              }
            ]
          }
        ],
        "sorts" => [
          {
            "propertyName" => "hs_lastmodifieddate",
            "direction" => "DESCENDING"
          }
        ],
        "properties" => company_property_names,
        "limit" => page_size
      }
      body["after"] = after if after.present?
      body
    end

    def upsert_company(payload, sync_started_at:)
      hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
      raise Error, "HubSpot company payload missing id." if hubspot_id.blank?

      properties = payload.fetch("properties", {}).to_h
      record = company_record_for(hubspot_id, properties)
      created = record.new_record?
      before = record.attributes.slice("name", "email", "phone", "domain", "stage", "status", "properties")
      record.source = "hubspot_company" if record.source.blank? || record.source == "hubspot_company"
      record.source_uid = hubspot_id if record.source == "hubspot_company"
      record.assign_attributes(attributes_for(payload, properties, hubspot_id, sync_started_at:))
      record.save!
      persist_ingestion_event(record, payload)

      state = if created
        :created
      elsif before != record.reload.attributes.slice("name", "email", "phone", "domain", "stage", "status", "properties")
        :updated
      else
        :unchanged
      end

      [record, state]
    end

    def company_record_for(hubspot_id, properties)
      record = organization.crm_records.find_by(source: "hubspot_company", source_uid: hubspot_id)
      return record if record.present?

      domain = domain_for(properties)
      if domain.present?
        record = organization.crm_records.find_by(record_type: "company", domain: domain)
        return record if record.present?
      end

      name = properties["name"].to_s.squish.presence
      if name.present?
        record = organization.crm_records.find_by(record_type: "company", name: name) ||
          organization.crm_records.where(record_type: "company").where("LOWER(name) = ?", name.downcase).first
        return record if record.present?
      end

      lookup_name = name.presence || company_name(properties, hubspot_id)
      fingerprint = fingerprint_for_company(domain, lookup_name)
      if fingerprint.present?
        record = organization.crm_records.find_by(record_type: "company", fingerprint: fingerprint)
        return record if record.present?
      end

      organization.crm_records.new
    end

    def fingerprint_for_company(domain, name)
      value = domain.presence || name.to_s.squish.presence
      return if value.blank?

      Digest::SHA256.hexdigest(["company", value].map { |part| part.to_s.strip.downcase.gsub(/\s+/, " ") }.join("|"))
    end

    def attributes_for(payload, properties, hubspot_id, sync_started_at:)
      existing_hubspot = company_record_for(hubspot_id, properties).properties.to_h.fetch("hubspot", {}).to_h
      {
        record_type: "company",
        name: company_name(properties, hubspot_id),
        domain: domain_for(properties),
        phone: properties["phone"].presence,
        status: "active",
        properties: {
          "hubspot" => existing_hubspot.deep_merge(
            "object_type" => "company",
            "id" => hubspot_id,
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "last_synced_at" => sync_started_at.iso8601,
            "lead_source" => "hubspot_company_address_sync",
            "lead_sources" => (Array(existing_hubspot["lead_sources"]) | ["hubspot_company_address_sync"]).compact_blank,
            "address_sync" => {
              "synced_at" => sync_started_at.iso8601,
              "properties_searched" => address_filter_properties
            },
            "properties" => compact_hash(properties)
          )
        }
      }
    end

    def company_name(properties, hubspot_id)
      properties["name"].presence || properties["domain"].presence || properties["website"].presence || "HubSpot Company #{hubspot_id}"
    end

    def domain_for(properties)
      sanitized_domain(properties["domain"]) || host_for(properties["website"])
    end

    def host_for(url)
      value = url.to_s.strip
      return if value.blank?

      normalized = value.match?(/\Ahttps?:\/\//i) ? value : "https://#{value}"
      sanitized_domain(URI.parse(normalized).host)
    rescue URI::InvalidURIError
      nil
    end

    def sanitized_domain(value)
      cleaned = value.to_s.strip.downcase
      return if cleaned.blank?

      cleaned = cleaned.sub(/\Ahttps?:\/\//, "").sub(/\Awww\./, "").split("/").first.to_s
      return if cleaned.blank? || cleaned.match?(/\s/) || cleaned.include?("@")
      return unless cleaned.match?(/\A[a-z0-9][a-z0-9.-]*\.[a-z0-9-]{2,}\z/)

      cleaned
    end

    def persist_ingestion_event(record, payload)
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      event = organization.ingestion_events.find_or_initialize_by(source: "hubspot_company_address_sync", source_uid: record.source_uid.presence || record.id.to_s)
      event.assign_attributes(
        crm_record: record,
        payload_digest: digest,
        raw_payload: payload,
        status: "accepted"
      )
      event.save!
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def company_property_names
      @company_property_names ||= (DEFAULT_COMPANY_PROPERTIES + dynamic_company_property_names).uniq.first(120)
    end

    def address_filter_properties
      @address_filter_properties ||= (DEFAULT_ADDRESS_FILTER_PROPERTIES + dynamic_address_filter_properties).uniq.first(40)
    end

    def dynamic_company_property_names
      company_property_definitions.filter_map do |definition|
        name = definition["name"].to_s
        next if name.blank?
        next unless name.match?(/address|street|city|state|zip|postal|country|location|service|trade|industr|business|category|phone|domain|website/i)

        name
      end
    rescue Hubspot::Error => error
      Rails.logger.warn("[Hubspot::CompanyAddressSync] property definition lookup failed: #{error.message}")
      []
    end

    def dynamic_address_filter_properties
      company_property_definitions.filter_map do |definition|
        name = definition["name"].to_s
        next if name.blank?
        next if name.match?(/email|recommendation|intake|count|number/i)
        next unless name.match?(/zip|postal/i)

        name
      end
    rescue Hubspot::Error
      []
    end

    def company_property_definitions
      @company_property_definitions ||= Array(client.get("/crm/v3/properties/companies")["results"])
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), memo|
        next if value.blank?

        memo[key] = value
      end
    end
  end
end
