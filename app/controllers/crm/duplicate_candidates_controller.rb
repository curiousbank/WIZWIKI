module Crm
  class DuplicateCandidatesController < ApplicationController
    before_action :require_organization!

    def index
      @duplicate_candidates = current_organization.duplicate_candidates.open.includes(:crm_record, :duplicate_record).recent
    end

    def update
      duplicate = current_organization.duplicate_candidates.find(params[:id])
      duplicate.update!(status: params[:status].presence_in(DuplicateCandidate::STATUSES) || "ignored")
      redirect_to crm_duplicate_candidates_path, notice: "Duplicate review updated."
    end
  end
end
