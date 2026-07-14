class BrainPowerController < ApplicationController
  before_action :require_organization!

  def show
    snapshot = Autos::BrainPower.snapshot(current_organization)

    render json: {
      configured: snapshot[:configured],
      model: snapshot[:model],
      reasoning_effort: snapshot[:reasoning_effort],
      budget: snapshot[:budget],
      used: snapshot[:used],
      breakdown: snapshot[:breakdown],
      remaining: snapshot[:remaining],
      percent_left: snapshot[:percent_left],
      window_hours: snapshot[:window_hours],
      status_label: snapshot[:status_label],
      generated_at: Time.current.iso8601
    }
  rescue StandardError => error
    Rails.logger.warn("Autos brain power endpoint failed: #{error.class} - #{error.message}")
    render json: { error: "brain power unavailable" }, status: :service_unavailable
  end
end
