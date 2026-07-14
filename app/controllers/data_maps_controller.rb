class DataMapsController < ApplicationController
  before_action :require_organization!

  def show
    @data_map = DataMaps::ReportPayloadMap.new(current_organization).call
  end
end
