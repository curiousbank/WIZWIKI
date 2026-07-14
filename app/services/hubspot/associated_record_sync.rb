require "bigdecimal"
require "uri"

module Hubspot
  class AssociatedRecordSync
    SECOND_HOP_DEAL_SOURCE_TYPES = %w[companies contacts].freeze
    SECOND_HOP_DEAL_LIMIT = 25

    ASSOCIATION_CONFIG = {
      "companies" => {
        record_type: "company",
        source: "hubspot_company",
        association_type: "primary_company",
        properties: %w[
          name domain website address address2 city state zip postal_code country industry phone lifecyclestage
          hs_object_id createdate hs_lastmodifieddate
        ]
      },
      "contacts" => {
        record_type: "contact",
        source: "hubspot_contact",
        association_type: "requester",
        properties: %w[
          firstname lastname email phone jobtitle company address city state zip country lifecyclestage
          hs_object_id createdate hs_lastmodifieddate
        ]
      },
      "deals" => {
        record_type: "deal",
        source: "hubspot",
        association_type: "related_deal",
        properties: %w[
          dealname amount closedate createdate hs_lastmodifieddate dealstage pipeline
          hubspot_owner_id dealtype description hs_object_id hs_analytics_source company_name
          address address_2 city state state_dd zip
        ]
      }
    }.freeze

    Result = Data.define(:created_count, :updated_count, :associated_count, :errors) do
      def to_h
        {
          created: created_count,
          updated: updated_count,
          associated: associated_count,
          errors: errors
        }
      end
    end

    def self.call(organization:, from_record:, from_object_type:, from_object_id:, client: Client.new)
      new(organization:, from_record:, from_object_type:, from_object_id:, client:).call
    end

    def initialize(organization:, from_record:, from_object_type:, from_object_id:, client:)
      @organization = organization
      @from_record = from_record
      @from_object_type = from_object_type.to_s
      @from_object_id = from_object_id.to_s
      @client = client
    end

    def call
      created_count = 0
      updated_count = 0
      associated_count = 0
      errors = []
      second_hop_sources = []

      ASSOCIATION_CONFIG.each do |to_object_type, config|
        association_ids(to_object_type).each do |hubspot_id|
          record, state = upsert_associated_record(to_object_type, hubspot_id, config)
          second_hop_sources << [to_object_type, hubspot_id] if SECOND_HOP_DEAL_SOURCE_TYPES.include?(to_object_type)
          created_count += 1 if state == :created
          updated_count += 1 if state == :updated
          associated_count += 1 if associate!(record, config.fetch(:association_type))
        rescue Hubspot::Error, ActiveRecord::ActiveRecordError, URI::InvalidURIError => error
          errors << "#{to_object_type}/#{hubspot_id}: #{error.message}"
          Rails.logger.warn("HubSpot associated #{to_object_type} sync failed for #{from_object_type}/#{from_object_id}: #{error.class} #{error.message}")
        end
      rescue Hubspot::Error => error
        errors << "#{to_object_type}: #{error.message}"
        Rails.logger.warn("HubSpot associations unavailable for #{from_object_type}/#{from_object_id} -> #{to_object_type}: #{error.message}")
      end

      second_hop_deal_ids(second_hop_sources).each do |hubspot_id|
        config = ASSOCIATION_CONFIG.fetch("deals")
        record, state = upsert_associated_record("deals", hubspot_id, config)
        created_count += 1 if state == :created
        updated_count += 1 if state == :updated
        associated_count += 1 if associate!(record, config.fetch(:association_type))
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError, URI::InvalidURIError => error
        errors << "second-hop deals/#{hubspot_id}: #{error.message}"
        Rails.logger.warn("HubSpot second-hop deal sync failed for #{from_object_type}/#{from_object_id}: #{error.class} #{error.message}")
      end

      Result.new(created_count:, updated_count:, associated_count:, errors: errors.first(10))
    end

    private

    attr_reader :organization, :from_record, :from_object_type, :from_object_id, :client

    def association_ids(to_object_type, source_object_type: from_object_type, source_object_id: from_object_id, limit: 100)
      response = client.get("/crm/v4/objects/#{source_object_type}/#{source_object_id}/associations/#{to_object_type}", limit: limit)
      Array(response["results"]).filter_map do |item|
        item["toObjectId"].presence || item["id"].presence
      end.map(&:to_s).uniq
    end

    def second_hop_deal_ids(sources)
      ids = []
      sources.each do |source_object_type, source_object_id|
        association_ids(
          "deals",
          source_object_type: source_object_type,
          source_object_id: source_object_id,
          limit: SECOND_HOP_DEAL_LIMIT
        ).each { |id| ids << id }
      rescue Hubspot::Error => error
        Rails.logger.warn("HubSpot second-hop deal associations unavailable for #{source_object_type}/#{source_object_id}: #{error.message}")
      end
      ids.uniq
    end

    def upsert_associated_record(object_type, hubspot_id, config)
      payload = fetch_object(object_type, hubspot_id, config.fetch(:properties))
      properties = payload.fetch("properties", {}).to_h
      record = associated_record_for(object_type, hubspot_id, properties, config)
      record.source = config.fetch(:source) if record.source.blank? || record.source == config.fetch(:source)
      if record.source == config.fetch(:source) && (record.source_uid.blank? || record.source_uid == hubspot_id)
        record.source_uid = hubspot_id
      end
      created = record.new_record?
      before = record.attributes.slice("name", "email", "phone", "domain", "amount", "close_date", "stage", "status", "properties")

      attributes = attributes_for(object_type, hubspot_id, payload, properties, config)
      attributes[:properties] = record.properties.to_h.deep_merge(attributes[:properties].to_h)
      record.assign_attributes(attributes)
      record.save!
      enqueue_embedding_source(record)

      state = if created
        :created
      elsif before != record.reload.attributes.slice("name", "email", "phone", "domain", "amount", "close_date", "stage", "status", "properties")
        :updated
      else
        :unchanged
      end

      [record, state]
    end

    def associated_record_for(object_type, hubspot_id, properties, config)
      source = config.fetch(:source)
      record = organization.crm_records.find_by(source: source, source_uid: hubspot_id)
      return record if record.present?

      identity_record = case object_type
      when "companies"
        domain = domain_for(properties)
        organization.crm_records.find_by(record_type: "company", domain: domain) if domain.present?
      when "contacts"
        email = properties["email"].to_s.strip.downcase.presence
        organization.crm_records.find_by(record_type: "contact", email: email) if email.present?
      end

      identity_record || organization.crm_records.new
    end

    def fetch_object(object_type, hubspot_id, properties)
      client.get("/crm/v3/objects/#{object_type}/#{hubspot_id}", properties: properties.join(","), archived: false)
    end

    def attributes_for(object_type, hubspot_id, payload, properties, config)
      base = {
        record_type: config.fetch(:record_type),
        name: name_for(object_type, properties, hubspot_id),
        status: status_for(object_type, properties),
        properties: {
          "hubspot" => {
            "object_type" => object_type.singularize,
            "id" => hubspot_id,
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "properties" => compact_hash(properties)
          }
        }
      }

      case object_type
      when "companies"
        base.merge(
          domain: domain_for(properties),
          phone: properties["phone"].presence
        )
      when "contacts"
        base.merge(
          email: properties["email"].presence,
          phone: properties["phone"].presence
        )
      when "deals"
        base.merge(
          amount: decimal_for(properties["amount"]),
          close_date: date_for(properties["closedate"]),
          stage: properties["dealstage"].presence
        )
      else
        base
      end
    end

    def associate!(record, association_type)
      return false if from_record.blank?

      association = organization.crm_associations.find_or_initialize_by(
        from_record: from_record,
        to_record: record,
        association_type: association_type
      )
      association.new_record?.tap { association.save! }
    end

    def enqueue_embedding_source(record)
      return unless record.present?
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
      return if record.is_a?(CrmRecord) && !Autos::EmbeddingQueue.crm_immediate_enqueue_enabled?

      Autos::EmbeddingQueue.enqueue_source!(record)
    rescue StandardError => error
      Rails.logger.warn("HubSpot associated embedding enqueue failed for #{record.class.name}/#{record.id}: #{error.class} #{error.message}")
    end

    def name_for(object_type, properties, hubspot_id)
      case object_type
      when "companies"
        properties["name"].presence || properties["domain"].presence || properties["website"].presence || "HubSpot Company #{hubspot_id}"
      when "contacts"
        [properties["firstname"], properties["lastname"]].compact_blank.join(" ").presence || properties["email"].presence || "HubSpot Contact #{hubspot_id}"
      when "deals"
        properties["dealname"].presence || properties["company_name"].presence || "HubSpot Deal #{hubspot_id}"
      else
        "HubSpot #{object_type.singularize.titleize} #{hubspot_id}"
      end
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

    def status_for(object_type, properties)
      case object_type
      when "companies", "contacts"
        "active"
      when "deals"
        stage = properties["dealstage"].to_s.downcase
        return "won" if stage.include?("closedwon") || stage.include?("closed_won") || stage == "won"
        return "lost" if stage.include?("closedlost") || stage.include?("closed_lost") || stage == "lost"

        "open"
      else
        "open"
      end
    end

    def decimal_for(value)
      cleaned = value.to_s.gsub(/[^0-9.\-]/, "")
      return if cleaned.blank?

      BigDecimal(cleaned)
    rescue ArgumentError
      nil
    end

    def date_for(value)
      return if value.blank?

      if value.to_s.match?(/\A\d{13}\z/)
        Time.zone.at(value.to_i / 1000).to_date
      else
        Time.zone.parse(value.to_s)&.to_date
      end
    rescue ArgumentError, TypeError
      nil
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), memo|
        next if value.blank?

        memo[key] = value
      end
    end
  end
end
