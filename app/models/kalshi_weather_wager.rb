class KalshiWeatherWager < ApplicationRecord
  STATUSES = %w[pending placed filled won lost pushed void skipped error].freeze
  RESULT_STATUSES = %w[won lost pushed void].freeze
  EXECUTION_MODES = %w[dry_run live].freeze

  belongs_to :organization
  belongs_to :kalshi_weather_prediction

  validates :status, inclusion: { in: STATUSES }
  validates :execution_mode, inclusion: { in: EXECUTION_MODES }
  validates :market_ticker, :budget_date, :strategy_key, presence: true
  validates :contracts, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :filled_contracts, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :max_cost, numericality: { greater_than_or_equal_to: 0 }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :budgeted, -> { where(status: %w[pending placed filled won lost pushed]) }
  scope :open_journal, -> { where(status: %w[pending placed filled]) }
  scope :live, -> { where(execution_mode: "live") }
  scope :paper, -> { where(execution_mode: "dry_run") }
  scope :for_strategy, ->(key) { where(strategy_key: key.to_s) }

  def self.storage_ready?
    table_exists?
  rescue ActiveRecord::StatementInvalid
    false
  end

  def result_symbol
    case display_result_status
    when "won" then "+"
    when "lost" then "-"
    when "pushed", "void" then "0"
    else
      "🪄"
    end
  end

  def display_result_status
    return status if status.in?(RESULT_STATUSES)
    return nil if realized_profit.blank?

    profit = realized_profit.to_f
    return "won" if profit.positive?
    return "lost" if profit.negative?

    "pushed"
  end

  def pending?
    status.in?(%w[pending placed filled])
  end

  def execution_label
    execution_mode == "live" ? "live" : "paper"
  end
end
