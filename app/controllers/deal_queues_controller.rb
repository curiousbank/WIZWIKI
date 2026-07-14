require "stringio"
require "zip"

class DealQueuesController < ApplicationController
  REPORT_FIELD_LABELS = Hubspot::TicketSync::REPORT_PROPERTY_LABELS.freeze
  MAX_MEDIA_UPLOADS = 10
  MAX_MEDIA_UPLOAD_SIZE = 50.megabytes
  REPORT_LIST_LIMIT = 24
  LEAD_CARD_LIMIT = 100
  TICKET_PIPELINE_ALL_VALUE = "all".freeze
  TICKET_STATUS_ALL_VALUE = "all".freeze
  LEAD_SOURCE_ALL_VALUE = "all".freeze
  LEAD_SOURCE_SAM_VALUE = "sam_tickets".freeze
  LEAD_SOURCE_FACEBOOK_VALUE = "facebook".freeze
  LEAD_SOURCE_SHOPIFY_VALUE = "shopify".freeze
  LEAD_SOURCE_HAYMARKET_VALUE = "haymarket".freeze
  LEAD_SOURCE_WEATHER_VALUE = "weather".freeze
  LEAD_SOURCE_OWNER_QUEUE_VALUE = "owner_queue".freeze
  LEAD_SOURCE_CLAIMED_BY_ME_VALUE = "claimed_by_me".freeze
  LEAD_SOURCE_ALL_CONTACTS_VALUE = "all_contacts".freeze
  LEAD_SOURCE_OPTIONS = [
    {
      value: LEAD_SOURCE_OWNER_QUEUE_VALUE,
      label: "Owner Queue",
      short_label: "SAMPLE_OWNER",
      description: "Owner-assigned HubSpot leads and hydrated WIZWIKI COMMS records ready for report and outreach work"
    },
    {
      value: LEAD_SOURCE_CLAIMED_BY_ME_VALUE,
      label: "Claimed by me",
      short_label: "MINE",
      description: "All lead cards claimed by the current user and ready to load into WIZWIKI COMMS"
    },
    {
      value: LEAD_SOURCE_ALL_VALUE,
      label: "ALL",
      short_label: "ALL",
      description: "Owner Queue, SAM tickets, Facebook, Shopify, Haymarket, and Storm Watch leads in one combined lane"
    },
    {
      value: LEAD_SOURCE_SAM_VALUE,
      label: "SAM tickets",
      short_label: "SAM",
      description: "Current 90-day ticket-backed SAM lane"
    },
    {
      value: LEAD_SOURCE_FACEBOOK_VALUE,
      label: "Facebook",
      short_label: "FB",
      description: "90-day contact search using Facebook click, inquiry, and source fields"
    },
    {
      value: LEAD_SOURCE_SHOPIFY_VALUE,
      label: "Shopify",
      short_label: "SHOP",
      description: "90-day contact search using Shopify customer and order fields"
    },
    {
      value: LEAD_SOURCE_HAYMARKET_VALUE,
      label: "Haymarket",
      short_label: "HAY",
      description: "90-day contact search using Haymarket inbound lead, SMS, and source fields"
    },
    {
      value: LEAD_SOURCE_WEATHER_VALUE,
      label: "Storm Watch",
      short_label: "STORM",
      description: "Weather.gov storm and disaster signals matched to nearby construction-trade CRM addresses"
    }
  ].freeze

  before_action :require_organization!
  before_action :set_deal, only: [:claim, :update_priority, :queue_report, :report_status, :upload_media, :destroy_media]
  helper_method :deal_queue_report_fields, :hubspot_deal_value, :deal_company_name, :deal_claim_label,
    :deal_claimed?, :deal_claimed_by_current_user?, :deal_media_icon, :report_downloadable?,
    :report_manifest, :report_publisher, :report_quality, :report_display_title,
    :report_local_path, :report_model, :report_completed_at, :report_byte_size,
    :report_logo_status, :report_quality_errors, :deal_completed_report_count, :report_lane_options, :report_local_model_options,
    :report_embedder_model_options, :report_challenger_model_options, :report_requested_embedder,
    :report_requested_model, :report_actual_model, :report_model_mismatch?,
    :report_document_downloadable?, :canva_kit_downloadable?, :canva_output_downloadable?, :canva_pdf_downloadable?,
    :report_document_url, :report_document_preview_url, :canva_kit_url, :canva_output_url, :canva_pdf_url, :canva_status_label, :report_processing_status_label,
    :report_build_timing, :report_duration_label, :report_build_time_summary,
    :deal_watch_artifact, :report_watch_lines,
    :deal_priority_level, :deal_priority_label, :deal_priority?, :deal_priority_source, :deal_priority_badge_class,
    :weather_lead_signals_for,
    :comm_kit_report?, :comm_stage_for_report, :comm_stage_sms_options, :comm_stage_email_options,
    :comm_stage_contact_options, :comm_stage_phone_options, :comm_stage_recipient_email_options,
    :comm_stage_address_options, :comm_stage_selected_sms, :comm_stage_selected_email,
    :comm_stage_selected_contact, :comm_stage_selected_phone, :comm_stage_selected_recipient_email,
    :comm_stage_selected_address, :comm_stage_aircall_ready?, :comm_stage_status_label, :industry_strategy_lens_options

  def index
    @hubspot_configured = WizwikiSettings.hubspot_configured?
    @canva_configured = WizwikiSettings.canva_configured?
    @canva_connection = current_organization.canva_connections.find_by(user: current_user)
    @canva_template_configured = WizwikiSettings.canva_brand_template_id.present?
    @lead_source_options = lead_source_options
    @active_lead_source = active_lead_source
    @active_lead_source_option = active_lead_source_option
    @active_lead_source_label = @active_lead_source_option[:label]
    @lead_source_counts = lead_source_counts
    @ticket_pipeline_filters_enabled = sam_ticket_lead_source?
    @ticket_pipeline_options = ticket_pipeline_options
    @active_ticket_status_value = @ticket_pipeline_filters_enabled ? active_ticket_status_value : nil
    @active_pipeline_id = @ticket_pipeline_filters_enabled ? active_ticket_status_pipeline_id.presence || active_ticket_pipeline_id : nil
    @active_pipeline_label = @ticket_pipeline_filters_enabled ? ticket_pipeline_label_for(@active_pipeline_id) : @active_lead_source_label
    @active_ticket_status_label = @ticket_pipeline_filters_enabled ? ticket_status_label_for_value(@active_ticket_status_value) : nil
    filtered_scope = filtered_deals
    @filtered_count = filtered_scope.count
    @deals = filtered_scope.left_joins(:owner).includes(:owner, :crm_record_artifacts, deal_media_attachments: :blob).order(queue_sort_sql).limit(LEAD_CARD_LIMIT)
    @visible_count = @deals.size
    @stages = base_deals.where.not(stage: [nil, ""]).distinct.order(:stage).pluck(:stage)
    @total_count = base_deals.count
    @hubspot_count = base_deals.where(source: ["hubspot_ticket", "hubspot", "hubspot_contact"]).count
    @claimed_count = base_deals.where.not(owner_id: nil).count
    @my_claimed_count = lead_source_count_for(LEAD_SOURCE_CLAIMED_BY_ME_VALUE)
    @priority_count = base_deals.where(priority_where_sql).count
    @unclaimed_count = base_deals.where(owner_id: nil).count
    @open_count = base_deals.where(status: "open").count
    @won_count = base_deals.where(status: "won").count
    @lost_count = base_deals.where(status: "lost").count
    @recent_count = @hubspot_count
    report_scope = current_organization.crm_record_artifacts.where(artifact_type: "market_report")
    @report_queue = report_scope.includes(:crm_record, :user).where(status: %w[queued generating report_ready]).joins(:crm_record).order(Arel.sql(report_artifact_sort_sql)).limit(REPORT_LIST_LIMIT)
    @queued_report_count = report_scope.where(status: %w[queued generating report_ready]).count
    @completed_report_count = report_scope.where(status: %w[canva_kit_ready ready]).count +
      report_scope.where(status: "archived").where("metadata -> 'canva_kit' ->> 'storage_key' IS NOT NULL").count
    my_report_scope = report_scope.joins(:crm_record).where(crm_records: { owner_id: current_user.id })
    @comm_kit_ready_count = my_report_scope.where(status: %w[report_ready canva_kit_ready ready archived])
      .where("metadata ->> 'report_audience' = ?", "copy_maker")
      .where("metadata ->> 'copy_maker_comm_kit_enabled' = ?", "true")
      .count
    @comm_staged_count = current_organization.crm_record_artifacts
      .joins(:crm_record)
      .where(crm_records: { owner_id: current_user.id })
      .where(artifact_type: "comm_staging", status: %w[staged aircall_ready])
      .where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "manual_comms")
      .where("crm_record_artifacts.metadata ->> 'claimed_call_source' = ?", "true")
      .count
    @claim_owners = User.where(id: base_deals.where.not(owner_id: nil).select(:owner_id)).order(Arel.sql("LOWER(COALESCE(NULLIF(users.name, ''), users.email_address)) ASC"))
    @ticket_sync_status = Hubspot::TicketSyncStatus.for(current_organization)
    if current_user.primary_membership&.admin?
      @voice_training_documents = voice_training_document_scope.limit(80)
      @fine_training_embedding_status = fine_training_embedding_status
    end
  end

def sync
  return_lead_source = active_lead_source
  lead_source = LEAD_SOURCE_ALL_CONTACTS_VALUE
  request_id = nil
  sync_status = Hubspot::TicketSyncStatus.for(current_organization)
  if sync_status[:contact_sync_active]
    return redirect_to deal_queue_path(lead_source: return_lead_source), notice: "HubSpot 90-day contact sync is already running. The status panel will update when it finishes."
  end

  with_expensive_action_gate("hubspot_contact_sync", ttl: 90.seconds) do |acquired|
    unless acquired
      redirect_to deal_queue_path(lead_source: return_lead_source), notice: "HubSpot contact sync is already being started. The status panel will update when it is queued."
      return
    end

    request_id = SecureRandom.uuid
    requested_at = Time.current
    Hubspot::TicketSyncStatus.mark_queued!(
      organization: current_organization,
      request_id: request_id,
      requested_by_user_id: current_user.id,
      requested_by: current_user.display_name,
      requested_at: requested_at,
      lead_source: lead_source,
      record_type: "contact"
    )
    job = Hubspot::ContactLeadSyncJob.perform_later(
      organization_id: current_organization.id,
      lead_source: lead_source,
      requested_by_user_id: current_user.id,
      requested_at: requested_at.iso8601,
      request_id: request_id
    )
    Hubspot::TicketSyncStatus.mark_enqueued!(
      organization: current_organization,
      request_id: request_id,
      job_id: job.job_id
    )
    redirect_to deal_queue_path(lead_source: return_lead_source), notice: "HubSpot 90-day contact sync started. WIZWIKI will keep working in the background; the source lanes will update as contacts are imported."
  end
rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError => error
  Hubspot::TicketSyncStatus.mark_failed!(organization: current_organization, error: error, request_id: request_id, job_id: nil) if defined?(request_id) && request_id.present?
  Rails.logger.warn("HubSpot lead sync enqueue failed: #{error.class}: #{error.message}")
  redirect_to deal_queue_path(lead_source: defined?(return_lead_source) ? return_lead_source : LEAD_SOURCE_SAM_VALUE), alert: "HubSpot contact sync could not start: #{error.message}"
end

def sync_status
  render json: { ok: true }.merge(Hubspot::TicketSyncStatus.for(current_organization)).merge(
    weather_scan: Weather::ScanStatus.for(current_organization)
  )
end

def sync_weather
  request_id = nil
  return_path = params[:return_to].to_s == "weather" ? weather_path : deal_queue_path(lead_source: LEAD_SOURCE_WEATHER_VALUE)
  scan_status = Weather::ScanStatus.for(current_organization)
  if scan_status[:active]
    return redirect_to return_path, notice: "Storm Watch is already #{scan_status[:state_label]}. The progress panel will update when it finishes."
  end
  if scan_status[:fresh_today]
    return redirect_to return_path, notice: "#{scan_status[:daily_lock_label]} Today's shared Storm Watch results are already available to Report Maker and WIZWIKI COMMS."
  end

  with_expensive_action_gate("weather_scan", ttl: 90.seconds) do |acquired|
    unless acquired
      redirect_to return_path, notice: "Storm Watch is already being queued. The progress panel will update shortly."
      return
    end

    request_id = SecureRandom.uuid
    requested_at = Time.current
    Weather::ScanStatus.mark_queued!(
      organization: current_organization,
      request_id: request_id,
      requested_by_user_id: current_user&.id,
      requested_by: current_user&.display_name,
      requested_at: requested_at
    )
    job = Weather::LeadSignalSyncJob.perform_later(
      organization_id: current_organization.id,
      requested_by_user_id: current_user&.id,
      requested_at: requested_at.iso8601,
      request_id: request_id
    )
    Weather::ScanStatus.mark_enqueued!(
      organization: current_organization,
      request_id: request_id,
      job_id: job.job_id
    )

    redirect_to return_path, notice: "Storm Watch scan queued. Thumper will pull active Weather.gov alerts, match nearby CRM addresses, and refresh this lane."
  end
rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError, Weather::LeadSignalSync::Error => error
  Weather::ScanStatus.mark_failed!(organization: current_organization, error: error, request_id: request_id, job_id: nil) if defined?(request_id) && request_id.present?
  Rails.logger.warn("Weather lead scan enqueue failed: #{error.class}: #{error.message}")
  redirect_to (params[:return_to].to_s == "weather" ? weather_path : deal_queue_path(lead_source: LEAD_SOURCE_WEATHER_VALUE)), alert: "Storm Watch scan could not start: #{error.message}"
end


  def update_priority
    level = params[:priority_level].to_s.strip.downcase
    unless CrmRecord::PRIORITY_LEVELS.include?(level)
      return redirect_back fallback_location: deal_queue_path, alert: "Unknown priority level."
    end

    note = params[:priority_note].to_s.strip.presence
    attrs = { priority_level: level }
    if level == "normal"
      attrs.merge!(priority_note: nil, priority_marked_at: nil, priority_marked_by: nil)
    else
      attrs.merge!(priority_note: note, priority_marked_at: Time.current, priority_marked_by: current_user)
    end

    @deal.update!(attrs)
    sync_active_report_priorities!(@deal)

    message = if level == "normal"
      "Cleared priority for #{deal_company_name(@deal)}."
    else
      "Marked #{deal_company_name(@deal)} as #{level.upcase}. It will surface ahead of standard report work."
    end
    redirect_back fallback_location: deal_queue_path, notice: message
  rescue ActiveRecord::ActiveRecordError => error
    redirect_back fallback_location: deal_queue_path, alert: "Could not update priority: #{error.message}"
  end

def claim
  if @deal.owner_id.blank?
    @deal.update!(owner: current_user)
    redirect_back fallback_location: deal_queue_path, notice: "Claimed #{deal_company_name(@deal)} for your AM queue."
  elsif @deal.owner_id == current_user.id
    @deal.update!(owner: nil)
    redirect_back fallback_location: deal_queue_path, notice: "Unclaimed #{deal_company_name(@deal)} from your AM queue."
  else
    redirect_back fallback_location: deal_queue_path, alert: "#{deal_company_name(@deal)} is already claimed by #{deal_claim_label(@deal)}."
  end
end

  def remove_report_from_queue
    artifact = current_organization.crm_record_artifacts.where(artifact_type: "market_report").find(params[:id])
    dom_id = "deal-report-queue-item-#{artifact.id}"
    artifact.update!(status: "archived")

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(dom_id) }
      format.html { redirect_back fallback_location: deal_queue_path, notice: "Removed #{artifact.title} from the AM report queue." }
    end
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: deal_queue_path, alert: "AM report request not found."
  rescue ActiveRecord::ActiveRecordError => error
    redirect_back fallback_location: deal_queue_path, alert: "Could not remove AM report request: #{error.message}"
  end

def run_all_comms
  claimed_count = lead_source_count_for(LEAD_SOURCE_CLAIMED_BY_ME_VALUE)
  job = DealReports::StageCommsJob.perform_later(
    organization_id: current_organization.id,
    user_id: current_user.id,
    claimed_by_user_id: current_user.id,
    claimed_cards: true
  )
  redirect_to comms_command_path(status: "active"), notice: "LOAD MY COMMS queued. Thumper will stage #{claimed_count} claimed call card#{'s' unless claimed_count == 1} into shared WIZWIKI COMMS. Job #{job.job_id}."
rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError => error
  redirect_back fallback_location: deal_queue_path, alert: "Could not queue LOAD MY COMMS: #{error.message}"
end

def prepare_report_comms
  source_report = current_organization.crm_record_artifacts.where(artifact_type: "market_report").find(params[:id])
  unless crm_record_claimed_by_current_user?(source_report.crm_record)
    return redirect_back fallback_location: deal_queue_path, alert: "Claim this lead before preparing WIZWIKI COMMS."
  end

  DealReports::StageCommsJob.perform_later(
    organization_id: current_organization.id,
    user_id: current_user.id,
    source_report_id: source_report.id
  )
  redirect_back fallback_location: deal_queue_path, notice: "COMMS staging queued for #{source_report.title}. Refresh shortly to review Thumper's selected text and email."
rescue ActiveRecord::RecordNotFound
  redirect_back fallback_location: deal_queue_path, alert: "COMM KIT report not found."
rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError => error
  redirect_back fallback_location: deal_queue_path, alert: "Could not queue COMMS staging: #{error.message}"
end

def run_comms_stage
  stage = current_organization.crm_record_artifacts.where(artifact_type: "comm_staging").find(params[:id])
  unless crm_record_claimed_by_current_user?(stage.crm_record)
    return redirect_back fallback_location: deal_queue_path, alert: "Claim this lead before saving WIZWIKI COMMS work."
  end

  DealReports::CommsStager.mark_aircall_ready!(
    stage: stage,
    sms_id: params[:selected_sms_id],
    email_id: params[:selected_email_id],
    contact_id: params[:selected_contact_id],
    phone_id: params[:selected_phone_id],
    recipient_email_id: params[:selected_recipient_email_id],
    address_id: params[:selected_address_id],
    sender_name_override: params[:sender_name_override],
    sms_body_override: params[:sms_body_override],
    email_subject_override: params[:email_subject_override],
    email_body_override: params[:email_body_override],
    user: current_user
  )
  redirect_back fallback_location: deal_queue_path, notice: "Saved work for #{stage.title}. It is staged for the Run All Calls batch. No message was sent yet."
rescue ActiveRecord::RecordNotFound
  redirect_back fallback_location: deal_queue_path, alert: "COMMS staging record not found."
rescue ActiveRecord::ActiveRecordError => error
  redirect_back fallback_location: deal_queue_path, alert: "Could not save WIZWIKI COMMS work: #{error.message}"
end

def queue_report
  return unless ensure_current_user_claimed_deal!

  audience = report_audience
  selected_lane = report_lane_param
  selected_model = WizwikiSettings.normalize_report_local_model(selected_lane[:report_local_model])
  selected_model_ladder = Array(selected_lane[:report_model_ladder].presence || [selected_model])
    .map { |model| WizwikiSettings.normalize_report_local_model(model) }
    .reject(&:blank?)
  selected_model_label = WizwikiSettings.report_local_model_label(selected_model)
  selected_embedder = WizwikiSettings.normalize_report_embedder_model(selected_lane[:report_embedder_model])
  selected_embedder_label = WizwikiSettings.report_embedder_model_label(selected_embedder)
  selected_challenger = report_challenger_model_param
  selected_challenger_label = WizwikiSettings.challenger_model_label(selected_challenger)
  preflight_scan_enabled = truthy_param?(params[:report_preflight_scan])
  post_review_enabled = truthy_param?(params[:report_post_review])
  page_visual_qa_enabled = truthy_param?(params[:report_page_visual_qa])
  design_press_enabled = truthy_param?(params[:report_design_press])
  design_press_template = report_design_press_template_param
  design_press_style = report_design_press_style_param
  design_press_output = report_design_press_output_param
  design_press_notes = design_press_enabled ? report_design_press_notes_param : nil
  report_context_prompt = report_context_prompt_param
  hubspot = (@deal.properties || {}).to_h.fetch("hubspot", {}).to_h
  labeled = hubspot.fetch("labeled_properties", {}).to_h
  raw = hubspot.fetch("properties", {}).to_h
  industry_strategy_lens = industry_strategy_lens_param
  industry_strategy = DealReports::IndustryStrategyPlaybook.payload_for(
    industry_strategy_lens,
    crm_record: @deal,
    labeled: labeled,
    raw: raw,
    company_name: deal_company_name(@deal),
    industry: hubspot_deal_value(@deal, "Industry"),
    services: hubspot_deal_value(@deal, "Main Services").presence || hubspot_deal_value(@deal, "Deal Description").presence || @deal.name,
    audience: audience
  )
  copy_maker_comm_kit_enabled = audience == "copy_maker" && truthy_param?(params[:copy_maker_comm_kit])
  copy_maker_comm_kit_direction = copy_maker_comm_kit_enabled ? copy_maker_comm_kit_direction_param : nil
  copy_maker_local_prep_enabled = audience == "copy_maker" && truthy_param?(params[:copy_maker_local_prep])
  copy_maker_prompt = audience == "copy_maker" ? report_context_prompt.presence || default_copy_maker_prompt(comm_kit: copy_maker_comm_kit_enabled, direction: copy_maker_comm_kit_direction) : nil
  copy_maker_cloud = audience == "copy_maker" ? copy_maker_cloud_config(report_copy_maker_cloud_provider_param) : copy_maker_cloud_config("nvidia")
  active_report = @deal.crm_record_artifacts
    .where(artifact_type: "market_report", status: %w[queued generating report_ready])
    .where("COALESCE(metadata ->> 'report_audience', 'client') = ?", audience)
    .order(created_at: :desc)
    .first
  if active_report.present?
    return redirect_back fallback_location: deal_queue_path, notice: "#{report_audience_label(audience)} report already #{active_report.status} for #{deal_company_name(@deal)}. The WIZWIKI market analyzer will pick it up from the queue."
  end

  report_number = @deal.crm_record_artifacts.where(artifact_type: "market_report").count + 1
  comms_sender_profile = current_user_comm_profile
  title_prefix = case audience
  when "am" then "AM strategy brief"
  when "copy_maker" then "Copy Maker"
  else "Client proposal"
  end
  weather_opportunity = report_weather_opportunity_payload(@deal)

  @deal.crm_record_artifacts.create!(
    user: current_user,
    artifact_type: "market_report",
    status: "queued",
    title: "#{title_prefix} #{report_number}: #{deal_company_name(@deal)}",
    metadata: {
      "queued_from" => "deal_queue",
      "queued_by_user_id" => current_user.id,
      "queued_by" => current_user.display_name,
      "queued_by_phone" => current_user.display_phone_number,
      "report_number" => report_number,
      "report_audience" => audience,
      "report_mode" => audience,
      "report_lane" => selected_lane[:value],
      "report_lane_label" => selected_lane[:label],
      "report_lane_description" => selected_lane[:description],
      "report_model_ladder" => selected_model_ladder,
      "report_model_flow" => selected_model_ladder.join(" -> "),
      "report_rounds" => selected_model_ladder.size,
      "report_retry_strategy" => "second_pass_vectorizes_hubspot_first_draft_and_quality_errors",
      "report_local_model" => selected_model,
      "report_local_model_label" => selected_model_label,
      "target_model" => selected_model,
      "ai_provider" => "qwen/local",
      "report_embedder_model" => selected_embedder,
      "report_embedder_model_label" => selected_embedder_label,
      "embedding_provider" => "ollama/local",
      "report_challenger_model" => selected_challenger,
      "report_challenger_model_label" => selected_challenger_label,
      "report_challenger_policy" => "Qwen 3 30B writes; the selected challenger reviews when polish/review is enabled.",
      "report_preflight_scan_enabled" => preflight_scan_enabled,
      "report_preflight_vision_model" => "qwen3-vl:8b",
      "report_preflight_ocr_model" => "glm-ocr:bf16",
      "report_post_review_enabled" => post_review_enabled,
      "report_post_review_model" => selected_challenger,
      "report_page_visual_qa_enabled" => page_visual_qa_enabled,
      "report_page_visual_qa_model" => "qwen3-vl:8b",
      "report_page_visual_qa_renderer" => "libreoffice+poppler",
      "report_design_press_enabled" => design_press_enabled,
      "report_design_press_stage" => design_press_enabled ? "queued" : "off",
      "report_design_press_template" => design_press_template,
      "report_design_press_style" => design_press_style,
      "report_design_press_output" => design_press_output,
      "report_design_press_notes" => design_press_notes,
      "report_design_press_renderer" => "alice-design-press",
      "report_context_prompt" => report_context_prompt,
      "industry_strategy_lens" => industry_strategy_lens,
      "industry_strategy" => industry_strategy,
      "industry_strategy_label" => industry_strategy["label"],
      "industry_strategy_detected" => industry_strategy["industry"],
      "industry_strategy_confidence" => industry_strategy["confidence"],
      "industry_strategy_campaigns" => Array(industry_strategy["campaign_types"]).first(8),
      "industry_strategy_output_sections" => Array(industry_strategy["output_sections"]).first(10),
      "weather_opportunity" => weather_opportunity,
      "weather_opportunity_active" => weather_opportunity["active"],
      "weather_opportunity_summary" => weather_opportunity["summary"],
      "copy_maker_enabled" => audience == "copy_maker",
      "copy_maker_comm_kit_enabled" => copy_maker_comm_kit_enabled,
      "copy_maker_comm_kit_direction" => copy_maker_comm_kit_direction,
      "copy_maker_comm_kit_direction_label" => copy_maker_comm_kit_direction_label(copy_maker_comm_kit_direction),
      "copy_maker_sender_profile" => comms_sender_profile,
      "copy_maker_local_prep_enabled" => copy_maker_local_prep_enabled,
      "copy_maker_deliverables" => copy_maker_deliverables(copy_maker_comm_kit_enabled),
      "copy_maker_comm_kit_contract" => copy_maker_comm_kit_enabled ? copy_maker_comm_kit_contract(copy_maker_comm_kit_direction, sender_profile: comms_sender_profile, industry_strategy: industry_strategy) : nil,
      "copy_maker_prompt" => copy_maker_prompt,
      "copy_maker_cloud_provider" => copy_maker_cloud[:provider],
      "copy_maker_cloud_label" => copy_maker_cloud[:label],
      "copy_maker_cloud_model" => copy_maker_cloud[:model],
      "copy_maker_cloud_base_url" => copy_maker_cloud[:base_url],
      "copy_maker_cloud_api_key_env" => copy_maker_cloud[:api_key_env],
      "copy_maker_pipeline" => copy_maker_pipeline(copy_maker_cloud[:provider], local_prep: copy_maker_local_prep_enabled),
      "hubspot_record_id" => @deal.source_uid,
      "company_name" => deal_company_name(@deal),
      "ticket_name" => @deal.name,
      "industry" => hubspot_deal_value(@deal, "Industry"),
      "amount" => @deal.amount&.to_s,
      "stage" => @deal.stage,
      "close_date" => @deal.close_date&.iso8601,
      "requested_output" => requested_output_for_report(audience, copy_maker_comm_kit: copy_maker_comm_kit_enabled, copy_maker_comm_kit_direction: copy_maker_comm_kit_direction),

      "priority_level" => deal_priority_level(@deal),
      "priority_label" => deal_priority_label(@deal),
      "priority_source" => deal_priority_source(@deal),
      "priority_note" => @deal.priority_note,
      "priority_marked_at" => @deal.priority_marked_at&.iso8601,
      "priority_marked_by" => @deal.priority_marked_by&.display_name,
      "uploaded_media_count" => @deal.deal_media.attachments.count,
      "uploaded_media_filenames" => @deal.deal_media.attachments.map { |attachment| attachment.filename.to_s }
    }
  )

  redirect_back fallback_location: deal_queue_path, notice: "#{report_audience_label(audience)} report #{report_number} queued for #{deal_company_name(@deal)} using #{selected_model_label} + #{selected_embedder_label}."
rescue ActiveRecord::ActiveRecordError => error
  redirect_back fallback_location: deal_queue_path, alert: "Could not queue report: #{error.message}"
end

def truthy_param?(value)
  ActiveModel::Type::Boolean.new.cast(value)
end

def report_design_press_template_param
  allowed = %w[market_one_sheet data_postcard executive_proposal neighborhood_blitz]
  safe_param(params[:report_design_press_template], allowed, "market_one_sheet")
end

def report_design_press_style_param
  allowed = %w[wizwiki_clean bold_postcard glossy_cyber classic_print]
  safe_param(params[:report_design_press_style], allowed, "wizwiki_clean")
end

def report_design_press_output_param
  allowed = %w[print_png_pdf canva_safe_png docx_visual_packet]
  safe_param(params[:report_design_press_output], allowed, "print_png_pdf")
end

def report_design_press_notes_param
  params[:report_design_press_notes].to_s.squish.first(280).presence
end

def report_context_prompt_param
  params[:report_context_prompt].to_s.squish.first(1_200).presence
end

def copy_maker_comm_kit_direction_param
  safe_param(params[:copy_maker_comm_kit_direction], %w[wizwiki_out client_out], "wizwiki_out")
end

def copy_maker_comm_kit_direction_label(value)
  case value.to_s
  when "client_out" then "CLIENT OUT"
  else "WIZWIKI OUT"
  end
end

def default_copy_maker_prompt(comm_kit: false, direction: "wizwiki_out")
  if comm_kit
    if direction.to_s == "client_out"
      "Create a CLIENT OUT COMM KIT from the related CRM data: three client-branded SMS/text messages and two friendly sales email templates that the business can send from its own CRM to customers and prospects."
    else
      "Create a WIZWIKI OUT COMM KIT from the related CRM data: include a Recipient & Address Review with associated names, roles, contact ranking reason, available addresses, and recommended contact path; then write three concise SMS messages and two useful email templates for the best business decision maker. Use only reviewed organization facts and the provided sender profile. Reference prior activity only when supported by CRM or playbook data."
    end
  else
    "Create useful client-ready marketing copy from the related CRM data."
  end
end

def copy_maker_deliverables(comm_kit_enabled)
  return [] unless comm_kit_enabled

  %w[sms_warm sms_helpful sms_urgent email_intro email_follow_up]
end

def copy_maker_comm_kit_contract(direction = "wizwiki_out", sender_profile: nil, industry_strategy: nil)
  client_out = direction.to_s == "client_out"
  sender_profile = sender_profile.to_h.compact_blank
  industry_strategy = industry_strategy.to_h
  {
    "name" => "COMM KIT",
    "direction" => client_out ? "client_out" : "wizwiki_out",
    "direction_label" => copy_maker_comm_kit_direction_label(direction),
    "description" => if client_out
      "Client-branded communication kit the business can send from its own CRM to customers and prospects."
                     else
      "WIZWIKI outbound communication kit for sales follow-up with the best business decision maker, including contact/address review."
                     end,
    "sms_count" => 3,
    "email_count" => 2,
    "speaker" => client_out ? "the client business" : "WIZWIKI Marketing",
    "recipient" => client_out ? "the client's customers and prospects" : "the business owner or decision maker",
    "wizwiki_sender_profile" => client_out ? nil : sender_profile,
    "campaign_context" => client_out ? "Help the client promote its own reviewed offer, service, appointment, event, or campaign using its CRM." : "Help WIZWIKI start a grounded conversation using only reviewed organization and CRM facts.",
    "industry_strategy" => industry_strategy.presence,
    "industry_campaign_context" => if industry_strategy.present?
      "Use the #{industry_strategy["label"] || "selected"} industry lens. Prefer these campaign families when supported by CRM data: #{Array(industry_strategy["campaign_types"]).first(6).join(", ")}."
                                   end,
    "sms_variants" => [
      { "id" => "sms_warm", "tone" => "warm check-in", "urgency" => "low" },
      { "id" => "sms_helpful", "tone" => "helpful reminder", "urgency" => "medium" },
      { "id" => "sms_urgent", "tone" => "clear next-step prompt", "urgency" => "high without pressure" }
    ],
    "email_templates" => [
      { "id" => "email_intro", "tone" => "friendly consultative", "purpose" => "open the sales conversation" },
      { "id" => "email_follow_up", "tone" => "helpful follow-up", "purpose" => "restart or advance the conversation" }
    ],
    "rules" => [
      "Each SMS must be concise, human, and ready to paste into a text thread.",
      "Each email must include a subject line and body.",
      client_out ? "Use client customer context where available, but do not expose internal WIZWIKI sales routing." : "Include a Recipient & Address Review with associated names, roles, contact ranking reason, recommended contact path, and available addresses for human review.",
      client_out ? "Pick customer/prospect-facing context from source data." : "Pick the best WIZWIKI OUT recipient from association type, decision-maker signals, phone/email availability, recent CRM/playbook activity, and relationship context.",
      client_out ? nil : "Use the WIZWIKI sender profile for action steps. If the sender phone is present, include it naturally as the callback/text number. If it is blank, invite the recipient to reply or schedule a quick review without inventing a number.",
      industry_strategy.present? ? "Apply the selected industry strategy lens to make the copy specific, but do not invent weather, utility, permit, ZIP ranking, or exact market statistics." : nil,
      "Reference prior success, recent engagement, previous work, or campaign history only when present in the CRM/playbook/source data.",
      "Use CRM/account context for specificity without exposing private IDs, raw metadata, or internal workflow terms.",
      "Avoid unsupported stats, fake discounts, fake deadlines, or claims not supported by source context.",
      client_out ? "Write as the client business to its customers/prospects; do not sell WIZWIKI services in CLIENT OUT mode." : "Write as WIZWIKI to the business owner; never invent offers, prices, links, deadlines, availability, or results."
    ].compact
  }
end

def current_user_comm_profile
  {
    "name" => current_user.display_name,
    "phone" => current_user.display_phone_number,
    "email" => current_user.email_address,
    "aircall" => current_user.aircall_profile
  }.compact_blank
end

def industry_strategy_lens_options
  DealReports::IndustryStrategyPlaybook.options
end

def industry_strategy_lens_param
  DealReports::IndustryStrategyPlaybook.normalize(params[:industry_strategy_lens])
end

def report_copy_maker_cloud_provider_param
  safe_param(params[:copy_maker_cloud_provider], %w[nvidia openai qwen qwen_9b qwen_30b qwen_35b], "nvidia")
end

def copy_maker_cloud_config(provider)
  case provider.to_s
  when "qwen"
    {
      provider: "qwen",
      label: "Qwen Local 8B",
      model: ENV["WIZWIKI_COPY_MAKER_QWEN_MODEL"].presence || "qwen3:8b",
      base_url: ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434",
      api_key_env: nil
    }
  when "qwen_9b"
    {
      provider: "qwen_9b",
      label: "Qwen Local 9B MLX",
      model: ENV["WIZWIKI_COPY_MAKER_QWEN_9B_MODEL"].presence || "qwen3.5:9b-mlx",
      base_url: ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434",
      api_key_env: nil
    }
  when "qwen_30b"
    {
      provider: "qwen_30b",
      label: "Qwen Local 30B",
      model: ENV["WIZWIKI_COPY_MAKER_QWEN_30B_MODEL"].presence || "qwen3:30b",
      base_url: ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434",
      api_key_env: nil
    }
  when "qwen_35b"
    {
      provider: "qwen_35b",
      label: "Qwen Local 35B MLX",
      model: ENV["WIZWIKI_COPY_MAKER_QWEN_35B_MODEL"].presence || "qwen3.6:35b-mlx",
      base_url: ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434",
      api_key_env: nil
    }
  when "openai"
    {
      provider: "openai",
      label: "OpenAI",
      model: ENV["WIZWIKI_COPY_MAKER_OPENAI_MODEL"].presence || WizwikiSettings.openai_model,
      base_url: "https://api.openai.com/v1",
      api_key_env: "OPENAI_API_KEY"
    }
  else
    {
      provider: "nvidia",
      label: "NVIDIA Nemotron",
      model: ENV["WIZWIKI_COPY_MAKER_NVIDIA_MODEL"].presence || "nvidia/nemotron-3-ultra-550b-a55b",
      base_url: ENV["WIZWIKI_COPY_MAKER_NVIDIA_BASE_URL"].presence || "https://integrate.api.nvidia.com/v1",
      api_key_env: "NVIDIA_API_KEY"
    }
  end
end

def copy_maker_pipeline(provider, local_prep:)
  final = provider.to_s == "qwen" ? "qwen_local_copy" : "#{provider}_cloud_copy"
  if local_prep
    "local_embedder_local_llm_prep_then_#{final}"
  else
    "local_embedder_payload_only_then_#{final}"
  end
end

def safe_param(value, allowed, fallback)
  candidate = value.to_s.strip
  allowed.include?(candidate) ? candidate : fallback
end

def report_status
    artifacts = @deal.crm_record_artifacts.where(artifact_type: "market_report").order(created_at: :desc)
    latest = artifacts.first
    audiences = %w[client am copy_maker].index_with do |audience|
      audience_artifacts = artifacts.where("COALESCE(metadata ->> 'report_audience', 'client') = ?", audience)
      audience_latest = audience_artifacts.first

      {
        report_count: audience_artifacts.count,
        active_report_count: audience_artifacts.where(status: %w[queued generating report_ready]).count,
        failed_report_count: audience_artifacts.where(status: "failed").count,
        latest_report: report_status_artifact_payload(audience_latest)
      }
    end

    render json: {
      ok: true,
      deal_id: @deal.id,
      report_count: artifacts.count,
      completed_report_count: deal_completed_report_count(@deal),
      active_report_count: artifacts.where(status: %w[queued generating report_ready]).count,
      failed_report_count: artifacts.where(status: "failed").count,
      latest_report: report_status_artifact_payload(latest),
      audiences: audiences
    }
  end

  def upload_media
    return unless ensure_current_user_claimed_deal!

    files = Array(params.dig(:deal_media, :files)).reject(&:blank?)
    if files.blank?
      return redirect_back fallback_location: deal_queue_path, alert: "Choose at least one media file before uploading."
    end

    if files.size > MAX_MEDIA_UPLOADS
      return redirect_back fallback_location: deal_queue_path, alert: "Upload #{MAX_MEDIA_UPLOADS} files or fewer at one time."
    end

    too_large = files.find { |file| file.respond_to?(:size) && file.size.to_i > MAX_MEDIA_UPLOAD_SIZE }
    if too_large.present?
      return redirect_back fallback_location: deal_queue_path, alert: "#{too_large.original_filename} is too large. Keep deal media under #{helpers.number_to_human_size(MAX_MEDIA_UPLOAD_SIZE)} per file."
    end

    files.each { |file| @deal.deal_media.attach(file) }
    redirect_back fallback_location: deal_queue_path, notice: "Media folder updated for #{deal_company_name(@deal)}."
  rescue StandardError => error
    redirect_back fallback_location: deal_queue_path, alert: "Media upload failed: #{error.message}"
  end

  def destroy_media
    return unless ensure_current_user_claimed_deal!

    attachment = @deal.deal_media.attachments.find(params[:attachment_id])
    filename = attachment.filename.to_s
    attachment.purge_later
    redirect_back fallback_location: deal_queue_path, notice: "Removed #{filename} from #{deal_company_name(@deal)}."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: deal_queue_path, alert: "Media file not found."
  end

  def preview_report
    @artifact = current_organization.crm_record_artifacts.find(params[:id])
    unless report_document_downloadable?(@artifact)
      return redirect_to deal_queue_path, alert: "Report document is not ready for preview yet."
    end

    bytes = DealReports::Publisher.download_bytes!(@artifact)
    @preview_blocks = DealReports::DocxPreview.call(bytes)
    @deal = @artifact.crm_record
    @download_url = report_document_url(@artifact)
  rescue ActiveRecord::RecordNotFound
    redirect_to deal_queue_path, alert: "Report not found."
  rescue StandardError => error
    Rails.logger.error("[DealQueues] report preview failed artifact=#{params[:id]} #{error.class}: #{error.message}")
    redirect_to deal_queue_path, alert: "Report preview failed: #{error.message}"
  end

  def download_report
    artifact = current_organization.crm_record_artifacts.find(params[:id])
    unless report_document_downloadable?(artifact)
      return redirect_to deal_queue_path, alert: "Report document is not ready for download yet."
    end

    bytes = DealReports::Publisher.download_bytes!(artifact)
    send_data(
      bytes,
      filename: report_download_filename(artifact),
      type: artifact.content_type.presence || "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      disposition: "inline"
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to deal_queue_path, alert: "Report not found."
  rescue StandardError => error
    Rails.logger.error("[DealQueues] report download failed artifact=#{params[:id]} #{error.class}: #{error.message}")
    redirect_to deal_queue_path, alert: "Report download failed: #{error.message}"
  end

  def download_canva_kit
    artifact = current_organization.crm_record_artifacts.find(params[:id])
    unless canva_kit_downloadable?(artifact)
      return redirect_to deal_queue_path, alert: "Canva Build Kit is not ready yet."
    end

    kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h
    bytes = DealReports::Publisher.download_key_bytes!(artifact: artifact, storage_key: kit["storage_key"])
    send_data(
      bytes,
      filename: canva_kit_filename(artifact),
      type: kit["content_type"].presence || "application/zip",
      disposition: "attachment"
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to deal_queue_path, alert: "Canva Build Kit not found."
  rescue StandardError => error
    Rails.logger.error("[DealQueues] canva kit download failed artifact=#{params[:id]} #{error.class}: #{error.message}")
    redirect_to deal_queue_path, alert: "Canva Build Kit download failed: #{error.message}"
  end

def download_canva_output
  artifact = current_organization.crm_record_artifacts.find(params[:id])
  unless canva_output_downloadable?(artifact)
    return redirect_to deal_queue_path, alert: "Canva output package is not ready for download yet."
  end

  output = artifact.metadata.to_h.dig("canva", "output_package").to_h
  bytes = DealReports::Publisher.download_key_bytes!(artifact: artifact, storage_key: output["storage_key"])
  send_data(
    bytes,
    filename: canva_output_filename(artifact),
    type: output["content_type"].presence || "application/zip",
    disposition: "attachment"
  )
rescue ActiveRecord::RecordNotFound
  redirect_to deal_queue_path, alert: "Canva output package not found."
rescue StandardError => error
  Rails.logger.error("[DealQueues] canva output download failed artifact=#{params[:id]} #{error.class}: #{error.message}")
  redirect_to deal_queue_path, alert: "Canva output package download failed: #{error.message}"
end

def download_canva_pdf
  artifact = current_organization.crm_record_artifacts.find(params[:id])
  unless canva_pdf_downloadable?(artifact)
    return redirect_to deal_queue_path, alert: "Canva PDF export is not ready yet."
  end

  if (file = canva_pdf_file(artifact)) && file["storage_key"].present?
    bytes = DealReports::Publisher.download_key_bytes!(artifact: artifact, storage_key: file["storage_key"])
    return send_data(
      bytes,
      filename: canva_pdf_filename(artifact, file["filename"]),
      type: file["content_type"].presence || "application/pdf",
      disposition: "inline"
    )
  end

  output = artifact.metadata.to_h.dig("canva", "output_package").to_h
  zip_bytes = DealReports::Publisher.download_key_bytes!(artifact: artifact, storage_key: output["storage_key"])
  pdf = extract_canva_pdf(zip_bytes)
  send_data(
    pdf.fetch(:bytes),
    filename: canva_pdf_filename(artifact, pdf.fetch(:filename)),
    type: "application/pdf",
    disposition: "inline"
  )
rescue ActiveRecord::RecordNotFound
  redirect_to deal_queue_path, alert: "Canva PDF export not found."
rescue StandardError => error
  Rails.logger.error("[DealQueues] canva PDF download failed artifact=#{params[:id]} #{error.class}: #{error.message}")
  redirect_to deal_queue_path, alert: "Canva PDF download failed: #{error.message}"
end

def download_canva_export
  artifact = current_organization.crm_record_artifacts.find(params[:id])
  file = canva_export_file(artifact, params[:filename])
  unless file && file["storage_key"].present?
    return redirect_to deal_queue_path, alert: "Canva export file is not ready yet."
  end

  bytes = DealReports::Publisher.download_key_bytes!(artifact: artifact, storage_key: file["storage_key"])
  send_data(
    bytes,
    filename: file["filename"].presence || params[:filename],
    type: file["content_type"].presence || "application/octet-stream",
    disposition: browser_preview_disposition(file["content_type"])
  )
rescue ActiveRecord::RecordNotFound
  redirect_to deal_queue_path, alert: "Canva export file not found."
rescue StandardError => error
  Rails.logger.error("[DealQueues] canva export download failed artifact=#{params[:id]} filename=#{params[:filename]} #{error.class}: #{error.message}")
  redirect_to deal_queue_path, alert: "Canva export download failed: #{error.message}"
end

def build_canva_output
  artifact = current_organization.crm_record_artifacts.find(params[:id])
  unless canva_kit_downloadable?(artifact)
    return redirect_to deal_queue_path, alert: "Review package is not ready yet. Generate the DOCX and Canva Build Kit first."
  end

  metadata = artifact.metadata.to_h
  artifact.update!(metadata: metadata.merge(
    "canva" => metadata.fetch("canva", {}).to_h.merge(
      "status" => "approved_for_build",
      "approved_by_user_id" => current_user.id,
      "approved_by" => current_user.display_name,
      "approved_at" => Time.current.iso8601
    )
  ))

  result = Canva::ReportAutofill.call(artifact.reload)
  if result[:status] == "ready"
    redirect_to deal_queue_path, notice: "Canva output package built for #{artifact.crm_record.name}."
  else
    redirect_to deal_queue_path, alert: "Canva build did not finish: #{result[:message].presence || result[:status]}"
  end
rescue ActiveRecord::RecordNotFound
  redirect_to deal_queue_path, alert: "Canva report package not found."
rescue StandardError => error
  Rails.logger.error("[DealQueues] canva build failed artifact=#{params[:id]} #{error.class}: #{error.message}")
  redirect_to deal_queue_path, alert: "Canva build failed: #{error.message}"
end

  private

  def deal_queue_report_fields
    REPORT_FIELD_LABELS
  end

def report_audience
  value = params[:report_audience].to_s
  %w[client am copy_maker].include?(value) ? value : "client"
end

def report_audience_label(value)
  case value.to_s
  when "am" then "AM/internal"
  when "copy_maker" then "Copy Maker"
  else "Client"
  end
end

def requested_output_for_report(value, copy_maker_comm_kit: false, copy_maker_comm_kit_direction: "wizwiki_out")
  case value.to_s
  when "am"
    "Internal AM market strategy brief in DOCX format: include in-house context, HubSpot/account notes, risks, talking points, operational next steps, and a clean client-safe summary."
  when "copy_maker"
    if copy_maker_comm_kit
      if copy_maker_comm_kit_direction.to_s == "client_out"
        "Copy Maker CLIENT OUT COMM KIT DOCX: use the selected local embedder and LLM to interpret CRM data and produce 3 client-branded SMS/text messages plus 2 friendly sales email templates the business can send from its own CRM to customers and prospects."
      else
        "Copy Maker WIZWIKI OUT COMM KIT DOCX: interpret the approved CRM context and produce 3 concise SMS messages plus 2 friendly email templates for contacting the business owner. Use only reviewed organization facts."
      end
    else
      "Copy Maker DOCX: use the selected local embedder and LLM to interpret the custom prompt against related CRM data, then send a compact final copy payload to the selected cloud copy model."
    end
  else
    "Client-facing WIZWIKI Marketing proposal in DOCX format: 3-5 pages, benefit-focused, no internal notes, ready for Canva import."
  end
end

def report_status_artifact_payload(artifact)
  return unless artifact

  {
    id: artifact.id,
    status: artifact.status,
    audience: artifact.metadata.to_h["report_audience"].presence || "client",
    file_url: artifact.file_url,
    storage_key: artifact.storage_key,
    canva_kit_url: canva_kit_url(artifact),
    generated_at: artifact.generated_at&.iso8601,
    completed_at: report_completed_at(artifact),
    build_timing: report_build_timing(artifact),
    build_time_label: report_build_time_summary(artifact)
  }
end



def parse_report_time(value)
  return value if value.is_a?(Time)
  return if value.blank?

  Time.zone.parse(value.to_s)
rescue ArgumentError, TypeError
  nil
end

def timing_seconds(stored_value, start_time = nil, end_time = nil)
  stored = stored_value.to_i if stored_value.present?
  return stored if stored.to_i.positive?
  return unless start_time.present? && end_time.present?

  [(end_time - start_time).round, 0].max
end

  def set_deal
    scope = current_organization.crm_records.where(record_type: %w[ticket deal contact company lead]).where.not(status: "archived")
    @deal = scope.find(params[:id])
  end

  def deal_company_name(deal)
    hubspot_deal_value(deal, "Company Name").presence ||
      hubspot_deal_value(deal, "Company").presence ||
      deal.properties.to_h.dig("hubspot", "properties", "company").presence ||
      deal.name
  end

  def deal_claimed?(deal)
    deal.owner_id.present?
  end

  def deal_claimed_by_current_user?(deal)
    deal.owner_id.present? && deal.owner_id == current_user&.id
  end

  def deal_claim_label(deal)
    deal.owner&.display_name.presence || "unclaimed"
  end


  def deal_priority_level(deal)
    deal.effective_priority_level
  end

  def deal_priority?(deal)
    deal.priority?
  end

  def deal_priority_label(deal)
    case deal_priority_level(deal)
    when "urgent" then "URGENT"
    when "priority" then "PRIORITY"
    else "STANDARD"
    end
  end

  def deal_priority_source(deal)
    case deal.priority_source
    when "manual"
      marker = deal.priority_marked_by&.display_name.presence || "WIZWIKI"
      marked_at = deal.priority_marked_at&.strftime("%b %-d %l:%M %p")
      ["manual", marker, marked_at].compact.join(" // ")
    when "hubspot"
      "HubSpot #{deal.hubspot_ticket_priority}"
    else
      "standard queue"
    end
  end

  def deal_priority_badge_class(deal)
    case deal_priority_level(deal)
    when "urgent" then "border-teal-300/80 bg-teal-950/45 text-teal-100 shadow-teal-500/20"
    when "priority" then "border-yellow-300/80 bg-yellow-950/35 text-yellow-100 shadow-yellow-500/20"
    else "border-white/20 bg-white/5 text-zinc-400"
    end
  end

  def sync_active_report_priorities!(deal)
    deal.crm_record_artifacts.where(artifact_type: "market_report", status: %w[queued generating report_ready]).find_each do |artifact|
      metadata = artifact.metadata.to_h
      metadata["priority_level"] = deal_priority_level(deal)
      metadata["priority_label"] = deal_priority_label(deal)
      metadata["priority_source"] = deal_priority_source(deal)
      metadata["priority_note"] = deal.priority_note
      metadata["priority_marked_at"] = deal.priority_marked_at&.iso8601
      metadata["priority_marked_by"] = deal.priority_marked_by&.display_name
      artifact.update!(metadata: metadata)
    end
  end

  def deal_media_icon(attachment)
    content_type = attachment.blob.content_type.to_s
    return "IMG" if content_type.start_with?("image/")
    return "PDF" if content_type == "application/pdf"
    return "VID" if content_type.start_with?("video/")
    return "AUD" if content_type.start_with?("audio/")

    "FILE"
  end

  def deal_completed_report_count(deal)
    deal.crm_record_artifacts
      .select { |artifact| artifact.artifact_type == "market_report" && canva_kit_downloadable?(artifact) }
      .count
  end

  def report_document_downloadable?(artifact)
    artifact.storage_key.present? && artifact.status.in?(%w[report_ready canva_kit_ready ready archived])
  end

  def canva_kit_downloadable?(artifact)
    kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h
    kit["storage_key"].present? && artifact.status.in?(%w[canva_kit_ready ready archived])
  end

def canva_output_downloadable?(artifact)
  output = artifact.metadata.to_h.dig("canva", "output_package").to_h
  output["storage_key"].present? && artifact.status.in?(%w[ready archived])
end

def canva_pdf_downloadable?(artifact)
  return false unless canva_output_downloadable?(artifact)

  artifact.metadata.to_h.dig("canva", "exports").to_a.any? do |export|
    export.to_h["format"] == "pdf" && export.to_h["status"] == "success"
  end
end

def report_downloadable?(artifact)
    canva_kit_downloadable?(artifact)
  end

  def report_document_url(artifact)
    return unless report_document_downloadable?(artifact)

    "/leads/reports/#{artifact.id}/download"
  end

  def report_document_preview_url(artifact)
    return unless report_document_downloadable?(artifact)

    "/leads/reports/#{artifact.id}/preview"
  end

  def canva_kit_url(artifact)
    return unless canva_kit_downloadable?(artifact)

    kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h
    kit["file_url"].presence || "/leads/reports/#{artifact.id}/canva-kit"
  end

def canva_output_url(artifact)
  return unless canva_output_downloadable?(artifact)

  output = artifact.metadata.to_h.dig("canva", "output_package").to_h
  output["file_url"].presence || "/leads/reports/#{artifact.id}/canva-output"
end

def canva_pdf_url(artifact)
  return unless canva_pdf_downloadable?(artifact)

  "/leads/reports/#{artifact.id}/canva-pdf"
end

def canva_export_files(artifact)
  artifact.metadata.to_h.dig("canva", "exports").to_a.flat_map do |export|
    Array(export.to_h["files"]).map { |file| file.to_h.merge("format" => export.to_h["format"]) }
  end
end

def canva_pdf_file(artifact)
  canva_export_files(artifact).find do |file|
    file["content_type"].to_s == "application/pdf" || file["filename"].to_s.downcase.end_with?(".pdf") || file["format"].to_s == "pdf"
  end
end

def canva_export_file(artifact, filename)
  requested = filename.to_s
  canva_export_files(artifact).find { |file| file["filename"].to_s == requested }
end



def report_build_timing(artifact)
  metadata = artifact.metadata.to_h
  timing = metadata.fetch("timing", {}).to_h
  queued_at = parse_report_time(timing["queued_at"] || metadata["queued_at"] || artifact.created_at)
  build_started_at = parse_report_time(timing["build_started_at"] || metadata["build_started_at"] || metadata["claimed_at"])
  docx_finished_at = parse_report_time(timing["docx_finished_at"] || metadata["docx_finished_at"] || metadata["report_ready_at"] || artifact.generated_at)
  canva_kit_started_at = parse_report_time(timing["canva_kit_started_at"] || metadata["canva_kit_started_at"])
  canva_kit_finished_at = parse_report_time(timing["canva_kit_finished_at"] || metadata["canva_kit_finished_at"] || metadata["completed_at"])
  canva = metadata.fetch("canva", {}).to_h
  canva_started_at = parse_report_time(canva["started_at"])
  canva_completed_at = parse_report_time(canva["completed_at"])

  {
    "queued_at" => queued_at&.iso8601,
    "build_started_at" => build_started_at&.iso8601,
    "docx_finished_at" => docx_finished_at&.iso8601,
    "canva_kit_started_at" => canva_kit_started_at&.iso8601,
    "canva_kit_finished_at" => canva_kit_finished_at&.iso8601,
    "queue_wait_seconds" => timing_seconds(timing["queue_wait_seconds"], queued_at, build_started_at),
    "docx_build_seconds" => timing_seconds(timing["docx_build_seconds"] || metadata["docx_build_seconds"], build_started_at, docx_finished_at),
    "canva_kit_build_seconds" => timing_seconds(timing["canva_kit_build_seconds"] || metadata["canva_kit_build_seconds"] || metadata.dig("canva_kit", "build_seconds"), canva_kit_started_at, canva_kit_finished_at),
    "total_build_seconds" => timing_seconds(timing["total_build_seconds"] || metadata["total_build_seconds"], build_started_at, canva_kit_finished_at || docx_finished_at),
    "total_elapsed_seconds" => timing_seconds(timing["total_elapsed_seconds"] || metadata["total_elapsed_seconds"], queued_at, canva_kit_finished_at || docx_finished_at),
    "canva_output_seconds" => timing_seconds(canva["build_seconds"], canva_started_at, canva_completed_at)
  }.compact
end

def report_duration_label(seconds)
  seconds = seconds.to_i
  return "--" unless seconds.positive?
  return "#{seconds}s" if seconds < 60

  minutes, remaining_seconds = seconds.divmod(60)
  return "#{minutes}m #{remaining_seconds}s" if minutes < 60

  hours, remaining_minutes = minutes.divmod(60)
  "#{hours}h #{remaining_minutes}m"
end

def report_build_time_summary(artifact)
  timing = report_build_timing(artifact)
  parts = []
  parts << "DOCX #{report_duration_label(timing['docx_build_seconds'])}" if timing["docx_build_seconds"].present?
  parts << "KIT #{report_duration_label(timing['canva_kit_build_seconds'])}" if timing["canva_kit_build_seconds"].present?
  parts << "TOTAL #{report_duration_label(timing['total_build_seconds'])}" if timing["total_build_seconds"].present?
  parts.presence&.join(" // ") || "timing pending"
end

def canva_status_label(artifact)
  canva = artifact.metadata.to_h.fetch("canva", {}).to_h
  case canva["status"]
  when "ready" then "Canva output ready"
  when "autofill_in_progress" then "Canva building design"
  when "waiting" then "Canva waiting: #{canva['message']}"
  when "failed" then "Canva failed: #{canva['message']}"
  else "Canva not started"
  end
end

def deal_watch_artifact(_deal, artifacts)
  reports = Array(artifacts)
  reports.find { |artifact| %w[queued generating report_ready canva_building].include?(artifact.status.to_s) } || reports.first
end

def report_watch_lines(artifact)
  return [] unless artifact

  metadata = artifact.metadata.to_h
  manifest = report_manifest(artifact)
  pipeline = manifest.fetch("pipeline", {}).to_h
  timing = report_build_timing(artifact)
  audience = case metadata["report_audience"].to_s
  when "am" then "AM"
  when "copy_maker" then "COPY"
  else "CLIENT"
  end
  requested_model = report_requested_model(artifact).presence || metadata["target_model"].presence || "pending"
  actual_model = report_actual_model(artifact).presence || requested_model
  embedder = report_requested_embedder(artifact).presence || manifest["embedder_model"].presence || "pending"
  preflight = report_watch_flag(metadata["report_preflight_scan_enabled"] || pipeline["preflight_visual_scan_enabled"])
  post_review = report_watch_flag(metadata["report_post_review_enabled"] || pipeline["post_generation_review_enabled"])
  page_qa = report_watch_flag(metadata["report_page_visual_qa_enabled"] || pipeline["page_visual_qa_enabled"])
  design_press = report_watch_flag(metadata["report_design_press_enabled"] || pipeline["design_press_enabled"])
  quality_errors = report_quality_errors(artifact)
  stamp = artifact.updated_at&.strftime("%H:%M:%S") || "--:--:--"
  status = artifact.status.to_s.presence || "pending"

  lines = [
    "[#{stamp}] RPT ##{artifact.id} #{audience} status=#{status}",
    "to=#{actual_model} // selected=#{requested_model}",
    "embedder=#{embedder} // pre=#{preflight} // post=#{post_review} // pageqa=#{page_qa} // press=#{design_press}",
    "queue=#{report_duration_label(timing['queue_wait_seconds'])} // docx=#{report_duration_label(timing['docx_build_seconds'])} // kit=#{report_duration_label(timing['canva_kit_build_seconds'])} // elapsed=#{report_duration_label(timing['total_elapsed_seconds'])}"
  ]

  lines << if quality_errors.any?
    "quality=#{clip_report_watch_line(quality_errors.first)}"
  elsif %w[ready report_ready canva_kit_ready archived].include?(status)
    "quality=passed // completed=#{clip_report_watch_line(report_completed_at(artifact), 70)}"
  else
    "quality=pending // #{report_processing_status_label(artifact)}"
  end

  lines
end

def report_processing_status_label(artifact)
  case artifact.status
  when "queued" then "queued for WIZWIKI"
  when "generating" then "WIZWIKI building report"
  when "report_ready" then "report ready // building Canva kit"
  when "canva_kit_ready" then canva_status_label(artifact) == "Canva not started" ? "Canva Build Kit ready" : canva_status_label(artifact)
  when "ready" then canva_output_downloadable?(artifact) ? "Canva output ready" : "Canva Build Kit ready"
  when "failed" then "failed"
  when "archived" then "archived"
  else artifact.status.to_s
  end
end

def report_watch_flag(value)
  value == true || %w[1 true yes on].include?(value.to_s.downcase) ? "on" : "off"
end

def clip_report_watch_line(value, max_length = 140)
  text = value.to_s.squish
  return text if text.length <= max_length

  "#{text.first(max_length - 3)}..."
end

def comm_kit_report?(artifact)
  metadata = artifact.metadata.to_h
  artifact.artifact_type == "market_report" &&
    metadata["report_audience"].to_s == "copy_maker" &&
    report_watch_flag(metadata["copy_maker_comm_kit_enabled"]) == "on"
end

def comm_stage_for_report(artifact)
  @comm_stage_by_report_id ||= current_organization.crm_record_artifacts
    .joins(:crm_record)
    .where(artifact_type: "comm_staging")
    .where(crm_records: { owner_id: current_user&.id })
    .where("metadata ->> 'source_report_id' IS NOT NULL")
    .order(created_at: :desc)
    .to_a
    .index_by { |stage| stage.metadata.to_h["source_report_id"].to_i }
  @comm_stage_by_report_id[artifact.id]
end

def comm_stage_sms_options(stage)
  Array(stage&.metadata.to_h["sms_options"])
end

def comm_stage_email_options(stage)
  Array(stage&.metadata.to_h["email_options"])
end

def comm_stage_contact_options(stage)
  Array(stage&.metadata.to_h["contact_options"])
end

def comm_stage_phone_options(stage)
  Array(stage&.metadata.to_h["phone_options"])
end

def comm_stage_recipient_email_options(stage)
  Array(stage&.metadata.to_h["recipient_email_options"])
end

def comm_stage_address_options(stage)
  Array(stage&.metadata.to_h["address_options"])
end

def comm_stage_selected_sms(stage)
  selected_id = stage&.metadata.to_h["selected_sms_id"].to_s
  comm_stage_sms_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_sms_options(stage).first
end

def comm_stage_selected_email(stage)
  selected_id = stage&.metadata.to_h["selected_email_id"].to_s
  comm_stage_email_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_email_options(stage).first
end

def comm_stage_selected_contact(stage)
  selected_id = stage&.metadata.to_h["selected_contact_id"].to_s
  comm_stage_contact_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_contact_options(stage).first
end

def comm_stage_selected_phone(stage)
  selected_id = stage&.metadata.to_h["selected_phone_id"].to_s
  comm_stage_phone_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_phone_options(stage).first
end

def comm_stage_selected_recipient_email(stage)
  selected_id = stage&.metadata.to_h["selected_recipient_email_id"].to_s
  comm_stage_recipient_email_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_recipient_email_options(stage).first
end

def comm_stage_selected_address(stage)
  selected_id = stage&.metadata.to_h["selected_address_id"].to_s
  comm_stage_address_options(stage).find { |option| option.to_h["id"].to_s == selected_id } || comm_stage_address_options(stage).first
end

def comm_stage_aircall_ready?(stage)
  stage&.status.to_s.in?(%w[aircall_ready aircall_sent])
end

def comm_stage_status_label(stage)
  case stage&.status.to_s
  when "aircall_ready"
    "Saved work"
  when "aircall_sent"
    "SMS sent"
  when "aircall_failed"
    "Needs review"
  else
    stage&.status.to_s.humanize.presence || "Staged"
  end
end

def crm_record_claimed_by_current_user?(record)
  record&.owner_id.present? && record.owner_id == current_user&.id
end

  def report_manifest(artifact)
    artifact.metadata.to_h.fetch("manifest", {}).to_h
  end

  def report_publisher(artifact)
    artifact.metadata.to_h.fetch("publisher", {}).to_h
  end

  def report_quality(artifact)
    artifact.metadata.to_h.fetch("quality", {}).to_h
  end

  def report_display_title(artifact)
    report_manifest(artifact)["report_title"].presence || artifact.title
  end

  def report_local_path(artifact)
    report_manifest(artifact)["local_path"].presence || artifact.metadata.to_h.dig("worker_payload", "local_path")
  end

  def report_model(artifact)
    report_actual_model(artifact).presence || report_requested_model(artifact).presence || "unknown"
  end

  def report_requested_model(artifact)
    artifact.metadata.to_h["report_local_model_label"].presence ||
      artifact.metadata.to_h["report_local_model"].presence ||
      artifact.metadata.to_h["target_model"]
  end

  def report_requested_embedder(artifact)
    artifact.metadata.to_h["report_embedder_model_label"].presence ||
      artifact.metadata.to_h["report_embedder_model"].presence ||
      artifact.metadata.to_h["embedding_model"].presence ||
      artifact.metadata.to_h.dig("worker_payload", "embedder_model") ||
      artifact.metadata.to_h.dig("worker_payload", "embedding_model")
  end

  def report_actual_model(artifact)
    report_manifest(artifact)["model"].presence ||
      report_quality(artifact)["model"].presence ||
      artifact.metadata.to_h["actual_report_model"].presence ||
      artifact.metadata.to_h.dig("worker_payload", "model")
  end

  def report_model_mismatch?(artifact)
    requested = artifact.metadata.to_h["report_local_model"].to_s
    actual = report_actual_model(artifact).to_s
    requested.present? && actual.present? && requested != actual
  end

  def report_lane_options
    WizwikiSettings.report_lane_options
  end

  def report_lane_param
    return WizwikiSettings.report_lane(params[:report_lane]) if params[:report_lane].present?

    selected_model = report_local_model_param
    selected_embedder = report_embedder_model_param
    model_label = WizwikiSettings.report_local_model_label(selected_model)
    embedder_label = WizwikiSettings.report_embedder_model_label(selected_embedder)

    {
      value: "dynamic_combo",
      label: "DYNAMIC // #{embedder_label} + #{model_label}",
      description: "Dynamic RAG combo. The selected embedder retrieves HubSpot context, the selected model writes, and repair retrieval runs only if validation asks.",
      report_local_model: selected_model,
      report_model_ladder: [selected_model],
      report_embedder_model: selected_embedder
    }
  end

  def report_local_model_options
    WizwikiSettings.report_local_model_options
  end

  def report_local_model_param
    WizwikiSettings.normalize_report_local_model(params[:report_local_model])
  end

  def report_embedder_model_options
    WizwikiSettings.report_embedder_model_options
  end

  def report_embedder_model_param
    WizwikiSettings.normalize_report_embedder_model(params[:report_embedder_model])
  end

  def report_challenger_model_options
    WizwikiSettings.challenger_model_options
  end

  def report_challenger_model_param
    WizwikiSettings.normalize_challenger_model(params[:report_challenger_model])
  end

  def voice_training_document_scope
    current_organization.training_documents
      .where.not(status: "archived")
      .includes(:user)
      .order(updated_at: :desc, created_at: :desc)
  end

  def fine_training_embedding_status
    embedding_model = WizwikiSettings.report_embedder_model
    scope = current_organization.training_documents.where.not(status: "archived")
    result = {
      total: scope.count,
      new: scope.where(status: "ingested").count,
      processing: scope.where(status: "processing").count,
      embedded: scope.where(status: "indexed").count,
      failed: 0,
      chunks_pending: 0,
      chunks_claimed: 0,
      chunks_embedded: 0,
      chunks_failed: 0,
      embedder_model: embedding_model
    }
    return result unless Autos::EmbeddingQueue.storage_ready?

    chunk_scope = AutosEmbeddingChunk.where(
      organization: current_organization,
      source_type: "TrainingDocument",
      source_id: scope.select(:id),
      embedding_model: embedding_model
    )
    counts = chunk_scope.group(:status).count
    result.merge(
      failed: counts["failed"].to_i,
      chunks_pending: counts["pending"].to_i,
      chunks_claimed: counts["claimed"].to_i,
      chunks_embedded: counts["embedded"].to_i,
      chunks_failed: counts["failed"].to_i
    )
  rescue StandardError => error
    Rails.logger.warn("[DealQueues] fine training status failed #{error.class}: #{error.message}")
    {
      total: 0,
      new: 0,
      processing: 0,
      embedded: 0,
      failed: 0,
      chunks_pending: 0,
      chunks_claimed: 0,
      chunks_embedded: 0,
      chunks_failed: 0,
      embedder_model: embedding_model
    }
  end

  def report_completed_at(artifact)
    artifact.metadata.to_h["completed_at"].presence ||
      report_manifest(artifact)["generated_at"].presence ||
      artifact.generated_at&.iso8601 ||
      artifact.updated_at&.iso8601
  end

  def report_byte_size(artifact)
    artifact.byte_size.presence ||
      report_publisher(artifact)["byte_size"].presence ||
      report_manifest(artifact)["byte_size"].presence ||
      report_quality(artifact)["byte_size"]
  end

  def report_logo_status(artifact)
    manifest = report_manifest(artifact)
    return "embedded" if manifest["logo_embedded"] == true

    manifest["logo_reason"].presence || manifest.dig("media", "logo_reason").presence || "not embedded"
  end

  def report_quality_errors(artifact)
    errors = Array(report_quality(artifact)["errors"]) + Array(report_manifest(artifact)["quality_errors"])
    errors.presence || Array(report_quality(artifact)["warnings"]) + Array(report_manifest(artifact)["quality_warnings"])
  end

  def hubspot_deal_value(deal, label)
    hubspot = deal.properties.to_h.fetch("hubspot", {})
    labeled = hubspot.fetch("labeled_properties", {})
    return labeled[label] if labeled[label].present?

    property_name = hubspot.fetch("label_property_names", {})[label]
    return hubspot.fetch("properties", {})[property_name] if property_name.present?

    fallback_value_for(deal, label, hubspot)
  end

  def weather_lead_signals_for(deal)
    weather = deal.properties.to_h.fetch("weather_lead", {}).to_h
    Array(weather["signals"]).filter_map do |signal|
      signal = signal.to_h
      event = signal["event"].presence || "Weather signal"
      severity = [signal["severity"], signal["urgency"], signal["certainty"]].compact_blank.join(" / ")
      postal_codes = Array(signal["postal_codes"]).compact_blank
      states = Array(signal["states"]).compact_blank
      location = postal_codes.first(5).join(", ").presence || states.join(", ").presence
      expires_at = weather_signal_time_label(signal["expires_at"])

      {
        event: event,
        severity: severity,
        location: location,
        expires_at: expires_at
      }
    end.first(3)
  end

  def report_weather_opportunity_payload(deal)
    weather = deal.properties.to_h.fetch("weather_lead", {}).to_h
    signals = Array(weather["signals"]).filter_map do |signal|
      signal = signal.to_h
      event = signal["event"].presence || "Weather signal"
      postal_codes = Array(signal["postal_codes"]).compact_blank.first(8)
      states = Array(signal["states"]).compact_blank.first(8)

      {
        "event" => event,
        "type" => signal["type"].presence,
        "severity" => signal["severity"].presence,
        "urgency" => signal["urgency"].presence,
        "certainty" => signal["certainty"].presence,
        "states" => states,
        "postal_codes" => postal_codes,
        "expires_at" => signal["expires_at"].presence
      }.compact_blank
    end.first(5)

    if signals.blank?
      return {
        "active" => false,
        "source" => "Weather.gov Storm Watch",
        "summary" => "No active Storm Watch match is attached to this record."
      }
    end

    events = signals.map { |signal| signal["event"] }.compact_blank.uniq.first(4)
    locations = signals.flat_map { |signal| Array(signal["postal_codes"]).presence || Array(signal["states"]) }.compact_blank.uniq.first(8)
    location_label = locations.present? ? locations.join(", ") : "the service area"
    event_label = events.present? ? events.join(", ") : "recent storm activity"

    {
      "active" => true,
      "source" => "Weather.gov Storm Watch",
      "matched_at" => weather["flagged_at"].presence,
      "signals_count" => weather["signals_count"].presence || signals.length,
      "events" => events,
      "locations" => locations,
      "summary" => "Storm Watch matched #{event_label} near #{location_label}.",
      "restoration_angle" => "If this client's services include restoration, roofing, exterior repair, plumbing, flooring, landscaping, tree work, HVAC, electrical, fencing, windows/doors, cleaning, mitigation, construction, or other home-service repair work, frame the weather signal as a timely opportunity to offer inspections, cleanup, repairs, and restoration services.",
      "truth_policy" => "Use only supplied weather events and locations. Do not claim confirmed damage at a specific property, do not invent forecasts, and do not use unsupported exact statistics.",
      "signals" => signals
    }
  end

  def fallback_value_for(deal, label, hubspot)
    properties = hubspot.fetch("properties", {})
    case label
    when "Company Name"
      properties["company_name"]
    when "Record ID"
      hubspot["id"].presence || deal.source_uid
    when "Amount"
      deal.amount
    when "Deal Stage", "Ticket Status"
      deal.stage
    when "Close Date"
      deal.close_date
    when "Deal Type"
      properties["dealtype"]
    when "SAM New Record"
      hubspot["labeled_properties"].to_h["SAM New Record"].presence || properties[hubspot["sam_property_name"].to_s]
    when "Industry"
      properties["industry"]
    when "Latest Traffic Source"
      properties["hs_analytics_source"]
    when "Deal owner"
      properties["hubspot_owner_name"].presence || properties["hubspot_owner_id"]
    when "Deal Description", "Ticket Description"
      properties["content"].presence || properties["description"]
    end
  end

  def weather_signal_time_label(value)
    return if value.blank?

    Time.zone.parse(value.to_s).strftime("%b %-d %-I:%M %p %Z")
  rescue ArgumentError, TypeError
    value.to_s
  end

  def ensure_current_user_claimed_deal!
    return true if @deal.owner_id == current_user&.id

    redirect_back fallback_location: deal_queue_path, alert: "Claim this lead before uploading media or generating reports."
    false
  end

  def base_deals
    lead_source_scope(active_lead_source)
  end

  def lead_source_options
    LEAD_SOURCE_OPTIONS
  end

  def active_lead_source
    value = params[:lead_source].to_s.strip.presence || LEAD_SOURCE_OWNER_QUEUE_VALUE
    lead_source_options.any? { |option| option[:value] == value } ? value : LEAD_SOURCE_OWNER_QUEUE_VALUE
  end

  def active_lead_source_option
    lead_source_options.find { |option| option[:value] == active_lead_source } || lead_source_options.first
  end

  def lead_source_label_for(value)
    return "90-day contacts" if value.to_s == LEAD_SOURCE_ALL_CONTACTS_VALUE

    lead_source_options.find { |option| option[:value] == value }&.dig(:label).presence || "Owner Queue"
  end

  def sam_ticket_lead_source?
    active_lead_source == LEAD_SOURCE_SAM_VALUE
  end

  def lead_source_counts
    @lead_source_counts ||= lead_source_options.to_h do |option|
      [option[:value], lead_source_count_for(option[:value])]
    end
  end

  def lead_source_count_for(value)
    if value == LEAD_SOURCE_ALL_VALUE
      return lead_source_options
        .reject { |option| option[:value].in?([LEAD_SOURCE_ALL_VALUE, LEAD_SOURCE_CLAIMED_BY_ME_VALUE]) }
        .sum { |option| lead_source_count_for(option[:value]) }
    end

    if value == LEAD_SOURCE_CLAIMED_BY_ME_VALUE
      return Rails.cache.fetch(["deal_queue_lead_source_count", current_organization.id, current_user.id, value], expires_in: 60.seconds) do
        claimed_by_me_scope.count
      end
    end

    Rails.cache.fetch(["deal_queue_lead_source_count", current_organization.id, value], expires_in: 60.seconds) do
      lead_source_scope(value).count
    end
  end

  def lead_source_scope(value)
    case value
    when LEAD_SOURCE_ALL_VALUE
      all_lead_scope
    when LEAD_SOURCE_OWNER_QUEUE_VALUE
      owner_queue_scope
    when LEAD_SOURCE_CLAIMED_BY_ME_VALUE
      claimed_by_me_scope
    when LEAD_SOURCE_FACEBOOK_VALUE
      facebook_lead_scope
    when LEAD_SOURCE_SHOPIFY_VALUE
      shopify_lead_scope
    when LEAD_SOURCE_HAYMARKET_VALUE
      haymarket_lead_scope
    when LEAD_SOURCE_WEATHER_VALUE
      weather_lead_scope
    else
      sam_ticket_scope
    end
  end

  def all_lead_scope
    owner_queue_scope.or(sam_ticket_scope).or(facebook_lead_scope).or(shopify_lead_scope).or(haymarket_lead_scope).or(weather_lead_scope)
  end

  def claimed_by_me_scope
    all_lead_scope.where(owner_id: current_user.id)
  end

  def sam_ticket_scope
    current_organization.crm_records.where(record_type: "ticket").where.not(status: "archived")
  end

  def facebook_lead_scope
    contact_source_scope(LEAD_SOURCE_FACEBOOK_VALUE)
  end

  def shopify_lead_scope
    contact_source_scope(LEAD_SOURCE_SHOPIFY_VALUE)
  end

  def haymarket_lead_scope
    contact_source_scope(LEAD_SOURCE_HAYMARKET_VALUE)
  end

  def owner_queue_scope
    facebook_lead_scope
      .where.not(source: "manual_comms")
      .where(
        <<~SQL.squish,
          crm_records.properties #>> '{hubspot,properties,hubspot_owner_id}' = :owner_id
          OR crm_records.properties #>> '{hubspot_owner_id}' = :owner_id
          OR crm_records.properties #>> '{contact_owner_id}' = :owner_id
        SQL
        owner_id: owner_queue_owner_id
      )
  end

  def weather_lead_scope
    Weather::LeadMatcher.scope_for(current_organization)
  end

  def contact_source_scope(source)
    scope = current_organization.crm_records.where(record_type: "contact").where.not(status: "archived")
    source = source.to_s
    like = "%#{ActiveRecord::Base.sanitize_sql_like("facebook")}%"
    if source == LEAD_SOURCE_SHOPIFY_VALUE
      shopify_like = "%#{ActiveRecord::Base.sanitize_sql_like("shopify")}%"
      return scope.where(
        <<~SQL.squish,
          crm_records.properties #>> '{hubspot,lead_source}' = :source
          OR (crm_records.properties #> '{hubspot,lead_sources}') @> CAST(:source_json AS jsonb)
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,b__shopify_eddm_order}', '') <> ''
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,ip__shopify__orders_count}', '') NOT IN ('', '0')
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,shopify_amount_spent}', '') NOT IN ('', '0')
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,ip__shopify__shopify_created_at}', '') <> ''
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,ip__shopify__tags}', '') <> ''
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_1}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_2}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_1}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_2}', '') ILIKE :q
        SQL
        source: source,
        source_json: JSON.generate([source]),
        q: shopify_like
      )
    end

    if source == LEAD_SOURCE_HAYMARKET_VALUE
      haymarket_like = "%#{ActiveRecord::Base.sanitize_sql_like("haymarket")}%"
      return scope.where(
        <<~SQL.squish,
          crm_records.properties #>> '{hubspot,lead_source}' = :source
          OR (crm_records.properties #> '{hubspot,lead_sources}') @> CAST(:source_json AS jsonb)
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,crm_used}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_1}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_2}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_1}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_2}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_object_source_label}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_object_source_detail_1}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_object_source_detail_2}', '') ILIKE :q
          OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_object_source_detail_3}', '') ILIKE :q
        SQL
        source: source,
        source_json: JSON.generate([source]),
        q: haymarket_like
      )
    end

    scope.where(
      <<~SQL.squish,
        crm_records.properties #>> '{hubspot,lead_source}' = :source
        OR (crm_records.properties #> '{hubspot,lead_sources}') @> CAST(:source_json AS jsonb)
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_click_id}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebookid}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_ad_clicked}', '') = 'true'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_inquiry}', '') = 'true'
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_messenger_conversion}', '') <> ''
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_1}', '') ILIKE :q
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_2}', '') ILIKE :q
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_1}', '') ILIKE :q
        OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_2}', '') ILIKE :q
      SQL
      source: source,
      source_json: JSON.generate([source]),
      q: like
    )
  end

  def lead_source_keyword_scope(scope, keyword)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(keyword)}%"
    scope.where(
      "crm_records.name ILIKE :q OR crm_records.source ILIKE :q OR crm_records.stage ILIKE :q OR crm_records.properties::text ILIKE :q",
      q: like
    )
  end

  def owner_queue_owner_id
    ENV["WIZWIKI_COMMS_SOURCE_OWNER_ID"].presence || ENV["HUBSPOT_COMMS_OWNER_ID"].presence
  end

def ticket_pipeline_options
  @ticket_pipeline_options ||= begin
    options = if @hubspot_configured
      Rails.cache.fetch("hubspot_ticket_pipeline_options", expires_in: 10.minutes) do
        Hubspot::TicketSync.ticket_pipeline_options
      end
    else
      []
    end

    options.presence || local_ticket_pipeline_options
  rescue Hubspot::Error => error
    Rails.logger.warn("HubSpot ticket pipeline schema unavailable: #{error.message}")
    local_ticket_pipeline_options
  end
end

def local_ticket_pipeline_options
  rows = sam_ticket_scope.pluck(
    Arel.sql("crm_records.properties #>> '{hubspot,properties,hs_pipeline}'"),
    Arel.sql("crm_records.properties #>> '{hubspot,properties,hs_pipeline_stage}'"),
    :stage
  )
  grouped = {}

  rows.each do |pipeline_id, stage_id, stage_label|
    pipeline_id = pipeline_id.to_s.presence || "local"
    stage_id = stage_id.to_s.presence || stage_label.to_s.presence
    next if stage_id.blank?

    grouped[pipeline_id] ||= {
      id: pipeline_id,
      label: pipeline_id == "local" ? "Local ticket records" : "Pipeline #{pipeline_id}",
      stages: []
    }
    grouped[pipeline_id][:stages] << { id: stage_id, label: stage_label.to_s.presence || stage_id }
  end

  grouped.values.each do |pipeline|
    pipeline[:stages] = pipeline[:stages].uniq { |stage| stage[:id] }.sort_by { |stage| stage[:label].downcase }
  end.sort_by { |pipeline| pipeline[:label].downcase }
end

def default_ticket_pipeline_id
  sam = ticket_pipeline_options.find { |option| option[:label].to_s == Hubspot::TicketSync::DEFAULT_PIPELINE_LABEL } ||
    ticket_pipeline_options.find { |option| option[:label].to_s.match?(/\bSAM\b/i) }
  sam&.dig(:id)
end

def active_ticket_pipeline_id
  value = params[:pipeline_id].to_s.strip
  return nil if value.blank? || value == TICKET_PIPELINE_ALL_VALUE

  value
end

def active_ticket_status_value
  value = params[:ticket_status].to_s.strip
  return nil if value.blank? || value == TICKET_STATUS_ALL_VALUE

  value
end

def active_ticket_status_pipeline_id
  ticket_status_pair(active_ticket_status_value).first
end

def ticket_status_pair(value)
  pipeline_id, stage_id = value.to_s.split(":", 2)
  return [nil, nil] if pipeline_id.blank? || stage_id.blank?

  [pipeline_id, stage_id]
end

def ticket_pipeline_label_for(pipeline_id)
  pipeline = ticket_pipeline_options.find { |option| option[:id].to_s == pipeline_id.to_s }
  pipeline&.dig(:label).presence || (pipeline_id.present? ? "Pipeline #{pipeline_id}" : "all pipelines")
end

def ticket_status_label_for_value(value)
  pipeline_id, stage_id = ticket_status_pair(value)
  return if pipeline_id.blank? || stage_id.blank?

  pipeline = ticket_pipeline_options.find { |option| option[:id].to_s == pipeline_id.to_s }
  stage = pipeline&.dig(:stages)&.find { |candidate| candidate[:id].to_s == stage_id.to_s }
  [pipeline&.dig(:label), stage&.dig(:label) || stage_id].compact.join(" // ")
end

  def filtered_deals
    scope = base_deals

    if sam_ticket_lead_source?
      if active_ticket_status_value.present?
        pipeline_id, stage_id = ticket_status_pair(active_ticket_status_value)
        if pipeline_id.present? && stage_id.present?
          scope = scope.where(
            "crm_records.properties #>> '{hubspot,properties,hs_pipeline}' = ? AND crm_records.properties #>> '{hubspot,properties,hs_pipeline_stage}' = ?",
            pipeline_id,
            stage_id
          )
        end
      elsif active_ticket_pipeline_id.present?
        scope = scope.where("crm_records.properties #>> '{hubspot,properties,hs_pipeline}' = ?", active_ticket_pipeline_id)
      end
    end

    scope = scope.where(stage: params[:stage]) if params[:stage].present?

  case params[:priority_status].to_s
  when "priority"
    scope = scope.where(priority_where_sql)
  when "standard"
    scope = scope.where("NOT (#{priority_where_sql})")
  end

    case params[:claim_status]
    when "claimed"
      scope = scope.where.not(owner_id: nil)
    when "unclaimed"
      scope = scope.where(owner_id: nil)
    end

    if params[:claim_owner_id].present?
      scope = scope.where(owner_id: params[:claim_owner_id])
    end

    query = params[:q].to_s.strip
    if query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      scope = scope.left_joins(:owner).where(
        "crm_records.name ILIKE :q OR crm_records.stage ILIKE :q OR crm_records.properties::text ILIKE :q OR users.name ILIKE :q OR users.email_address ILIKE :q",
        q: like
      )
    end

    scope
  end


  def priority_rank_sql(table_name = "crm_records")
    manual = "LOWER(COALESCE(NULLIF(#{table_name}.priority_level, ''), 'normal'))"
    hubspot = "LOWER(COALESCE(#{table_name}.properties #>> '{hubspot,labeled_properties,Ticket Priority}', #{table_name}.properties #>> '{hubspot,properties,hs_ticket_priority}', ''))"

    <<~SQL.squish
      CASE
        WHEN #{manual} = 'urgent' THEN 0
        WHEN #{manual} = 'priority' THEN 1
        WHEN #{hubspot} LIKE '%urgent%' OR #{hubspot} LIKE '%critical%' OR #{hubspot} LIKE '%rush%' OR #{hubspot} LIKE '%asap%' OR #{hubspot} LIKE '%high%' THEN 1
        ELSE 2
      END
    SQL
  end

  def priority_where_sql
    rank_sql = priority_rank_sql("crm_records")
    "(#{rank_sql}) < 2"
  end

  def report_artifact_sort_sql
    artifact_priority = "LOWER(COALESCE(NULLIF(crm_record_artifacts.metadata ->> 'priority_level', ''), NULLIF(crm_records.priority_level, ''), 'normal'))"
    hubspot = "LOWER(COALESCE(crm_records.properties #>> '{hubspot,labeled_properties,Ticket Priority}', crm_records.properties #>> '{hubspot,properties,hs_ticket_priority}', ''))"

    <<~SQL.squish
      CASE
        WHEN #{artifact_priority} = 'urgent' THEN 0
        WHEN #{artifact_priority} = 'priority' THEN 1
        WHEN #{hubspot} LIKE '%urgent%' OR #{hubspot} LIKE '%critical%' OR #{hubspot} LIKE '%rush%' OR #{hubspot} LIKE '%asap%' OR #{hubspot} LIKE '%high%' THEN 1
        ELSE 2
      END ASC, crm_record_artifacts.created_at ASC
    SQL
  end

  def queue_sort_sql
    priority_sort = "#{priority_rank_sql} ASC"
    my_claim_sort = current_user&.id.present? ? "CASE WHEN crm_records.owner_id = #{current_user.id.to_i} THEN 0 ELSE 1 END ASC" : "1 ASC"
    company_sort = <<~SQL.squish
      LOWER(COALESCE(
        NULLIF(crm_records.properties #>> '{hubspot,labeled_properties,Company Name}', ''),
        NULLIF(crm_records.properties #>> '{hubspot,properties,company_name}', ''),
        crm_records.name
      ))
    SQL
    claimer_sort = "LOWER(COALESCE(NULLIF(users.name, ''), NULLIF(users.email_address, ''), 'zzzzzz'))"

    sort_sql = case params[:sort]
    when "claimer_desc"
      "CASE WHEN crm_records.owner_id IS NULL THEN 1 ELSE 0 END ASC, #{claimer_sort} DESC, #{company_sort} ASC, crm_records.updated_at DESC"
    when "claimer_asc"
      "CASE WHEN crm_records.owner_id IS NULL THEN 1 ELSE 0 END ASC, #{claimer_sort} ASC, #{company_sort} ASC, crm_records.updated_at DESC"
    when "updated"
      "crm_records.updated_at DESC, #{company_sort} ASC"
    else
      "#{company_sort} ASC, crm_records.updated_at DESC"
    end

    Arel.sql("#{priority_sort}, #{my_claim_sort}, #{sort_sql}")
  end

  def report_download_filename(artifact)
    base = artifact.title.to_s.parameterize.presence || "market-strategy-report-#{artifact.id}"
    "#{base}.docx"
  end

  def canva_kit_filename(artifact)
    kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h
    kit["filename"].presence || "canva-build-kit-#{artifact.id}.zip"
  end
def canva_output_filename(artifact)
  output = artifact.metadata.to_h.dig("canva", "output_package").to_h
  output["filename"].presence || "canva-output-#{artifact.id}.zip"
end

def canva_pdf_filename(artifact, fallback)
  fallback.to_s.presence || "canva-report-#{artifact.id}.pdf"
end

def browser_preview_disposition(content_type)
  content_type = content_type.to_s
  return "inline" if content_type == "application/pdf" || content_type.start_with?("image/")

  "attachment"
end

def extract_canva_pdf(zip_bytes)
  extracted_pdf = nil

  Zip::File.open_buffer(StringIO.new(zip_bytes.to_s.b)) do |zip|
    entry = zip.find { |candidate| candidate.name.start_with?("exports/") && candidate.name.downcase.end_with?(".pdf") }
    raise "Canva output package does not contain a PDF export." if entry.blank?

    extracted_pdf = { filename: File.basename(entry.name), bytes: entry.get_input_stream.read }
  end

  extracted_pdf
end
end
