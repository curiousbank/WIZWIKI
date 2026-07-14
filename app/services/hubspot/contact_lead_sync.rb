require "digest"
require "json"
require "set"

module Hubspot
  class ContactLeadSync
    DEFAULT_PAGE_SIZE = 100
    ALL_CONTACTS_SOURCE = "all_contacts".freeze
    VALID_SOURCES = %w[all_contacts facebook shopify haymarket].freeze

    DEFAULT_CONTACT_PROPERTIES = %w[
      firstname lastname email phone mobilephone hs_calculated_phone_number hs_calculated_mobile_number
      jobtitle company website address city state zip country lifecyclestage
      hs_object_id createdate hs_lastmodifieddate hubspot_owner_id
      hs_analytics_source hs_analytics_source_data_1 hs_analytics_source_data_2
      hs_latest_source hs_latest_source_data_1 hs_latest_source_data_2
      first_conversion_event_name recent_conversion_event_name
      hs_object_source_label hs_object_source_detail_1 hs_object_source_detail_2 hs_object_source_detail_3
      crm_used facebook_inquiry facebook_messenger_conversion hs_facebook_ad_clicked hs_facebook_click_id hs_facebookid
      b__shopify_eddm_order ip__shopify__orders_count ip__shopify__shopify_created_at
      ip__shopify__tags ip__shopify__account_state shopify_amount_spent
    ].freeze

    Result = Data.define(:lead_source, :created_count, :updated_count, :unchanged_count, :associated_count, :error_count, :records, :sync_window_start) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          lead_source: lead_source,
          record_type: "contact",
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          associated: associated_count,
          errors: error_count,
          total: total_count,
          sync_window_start: sync_window_start&.iso8601
        }
      end
    end

    def self.call(organization:, source:, since: 90.days.ago, limit: nil)
      new(organization:, source:, since:, limit:).call
    end

    def initialize(organization:, source:, since:, limit:)
      @organization = organization
      @source = normalize_source(source)
      @since = since
      @limit = normalize_limit(limit)
      @page_size = [@limit || DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE].min
      @client = Client.new
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      associated_count = 0
      error_count = 0
      records = []
      sync_started_at = Time.current

      each_contact do |payload|
        record, state, associations = upsert_contact(payload, sync_started_at:)
        records << record
        associated_count += associations.to_i
        case state
        when :created then created_count += 1
        when :updated then updated_count += 1
        else unchanged_count += 1
        end
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError, URI::InvalidURIError => error
        error_count += 1
        Rails.logger.warn("[Hubspot::ContactLeadSync] source=#{source} contact failed: #{error.class}: #{error.message}")
      end

      Result.new(
        lead_source: source,
        created_count:,
        updated_count:,
        unchanged_count:,
        associated_count:,
        error_count:,
        records: records,
        sync_window_start: since
      )
    end

    private

    attr_reader :organization, :source, :since, :limit, :page_size, :client

    def normalize_source(value)
      normalized = value.to_s.strip.downcase
      return normalized if VALID_SOURCES.include?(normalized)

      raise Error, "Unsupported contact lead source: #{value}"
    end

    def normalize_limit(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s == "all"

      value.to_i.clamp(1, 10_000)
    end

    def each_contact
      seen = Set.new
      yielded = 0

      source_filters.each do |filter|
        after = nil
        loop do
          response = client.post("/crm/v3/objects/contacts/search", search_body(filter, after))
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
        Rails.logger.warn("[Hubspot::ContactLeadSync] source=#{source} filter=#{filter.inspect} failed: #{error.message}")
      end
    end

    def search_body(source_filter, after)
      filters = [
        {
          "propertyName" => "createdate",
          "operator" => "GTE",
          "value" => hubspot_milliseconds(since).to_s
        }
      ]
      filters << source_filter if source_filter.present?

      body = {
        "filterGroups" => [
          {
            "filters" => filters
          }
        ],
        "sorts" => [
          {
            "propertyName" => "createdate",
            "direction" => "DESCENDING"
          }
        ],
        "properties" => contact_property_names,
        "limit" => page_size
      }
      body["after"] = after if after.present?
      body
    end

    def source_filters
      case source
      when ALL_CONTACTS_SOURCE
        [nil]
      when "facebook"
        [
          { "propertyName" => "hs_facebook_click_id", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "hs_facebookid", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "hs_facebook_ad_clicked", "operator" => "EQ", "value" => "true" },
          { "propertyName" => "facebook_inquiry", "operator" => "EQ", "value" => "true" },
          { "propertyName" => "facebook_messenger_conversion", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "hs_analytics_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*facebook*" },
          { "propertyName" => "hs_analytics_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*facebook*" },
          { "propertyName" => "hs_latest_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*facebook*" },
          { "propertyName" => "hs_latest_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*facebook*" },
          { "propertyName" => "crm_used", "operator" => "EQ", "value" => "Facebook" }
        ]
      when "shopify"
        [
          { "propertyName" => "ip__shopify__orders_count", "operator" => "GT", "value" => "0" },
          { "propertyName" => "b__shopify_eddm_order", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "shopify_amount_spent", "operator" => "GT", "value" => "0" },
          { "propertyName" => "ip__shopify__shopify_created_at", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "ip__shopify__tags", "operator" => "HAS_PROPERTY" },
          { "propertyName" => "hs_analytics_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*shopify*" },
          { "propertyName" => "hs_analytics_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*shopify*" },
          { "propertyName" => "hs_latest_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*shopify*" },
          { "propertyName" => "hs_latest_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*shopify*" },
          { "propertyName" => "crm_used", "operator" => "EQ", "value" => "Shopify" }
        ]
      when "haymarket"
        [
          { "propertyName" => "crm_used", "operator" => "EQ", "value" => "Haymarket" },
          { "propertyName" => "crm_used", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_analytics_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_analytics_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_latest_source_data_1", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_latest_source_data_2", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_object_source_label", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_object_source_detail_1", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_object_source_detail_2", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" },
          { "propertyName" => "hs_object_source_detail_3", "operator" => "CONTAINS_TOKEN", "value" => "*haymarket*" }
        ]
      else
        []
      end
    end

    def upsert_contact(payload, sync_started_at:)
      hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
      raise Error, "HubSpot contact payload missing id." if hubspot_id.blank?

      properties = payload.fetch("properties", {}).to_h
      record = organization.crm_records.find_or_initialize_by(source: "hubspot_contact", source_uid: hubspot_id)
      created = record.new_record?
      before = record.attributes.slice("name", "email", "phone", "domain", "stage", "status", "properties")
      record.assign_attributes(attributes_for(payload, properties, hubspot_id, sync_started_at:))
      record.save!
      persist_ingestion_event(record, payload)
      enqueue_embedding_source(record)
      associations = sync_associated_records(record, hubspot_id, sync_started_at:)

      state = if created
        :created
      elsif before != record.reload.attributes.slice("name", "email", "phone", "domain", "stage", "status", "properties")
        :updated
      else
        :unchanged
      end

      [record, state, associations]
    end

    def attributes_for(payload, properties, hubspot_id, sync_started_at:)
      existing_hubspot = organization.crm_records.find_by(source: "hubspot_contact", source_uid: hubspot_id)&.properties.to_h.fetch("hubspot", {}).to_h
      detected_sources = detected_lead_sources(properties)
      lead_source = source == ALL_CONTACTS_SOURCE ? detected_sources.first.presence || ALL_CONTACTS_SOURCE : source
      lead_sources = (Array(existing_hubspot["lead_sources"]) | detected_sources | [lead_source]).compact_blank
      phone = properties["phone"].presence || properties["mobilephone"].presence || properties["hs_calculated_phone_number"].presence || properties["hs_calculated_mobile_number"].presence
      {
        record_type: "contact",
        name: contact_name(properties, hubspot_id),
        email: properties["email"].presence,
        phone: phone,
        status: "active",
        properties: {
          "hubspot" => existing_hubspot.deep_merge(
            "object_type" => "contact",
            "id" => hubspot_id,
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "last_synced_at" => sync_started_at.iso8601,
            "sync_window_start" => since&.to_time&.iso8601,
            "lead_source" => lead_source,
            "lead_sources" => lead_sources,
            "lead_source_synced_at" => sync_started_at.iso8601,
            "lead_source_filters" => source_filters.filter_map { |filter| filter&.fetch("propertyName", nil) },
            "properties" => compact_hash(properties)
          )
        }
      }
    end

    def detected_lead_sources(properties)
      sources = []
      sources << "facebook" if facebook_contact?(properties)
      sources << "shopify" if shopify_contact?(properties)
      sources << "haymarket" if haymarket_contact?(properties)
      sources
    end

    def facebook_contact?(properties)
      [
        properties["hs_facebook_click_id"],
        properties["hs_facebookid"],
        properties["facebook_messenger_conversion"]
      ].any?(&:present?) ||
        truthy?(properties["hs_facebook_ad_clicked"]) ||
        truthy?(properties["facebook_inquiry"]) ||
        source_text(properties).include?("facebook") ||
        properties["crm_used"].to_s.casecmp("Facebook").zero?
    end

    def shopify_contact?(properties)
      [
        properties["b__shopify_eddm_order"],
        properties["ip__shopify__shopify_created_at"],
        properties["ip__shopify__tags"]
      ].any?(&:present?) ||
        properties["ip__shopify__orders_count"].to_i.positive? ||
        properties["shopify_amount_spent"].to_f.positive? ||
        source_text(properties).include?("shopify") ||
        properties["crm_used"].to_s.casecmp("Shopify").zero?
    end

    def haymarket_contact?(properties)
      source_text(properties).include?("haymarket") ||
        properties["crm_used"].to_s.downcase.include?("haymarket")
    end

    def source_text(properties)
      [
        properties["hs_analytics_source_data_1"],
        properties["hs_analytics_source_data_2"],
        properties["hs_latest_source_data_1"],
        properties["hs_latest_source_data_2"],
        properties["hs_object_source_label"],
        properties["hs_object_source_detail_1"],
        properties["hs_object_source_detail_2"],
        properties["hs_object_source_detail_3"]
      ].compact.join(" ").downcase
    end

    def truthy?(value)
      %w[true 1 yes y].include?(value.to_s.strip.downcase)
    end

    def contact_name(properties, hubspot_id)
      [properties["firstname"], properties["lastname"]].compact_blank.join(" ").presence ||
        properties["company"].presence ||
        properties["email"].presence ||
        "HubSpot Contact #{hubspot_id}"
    end

    def sync_associated_records(record, hubspot_id, sync_started_at:)
      result = Hubspot::AssociatedRecordSync.call(
        organization: organization,
        from_record: record,
        from_object_type: "contacts",
        from_object_id: hubspot_id,
        client: client
      )

      properties = record.properties.to_h
      hubspot = properties.fetch("hubspot", {}).to_h
      hubspot["association_sync"] = result.to_h.merge("synced_at" => sync_started_at.iso8601)
      hubspot["last_synced_at"] = sync_started_at.iso8601
      properties["hubspot"] = hubspot
      record.update_column(:properties, properties)
      result.associated_count
    rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[Hubspot::ContactLeadSync] association sync failed contact=#{hubspot_id}: #{error.class}: #{error.message}")
      0
    end

    def persist_ingestion_event(record, payload)
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      event = organization.ingestion_events.find_or_initialize_by(source: "hubspot_contact_#{source}", source_uid: record.source_uid)
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

    def enqueue_embedding_source(record)
      return unless record.present?
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
      return if record.is_a?(CrmRecord) && !Autos::EmbeddingQueue.crm_immediate_enqueue_enabled?

      Autos::EmbeddingQueue.enqueue_source!(record)
    rescue StandardError => error
      Rails.logger.warn("[Hubspot::ContactLeadSync] embedding enqueue failed contact=#{record&.id}: #{error.class}: #{error.message}")
    end

    def contact_property_names
      DEFAULT_CONTACT_PROPERTIES.uniq
    end

    def hubspot_milliseconds(time)
      (time.to_time.to_f * 1000).round
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), memo|
        next if value.blank?

        memo[key] = value
      end
    end
  end
end
