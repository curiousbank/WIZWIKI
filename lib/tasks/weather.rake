namespace :weather do
  desc "Import HUD USPS county-to-ZIP crosswalk rows from CSV or HUD API"
  task import_zip_crosswalk: :environment do
    path = ENV["WIZWIKI_WEATHER_ZIP_CROSSWALK_PATH"].presence
    states = ENV.fetch("WIZWIKI_WEATHER_CROSSWALK_STATES", "").split(",")
    source = ENV["WIZWIKI_WEATHER_CROSSWALK_SOURCE"].presence
    source_version = ENV["WIZWIKI_WEATHER_CROSSWALK_VERSION"].presence

    result = Weather::ZipCrosswalkImporter.call(
      path: path,
      states: states,
      source: source,
      source_version: source_version
    )
    puts result.to_h.inspect
  end

  desc "Run Storm Watch weather lead scan now"
  task sync_leads: :environment do
    Organization.find_each do |organization|
      result = Weather::LeadSignalSync.call(organization: organization)
      puts "#{organization.slug}: #{result.to_h.inspect}"
    end
  end
end
