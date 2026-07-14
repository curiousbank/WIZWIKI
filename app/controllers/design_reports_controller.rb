class DesignReportsController < ApplicationController
  before_action :require_organization!

  def index
    @design_report = DesignReport.new
    @recent_reports = current_organization.design_reports.includes(:user).recent.limit(8)
    @queue_scope = current_organization.design_orders.queued
    @design_orders = @queue_scope
      .includes(:design_report, :user)
      .search(params[:q])
      .recent
      .limit(100)
    @queue_count = @queue_scope.count
    @queue_green_count = @queue_scope.where("COALESCE(biz_days_overall, 0) < 1").count
    @queue_orange_count = @queue_scope.where(biz_days_overall: 1..2).count
    @queue_red_count = @queue_scope.where("COALESCE(biz_days_overall, 0) >= 3").count
    @complete_count = current_organization.design_orders.complete.count
    @total_design_order_count = current_organization.design_orders.count
    @product_counts = @queue_scope.group(:product_name).order(Arel.sql("COUNT(*) DESC")).limit(8).count
    @designer_counts = @queue_scope.group(:designer_name).order(Arel.sql("COUNT(*) DESC")).limit(8).count
  end

  def show
    @design_report = current_organization.design_reports.includes(:user).find(params[:id])
    @design_orders = @design_report.design_orders.includes(:user).order(:row_number)
  end

  def create
    result = DesignReports::CsvImporter.call(
      organization: current_organization,
      user: current_user,
      file: params.dig(:design_report, :file),
      title: params.dig(:design_report, :title)
    )

    redirect_to design_report_return_path(result.report), notice: "Design report imported: #{result.created_count} new, #{result.updated_count} updated, #{result.completed_count} completed, #{result.skipped_count} skipped."
  rescue ArgumentError, CSV::MalformedCSVError, ActiveRecord::RecordInvalid => e
    redirect_to design_report_failure_path, alert: e.message
  end

  private

  def design_report_return_path(report)
    return train_path(anchor: "design-reports") if params.dig(:design_report, :return_to) == "train"

    design_report_path(report)
  end

  def design_report_failure_path
    return train_path(anchor: "design-reports") if params.dig(:design_report, :return_to) == "train"

    design_reports_path
  end
end
