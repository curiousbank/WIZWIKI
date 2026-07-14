require "digest"
require "set"

module Hubspot
  class PlaybookCallSync
    DEFAULT_PAGE_SIZE = 100
    DEFAULT_DIRECT_CALL_LIMIT = 250
    ASSOCIATED_OBJECT_TYPES = %w[tickets companies contacts deals].freeze
    CALL_PROPERTIES = %w[
      hs_object_id hs_timestamp hs_createdate hs_lastmodifieddate hubspot_owner_id
      hs_call_title hs_call_body hs_body_preview hs_body_preview_html hs_call_summary
      hs_call_suggested_next_actions hs_call_status hs_call_direction hs_call_disposition
      hs_call_duration hs_call_recording_url hs_call_video_recording_url
      hs_call_has_transcript hs_call_transcription_id hs_call_zoom_meeting_uuid
      hs_call_meeting_id hs_call_video_meeting_type hs_call_source hs_activity_type
      hs_call_deal_stage_during_call hs_call_owner_talk_time hs_call_owner_talk_time_percentage
      hs_call_interactivity hs_call_patience hs_call_longest_customer_story
      hs_call_owner_longest_monologue hs_call_recording_duration
    ].freeze

    Result = Data.define(:created_count, :updated_count, :unchanged_count, :ticket_count, :call_count, :error_count) do
      def total_count
        created_count + updated_count + unchanged_count
      end

      def to_h
        {
          created: created_count,
          updated: updated_count,
          unchanged: unchanged_count,
          total: total_count,
          ticket_count: ticket_count,
          call_count: call_count,
          errors: error_count
        }
      end
    end

    def self.call(organization:, since: 90.days.ago, limit: nil, client: Client.new)
      new(organization: organization, since: since, limit: limit, client: client).call
    end

    def initialize(organization:, since:, limit:, client:)
      @organization = organization
      @since = since
      @limit = normalize_limit(limit)
      @client = client
      @owners_by_id = nil
    end

    def call
      created_count = 0
      updated_count = 0
      unchanged_count = 0
      error_count = 0
      scanned_ticket_count = 0
      seen_call_ids = Set.new
      sync_started_at = Time.current

      each_recent_call_id do |call_id|
        next if seen_call_ids.include?(call_id)
        break if sync_limit.present? && seen_call_ids.size >= sync_limit

        seen_call_ids << call_id
        call_record, state = upsert_call(nil, call_id, sync_started_at: sync_started_at)
        persist_ingestion_event(call_record)
        case state
        when :created then created_count += 1
        when :updated then updated_count += 1
        else unchanged_count += 1
        end
      rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
        error_count += 1
        Rails.logger.warn("HubSpot direct playbook call sync failed for call=#{call_id}: #{error.class} #{error.message}")
      end

      ticket_scope.reorder(nil).find_each do |ticket|
        scanned_ticket_count += 1
        break if sync_limit.present? && seen_call_ids.size >= sync_limit

        call_ids_for_ticket(ticket).each do |call_id|
          next if seen_call_ids.include?(call_id)
          break if sync_limit.present? && seen_call_ids.size >= sync_limit

          seen_call_ids << call_id
          call_record, state = upsert_call(ticket, call_id, sync_started_at: sync_started_at)
          persist_ingestion_event(call_record)
          case state
          when :created then created_count += 1
          when :updated then updated_count += 1
          else unchanged_count += 1
          end
        rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
          error_count += 1
          Rails.logger.warn("HubSpot playbook call sync failed for ticket=#{ticket.id} call=#{call_id}: #{error.class} #{error.message}")
        end
      end

      Result.new(
        created_count: created_count,
        updated_count: updated_count,
        unchanged_count: unchanged_count,
        ticket_count: scanned_ticket_count,
        call_count: seen_call_ids.size,
        error_count: error_count
      )
    end

    private

    attr_reader :organization, :since, :limit, :client

    def normalize_limit(value)
      return nil if value.nil? || value.to_s.strip.blank? || value.to_s == "all"

      value.to_i.clamp(1, 10_000)
    end

    def sync_limit
      @sync_limit ||= limit.presence || ENV.fetch("HUBSPOT_PLAYBOOK_CALL_LIMIT", DEFAULT_DIRECT_CALL_LIMIT).to_i.clamp(1, 10_000)
    end

    def ticket_scope
      scope = organization.crm_records.where(record_type: "ticket", source: "hubspot_ticket").where.not(status: "archived")
      if since.present?
        scope = scope.where("created_at >= ? OR updated_at >= ? OR properties #>> '{hubspot,created_at}' >= ?", since, since, since.to_time.iso8601)
      end
      scope.order(updated_at: :desc)
    end

    def call_ids_for_ticket(ticket)
      hubspot_ticket_id = ticket.source_uid.to_s
      return [] if hubspot_ticket_id.blank?

      association_ids("tickets", hubspot_ticket_id, "calls")
    end

    def association_ids(from_object_type, from_object_id, to_object_type)
      ids = []
      after = nil

      loop do
        params = { limit: DEFAULT_PAGE_SIZE }
        params[:after] = after if after.present?
        response = client.get("/crm/v4/objects/#{from_object_type}/#{from_object_id}/associations/#{to_object_type}", params)
        ids.concat(Array(response["results"]).filter_map { |item| item["toObjectId"].presence || item["id"].presence }.map(&:to_s))
        after = response.dig("paging", "next", "after")
        break if after.blank?
      end

      ids.uniq
    end

    def each_recent_call_id
      after = nil
      yielded = 0

      loop do
        response = client.post("/crm/v3/objects/calls/search", call_search_body(after))
        Array(response["results"]).each do |payload|
          break if yielded >= sync_limit

          call_id = payload["id"].presence || payload.dig("properties", "hs_object_id").presence
          next if call_id.blank?

          yield call_id.to_s
          yielded += 1
        end
        break if yielded >= sync_limit

        after = response.dig("paging", "next", "after")
        break if after.blank?
      end
    end

    def call_search_body(after)
      filters = [
        {
          "propertyName" => "hs_call_body",
          "operator" => "HAS_PROPERTY"
        }
      ]
      if since.present?
        filters.unshift(
          {
            "propertyName" => "hs_timestamp",
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
            "propertyName" => "hs_timestamp",
            "direction" => "DESCENDING"
          }
        ],
        "properties" => CALL_PROPERTIES,
        "limit" => [sync_limit, DEFAULT_PAGE_SIZE].min
      }
      body["after"] = after if after.present?
      body
    end

    def upsert_call(ticket, call_id, sync_started_at:)
      payload = fetch_call(call_id)
      properties = payload.fetch("properties", {}).to_h
      associations = associations_for_call(call_id, fallback_ticket: ticket)
      primary_record = primary_record_for(associations, fallback_ticket: ticket)
      playbook_call = organization.playbook_calls.find_or_initialize_by(hubspot_call_id: call_id.to_s)
      created = playbook_call.new_record?
      before = playbook_call.attributes.except("updated_at", "created_at")

      playbook_call.assign_attributes(attributes_for(
        payload: payload,
        properties: properties,
        associations: associations,
        primary_record: primary_record,
        sync_started_at: sync_started_at
      ))
      playbook_call.save!
      hydrate_associated_records(call_id, primary_record: primary_record)

      if playbook_call.crm_record.blank?
        hydrated_primary_record = primary_record_for(associations, fallback_ticket: ticket)
        playbook_call.update!(crm_record: hydrated_primary_record) if hydrated_primary_record.present?
      end

      state = if created
        :created
      elsif before != playbook_call.reload.attributes.except("updated_at", "created_at")
        :updated
      else
        :unchanged
      end

      [playbook_call, state]
    end

    def hydrate_associated_records(call_id, primary_record:)
      Hubspot::AssociatedRecordSync.call(
        organization: organization,
        from_record: primary_record,
        from_object_type: "calls",
        from_object_id: call_id,
        client: client
      )
    rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("HubSpot playbook associated record hydration failed for call=#{call_id}: #{error.class} #{error.message}")
      nil
    end

    def fetch_call(call_id)
      client.get("/crm/v3/objects/calls/#{call_id}", properties: CALL_PROPERTIES.join(","), archived: false)
    end

    def associations_for_call(call_id, fallback_ticket:)
      ASSOCIATED_OBJECT_TYPES.each_with_object({}) do |object_type, memo|
        ids = association_ids("calls", call_id, object_type)
        ids << fallback_ticket.source_uid.to_s if object_type == "tickets" && fallback_ticket&.source_uid.present?
        memo[object_type] = ids.uniq
      rescue Hubspot::Error => error
        Rails.logger.warn("HubSpot playbook call associations unavailable for call=#{call_id} -> #{object_type}: #{error.message}")
        memo[object_type] = object_type == "tickets" && fallback_ticket&.source_uid.present? ? [fallback_ticket.source_uid.to_s] : []
      end
    end

    def primary_record_for(associations, fallback_ticket:)
      ticket_ids = Array(associations["tickets"]).map(&:to_s)
      record = organization.crm_records.find_by(source: "hubspot_ticket", source_uid: ticket_ids) if ticket_ids.present?
      return record if record.present?

      {
        "deals" => "hubspot",
        "companies" => "hubspot_company",
        "contacts" => "hubspot_contact"
      }.each do |object_type, source|
        ids = Array(associations[object_type]).map(&:to_s)
        record = organization.crm_records.find_by(source: source, source_uid: ids) if ids.present?
        return record if record.present?
      end

      fallback_ticket
    end

    def attributes_for(payload:, properties:, associations:, primary_record:, sync_started_at:)
      title = clean_text(properties["hs_call_title"]).presence || "HubSpot playbook call #{payload["id"]}"
      notes = html_to_text(properties["hs_call_body"].presence || properties["hs_body_preview_html"].presence || properties["hs_body_preview"])
      summary = clean_text(properties["hs_call_summary"])
      next_actions = clean_text(properties["hs_call_suggested_next_actions"])
      analyzer_text = analyzer_text_for(title: title, properties: properties, notes: notes, summary: summary, next_actions: next_actions)

      {
        crm_record: primary_record,
        title: title,
        status: "synced",
        call_status: properties["hs_call_status"].presence,
        call_direction: properties["hs_call_direction"].presence,
        call_disposition: properties["hs_call_disposition"].presence,
        owner_id: properties["hubspot_owner_id"].presence,
        owner_name: owner_name_for(properties["hubspot_owner_id"]),
        occurred_at: time_for(properties["hs_timestamp"] || properties["hs_createdate"] || payload["createdAt"]),
        duration_ms: integer_for(properties["hs_call_duration"]),
        has_transcript: ActiveModel::Type::Boolean.new.cast(properties["hs_call_has_transcript"]) == true,
        transcription_id: properties["hs_call_transcription_id"].presence,
        zoom_meeting_uuid: properties["hs_call_zoom_meeting_uuid"].presence,
        meeting_id: properties["hs_call_meeting_id"].presence,
        recording_url: properties["hs_call_recording_url"].presence,
        video_recording_url: properties["hs_call_video_recording_url"].presence,
        summary: summary,
        notes: notes,
        suggested_next_actions: next_actions,
        analyzer_text: analyzer_text,
        playbook_data: playbook_data_for(properties, analyzer_text),
        associations: associations,
        raw_payload: payload,
        metadata: {
          "hubspot" => {
            "object_type" => "call",
            "id" => payload["id"].presence || properties["hs_object_id"],
            "archived" => payload["archived"],
            "created_at" => payload["createdAt"].presence || properties["hs_createdate"],
            "updated_at" => payload["updatedAt"].presence || properties["hs_lastmodifieddate"],
            "last_synced_at" => sync_started_at.iso8601
          }
        },
        last_synced_at: sync_started_at
      }
    end

    def analyzer_text_for(title:, properties:, notes:, summary:, next_actions:)
      [
        "PLAYBOOK CALL: #{title}",
        properties["hs_call_source"].present? ? "source=#{properties["hs_call_source"]}" : nil,
        properties["hs_activity_type"].present? ? "activity_type=#{properties["hs_activity_type"]}" : nil,
        properties["hs_call_deal_stage_during_call"].present? ? "deal_stage_during_call=#{properties["hs_call_deal_stage_during_call"]}" : nil,
        summary.present? ? "SUMMARY\n#{summary}" : nil,
        next_actions.present? ? "SUGGESTED NEXT ACTIONS\n#{next_actions}" : nil,
        notes.present? ? "CALL NOTES / PLAYBOOK ANSWERS\n#{notes}" : nil,
        conversation_metrics(properties).presence
      ].compact.join("\n\n").truncate(8_000, omission: "\n...")
    end

    def playbook_data_for(properties, analyzer_text)
      {
        "source" => properties["hs_call_source"],
        "activity_type" => properties["hs_activity_type"],
        "deal_stage_during_call" => properties["hs_call_deal_stage_during_call"],
        "has_transcript" => ActiveModel::Type::Boolean.new.cast(properties["hs_call_has_transcript"]) == true,
        "conversation_metrics" => conversation_metric_hash(properties),
        "analyzer_digest" => Digest::SHA256.hexdigest(analyzer_text.to_s)
      }.compact
    end

    def conversation_metrics(properties)
      values = conversation_metric_hash(properties)
      return if values.blank?

      "CONVERSATION METRICS\n" + values.map { |key, value| "#{key}=#{value}" }.join(" | ")
    end

    def conversation_metric_hash(properties)
      {
        "owner_talk_time_ms" => properties["hs_call_owner_talk_time"],
        "owner_talk_time_percentage" => properties["hs_call_owner_talk_time_percentage"],
        "interactivity" => properties["hs_call_interactivity"],
        "patience" => properties["hs_call_patience"],
        "longest_customer_story" => properties["hs_call_longest_customer_story"],
        "owner_longest_monologue" => properties["hs_call_owner_longest_monologue"]
      }.compact_blank
    end

    def persist_ingestion_event(playbook_call)
      digest = Digest::SHA256.hexdigest(JSON.generate(playbook_call.raw_payload))
      event = organization.ingestion_events.find_or_initialize_by(source: "hubspot_playbook_call", source_uid: playbook_call.hubspot_call_id)
      event.assign_attributes(
        crm_record: playbook_call.crm_record,
        payload_digest: digest,
        raw_payload: playbook_call.raw_payload,
        status: "accepted"
      )
      event.save!
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def owner_name_for(owner_id)
      id = owner_id.to_s
      return if id.blank?
      return id unless ActiveModel::Type::Boolean.new.cast(ENV["HUBSPOT_OWNER_LOOKUP_ENABLED"])

      owner = owners_by_id[id]
      return id if owner.blank?

      [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence || owner["email"].presence || id
    end

    def owners_by_id
      @owners_by_id ||= Array(client.get("/crm/v3/owners", archived: false)["results"]).index_by { |owner| owner["id"].to_s }
    rescue Error => error
      Rails.logger.warn("HubSpot owners unavailable for playbook call sync: #{error.message}")
      @owners_by_id = {}
    end

    def html_to_text(value)
      clean_text(ActionView::Base.full_sanitizer.sanitize(value.to_s))
    end

    def clean_text(value)
      value.to_s.gsub(/\r\n?/, "\n").gsub(/\u00a0/, " ").gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
    end

    def time_for(value)
      return if value.blank?

      text = value.to_s
      if text.match?(/\A\d{13}\z/)
        Time.zone.at(text.to_i / 1000.0)
      else
        Time.zone.parse(text)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def integer_for(value)
      value.to_s.gsub(/[^0-9\-]/, "").presence&.to_i
    end

    def hubspot_milliseconds(time)
      value = time.respond_to?(:to_time) ? time.to_time : Time.zone.parse(time.to_s)
      (value.to_f * 1000).to_i
    end
  end
end
