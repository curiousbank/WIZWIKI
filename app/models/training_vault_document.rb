require "digest"

class TrainingVaultDocument < ApplicationRecord
  MAX_BODY_LENGTH = 5.megabytes
  STATUSES = %w[review approved indexed archived rejected].freeze
  SOURCE_TYPES = %w[vault_upload pasted_text folder_upload github_import ssh_import].freeze

  belongs_to :organization
  belongs_to :user
  belongs_to :approved_by, class_name: "User", optional: true

  encrypts :body

  validates :title, :body, :body_sha256, :source_type, :status, presence: true
  validates :body, length: { maximum: MAX_BODY_LENGTH }
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where.not(status: "archived") }
  scope :approved_for_memory, -> { where(status: ["approved", "indexed"]) }

  before_validation :set_body_digest

  def self.encryption_ready?
    %w[
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
    ].all? { |key| ENV[key].present? }
  end

  def approve_for_embedding!(approver:)
    now = Time.current
    update!(
      status: "approved",
      approved_by: approver,
      approved_at: approved_at || now,
      metadata: metadata.to_h.merge(
        "approved_for_vector_memory" => true,
        "approved_by_user_id" => approver&.id,
        "approved_at" => now.iso8601,
        "brain_types" => %w[wizwiki_ask market_report common]
      )
    )

    Autos::EmbeddingQueue.enqueue_source!(self)
  end

  def archive!
    Autos::EmbeddingQueue.delete_source!(self)
    update!(status: "archived", archived_at: Time.current)
  end

  def mark_embedding_queued!
    update!(status: "approved") unless archived? || indexed?
  end

  def mark_indexed!
    update!(status: "indexed", indexed_at: Time.current) unless archived?
  end

  def archived?
    status == "archived"
  end

  def indexed?
    status == "indexed"
  end

  private

  def set_body_digest
    self.body_sha256 = Digest::SHA256.hexdigest(body.to_s) if body.present?
  end
end
