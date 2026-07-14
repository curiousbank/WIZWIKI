module Crm
  class RecordsController < ApplicationController
    before_action :require_organization!
    before_action :set_record, only: [:show, :edit, :update, :destroy]

    def index
      @record_type = normalized_record_type(params[:record_type])
      @records = current_organization.crm_records
        .for_type(@record_type)
        .search(params[:q])
        .includes(:owner)
        .order(updated_at: :desc)
      @record_counts = CrmRecord::RECORD_TYPES.index_with { |type| current_organization.crm_records.where(record_type: type).count }
    end

    def show
      @property_definitions = property_definitions_for(@record.record_type)
      @duplicate_candidates = @record.duplicate_candidates.open.includes(:duplicate_record).recent
    end

    def new
      @record = current_organization.crm_records.new(record_type: normalized_record_type(params[:record_type]) || "contact")
      @property_definitions = property_definitions_for(@record.record_type)
    end

    def edit
      @property_definitions = property_definitions_for(@record.record_type)
    end

    def create
      result = RecordCreator.call(organization: current_organization, owner: current_user, attributes: record_attributes)

      if result.duplicate_record.present?
        redirect_to crm_record_path(result.duplicate_record), alert: "Duplicate blocked. This #{result.duplicate_record.record_type} already exists."
      elsif result.duplicate_candidates.any?
        redirect_to crm_record_path(result.record), alert: "Saved, but possible duplicates were found. Review before adding more data."
      else
        redirect_to crm_record_path(result.record), notice: "#{result.record.record_type.titleize} saved."
      end
    rescue ActiveRecord::RecordInvalid => e
      @record = e.record
      @property_definitions = property_definitions_for(@record.record_type)
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end

    def update
      if @record.update(record_attributes)
        duplicates = DuplicateDetector.call(@record)
        message = duplicates.any? ? "Record updated. Possible duplicates were found." : "Record updated."
        redirect_to crm_record_path(@record), notice: message
      else
        @property_definitions = property_definitions_for(@record.record_type)
        flash.now[:alert] = @record.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @record.update!(status: "archived")
      redirect_to crm_records_path(record_type: @record.record_type), notice: "#{@record.record_type.titleize} archived."
    end

    private

    def set_record
      @record = current_organization.crm_records.find(params[:id])
    end

    def normalized_record_type(value)
      type = value.to_s.downcase
      CrmRecord::RECORD_TYPES.include?(type) ? type : nil
    end

    def record_attributes
      attrs = params.require(:crm_record).permit(
        :record_type, :name, :email, :phone, :domain, :stage, :status, :amount, :close_date, :source, :source_uid,
        properties: {}
      )
      attrs[:record_type] = normalized_record_type(attrs[:record_type]) || "contact"
      attrs[:properties] = clean_properties(attrs[:properties])
      attrs
    end

    def clean_properties(properties)
      properties.to_h.transform_values { |value| value.is_a?(String) ? value.strip : value }.reject { |_key, value| value.blank? }
    end

    def property_definitions_for(record_type)
      current_organization.crm_property_definitions.active.for_type(record_type).order(:label)
    end
  end
end
