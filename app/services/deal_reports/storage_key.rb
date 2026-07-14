module DealReports
  class StorageKey
    SAFE_EXTENSION = /\A[a-z0-9]{1,12}\z/

    def self.call(crm_record:, artifact_type: "market_report", filename: nil, extension: "docx")
      new(crm_record:, artifact_type:, filename:, extension:).call
    end

    def initialize(crm_record:, artifact_type:, filename:, extension:)
      @crm_record = crm_record
      @artifact_type = artifact_type
      @filename = filename
      @extension = extension
    end

    def call
      [prefix, organization_segment, deal_segment, safe_filename].join("/")
    end

    private

    attr_reader :crm_record, :artifact_type, :filename, :extension

    def prefix
      WizwikiSettings.backblaze_report_prefix
    end

    def organization_segment
      crm_record.organization.slug.presence || "organization-#{crm_record.organization_id}"
    end

    def deal_segment
      source = crm_record.source_uid.presence || crm_record.id
      "deal-#{source.to_s.parameterize.presence || crm_record.id}"
    end

    def safe_filename
      base = filename.to_s.squish.presence || [artifact_type, crm_record.name, Time.current.strftime("%Y%m%d%H%M%S")].join("-")
      ext = extension.to_s.downcase.gsub(/[^a-z0-9]/, "")
      ext = "docx" unless ext.match?(SAFE_EXTENSION)
      "#{base.parameterize.first(96)}.#{ext}"
    end
  end
end
