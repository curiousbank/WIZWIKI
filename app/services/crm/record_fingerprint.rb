require "digest"

module Crm
  class RecordFingerprint
    def self.call(record)
      new(record).call
    end

    def initialize(record)
      @record = record
    end

    def call
      parts = case record.record_type
      when "contact"
        if record.source.to_s == "manual_comms" && record.source_uid.present?
          ["contact", record.source, record.source_uid]
        else
          ["contact", record.email.presence || record.phone.presence || record.name]
        end
      when "company"
        ["company", record.domain.presence || record.name]
      when "deal"
        if record.source.present? && record.source_uid.present?
          ["deal", record.source, record.source_uid]
        else
          ["deal", record.name, record.amount, record.close_date]
        end
      when "ticket"
        if record.source.present? && record.source_uid.present?
          ["ticket", record.source, record.source_uid]
        else
          ["ticket", record.name, record.email.presence || record.phone.presence]
        end
      else
        [record.record_type, record.name]
      end

      Digest::SHA256.hexdigest(parts.compact.map { |part| normalize(part) }.join("|"))
    end

    private

    attr_reader :record

    def normalize(value)
      value.to_s.strip.downcase.gsub(/\s+/, " ")
    end
  end
end
