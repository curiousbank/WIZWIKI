class AutosEmbeddingChunk < ApplicationRecord
  STATUSES = %w[pending claimed embedded failed stale].freeze

  belongs_to :organization

  validates :scope, :source_type, :source_id, :chunk_index, :content,
    :source_digest, :content_digest, :embedding_model, :status, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: ["pending", "stale"]) }
  scope :embedded, -> { where(status: "embedded").where.not(embedding_dimensions: nil) }
  scope :for_model, ->(model) { where(embedding_model: model.to_s) if model.present? }
end
