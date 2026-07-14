module Authentication
  extend ActiveSupport::Concern

  SESSION_IDLE_TIMEOUT = 30.minutes
  SESSION_ABSOLUTE_TIMEOUT = 12.hours

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      session_id = cookies.signed[:session_id]
      return if session_id.blank?

      active_session = Session.find_by(id: session_id)
      return if active_session.blank?

      if session_expired?(active_session)
        active_session.destroy
        delete_session_cookie
        return
      end

      active_session.touch if active_session.updated_at < 5.minutes.ago
      active_session
    end

    def session_expired?(active_session)
      active_session.updated_at < SESSION_IDLE_TIMEOUT.ago || active_session.created_at < SESSION_ABSOLUTE_TIMEOUT.ago
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.fullpath if request.get? || request.head?
      redirect_to new_session_path
    end

    def after_authentication_url
      requested_path = session.delete(:return_to_after_authenticating).to_s
      safe_internal_path?(requested_path) ? requested_path : dashboard_path
    end

    def safe_internal_path?(path)
      path.start_with?("/") && !path.start_with?("//")
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |active_session|
        Current.session = active_session
        delete_session_cookie_variants
        cookies.signed[:session_id] = {
          value: active_session.id,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?,
          expires: SESSION_ABSOLUTE_TIMEOUT.from_now
        }.merge(session_cookie_domain_options)
      end
    end

    def terminate_session
      Current.session&.destroy
      delete_session_cookie
    end

    def delete_session_cookie
      delete_session_cookie_variants
    end

    def delete_session_cookie_variants
      base_options = { same_site: :lax, secure: Rails.env.production? }
      cookies.delete(:session_id, base_options)
      domain_options = session_cookie_domain_options
      cookies.delete(:session_id, base_options.merge(domain_options)) if domain_options.present?
    end

    def session_cookie_domain_options
      return {} unless Rails.env.production?

      host = request.host.to_s.downcase
      configured_domain = ENV.fetch("WIZWIKI_SESSION_COOKIE_DOMAIN", ".wizwiki.local").to_s.strip.downcase
      cookie_host = configured_domain.delete_prefix(".")
      return {} if cookie_host.blank?
      return { domain: ".#{cookie_host}" } if host == cookie_host || host.end_with?(".#{cookie_host}")

      {}
    end
end
