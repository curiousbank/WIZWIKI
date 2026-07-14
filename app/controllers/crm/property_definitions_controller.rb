module Crm
  class PropertyDefinitionsController < ApplicationController
    before_action :require_organization!
    before_action :set_property_definition, only: [:edit, :update, :destroy]

    def index
      @property_definitions = current_organization.crm_property_definitions.order(:record_type, :label)
    end

    def new
      @property_definition = current_organization.crm_property_definitions.new(record_type: params[:record_type].presence || "contact")
    end

    def edit
    end

    def create
      @property_definition = current_organization.crm_property_definitions.new(property_definition_params)

      if @property_definition.save
        redirect_to crm_property_definitions_path, notice: "Property created."
      else
        flash.now[:alert] = @property_definition.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @property_definition.update(property_definition_params)
        redirect_to crm_property_definitions_path, notice: "Property updated."
      else
        flash.now[:alert] = @property_definition.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @property_definition.update!(active: false)
      redirect_to crm_property_definitions_path, notice: "Property archived."
    end

    private

    def set_property_definition
      @property_definition = current_organization.crm_property_definitions.find(params[:id])
    end

    def property_definition_params
      params.require(:crm_property_definition).permit(:record_type, :key, :label, :data_type, :required, :unique_value, :active)
    end
  end
end
