class SiteGatesController < ApplicationController
  allow_unauthenticated_access

  def new
    redirect_to new_session_path if company_gate_verified?
  end

  def create
    if company_gate_password_valid?(params[:password])
      mark_company_gate_verified!
      redirect_to session.delete(:site_gate_return_to).presence || new_session_path, status: :see_other, notice: "Company access confirmed."
    else
      flash.now[:alert] = "Company password did not match."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:site_gate_verified_at)
    session.delete(:site_gate_return_to)
    redirect_to new_session_path, status: :see_other
  end
end
