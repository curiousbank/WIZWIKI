class TrainingDocument < ApplicationRecord
  MAX_BODY_LENGTH = 5.megabytes
  STATUSES = %w[ingested processing indexed archived].freeze
  SOURCE_TYPES = %w[pasted_text text_file folder_upload transcript meeting_note sales_call autos_rem comms_playbook_memory].freeze

  belongs_to :organization
  belongs_to :user

  validates :title, :body, :source_type, presence: true
  validates :body, length: { maximum: MAX_BODY_LENGTH }
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :recent, -> { order(created_at: :desc) }

  scope :waiting_for_embedding, -> { where(status: "ingested") }

  def mark_embedding_queued!
    update!(status: "processing") unless archived? || processing?
  end

  def mark_indexed!
    update!(status: "indexed") unless archived?
  end

  def archived?
    status == "archived"
  end

  def processing?
    status == "processing"
  end
end
