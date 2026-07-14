class DashboardController < ApplicationController
  before_action :require_organization!

  def index
    @record_counts = CrmRecord::RECORD_TYPES.index_with do |type|
      current_organization.crm_records.where(record_type: type).count
    end
    @open_duplicates = current_organization.duplicate_candidates.open.count
    @recent_records = current_organization.crm_records.includes(:owner).order(updated_at: :desc).limit(8)
    if current_user.primary_membership&.admin?
      @pending_training_document_count = current_organization.training_documents.where(status: "ingested").count
      @pending_training_vault_count = current_organization.training_vault_documents.active.where(status: "review").count
    end
  end
end
