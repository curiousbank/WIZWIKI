class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :owned_crm_records, class_name: "CrmRecord", foreign_key: :owner_id, dependent: :nullify
  has_many :build_requests, dependent: :destroy
  has_many :autos_questions, dependent: :destroy
  has_many :training_documents, dependent: :destroy
  has_many :design_reports, dependent: :destroy
  has_many :design_orders, dependent: :destroy
  has_many :crm_record_artifacts, dependent: :nullify
  has_many :canva_connections, dependent: :destroy
  has_many :requested_playbook_calls, through: :organizations, source: :playbook_calls
  has_one :employee_profile, dependent: :nullify

  before_validation :normalize_profile_fields

  generates_token_for :email_confirmation, expires_in: 3.days do
    [email_address, password_digest, confirmed_at]
  end

  validates :email_address, presence: true, uniqueness: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  validates :name, length: { maximum: 120 }, allow_blank: true
  validates :phone_number, length: { maximum: 32 }, allow_blank: true
  validates :aircall_user_id, :aircall_number_id, :aircall_external_key, length: { maximum: 120 }, allow_blank: true
  validates :twilio_from_number, length: { maximum: 32 }, allow_blank: true
  validates :twilio_messaging_service_sid, length: { maximum: 80 }, allow_blank: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  def email_confirmation_token
    generate_token_for(:email_confirmation)
  end

  def self.find_by_email_confirmation_token!(token)
    find_by_token_for!(:email_confirmation, token)
  end

  def confirmed?
    confirmed_at.present?
  end

  def confirm!
    update!(confirmed_at: Time.current)
  end

  def display_name
    name.presence || email_address.to_s.split("@").first
  end

  def display_phone_number
    phone_number.to_s.presence
  end

  def aircall_profile
    {
      "user_id" => aircall_user_id.to_s.presence,
      "number_id" => aircall_number_id.to_s.presence,
      "external_key" => aircall_external_key.to_s.presence
    }.compact_blank
  end

  def twilio_profile
    {
      "from_number" => twilio_from_number.to_s.presence || display_phone_number,
      "messaging_service_sid" => twilio_messaging_service_sid.to_s.presence
    }.compact_blank
  end

  def primary_membership
    memberships.includes(:organization).order(:created_at).first
  end

  def primary_organization
    primary_membership&.organization || organizations.order(:created_at).first
  end

  private

  def normalize_profile_fields
    self.name = name.to_s.squish.presence
    self.phone_number = phone_number.to_s.squish.gsub(/[^\d+().\-\sx]/i, "").presence
    self.aircall_user_id = normalize_aircall_identifier(aircall_user_id)
    self.aircall_number_id = normalize_aircall_identifier(aircall_number_id)
    self.aircall_external_key = normalize_aircall_identifier(aircall_external_key)
    self.twilio_from_number = twilio_from_number.to_s.squish.gsub(/[^\d+().\-\sx]/i, "").presence
    self.twilio_messaging_service_sid = normalize_aircall_identifier(twilio_messaging_service_sid)
  end

  def normalize_aircall_identifier(value)
    value.to_s.squish.gsub(/[^\w.\-:@]/, "").presence
  end
end
