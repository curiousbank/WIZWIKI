class ApprovalsController < ApplicationController
  before_action :require_organization!
  before_action :require_admin!
  before_action :set_membership, only: %i[edit_user update_user send_password_reset]

  def index
    @staged_build_requests = current_organization.build_requests
      .includes(:user)
      .where(status: "staged")
      .recent
      .limit(25)
    @recent_build_requests = current_organization.build_requests
      .includes(:user)
      .where.not(status: "staged")
      .recent
      .limit(12)
    @recent_design_reports = current_organization.design_reports.includes(:user).recent.limit(6)
    @memberships = current_organization.memberships
      .joins(:user)
      .includes(:user)
      .order(Arel.sql("LOWER(users.email_address) ASC"))
  end

  def edit_user
  end

  def update_user
    requested_role = requested_role_value
    requested_admin = requested_admin_value

    if removing_last_admin?(@membership, requested_admin)
      redirect_to edit_approve_user_path(@membership), alert: "At least one admin is required."
      return
    end

    @membership.role = requested_role
    @membership.admin = requested_admin

    if @membership.save
      redirect_to approve_path(anchor: "users"), notice: "#{@membership.user.display_name} updated."
    else
      flash.now[:alert] = @membership.errors.full_messages.to_sentence
      render :edit_user, status: :unprocessable_entity
    end
  end

  def send_password_reset
    PasswordsMailer.reset(@membership.user).deliver_later
    redirect_to approve_path(anchor: "users"), notice: "Password reset email sent to #{@membership.user.email_address}."
  end

  def update_build_request
    build_request = current_organization.build_requests.find(params[:id])
    status = params.require(:status)

    unless status.in?(%w[approved rejected])
      redirect_to approve_path, alert: "Approval status not allowed."
      return
    end

    build_request.update!(status: status)
    redirect_to approve_path, notice: "Build request #{status}."
  end

  private

  def set_membership
    @membership = current_organization.memberships.includes(:user).find(params[:id])
  end

  def requested_role_value
    role = params.require(:membership)[:role].to_s
    return @membership.role if role.blank?

    role
  end

  def requested_admin_value
    membership = params.require(:membership)
    return @membership.admin? unless membership.key?(:admin)

    ActiveModel::Type::Boolean.new.cast(membership[:admin])
  end

  def removing_last_admin?(membership, requested_admin)
    return false if requested_admin
    return false unless membership.admin?

    !current_organization.memberships.where(admin: true).where.not(id: membership.id).exists?
  end

  def require_admin!
    membership = current_user&.memberships&.find_by(organization: current_organization)
    return if membership&.admin?

    redirect_to dashboard_path, alert: "Admin approval access required."
  end
end
