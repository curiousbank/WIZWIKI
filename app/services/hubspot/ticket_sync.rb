require "bigdecimal"
require "digest"

module Hubspot
  class TicketSync
    DEFAULT_PAGE_SIZE = 100

    DEFAULT_TICKET_PROPERTIES = %w[
      subject content createdate hs_lastmodifieddate hs_object_id hubspot_owner_id
      hs_pipeline hs_pipeline_stage hs_ticket_priority hs_ticket_category source_type
    ].freeze

    REPORT_PROPERTY_LABELS = [
      "Company Name",
      "Company Status",
      "New Company",
      "SAM New Record",
      "Ticket owner",
      "Record ID",
      "Ticket Status",
      "Ticket Pipeline",
      "Created Date",
      "Last Modified Date",
      "Agency Deal Type",
      "Last Contacted",
      "Latest Traffic Source",
      "Website URL",
      "Industry",
      "CRM Used",
      "Quote Purchase Link",
      "Shopify Payment Link",
      "Ticket Description",
      "Ticket Priority",
      "Ticket Category",
      "Ticket Source",
      "Free Postcard Logo"
    ].freeze

    PROPERTY_LABEL_ALIASES = {
      "Company Name" => ["Company Name*", "Company", "Associated Company"],
      "Company Status" => ["[S] - Company Status"],
      "New Company" => ["New or Repeat Business"],
      "SAM New Record" => ["SAM new record", "SAM Record", "SAM Status", "[S] - SAM New Record", "New Record Status"],
      "Ticket owner" => ["Ticket owner", "HubSpot owner"],
      "Ticket Status" => ["Ticket status", "Status", "Pipeline Stage"],
      "Ticket Description" => ["Description", "Ticket description", "Content"]
    }.freeze

    SAM_PROPERTY_ENV = "HUBSPOT_TICKET_SAM_PROPERTY".freeze
    SAM_VALUE_ENV = "HUBSPOT_TICKET_SAM_VALUE".freeze
    SAM_STAGE_ENV = "HUBSPOT_TICKET_SAM_STAGE".freeze
    TICKET_STATUS_PROPERTY = "hs_pipeline_stage".freeze
    DEFAULT_PIPELINE_LABEL = "SAM (New Account)".freeze

    Result = Data.define(:created_count, :updated_count, :unchanged_count, :archived_count, :records, :sam_property_name, :sam_filter, :sync_window_start) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          archived: archived_count,
          total: total_count,
          sam_property_name: sam_property_name,
          sam_filter: sam_filter,
          sync_window_start: sync_window_start&.iso8601
        }
      end
    end

    def self.call(organization:, since: 90.days.ago, limit: nil, create_only: false, prune_stale: false)
      new(organization:, since:, limit:, create_only:, prune_stale:).call
    end

    def self.ticket_pipeline_options(client: Client.new)
      Array(client.get("/crm/v3/pipelines/tickets")["results"]).map do |pipeline|
        {
          id: pipeline["id"].to_s,
          label: pipeline["label"].to_s.presence || pipeline["id"].to_s,
          stages: Array(pipeline["stages"]).sort_by { |stage| stage["displayOrder"].to_i }.map do |stage|
            {
              id: stage["id"].to_s,
              label: stage["label"].to_s.presence || stage["id"].to_s
            }
          end
        }
      end.sort_by { |pipeline| [pipeline[:label] == DEFAULT_PIPELINE_LABEL ? 0 : 1, pipeline[:label].downcase] }
    end

    def initialize(organization:, since:, limit:, create_only:, prune_stale:)
      @organization = organization
      @since = since
      @limit = normalize_limit(limit)
      @page_size = [@limit || DEFAULT_PAGE_SIZE, DEFAULT_PAGE_SIZE].min
      @create_only = create_only
      @prune_stale = prune_stale
      @client = Client.new
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      synced_records = []
      sync_started_at = Time.current

      each_ticket do |payload|
        record, state = upsert_ticket(payload, sync_started_at: sync_started_at)
        synced_records << record
        case state
        when :created then created_count += 1
        when :updated then updated_count += 1
        else unchanged_count += 1
        end
      end

      archived_count = prune_stale? ? archive_stale_records!(synced_records, sync_started_at:) : 0

      Result.new(
        created_count:,
        updated_count:,
        unchanged_count:,
        archived_count:,
        records: synced_records,
        sam_property_name: sam_property_name,
        sam_filter: sam_filter_summary,
        sync_window_start: since
      )
    end

    private

    attr_reader :organization, :since, :limit, :page_size, :client

    def create_only?
      @create_only
    end

    def prune_stale?
      @prune_stale
    end

    def normalize_limit(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s == "all"

      value.to_i.clamp(1, 10_000)
    end

    def each_ticket
      after = nil
      yielded = 0

      loop do
        response = client.post("/crm/v3/objects/tickets/search", search_body(after))
        Array(response["results"]).each do |payload|
          break if limit.present? && yielded >= limit

          yield payload
          yielded += 1
        end
        break if limit.present? && yielded >= limit

        after = response.dig("paging", "next", "after")
        break if after.blank?
      end
    end

    def search_body(after)
      filters = [sam_ticket_filter]
      if since.present?
        filters.unshift(
          {
            "propertyName" => "createdate",
            "operator" => "GTE",
            "value" => hubspot_milliseconds(since).to_s
          }
        )
      end

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
        "properties" => ticket_property_names,
        "limit" => page_size
      }
      body["after"] = after if after.present?
      body
    end

    def upsert_ticket(payload, sync_started_at:)
      hubspot_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
      raise Error, "HubSpot ticket payload missing id." if hubspot_id.blank?

      properties = payload.fetch("properties", {}).to_h
      normalize_display_properties!(properties)
      record = organization.crm_records.find_or_initialize_by(source: "hubspot_ticket", source_uid: hubspot_id)
      created = record.new_record?
      if create_only? && !created
        sync_associated_records(record, hubspot_id, sync_started_at: sync_started_at)
        return [record, :unchanged]
      end

      before = record.attributes.slice("name", "amount", "close_date", "stage", "status", "properties")
      manually_hidden = manually_hidden_from_report_queue?(record)
      attributes = attributes_for(payload, properties, hubspot_id, sync_started_at: sync_started_at)
      preserve_manual_queue_hide!(attributes, record) if manually_hidden

      record.assign_attributes(attributes)
      record.save!
      sync_associated_records(record, hubspot_id, sync_started_at: sync_started_at)
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

    def manually_hidden_from_report_queue?(record)
      return false unless record.persisted?

      hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
      record.status == "archived" && ActiveModel::Type::Boolean.new.cast(hubspot["manual_queue_hide"])
    end

    def preserve_manual_queue_hide!(attributes, record)
      previous_hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
      hubspot = attributes.fetch(:properties).fetch("hubspot")
      hubspot["manual_queue_hide"] = true
      hubspot["queue_hidden_at"] = previous_hubspot["queue_hidden_at"]
      hubspot["queue_hidden_reason"] = previous_hubspot["queue_hidden_reason"]
      attributes[:status] = "archived"
    end

    def attributes_for(payload, properties, hubspot_id, sync_started_at:)
      label_map = label_property_names
      labeled_properties = REPORT_PROPERTY_LABELS.each_with_object({}) do |label, memo|
        value = properties[label_map[label]] if label_map[label].present?
        memo[label] = value if value.present?
      end
      sam_value = sam_property_value(properties)
      labeled_properties["SAM New Record"] = sam_value if sam_value.present?
      labeled_properties["Ticket Status"] = properties["hs_pipeline_stage_label"] if properties["hs_pipeline_stage_label"].present?
      labeled_properties["Ticket Pipeline"] = properties["hs_pipeline_label"] if properties["hs_pipeline_label"].present?
      labeled_properties["Ticket owner"] = properties["hubspot_owner_name"] if properties["hubspot_owner_name"].present?
      labeled_properties["Ticket Priority"] = properties["hs_ticket_priority"] if properties["hs_ticket_priority"].present?
      labeled_properties["Ticket Category"] = properties["hs_ticket_category"] if properties["hs_ticket_category"].present?
      labeled_properties["Ticket Source"] = properties["source_type"] if properties["source_type"].present?
      labeled_properties["Record ID"] = hubspot_id

      {
        record_type: "ticket",
        name: ticket_name(properties, label_map, hubspot_id),
        amount: decimal_for(properties[label_map["Amount"]]),
        close_date: date_for(properties[label_map["Close Date"]]),
        stage: properties["hs_pipeline_stage_label"].presence || properties["hs_pipeline_stage"].presence || properties[label_map["Ticket Status"]].presence || sam_property_value(properties),
        status: status_for(properties["hs_pipeline_stage_label"] || properties["hs_pipeline_stage"] || sam_property_value(properties)),
        properties: {
          "hubspot" => {
            "object_type" => "ticket",
            "id" => hubspot_id,
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "last_synced_at" => sync_started_at.iso8601,
            "sync_window_start" => since&.to_time&.iso8601,
            "sam_property_name" => sam_property_name,
            "sam_filter" => sam_filter_summary,
            "label_property_names" => label_map,
            "property_labels" => property_labels_by_name,
            "labeled_properties" => labeled_properties,
            "properties" => properties
          }
        }
      }
    end

    def ticket_name(properties, label_map, hubspot_id)
      properties[label_map["Company Name"]].presence ||
        properties["company_name"].presence ||
        properties["subject"].presence ||
        properties["content"].to_s.truncate(80).presence ||
        "HubSpot Ticket #{hubspot_id}"
    end

    def sync_associated_records(record, hubspot_id, sync_started_at:)
      result = Hubspot::AssociatedRecordSync.call(
        organization: organization,
        from_record: record,
        from_object_type: "tickets",
        from_object_id: hubspot_id,
        client: client
      )

      properties = record.properties.to_h
      hubspot = properties.fetch("hubspot", {}).to_h
      hubspot["association_sync"] = result.to_h.merge("synced_at" => sync_started_at.iso8601)
      hubspot["last_synced_at"] = sync_started_at.iso8601
      hubspot["sync_window_start"] = since&.to_time&.iso8601
      properties["hubspot"] = hubspot
      record.update_column(:properties, properties)
      enqueue_embedding_source(record)
      result
    rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("HubSpot ticket association sync failed for #{hubspot_id}: #{error.class} #{error.message}")
      nil
    end

    def enqueue_embedding_source(record)
      return unless record.present?
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
      return if record.is_a?(CrmRecord) && !Autos::EmbeddingQueue.crm_immediate_enqueue_enabled?

      Autos::EmbeddingQueue.enqueue_source!(record)
    rescue StandardError => error
      Rails.logger.warn("HubSpot ticket embedding enqueue failed for #{record.class.name}/#{record.id}: #{error.class} #{error.message}")
    end

    def archive_stale_records!(synced_records, sync_started_at:)
      synced_source_uids = synced_records.filter_map(&:source_uid).map(&:to_s).uniq
      scope = organization.crm_records.where(record_type: "ticket", source: "hubspot_ticket").where.not(status: "archived")

      stale_records = if synced_source_uids.any?
        scope.where.not(source_uid: synced_source_uids)
      elsif since.present?
        scope.select { |record| hubspot_created_before_window?(record) }
      else
        []
      end

      archived_count = 0
      stale_records.each do |record|
        properties = record.properties.to_h
        hubspot = properties.fetch("hubspot", {}).to_h
        hubspot["last_synced_at"] = sync_started_at.iso8601
        hubspot["sync_window_start"] = since&.to_time&.iso8601
        hubspot["archived_from_queue_at"] = sync_started_at.iso8601
        hubspot["archive_reason"] = "not_returned_in_latest_90_day_ticket_sync"
        properties["hubspot"] = hubspot

        record.update_columns(status: "archived", properties: properties, updated_at: Time.current)
        archived_count += 1
      end

      archived_count
    end

    def hubspot_created_before_window?(record)
      created_at = record.properties.to_h.dig("hubspot", "created_at") || record.properties.to_h.dig("hubspot", "properties", "createdate")
      date_for(created_at)&.<(since.to_date)
    end

    def persist_ingestion_event(record, payload)
      source_uid = record.source_uid
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      event = organization.ingestion_events.find_or_initialize_by(source: "hubspot_ticket", source_uid: source_uid)
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

    def ticket_property_names
      @ticket_property_names ||= (DEFAULT_TICKET_PROPERTIES + label_property_names.values + [sam_property_name]).compact.uniq
    end

    def sam_property_name
      return @sam_property_name if defined?(@sam_property_name)

      override = ENV[SAM_PROPERTY_ENV].to_s.strip.presence
      @sam_property_name = override.presence || property_name_for_label("SAM New Record")
    end

    def sam_property_value(properties)
      name = sam_property_name
      properties[name] if name.present?
    end

    def sam_ticket_filter
      return @sam_ticket_filter if defined?(@sam_ticket_filter)

      override_property = ENV[SAM_PROPERTY_ENV].to_s.strip.presence
      override_value = ENV[SAM_VALUE_ENV].to_s.strip.presence
      if override_property.present?
        return @sam_ticket_filter = property_filter_for(override_property, override_value)
      end

      stage = sam_pipeline_stage
      if stage.present?
        return @sam_ticket_filter = {
          "propertyName" => TICKET_STATUS_PROPERTY,
          "operator" => "EQ",
          "value" => stage.fetch(:id)
        }
      end

      pipeline = sam_pipeline
      if pipeline.present?
        return @sam_ticket_filter = {
          "propertyName" => "hs_pipeline",
          "operator" => "EQ",
          "value" => pipeline.fetch(:id)
        }
      end

      name = sam_property_name
      if name.present?
        return @sam_ticket_filter = property_filter_for(name, override_value)
      end

      raise Error, "HubSpot ticket SAM selector was not found. Grant ticket schema access, or set #{SAM_STAGE_ENV} to the ticket stage id, or #{SAM_PROPERTY_ENV} to the internal ticket property name."
    end

    def property_filter_for(property_name, value)
      return { "propertyName" => property_name, "operator" => "EQ", "value" => value } if value.present?

      { "propertyName" => property_name, "operator" => "HAS_PROPERTY" }
    end

    def sam_filter_summary
      filter = sam_ticket_filter
      case filter["propertyName"]
      when TICKET_STATUS_PROPERTY
        stage = sam_pipeline_stage
        "ticket stage: #{stage&.fetch(:label, nil).presence || filter["value"]}"
      when "hs_pipeline"
        pipeline = sam_pipeline
        "ticket pipeline: #{pipeline&.fetch(:label, nil).presence || filter["value"]}"
      else
        filter["operator"] == "EQ" ? "#{filter["propertyName"]}=#{filter["value"]}" : "#{filter["propertyName"]} present"
      end
    end

    def sam_pipeline_stage
      return @sam_pipeline_stage if defined?(@sam_pipeline_stage)

      override = ENV[SAM_STAGE_ENV].to_s.strip.presence
      if override.present?
        return @sam_pipeline_stage = { id: override, label: override, pipeline_id: nil }
      end

      @sam_pipeline_stage = ticket_pipeline_stages.find { |stage| sam_stage_label?(stage[:label]) }
    end

    def sam_pipeline
      return @sam_pipeline if defined?(@sam_pipeline)

      @sam_pipeline = ticket_pipeline_options.find { |option| option[:label].to_s == DEFAULT_PIPELINE_LABEL } ||
        ticket_pipeline_options.find { |option| option[:label].to_s.match?(/\bSAM\b/i) }
    end

    def sam_stage_label?(label)
      normalized = normalize_label(label)
      normalized == "sam new record" ||
        normalized == "new record" ||
        normalized == "new account" ||
        normalized.end_with?(" sam new record") ||
        (normalized.include?("sam") && normalized.include?("new") && normalized.include?("record"))
    end

    def ticket_pipeline_options
      @ticket_pipeline_options ||= self.class.ticket_pipeline_options(client: client)
    rescue Error => error
      Rails.logger.warn("HubSpot ticket pipelines unavailable: #{error.message}")
      []
    end

    def ticket_pipeline_stages
      @ticket_pipeline_stages ||= ticket_pipeline_options.flat_map do |pipeline|
        Array(pipeline[:stages]).map do |stage|
          {
            id: stage[:id].to_s,
            label: stage[:label].to_s.presence || stage[:id].to_s,
            pipeline_id: pipeline[:id].to_s,
            pipeline_label: pipeline[:label].to_s
          }
        end
      end
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
        candidate_label == normalized || candidate_label.end_with?(" #{normalized}") || candidate_label.include?(normalized)
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

      @property_definitions = Array(client.get("/crm/v3/properties/tickets")["results"])
    rescue Error => error
      Rails.logger.warn("HubSpot ticket property schema unavailable: #{error.message}")
      raise
    end

    def normalize_display_properties!(properties)
      stage_id = properties["hs_pipeline_stage"].presence
      pipeline_id = properties["hs_pipeline"].presence
      properties["hs_pipeline_stage_label"] = ticket_stage_label_for(pipeline_id, stage_id) if stage_id.present?
      properties["hs_pipeline_label"] = ticket_pipeline_label_for(pipeline_id) if pipeline_id.present?

      owner_id = properties["hubspot_owner_id"].presence
      properties["hubspot_owner_name"] = owner_name_for(owner_id) if owner_id.present?
    end

    def ticket_pipeline_label_for(pipeline_id)
      ticket_pipeline_options.find { |pipeline| pipeline[:id].to_s == pipeline_id.to_s }&.dig(:label) || pipeline_id
    end

    def ticket_stage_label_for(pipeline_id, stage_id)
      pipeline = ticket_pipeline_options.find { |option| option[:id].to_s == pipeline_id.to_s }
      stage = pipeline&.dig(:stages)&.find { |candidate| candidate[:id].to_s == stage_id.to_s }
      stage&.dig(:label).presence || stage_id
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
      return "lost" if cleaned.include?("abandon") || cleaned.include?("closed") || cleaned.include?("spam")
      return "closed" if cleaned.include?("done") || cleaned.include?("complete") || cleaned.include?("resolved")

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
