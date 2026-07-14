module Crm
  class RecordCreator
    Result = Data.define(:record, :duplicate_record, :duplicate_candidates)

    def self.call(organization:, owner:, attributes:)
      new(organization:, owner:, attributes:).call
    end

    def initialize(organization:, owner:, attributes:)
      @organization = organization
      @owner = owner
      @attributes = attributes.to_h.deep_symbolize_keys
    end

    def call
      record = organization.crm_records.new(attributes)
      record.owner = owner

      duplicate_record = existing_exact_record_for(record)
      return Result.new(record:, duplicate_record:, duplicate_candidates: []) if duplicate_record.present?

      record.save!
      duplicate_candidates = DuplicateDetector.call(record)
      Result.new(record:, duplicate_record: nil, duplicate_candidates:)
    end

    private

    attr_reader :organization, :owner, :attributes

    def existing_exact_record_for(record)
      record.valid?
      return if record.fingerprint.blank?

      organization.crm_records
        .where(record_type: record.record_type, fingerprint: record.fingerprint)
        .first
    end
  end
end
