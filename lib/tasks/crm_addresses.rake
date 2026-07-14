namespace :crm do
  desc "Extract address records from local HubSpot CRM records and playbook associations"
  task backfill_addresses: :environment do
    Organization.find_each do |organization|
      result = Crm::AddressBackfill.call(organization: organization)
      puts "#{organization.slug}: #{result.to_h.inspect}"
    end
  end
end
