class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]
  before_action :require_company_gate!, only: %i[new create]
  rate_limit to: 6, within: 3.minutes, only: :create, with: -> { redirect_to new_registration_path, alert: "Try again later." }

  def new
    @user = User.new
  end

  def create
    existing_user = User.find_by(email_address: registration_params[:email_address].to_s.strip.downcase)
    if existing_user.present?
      UserMailer.confirmation(existing_user).deliver_later unless existing_user.confirmed?
      redirect_to new_session_path, alert: existing_user.confirmed? ? "That email already has an account. Sign in instead." : "That account already exists. Confirmation email resent."
      return
    end

    @user = User.new(registration_params)

    if @user.save
      access_result = Access::EmployeeMembershipSync.call(user: @user, allow_bootstrap: company_gate_verified?)
      @user.update!(confirmation_sent_at: Time.current)
      UserMailer.confirmation(@user).deliver_later
      redirect_to new_session_path, notice: registration_notice(access_result)
    else
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
  end

  def registration_notice(access_result)
    if access_result.active? && access_result.matched?
      "Account created and matched to the employee roster. Check your email to confirm access."
    elsif access_result.active?
      "Account created. Check your email to confirm access."
    else
      "Account created. Check your email to confirm your address. Workspace access will activate after your email matches the employee roster."
    end
  end
end
