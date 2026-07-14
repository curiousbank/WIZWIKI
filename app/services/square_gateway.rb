require "json"
require "net/http"
require "securerandom"
require "uri"

class SquareGateway
  class Error < StandardError; end

  def initialize(settings: WizwikiSettings)
    @settings = settings
  end

  def configured?
    access_token.present? && location_id.present?
  end

  def create_payment(source_id:, amount_cents:, currency:, reference_id:, note:, buyer_email_address: nil)
    raise Error, "Square checkout is not configured." unless configured?
    raise Error, "Square card token is missing." if source_id.blank?
    raise Error, "Campaign checkout price is not configured." unless amount_cents.to_i.positive?

    uri = URI("#{base_url}/v2/payments")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(
      {
        source_id: source_id,
        idempotency_key: SecureRandom.uuid,
        amount_money: { amount: amount_cents.to_i, currency: currency },
        location_id: location_id,
        reference_id: reference_id,
        note: note,
        buyer_email_address: buyer_email_address.presence
      }.compact
    )

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end

    payload = JSON.parse(response.body.presence || "{}")
    unless response.is_a?(Net::HTTPSuccess) && payload["payment"].present?
      raise Error, square_error_message(payload["errors"])
    end

    payload.fetch("payment")
  rescue JSON::ParserError
    raise Error, "Square returned an unreadable response."
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "Square timed out before the payment completed."
  end

  private

  attr_reader :settings

  def access_token
    settings.square_access_token
  end

  def location_id
    settings.square_location_id
  end

  def base_url
    settings.square_mode.to_s.downcase == "sandbox" ? "https://connect.squareupsandbox.com" : "https://connect.squareup.com"
  end

  def square_error_message(errors)
    first = Array(errors).first.to_h
    first["detail"].presence || first["code"].presence || "Square payment was declined or could not be completed."
  end
end
