class FathomCall < ApplicationRecord
  STATUSES = %w[synced archived failed].freeze

  belongs_to :organization

  validates :recording_id, presence: true, uniqueness: { scope: :organization_id }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(recording_start_time: :desc, fathom_created_at: :desc, updated_at: :desc) }
  scope :active, -> { where.not(status: "archived") }

  def compact_context(max_chars: 1_200)
    parts = [
      title.presence || meeting_title.presence || "Fathom call #{recording_id}",
      recording_start_time.present? ? "recorded_at=#{recording_start_time.iso8601}" : nil,
      recorded_by_name.present? ? "recorded_by=#{recorded_by_name}" : nil,
      recorded_by_email.present? ? "recorded_by_email=#{recorded_by_email}" : nil,
      meeting_type.present? ? "meeting_type=#{meeting_type}" : nil,
      participant_label.present? ? "participants=#{participant_label}" : nil,
      summary.present? ? "summary=#{summary}" : nil,
      action_items_text.present? ? "action_items=#{action_items_text}" : nil
    ].compact.join(" | ")

    parts.truncate(max_chars, omission: "...")
  end

  def participant_label
    Array(calendar_invitees).filter_map do |invitee|
      name = invitee["name"].presence || invitee["matched_speaker_display_name"].presence
      email = invitee["email"].presence
      label = [name, email].compact.join(" <")
      label += ">" if name.present? && email.present?
      next if label.blank?

      invitee["is_external"] ? "#{label} external" : label
    end.join("; ")
  end
end
