require "bigdecimal"
require "digest"

module Hubspot
  class DealSync
    DEFAULT_DEAL_PROPERTIES = %w[
      dealname amount closedate createdate hs_lastmodifieddate dealstage pipeline
      hubspot_owner_id dealtype description hs_object_id hs_analytics_source company_name
    ].freeze

    REPORT_PROPERTY_LABELS = [
      "Company Name",
      "Company Status",
      "New Company",
      "Shopify Order?",
      "Monday Order Number",
      "Deal owner",
      "Record ID",
      "Amount",
      "Deal Stage",
      "Close Date",
      "Deal Type",
      "Agency Deal Type",
      "Last Contacted",
      "Latest Traffic Source",
      "Website URL",
      "Industry",
      "CRM Used",
      "Quote Purchase Link",
      "Shopify Payment Link",
      "Deal Description",
      "Free Postcard Logo"
    ].freeze

    PROPERTY_LABEL_ALIASES = {
      "Company Name" => ["Company Name*"],
      "Company Status" => ["[S] - Company Status"],
      "New Company" => ["New or Repeat Business"]
    }.freeze

    Result = Data.define(:created_count, :updated_count, :unchanged_count, :records) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          total: total_count
        }
      end
    end

    def self.call(organization:, since: 30.days.ago, limit: 100, create_only: false)
      new(organization:, since:, limit:, create_only:).call
    end

    def initialize(organization:, since:, limit:, create_only:)
      @organization = organization
      @since = since
      @limit = limit.to_i.clamp(1, 500)
      @create_only = create_only
      @client = Client.new
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      synced_records = []

      each_deal do |payload|
        record, state = upsert_deal(payload)
        synced_records << record
        case state
        when :created then created_count += 1
        when :updated then updated_count += 1
        else unchanged_count += 1
        end
      end

      Result.new(created_count:, updated_count:, unchanged_count:, records: synced_records)
    end

    private

    attr_reader :organization, :since, :limit, :client

    def create_only?
      @create_only
    end

    def each_deal
      after = nil

      loop do
        response = client.post("/crm/v3/objects/deals/search", search_body(after))
        Array(response["results"]).each { |payload| yield payload }
        after = response.dig("paging", "next", "after")
        break if after.blank?
      end
    end

    def search_body(after)
      body = {
        "filterGroups" => [
          {
            "filters" => [
              {
                "propertyName" => "createdate",
                "operator" => "GTE",
                "value" => hubspot_milliseconds(since).to_s
              }
            ]
          }
        ],
        "sorts" => [
          {
            "propertyName" => "createdate",
            "direction" => "DESCENDING"
          }
        ],
        "properties" => deal_property_names,
        "limit" => limit
      }
      body["after"] = after if after.present?
      body
    end

    def upsert_deal(payload)
      hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
      raise Error, "HubSpot deal payload missing id." if hubspot_id.blank?

      properties = payload.fetch("properties", {}).to_h
      normalize_display_properties!(properties)
      record = organization.crm_records.find_or_initialize_by(source: "hubspot", source_uid: hubspot_id)
      created = record.new_record?
      return [record, :unchanged] if create_only? && !created

      before = record.attributes.slice("name", "amount", "close_date", "stage", "status", "properties")

      record.assign_attributes(attributes_for(payload, properties, hubspot_id))
      record.save!
      persist_ingestion_event(record, payload)

      state = if created
        :created
      elsif before != record.reload.attributes.slice("name", "amount", "close_date", "stage", "status", "properties")
        :updated
      else
        :unchanged
      end

      [record, state]
    end

    def attributes_for(payload, properties, hubspot_id)
      label_map = label_property_names
      labeled_properties = REPORT_PROPERTY_LABELS.each_with_object({}) do |label, memo|
        value = properties[label_map[label]] if label_map[label].present?
        memo[label] = value if value.present?
      end
      labeled_properties["Deal Stage"] = properties["dealstage_label"] if properties["dealstage_label"].present?
      labeled_properties["Deal owner"] = properties["hubspot_owner_name"] if properties["hubspot_owner_name"].present?
      labeled_properties["Record ID"] = hubspot_id

      {
        record_type: "deal",
        name: properties["dealname"].presence || properties["company_name"].presence || properties[label_map["Company Name"]].presence || "HubSpot Deal #{hubspot_id}",
        amount: decimal_for(properties["amount"] || properties[label_map["Amount"]]),
        close_date: date_for(properties["closedate"] || properties[label_map["Close Date"]]),
        stage: properties["dealstage_label"].presence || properties["dealstage"].presence || properties[label_map["Deal Stage"]].presence,
        status: status_for(properties["dealstage_label"] || properties["dealstage"] || properties[label_map["Deal Stage"]]),
        properties: {
          "hubspot" => {
            "id" => hubspot_id,
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "label_property_names" => label_map,
            "property_labels" => property_labels_by_name,
            "labeled_properties" => labeled_properties,
            "properties" => properties
          }
        }
      }
    end

    def persist_ingestion_event(record, payload)
      source_uid = record.source_uid
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      event = organization.ingestion_events.find_or_initialize_by(source: "hubspot_deal", source_uid: source_uid)
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

    def deal_property_names
      @deal_property_names ||= (DEFAULT_DEAL_PROPERTIES + label_property_names.values).compact.uniq
    end

    def label_property_names
      @label_property_names ||= REPORT_PROPERTY_LABELS.each_with_object({}) do |label, memo|
        name = property_name_for_label(label)
        memo[label] = name if name.present?
      end
    end

    def property_name_for_label(label)
      labels = [label] + PROPERTY_LABEL_ALIASES.fetch(label, [])
      labels.each do |candidate|
        definition = property_definitions_by_label[normalize_label(candidate)]
        return definition["name"] if definition.present?
      end

      normalized = normalize_label(label)
      definition = property_definitions.find do |candidate|
        candidate_label = normalize_label(candidate["label"])
        candidate_label == normalized || candidate_label.end_with?(" #{normalized}")
      end
      definition&.fetch("name", nil)
    end

    def property_labels_by_name
      @property_labels_by_name ||= property_definitions.each_with_object({}) do |definition, memo|
        name = definition["name"].to_s
        next if name.blank?

        memo[name] = definition["label"].to_s.presence || name
      end
    end

    def property_definitions_by_label
      @property_definitions_by_label ||= property_definitions.index_by { |definition| normalize_label(definition["label"]) }
    end

    def property_definitions
      return @property_definitions if defined?(@property_definitions)

      @property_definitions = Array(client.get("/crm/v3/properties/deals")["results"])
    rescue Error => error
      Rails.logger.warn("HubSpot deal property schema unavailable: #{error.message}")
      @property_definitions = []
    end

    def normalize_display_properties!(properties)
      stage_id = properties["dealstage"].presence
      pipeline_id = properties["pipeline"].presence
      properties["dealstage_label"] = deal_stage_label_for(pipeline_id, stage_id) if stage_id.present?

      owner_id = properties["hubspot_owner_id"].presence
      properties["hubspot_owner_name"] = owner_name_for(owner_id) if owner_id.present?
    end

    def deal_stage_label_for(pipeline_id, stage_id)
      pipeline_stage_labels[[pipeline_id, stage_id]] || pipeline_stage_labels[stage_id] || stage_id
    end

    def pipeline_stage_labels
      return @pipeline_stage_labels if defined?(@pipeline_stage_labels)

      @pipeline_stage_labels = Array(client.get("/crm/v3/pipelines/deals")["results"]).each_with_object({}) do |pipeline, memo|
        pipeline_id = pipeline["id"].to_s
        Array(pipeline["stages"]).each do |stage|
          stage_id = stage["id"].to_s
          label = stage["label"].to_s.presence || stage_id
          memo[[pipeline_id, stage_id]] = label
          memo[stage_id] ||= label
        end
      end
    rescue Error => error
      Rails.logger.warn("HubSpot deal pipeline schema unavailable: #{error.message}")
      @pipeline_stage_labels = {}
    end

    def owner_name_for(owner_id)
      owner = owners_by_id[owner_id.to_s]
      return if owner.blank?

      [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence || owner["email"].presence || owner_id
    end

    def owners_by_id
      return @owners_by_id if defined?(@owners_by_id)

      @owners_by_id = Array(client.get("/crm/v3/owners", archived: false)["results"]).index_by { |owner| owner["id"].to_s }
    rescue Error => error
      Rails.logger.warn("HubSpot owners unavailable: #{error.message}")
      @owners_by_id = {}
    end

    def status_for(stage)
      cleaned = stage.to_s.downcase
      return "won" if cleaned.include?("closedwon") || cleaned.include?("closed_won") || cleaned == "won"
      return "lost" if cleaned.include?("closedlost") || cleaned.include?("closed_lost") || cleaned == "lost"

      "open"
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

    def hubspot_milliseconds(time)
      value = time.respond_to?(:to_time) ? time.to_time : Time.zone.parse(time.to_s)
      (value.to_f * 1000).to_i
    end

    def normalize_label(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end
  end
end
