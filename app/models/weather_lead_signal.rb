class WeatherLeadSignal < ApplicationRecord
  STATUSES = %w[active recent expired stale].freeze
  SIGNAL_TYPES = %w[alert historical_alert forecast].freeze

  belongs_to :organization

  before_validation :normalize_fields
  after_commit :enqueue_autos_embedding_chunk

  validates :source, :source_uid, :signal_type, :event, :status, presence: true
  validates :source_uid, uniqueness: { scope: [:organization_id, :source] }
  validates :status, inclusion: { in: STATUSES }
  validates :signal_type, inclusion: { in: SIGNAL_TYPES }

  scope :actionable, -> {
    where(status: ["active", "recent"])
      .where("weather_lead_signals.status = 'recent' OR weather_lead_signals.expires_at IS NULL OR weather_lead_signals.expires_at >= ?", Time.current)
  }
  scope :alerts, -> { where(signal_type: "alert") }
  scope :historical_alerts, -> { where(signal_type: "historical_alert") }
  scope :forecasts, -> { where(signal_type: "forecast") }
  scope :recent_first, -> { order(Arel.sql("COALESCE(started_at, created_at) DESC")) }

  def self.storage_ready?
    table_exists?
  rescue ActiveRecord::StatementInvalid
    false
  end

  def display_label
    [event, headline.presence || area_desc].compact_blank.join(" // ")
  end

  def urgency_score
    severity_score + urgency_weight + certainty_weight
  end

  private

  def normalize_fields
    self.source = source.to_s.strip.downcase.presence || "weather.gov"
    self.source_uid = source_uid.to_s.strip.presence
    self.signal_type = signal_type.to_s.strip.downcase.presence || "alert"
    self.event = event.to_s.squish.presence || "Weather Alert"
    self.headline = headline.to_s.squish.presence
    self.description = description.to_s.squish.presence
    self.severity = severity.to_s.squish.presence
    self.urgency = urgency.to_s.squish.presence
    self.certainty = certainty.to_s.squish.presence
    self.status = status.to_s.strip.downcase.presence || "active"
    self.area_desc = area_desc.to_s.squish.presence
    self.affected_states = Array(affected_states).map { |state| state.to_s.strip.upcase }.compact_blank.uniq
    self.affected_postal_codes = Array(affected_postal_codes).map { |zip| zip.to_s[/\d{5}/] }.compact_blank.uniq
    self.raw_payload = raw_payload.to_h
    self.metadata = metadata.to_h
  end

  def severity_score
    case severity.to_s.downcase
    when "extreme" then 50
    when "severe" then 40
    when "moderate" then 25
    else 10
    end
  end

  def urgency_weight
    case urgency.to_s.downcase
    when "immediate" then 25
    when "expected" then 18
    when "future" then 10
    else 5
    end
  end

  def certainty_weight
    case certainty.to_s.downcase
    when "observed" then 20
    when "likely" then 15
    when "possible" then 8
    else 4
    end
  end

  def enqueue_autos_embedding_chunk
    Autos::EmbeddingQueue.enqueue_source!(self) if defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
  end
end
