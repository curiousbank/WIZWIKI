require "digest"

class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :redirect_cloudflare_http_to_https

  helper_method :current_user, :current_organization

  private

  COMPANY_GATE_TTL = 12.hours

  def redirect_cloudflare_http_to_https
    return unless request.headers["CF-Visitor"].to_s.include?("\"scheme\":\"http\"")

    redirect_to "https://#{request.host}#{request.fullpath}", status: :moved_permanently, allow_other_host: true
  end

  def current_user
    Current.session&.user
  end

  def current_organization
    @current_organization ||= current_user&.primary_organization || Organization.order(:created_at).first
  end

  def company_gate_verified?
    verified_at = session[:site_gate_verified_at].to_i
    verified_at.positive? && Time.at(verified_at) > COMPANY_GATE_TTL.ago
  end

  def require_company_gate!
    return if company_gate_verified?

    session[:site_gate_return_to] = (request.get? || request.head?) ? request.fullpath : new_session_path
    redirect_to new_site_gate_path, alert: "Enter the company gate password first."
  end

  def mark_company_gate_verified!
    session[:site_gate_verified_at] = Time.current.to_i
  end

  def company_gate_password_valid?(password)
    expected = ENV["WIZWIKI_SITE_PASSWORD"].to_s
    return false if expected.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(password.to_s),
      Digest::SHA256.hexdigest(expected)
    )
  end

  def require_organization!
    return if current_organization.present?

    redirect_to new_session_path, alert: "No organization is connected to this account yet."
  end

  def with_expensive_action_gate(key, ttl: 2.minutes)
    cache_key = expensive_action_gate_key(key)
    token = SecureRandom.uuid
    acquired = Rails.cache.write(cache_key, token, expires_in: ttl, unless_exist: true)
    return yield(false) unless acquired

    yield(true)
  ensure
    Rails.cache.delete(cache_key) if acquired && Rails.cache.read(cache_key) == token
  end

  def expensive_action_gate_key(key)
    [
      "wizwiki",
      Rails.env,
      "action_gate",
      current_organization&.id || "global",
      key.to_s.parameterize
    ].join(":")
  end
end
