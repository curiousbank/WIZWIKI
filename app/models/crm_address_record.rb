class CrmAddressRecord < ApplicationRecord
  ADDRESS_KINDS = %w[address locality postal_area].freeze

  belongs_to :organization
  belongs_to :crm_record, optional: true
  belongs_to :playbook_call, optional: true

  before_validation :normalize_address_fields
  after_destroy_commit :delete_autos_embedding_chunks

  validates :source_type, :source_key, :source_path, :address_kind, :address_one_line, :normalized_key, presence: true
  validates :address_kind, inclusion: { in: ADDRESS_KINDS }
  validates :source_path, uniqueness: { scope: [:organization_id, :source_key] }

  scope :sorted, -> { order(Arel.sql("LOWER(address_one_line) ASC, updated_at DESC")) }
  scope :for_kind, ->(kind) { where(address_kind: kind) if kind.present? }

  def display_address
    address_one_line.presence || address_line
  end

  private

  def normalize_address_fields
    self.source_type = source_type.to_s.presence
    self.source_key = source_key.to_s.presence || [source_type, source_id].compact.join(":")
    self.source_path = source_path.to_s.presence || "unknown"
    self.address_kind = address_kind.to_s.presence || "address"
    self.address1 = clean_component(address1)
    self.address2 = clean_component(address2)
    self.city = clean_component(city)
    self.state = clean_component(state)
    self.postal_code = clean_component(postal_code)
    self.country = clean_component(country)
    self.address_line = clean_component(address_line)
    self.address_one_line = clean_component(address_one_line).presence || formatted_address
    self.normalized_key = normalize_key(address_one_line)
    self.raw_components = raw_components.to_h
    self.association_context = association_context.to_h
    self.metadata = metadata.to_h
  end

  def formatted_address
    [
      [address1, address2].compact_blank.join(" "),
      [city, state, postal_code].compact_blank.join(", "),
      country
    ].compact_blank.join(" | ")
  end

  def clean_component(value)
    value.to_s.gsub(/\s+/, " ").strip.presence
  end

  def normalize_key(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.presence
  end

  def delete_autos_embedding_chunks
    return unless ActiveRecord::Base.connection.table_exists?(:autos_embedding_chunks)

    AutosEmbeddingChunk.where(organization: organization, source_type: "CrmAddressRecord", source_id: id).delete_all
  rescue StandardError => error
    Rails.logger.warn("[CrmAddressRecord] embedding cleanup failed id=#{id} #{error.class}: #{error.message}")
  end
end
