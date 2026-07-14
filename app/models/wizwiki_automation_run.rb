class WizwikiAutomationRun < ApplicationRecord
  STATUSES = %w[queued running waiting succeeded failed skipped].freeze
  TRIGGERS = %w[systemd manual solid_queue].freeze

  belongs_to :organization

  validates :automation_key, :run_key, :status, :trigger, presence: true
  validates :run_key, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[queued running waiting]) }
  scope :for_automation, ->(key) { where(automation_key: key.to_s) }

  before_validation :normalize_fields

  def active?
    status.in?(%w[queued running waiting])
  end

  def mark_queued!(step: "queued", data: {})
    update_with_event!(status: "queued", step: step, data: data)
  end

  def mark_running!(step:, data: {})
    update_with_event!(
      status: "running",
      step: step,
      data: data,
      attrs: { started_at: started_at || Time.current, error_message: nil }
    )
  end

  def mark_waiting!(step:, data: {})
    update_with_event!(status: "waiting", step: step, data: data)
  end

  def mark_succeeded!(step:, data: {})
    update_with_event!(
      status: "succeeded",
      step: step,
      data: data,
      attrs: { finished_at: Time.current, error_message: nil }
    )
  end

  def mark_skipped!(step:, data: {})
    update_with_event!(
      status: "skipped",
      step: step,
      data: data,
      attrs: { finished_at: Time.current, error_message: data[:reason].presence || data["reason"].presence }
    )
  end

  def mark_failed!(step:, error:, data: {})
    update_with_event!(
      status: "failed",
      step: step,
      data: data.merge(error_class: error.class.name, error_message: error.message),
      attrs: { finished_at: Time.current, error_message: "#{error.class}: #{error.message}".truncate(1_000) }
    )
  end

  def append_event!(step:, data: {})
    update_with_event!(status: status, step: step, data: data)
  end

  private

  def normalize_fields
    self.automation_key = automation_key.to_s.strip.presence
    self.run_key = run_key.to_s.strip.presence
    self.status = status.to_s.strip.presence || "queued"
    self.trigger = trigger.to_s.strip.presence || "systemd"
    self.current_step = current_step.to_s.strip.presence
    self.result = result.to_h
    self.metadata = metadata.to_h
  end

  def update_with_event!(status:, step:, data:, attrs: {})
    with_lock do
      event = {
        "at" => Time.current.iso8601,
        "step" => step.to_s,
        "status" => status.to_s,
        "data" => data.to_h
      }
      next_metadata = metadata.to_h
      next_metadata["events"] = Array(next_metadata["events"]).last(80) + [event]
      merged_result = result.to_h.deep_merge(step.to_s => data.to_h)
      update!(
        {
          status: status,
          current_step: step.to_s,
          metadata: next_metadata,
          result: merged_result
        }.merge(attrs)
      )
    end
  end
end
