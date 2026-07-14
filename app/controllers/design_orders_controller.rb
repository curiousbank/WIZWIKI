class DesignOrdersController < ApplicationController
  before_action :require_organization!

  def show
    @design_order = current_organization.design_orders.includes(:design_report, :user).find(params[:id])
  end
end
