namespace :hubspot do
  desc "Sync HubSpot deals from the last 30 days into WIZWIKI CRM records"
  task sync_deals: :environment do
    organization = if ENV["ORGANIZATION_ID"].present?
      Organization.find(ENV.fetch("ORGANIZATION_ID"))
    else
      Organization.order(:created_at).first
    end

    abort "No organization found." unless organization

    result = Hubspot::DealSync.call(organization: organization, since: 30.days.ago)
    puts "HubSpot deals synced: #{result.created_count} created, #{result.updated_count} updated, #{result.unchanged_count} unchanged."
  end
end
