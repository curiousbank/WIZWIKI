class ProfilesController < ApplicationController
  before_action :require_organization!

  def edit
  end

  def update
    if current_user.update(profile_params)
      redirect_to edit_profile_path, notice: "WIZWIKI profile updated. COMM KITs will use this sender profile on future runs."
    else
      flash.now[:alert] = current_user.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(
      :name,
      :phone_number,
      :aircall_user_id,
      :aircall_number_id,
      :aircall_external_key,
      :twilio_from_number,
      :twilio_messaging_service_sid
    )
  end
end
