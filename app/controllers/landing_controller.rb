class LandingController < ApplicationController
  allow_unauthenticated_access

  def index
    @quick_cart_packages = QuickCartsController::PUBLIC_PACKAGES.map do |public_name, package|
      {
        name: public_name.tr("_", " "),
        value: public_name.downcase,
        headline: WizwikiSettings.square_package_label(package),
        detail: quick_cart_package_detail(package),
        standard_price: WizwikiSettings.square_package_price_label(package, production_speed: "standard"),
        skip_line_price: WizwikiSettings.square_package_price_label(package, production_speed: "skip_line")
      }
    end
    @square_application_id = WizwikiSettings.square_application_id.to_s
    @square_location_id = WizwikiSettings.square_location_id.to_s
    @square_environment = WizwikiSettings.square_mode.to_s.downcase
    @square_frontend_configured = WizwikiSettings.square_frontend_configured?
    @square_server_configured = WizwikiSettings.square_server_configured?
  end

  private

  def quick_cart_package_detail(package)
    case package
    when "STARTER" then "Starter campaign intake."
    when "PRIORITY" then "Priority creative direction."
    when "FULL_LAUNCH" then "Highest-touch campaign start."
    else "Express design lane."
    end
  end
end
