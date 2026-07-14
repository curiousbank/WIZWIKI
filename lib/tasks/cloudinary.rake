require "cloudinary/uploader"

namespace :cloudinary do
  desc "Upload Wizwiki static image assets to the configured Cloudinary folder"
  task sync_static: :environment do
    abort "Cloudinary is not configured for Wizwiki." unless WizwikiSettings.cloudinary_configured?

    folder = WizwikiSettings.cloudinary_folder
    files = Rails.root.glob("app/assets/images/*.{png,jpg,jpeg,webp,gif}")

    files.each do |path|
      public_id = [folder, path.basename(path.extname).to_s].join("/")
      Cloudinary::Uploader.upload(
        path.to_s,
        public_id: public_id,
        resource_type: "image",
        overwrite: true,
        invalidate: true
      )
      puts "uploaded #{public_id}"
    end

    puts "Uploaded #{files.count} Wizwiki image asset(s) to Cloudinary folder #{folder}."
  end
end
