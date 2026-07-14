class BuildsController < ApplicationController
  before_action :require_organization!
  before_action :require_build_access!

  def index
    @build_request = BuildRequest.new
    @recent_build_requests = current_organization.build_requests
      .where(user: current_user)
      .recent
      .limit(8)
  end

  def create
    @build_request = current_organization.build_requests.new(build_request_params)
    @build_request.user = current_user
    @build_request.status = "staged"
    @build_request.metadata = {
      role: current_user.primary_membership&.role,
      seniority_days: current_user.primary_membership ? (Date.current - current_user.primary_membership.created_at.to_date).to_i : 0
    }

    if @build_request.save
      Autos::BuildAnswerer.call(@build_request)
      redirect_to build_path, notice: "Build request staged. Thumper added a read-only build brief."
    else
      @recent_build_requests = current_organization.build_requests.where(user: current_user).recent.limit(8)
      flash.now[:alert] = @build_request.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end
  end

  private

  def require_build_access!
    membership = current_user&.memberships&.find_by(organization: current_organization)
    return if membership&.can_build?

    redirect_to dashboard_path, alert: "Build access requires develop role or admin approval."
  end

  def build_request_params
    params.require(:build_request).permit(:title, :target_area, :prompt)
  end
end
