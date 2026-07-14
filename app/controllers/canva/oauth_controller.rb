module Canva
  class OauthController < ApplicationController
    before_action :require_organization!

    def connect
      unless WizwikiSettings.canva_configured?
        return redirect_to deal_queue_path, alert: "Canva client ID/secret are not configured yet."
      end

      verifier = Canva::OauthClient.code_verifier
      state = Canva::OauthClient.state
      connection = current_organization.canva_connections.find_or_initialize_by(user: current_user)
      connection.update!(
        status: "pending",
        code_verifier: verifier,
        state: state,
        metadata: connection.metadata.to_h.merge(
          "requested_scopes" => WizwikiSettings.canva_scopes,
          "started_at" => Time.current.iso8601
        )
      )

      redirect_to Canva::OauthClient.authorization_url(code_verifier: verifier, state: state), allow_other_host: true
    rescue Canva::OauthError, ActiveRecord::ActiveRecordError => error
      redirect_to deal_queue_path, alert: "Canva connect failed: #{error.message}"
    end

    def callback
      if params[:error].present?
        return redirect_to deal_queue_path, alert: "Canva authorization failed: #{params[:error_description].presence || params[:error]}"
      end

      state = params[:state].to_s
      connection = current_organization.canva_connections.find_by!(user: current_user, state: state)
      Canva::OauthClient.new(connection).exchange_code!(params[:code].to_s)

      redirect_to deal_queue_path, notice: "Canva connected. WIZWIKI can now create Canva Autofill jobs for this account."
    rescue ActiveRecord::RecordNotFound
      redirect_to deal_queue_path, alert: "Canva authorization state was not recognized. Start the connect flow again."
    rescue Canva::OauthError, ActiveRecord::ActiveRecordError => error
      redirect_to deal_queue_path, alert: "Canva authorization failed: #{error.message}"
    end
  end
end
