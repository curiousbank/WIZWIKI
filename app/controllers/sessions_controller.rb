class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, status: :see_other, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      unless user.confirmed?
        UserMailer.confirmation(user).deliver_later
        redirect_to new_session_path, status: :see_other, alert: "Confirm your email before signing in. We sent a fresh confirmation link."
        return
      end

      unless active_employee_member?(user)
        redirect_to new_session_path, status: :see_other, alert: "Your account is confirmed, but workspace access is waiting for an active employee roster match."
        return
      end

      start_new_session_for user
      redirect_to after_authentication_url, status: :see_other
    else
      redirect_to new_session_path, status: :see_other, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def active_employee_member?(user)
    return true if user.memberships.where(status: "active").exists?

    Access::EmployeeMembershipSync.call(user: user, allow_bootstrap: company_gate_verified?).active?
  end
end
