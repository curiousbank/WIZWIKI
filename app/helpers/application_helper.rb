module ApplicationHelper
  def autos_brain_power_snapshot
    return unless authenticated? && current_organization.present?

    Autos::BrainPower.snapshot(current_organization)
  rescue StandardError => error
    Rails.logger.warn("Autos brain power snapshot failed: #{error.class} - #{error.message}")
    nil
  end

  def wizwiki_cloudinary_ui_asset_url(public_id, fallback: nil, **options)
    fallback ||= "#{public_id}.png"

    return asset_path(fallback) unless defined?(Cloudinary) && WizwikiSettings.cloudinary_configured?

    normalized = public_id.to_s.sub(%r{\A/+}, "").sub(/\.[a-zA-Z0-9]+\z/, "")
    cloudinary_id = [WizwikiSettings.cloudinary_folder, normalized].join("/")
    Cloudinary::Utils.cloudinary_url(
      cloudinary_id,
      secure: true,
      fetch_format: options.delete(:fetch_format) || :auto,
      quality: options.delete(:quality) || :auto,
      **options
    )
  rescue StandardError => error
    Rails.logger.warn("WIZWIKI Cloudinary asset fallback for #{public_id}: #{error.class}")
    asset_path(fallback)
  end

  def wizwiki_cloudinary_ui_image_tag(public_id, fallback: nil, **options)
    cloudinary_options = options.delete(:cloudinary) || {}
    image_tag(wizwiki_cloudinary_ui_asset_url(public_id, fallback:, **cloudinary_options), **options)
  end
end
