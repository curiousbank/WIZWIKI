class ConfirmationsController < ApplicationController
  allow_unauthenticated_access only: :show

  def show
    user = User.find_by_email_confirmation_token!(params[:token])
    user.confirm!
    redirect_to new_session_path, notice: "Email confirmed. You can sign in now."
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to new_session_path, alert: "Confirmation link is invalid or expired."
  end
end
