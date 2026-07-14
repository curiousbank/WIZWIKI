class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :crm_records, dependent: :destroy
  has_many :crm_address_records, dependent: :destroy
  has_many :crm_property_definitions, dependent: :destroy
  has_many :crm_associations, dependent: :destroy
  has_many :duplicate_candidates, dependent: :destroy
  has_many :ingestion_events, dependent: :destroy
  has_many :build_requests, dependent: :destroy
  has_many :autos_questions, dependent: :destroy
  has_many :training_documents, dependent: :destroy
  has_many :training_vault_documents, dependent: :destroy
  has_many :quick_cart_orders, dependent: :destroy
  has_many :design_reports, dependent: :destroy
  has_many :design_orders, dependent: :destroy
  has_many :employee_profiles, dependent: :destroy
  has_many :crm_record_artifacts, dependent: :destroy
  has_many :canva_connections, dependent: :destroy
  has_many :wizwiki_automation_runs, dependent: :destroy
  has_many :playbook_calls, dependent: :destroy
  has_many :fathom_calls, dependent: :destroy
  has_many :weather_lead_signals, dependent: :destroy
  has_many :kalshi_weather_predictions, dependent: :destroy
  has_many :kalshi_weather_wagers, dependent: :destroy

  validates :name, :slug, presence: true
  validates :slug, uniqueness: true

  normalizes :slug, with: ->(value) { value.to_s.strip.downcase.parameterize }
  normalizes :domain, with: ->(value) { value.to_s.strip.downcase.presence }
end
