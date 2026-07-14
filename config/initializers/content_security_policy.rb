# Be sure to restart your server when you modify this file.

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.font_src :self, :https, :data
    policy.img_src :self, :https, :data
    policy.object_src :none
    policy.script_src :self, :https
    policy.style_src :self, :https, :unsafe_inline
    policy.connect_src :self, :https
    policy.form_action :self
    policy.frame_src :self, :https
    policy.frame_ancestors :self
    policy.media_src :self, :https, :data
    policy.worker_src :self
    policy.manifest_src :self
    policy.upgrade_insecure_requests if Rails.env.production?
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_nonce_auto = true

  config.permissions_policy do |policy|
    policy.camera :none
    policy.microphone :self
    policy.geolocation :self
    policy.payment :self
    policy.usb :none
    policy.fullscreen :self
  end
end
