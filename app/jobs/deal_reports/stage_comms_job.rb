module DealReports
  class StageCommsJob < ApplicationJob
    queue_as :default

    def perform(organization_id:, user_id:, source_report_id: nil, claimed_by_user_id: nil, claimed_cards: false)
      organization = Organization.find(organization_id)
      user = User.find_by(id: user_id)

      if source_report_id.present?
        source_report = organization.crm_record_artifacts.find(source_report_id)
        DealReports::CommsStager.stage!(source_report: source_report, user: user, force: true)
      elsif claimed_cards
        DealReports::CommsStager.stage_claimed_records!(
          organization: organization,
          user: user,
          owner_id: claimed_by_user_id || user&.id
        )
      else
        DealReports::CommsStager.stage_all!(organization: organization, user: user, owner_id: claimed_by_user_id)
      end
    end
  end
end
