class CrmRecordArtifact < ApplicationRecord
  ARTIFACT_TYPES = %w[market_report comm_staging campaign_outline creative_brief strategy_doc].freeze
  STATUSES = %w[queued generating report_ready canva_kit_ready ready staged aircall_ready aircall_sent aircall_failed failed canceled archived].freeze
  STORAGE_PROVIDERS = %w[backblaze cloudinary local].freeze

  belongs_to :organization
  belongs_to :crm_record
  belongs_to :user, optional: true

  before_validation :inherit_organization
  before_validation :default_title
  before_validation :normalize_fields
  before_validation :default_comms_rag_profile

  validates :artifact_type, inclusion: { in: ARTIFACT_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :storage_provider, inclusion: { in: STORAGE_PROVIDERS }, allow_blank: true
  validates :title, presence: true
  validates :metadata, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :ready, -> { where(status: %w[canva_kit_ready ready]) }
  scope :queued, -> { where(status: "queued") }

  def ready?
    status.in?(%w[canva_kit_ready ready])
  end

  def report_ready?
    status.in?(%w[report_ready canva_kit_ready ready archived]) && storage_key.present?
  end

  def canva_kit_ready?
    status.in?(%w[canva_kit_ready ready archived]) && metadata.to_h.dig("canva_kit", "storage_key").present?
  end

  def stored?
    file_url.present? || storage_key.present?
  end

  private

  def inherit_organization
    self.organization ||= crm_record&.organization
  end

  def default_title
    self.title = title.to_s.squish.presence || default_title_for_artifact
  end

  def normalize_fields
    self.artifact_type = artifact_type.to_s.strip.downcase.presence || "market_report"
    self.status = status.to_s.strip.downcase.presence || "queued"
    self.storage_provider = storage_provider.to_s.strip.downcase.presence
    self.storage_bucket = storage_bucket.to_s.strip.presence
    self.storage_key = storage_key.to_s.strip.presence
    self.file_url = file_url.to_s.strip.presence
    self.content_type = content_type.to_s.strip.downcase.presence
    self.metadata = metadata.to_h
  end

  def default_comms_rag_profile
    return unless artifact_type.to_s == "comm_staging"
    return unless defined?(Comms::RagProfile)

    fallback = persisted? ? Comms::RagProfile::LEGACY_KEY : Comms::RagProfile::DEFAULT_KEY
    profile = Comms::RagProfile.fetch(metadata.to_h["rag_profile"], fallback: fallback, organization: organization)
    self.metadata = metadata.to_h.merge(
      "rag_profile" => profile.fetch("key"),
      "rag_profile_label" => profile.fetch("label"),
      "rag_scope" => profile.fetch("scope"),
      "rag_kind" => profile.fetch("kind")
    )
  end

  def default_title_for_artifact
    label = artifact_type.to_s.humanize.presence || "Market report"
    record_name = crm_record&.name.to_s.presence || "deal"
    "#{label}: #{record_name}"
  end
end
