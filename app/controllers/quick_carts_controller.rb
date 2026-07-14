require "digest"

class QuickCartsController < ApplicationController
  PACKAGES = %w[STARTER PRIORITY FULL_LAUNCH].freeze
  PUBLIC_PACKAGES = { "WIZWIKI" => "STARTER" }.freeze
  PRODUCTION_SPEEDS = %w[standard skip_line].freeze

  allow_unauthenticated_access only: :create
  rate_limit to: 5, within: 10.minutes, only: :create, with: -> { redirect_to root_path, alert: "Skip the Line is cooling down. Try again in a few minutes." }

  def create
    submitted_package = quick_cart_params[:package].to_s.upcase.tr(" -", "__")
    package = PUBLIC_PACKAGES.fetch(submitted_package, submitted_package)
    unless PACKAGES.include?(package)
      redirect_to root_path, alert: "Pick a campaign package."
      return
    end

    production_speed = normalize_production_speed(quick_cart_params[:production_speed])
    email = quick_cart_params[:email].to_s.strip.downcase
    phone = quick_cart_params[:phone].to_s.gsub(/[^\d+]/, "")
    if email.blank? && phone.blank?
      redirect_to root_path, alert: "Add an email or phone number so a designer can follow up."
      return
    end

    record = upsert_quick_cart_contact(package:, email:, phone:, production_speed:)
    Crm::DuplicateDetector.call(record) if record.persisted?

    order = create_quick_cart_order(record:, package:, email:, phone:, production_speed:)
    unless payment_ready_for?(order)
      order.update!(status: "payment_unconfigured", error_message: "Square checkout credentials or package price are missing.")
      redirect_to root_path, alert: "Campaign lead saved. Square checkout needs credentials and package prices before checkout is live."
      return
    end

    source_id = quick_cart_params[:source_id].to_s
    if source_id.blank?
      order.update!(status: "card_token_missing", error_message: "Square card token was missing.")
      redirect_to root_path, alert: "Enter card details before starting the campaign checkout."
      return
    end

    order.update!(status: "payment_pending")
    payment = SquareGateway.new.create_payment(
      source_id: source_id,
      amount_cents: order.amount_cents,
      currency: order.currency,
      reference_id: "quick_cart_order_#{order.id}",
      note: "#{package} #{production_speed_label(production_speed)} campaign checkout",
      buyer_email_address: email.presence
    )

    mark_order_paid!(order, record, payment)
    redirect_to WizwikiSettings.campaign_url, allow_other_host: true
  rescue SquareGateway::Error => error
    order&.update!(status: "payment_failed", error_message: error.message)
    redirect_to root_path, alert: "Square checkout did not complete: #{error.message}"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to root_path, alert: error.record.errors.full_messages.to_sentence.presence || "Campaign checkout could not be saved."
  end

  private

  def quick_cart_params
    params.require(:quick_cart).permit(:package, :production_speed, :email, :phone, :source_id)
  end

  def payment_ready_for?(order)
    WizwikiSettings.square_server_configured? && order.amount_cents.positive?
  end

  def create_quick_cart_order(record:, package:, email:, phone:, production_speed:)
    record.organization.quick_cart_orders.create!(
      crm_record: record,
      package: package,
      email: email.presence,
      phone: phone.presence,
      amount_cents: WizwikiSettings.square_package_amount_cents(package, production_speed: production_speed),
      currency: WizwikiSettings.square_currency,
      metadata: {
        source: "campaign_checkout",
        public_page: "wizwiki.local",
        package_label: WizwikiSettings.square_package_label(package),
        production_speed: production_speed,
        production_speed_label: production_speed_label(production_speed),
        skip_line_multiplier: WizwikiSettings.square_skip_line_multiplier
      }
    )
  end

  def mark_order_paid!(order, record, payment)
    card = payment.dig("card_details", "card").to_h
    order.update!(
      status: "paid",
      square_payment_id: payment["id"],
      square_order_id: payment["order_id"],
      square_receipt_url: payment["receipt_url"],
      square_status: payment["status"],
      card_brand: card["card_brand"],
      card_last_4: card["last_4"],
      error_message: nil,
      metadata: order.metadata.to_h.merge("paid_at" => Time.current.iso8601)
    )

    record.update!(properties: record.properties.to_h.merge(payment_properties(order)))
  end

  def payment_properties(order)
    {
      "quick_cart_order_id" => order.id,
      "payment_status" => order.status,
      "paid_at" => Time.current.iso8601,
      "amount_cents" => order.amount_cents,
      "currency" => order.currency,
      "square_payment_id" => order.square_payment_id,
      "square_order_id" => order.square_order_id,
      "square_receipt_url" => order.square_receipt_url,
      "square_status" => order.square_status,
      "card_brand" => order.card_brand,
      "card_last_4" => order.card_last_4,
      "production_speed" => order.metadata.to_h["production_speed"],
      "production_speed_label" => order.metadata.to_h["production_speed_label"]
    }.compact
  end

  def upsert_quick_cart_contact(package:, email:, phone:, production_speed:)
    organization = default_organization
    existing = find_existing_contact(organization, email:, phone:)
    properties = quick_cart_properties(package:, email:, phone:, production_speed:)

    if existing.present?
      existing.update!(
        phone: phone.presence || existing.phone,
        email: email.presence || existing.email,
        source: "campaign_checkout",
        source_uid: source_uid(email:, phone:),
        stage: production_speed == "skip_line" ? "skip_line" : "standard_queue",
        status: "open",
        properties: existing.properties.to_h.merge(properties)
      )
      existing
    else
      result = Crm::RecordCreator.call(
        organization: organization,
        owner: nil,
        attributes: {
          record_type: "contact",
          name: lead_name(email:, phone:),
          email: email.presence,
          phone: phone.presence,
          source: "campaign_checkout",
          source_uid: source_uid(email:, phone:),
          stage: production_speed == "skip_line" ? "skip_line" : "standard_queue",
          status: "open",
          properties: properties
        }
      )
      result.duplicate_record || result.record
    end
  end

  def default_organization
    Organization.find_or_create_by!(slug: "wizwiki-autos") do |organization|
      organization.name = ENV.fetch("WIZWIKI_ORGANIZATION_NAME", "WIZWIKI Thumper")
      organization.domain = "wizwiki.local"
    end
  end

  def find_existing_contact(organization, email:, phone:)
    contacts = organization.crm_records.where(record_type: "contact")
    return contacts.find_by(email: email) if email.present? && contacts.exists?(email: email)
    return contacts.find_by(phone: phone) if phone.present? && contacts.exists?(phone: phone)

    nil
  end

  def lead_name(email:, phone:)
    if email.present?
      "Campaign Lead - #{email.split('@').first}"
    elsif phone.present?
      "Campaign Lead - #{phone.last(4)}"
    else
      "Campaign Lead"
    end
  end

  def source_uid(email:, phone:)
    Digest::SHA256.hexdigest([email.presence, phone.presence].compact.join("|"))
  end

  def quick_cart_properties(package:, email:, phone:, production_speed:)
    {
      "lead_type" => "campaign_checkout",
      "package" => package,
      "production_speed" => production_speed,
      "production_speed_label" => production_speed_label(production_speed),
      "callback_requested" => true,
      "callback_channel" => callback_channel(email:, phone:),
      "submitted_email" => email.presence,
      "submitted_phone" => phone.presence,
      "submitted_at" => Time.current.iso8601,
      "public_page" => "wizwiki.local"
    }.compact
  end

  def normalize_production_speed(value)
    cleaned = value.to_s.strip.downcase.tr("-", "_")
    PRODUCTION_SPEEDS.include?(cleaned) ? cleaned : "standard"
  end

  def production_speed_label(production_speed)
    production_speed == "skip_line" ? "Skip the Line" : "Save a Bit"
  end

  def callback_channel(email:, phone:)
    return "phone_and_email" if phone.present? && email.present?
    return "phone" if phone.present?
    return "email" if email.present?

    "unknown"
  end
end
