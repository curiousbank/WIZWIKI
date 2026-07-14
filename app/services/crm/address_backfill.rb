module Crm
  class AddressBackfill
    Result = Data.define(:crm_records_scanned, :playbook_calls_scanned, :addresses_upserted, :addresses_pruned) do
      def to_h
        {
          crm_records_scanned: crm_records_scanned,
          playbook_calls_scanned: playbook_calls_scanned,
          addresses_upserted: addresses_upserted,
          addresses_pruned: addresses_pruned
        }
      end
    end

    def self.call(organization:, limit: nil, record_types: nil, include_playbooks: true)
      new(organization: organization, limit: limit, record_types: record_types, include_playbooks: include_playbooks).call
    end

    def self.storage_ready?
      ActiveRecord::Base.connection.table_exists?(:crm_address_records)
    rescue StandardError
      false
    end

    def self.extract_record!(record)
      new(organization: record.organization).extract_record!(record)
    end

    def self.extract_playbook_call!(call)
      new(organization: call.organization).extract_playbook_call!(call)
    end

    def initialize(organization:, limit: nil, record_types: nil, include_playbooks: true)
      @organization = organization
      @limit = limit
      @record_types = Array(record_types).map(&:to_s).reject(&:blank?)
      @include_playbooks = include_playbooks
      @crm_records_scanned = 0
      @playbook_calls_scanned = 0
      @addresses_upserted = 0
      @addresses_pruned = 0
    end

    def call
      return Result.new(crm_records_scanned: 0, playbook_calls_scanned: 0, addresses_upserted: 0, addresses_pruned: 0) unless self.class.storage_ready?

      crm_scope.find_each { |record| extract_record!(record) }
      playbook_scope.find_each { |call| extract_playbook_call!(call) } if include_playbooks

      Result.new(
        crm_records_scanned: @crm_records_scanned,
        playbook_calls_scanned: @playbook_calls_scanned,
        addresses_upserted: @addresses_upserted,
        addresses_pruned: @addresses_pruned
      )
    end

    def extract_record!(record)
      @crm_records_scanned += 1
      hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
      candidates = Crm::AddressExtractor.call(record.properties, label_map: hubspot.fetch("property_labels", {}).to_h)
      upsert_candidates!(
        candidates,
        source: record,
        crm_record: record,
        record_type: record.record_type,
        association_context: association_context_for(record)
      )
    end

    def extract_playbook_call!(call)
      @playbook_calls_scanned += 1
      payload = {
        "associations" => call.associations,
        "playbook_data" => call.playbook_data,
        "raw_payload" => call.raw_payload
      }
      candidates = Crm::AddressExtractor.call(payload)
      upsert_candidates!(
        candidates,
        source: call,
        playbook_call: call,
        crm_record: call.crm_record,
        record_type: call.crm_record&.record_type,
        association_context: playbook_context_for(call)
      )
    end

    private

    attr_reader :organization, :limit, :record_types, :include_playbooks

    def crm_scope
      scope = organization.crm_records.order(updated_at: :desc)
      scope = scope.where(record_type: record_types) if record_types.present?
      limit.present? ? scope.limit(limit) : scope
    end

    def playbook_scope
      scope = organization.playbook_calls.order(updated_at: :desc)
      limit.present? ? scope.limit(limit) : scope
    end

    def upsert_candidates!(candidates, source:, crm_record:, playbook_call: nil, record_type:, association_context:)
      source_key = "#{source.class.name}:#{source.id}"
      active_paths = candidates.map(&:source_path)

      candidates.each do |candidate|
        row = organization.crm_address_records.find_or_initialize_by(source_key: source_key, source_path: candidate.source_path)
        row.assign_attributes(
          crm_record: crm_record,
          playbook_call: playbook_call,
          source_type: source.class.name,
          source_id: source.id,
          source_label: candidate.source_label,
          record_type: record_type,
          address_kind: candidate.address_kind,
          address1: candidate.address1,
          address2: candidate.address2,
          city: candidate.city,
          state: candidate.state,
          postal_code: candidate.postal_code,
          country: candidate.country,
          address_line: candidate.address_line,
          address_one_line: candidate.address_one_line,
          normalized_key: candidate.normalized_key,
          confidence: candidate.confidence,
          raw_components: candidate.raw_components,
          association_context: association_context,
          metadata: candidate.metadata.to_h.merge("source_updated_at" => source.updated_at&.iso8601)
        )
        row.save!
        @addresses_upserted += 1
      end

      pruned = organization.crm_address_records
        .where(source_key: source_key)
        .where.not(source_path: active_paths.presence || [""])
        .destroy_all
      @addresses_pruned += pruned.length
    end

    def association_context_for(record)
      outbound = record.outbound_associations.includes(:to_record).limit(25).map do |association|
        association_payload(association, association.to_record)
      end
      inbound = record.inbound_associations.includes(:from_record).limit(25).map do |association|
        association_payload(association, association.from_record)
      end

      {
        source_record: record_payload(record),
        outbound: outbound,
        inbound: inbound
      }
    end

    def playbook_context_for(call)
      {
        playbook_call: {
          id: call.id,
          hubspot_call_id: call.hubspot_call_id,
          title: call.title,
          occurred_at: call.occurred_at&.iso8601
        }.compact,
        crm_record: call.crm_record.present? ? record_payload(call.crm_record) : nil,
        hubspot_associations: call.associations.to_h
      }.compact
    end

    def association_payload(association, associated_record)
      {
        association_type: association.association_type,
        record: associated_record.present? ? record_payload(associated_record) : nil
      }.compact
    end

    def record_payload(record)
      {
        id: record.id,
        record_type: record.record_type,
        name: record.name,
        source: record.source,
        source_uid: record.source_uid,
        email_present: record.email.present?,
        phone_present: record.phone.present?,
        domain: record.domain
      }.compact
    end
  end
end
