class CrmRecord < ApplicationRecord
  RECORD_TYPES = %w[contact company deal ticket].freeze
  STATUSES = %w[open active won lost closed archived].freeze

  belongs_to :organization
  belongs_to :owner, class_name: "User", optional: true
  belongs_to :priority_marked_by, class_name: "User", optional: true
  has_many :duplicate_candidates, dependent: :destroy
  has_many :reverse_duplicate_candidates, class_name: "DuplicateCandidate", foreign_key: :duplicate_record_id, dependent: :destroy
  has_many :outbound_associations, class_name: "CrmAssociation", foreign_key: :from_record_id, dependent: :destroy
  has_many :inbound_associations, class_name: "CrmAssociation", foreign_key: :to_record_id, dependent: :destroy
  has_many :quick_cart_orders, dependent: :destroy
  has_many :crm_record_artifacts, dependent: :destroy
  has_many :crm_address_records, dependent: :destroy
  has_many :playbook_calls, dependent: :nullify
  has_many_attached :deal_media

  before_validation :normalize_identity_fields
  before_validation :assign_fingerprint
  after_commit :extract_crm_addresses, on: [:create, :update]

  validates :record_type, inclusion: { in: RECORD_TYPES }
  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :fingerprint, uniqueness: { scope: [:organization_id, :record_type], allow_blank: true }
  validates :source_uid, uniqueness: { scope: [:organization_id, :source], allow_blank: true }

  scope :for_type, ->(type) { where(record_type: type) if type.present? }
  scope :search, ->(query) {
    next all if query.blank?

    cleaned = "%#{sanitize_sql_like(query.to_s.strip)}%"
    where("name ILIKE :q OR email ILIKE :q OR phone ILIKE :q OR domain ILIKE :q", q: cleaned)
  }

  def self.record_type_label(type)
    type.to_s.pluralize.titleize
  end

  def property_value(key)
    properties.to_h[key.to_s]
  end

  def open_duplicate_count
    duplicate_candidates.open.count
  end

  def effective_priority_level
    manual = priority_level.to_s.strip.downcase
    return "urgent" if manual == "urgent"
    return "priority" if manual == "priority"

    hubspot = hubspot_ticket_priority.to_s.downcase
    return "priority" if hubspot.match?(/urgent|critical|rush|asap|high/)

    "normal"
  end

  def priority?
    effective_priority_level != "normal"
  end

  def priority_source
    manual = priority_level.to_s.strip.downcase
    return "manual" if manual.in?(%w[urgent priority])
    return "hubspot" if effective_priority_level != "normal"

    "standard"
  end

  def hubspot_ticket_priority
    hubspot = properties.to_h.fetch("hubspot", {}).to_h
    labeled = hubspot.fetch("labeled_properties", {}).to_h
    raw = hubspot.fetch("properties", {}).to_h
    labeled["Ticket Priority"].presence || raw["hs_ticket_priority"].presence
  end

  private

  def normalize_identity_fields
    self.email = email.to_s.strip.downcase.presence
    self.phone = phone.to_s.gsub(/[^\d+]/, "").presence
    self.domain = domain.to_s.strip.downcase.sub(/\Ahttps?:\/\//, "").sub(/\Awww\./, "").split("/").first.presence
    self.source = source.to_s.strip.downcase.presence
    self.source_uid = source_uid.to_s.strip.presence
    self.properties = properties.to_h
  end

  def assign_fingerprint
    self.fingerprint = Crm::RecordFingerprint.call(self)
  end

  def extract_crm_addresses
    return unless Crm::AddressBackfill.storage_ready?

    Crm::AddressBackfill.extract_record!(self)
  end
end
