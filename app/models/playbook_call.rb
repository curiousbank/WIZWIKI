class PlaybookCall < ApplicationRecord
  STATUSES = %w[synced archived failed].freeze

  belongs_to :organization
  belongs_to :crm_record, optional: true
  has_many :crm_address_records, dependent: :destroy

  validates :hubspot_call_id, presence: true, uniqueness: { scope: :organization_id }
  validates :status, inclusion: { in: STATUSES }

  after_commit :extract_crm_addresses

  scope :recent, -> { order(occurred_at: :desc, updated_at: :desc) }
  scope :active, -> { where.not(status: "archived") }

  def self.for_crm_record_graph(record)
    ids = [record.id]
    ids.concat(record.outbound_associations.select(:to_record_id).map(&:to_record_id))
    ids.concat(record.inbound_associations.select(:from_record_id).map(&:from_record_id))
    ids.compact!

    active.where(crm_record_id: ids).recent
  end

  def compact_context(max_chars: 1_200)
    parts = [
      title.presence || "HubSpot playbook call #{hubspot_call_id}",
      occurred_at.present? ? "occurred_at=#{occurred_at.iso8601}" : nil,
      owner_name.present? ? "owner=#{owner_name}" : nil,
      call_direction.present? ? "direction=#{call_direction}" : nil,
      call_disposition.present? ? "outcome=#{call_disposition}" : nil,
      summary.present? ? "summary=#{summary}" : nil,
      suggested_next_actions.present? ? "next_actions=#{suggested_next_actions}" : nil,
      notes.present? ? "notes=#{notes}" : nil
    ].compact.join(" | ")

    parts.truncate(max_chars, omission: "...")
  end

  private

  def extract_crm_addresses
    return unless Crm::AddressBackfill.storage_ready?

    Crm::AddressBackfill.extract_playbook_call!(self)
  end
end
