require "digest"
require "csv"
require "fileutils"
require "ostruct"

class CommsCommandsController < ApplicationController
  COMMS_INDEX_DEFAULT_CANDIDATE_LIMIT = 100
  COMMS_INDEX_WIDE_CANDIDATE_LIMIT = 100
  COMMS_INDEX_DEFAULT_DISPLAY_LIMIT = 100
  COMMS_DEFAULT_STATUS_FILTER = "claimed_by_me".freeze
  COMMS_STATUS_FILTER_OPTIONS = [
    ["claimed_by_me", "Claimed by me"],
    ["owner_queue", "Owner Queue"],
    ["active", "Active shown"],
    ["new", "New"],
    ["needs_reply", "Needs reply"],
    ["autopilot", "Autopilot"],
    ["stale_due", "Stale / due"],
    ["storm_watch", "Storm Watch blocks"],
    ["waiting", "Waiting"],
    ["link_sent", "Link sent"],
    ["am_support", "AM support"],
    ["complete", "Complete"],
    ["hold", "On hold"],
    ["hidden", "Hidden"],
    ["opt_out", "Opt out"],
    ["all", "All blocks"]
  ].freeze
  COMMS_RUN_ALL_DEFAULT_CADENCE = "med".freeze
  COMMS_RUN_ALL_CADENCES = {
    "fast" => { label: "Fast 5s", delay_seconds: 5.0 },
    "med" => { label: "Med 15s", delay_seconds: 15.0 },
    "slow" => { label: "Slow 30s", delay_seconds: 30.0 }
  }.freeze
  COMMS_RUN_ALL_CADENCE_ALIASES = {
    "normal" => "med",
    "safe" => "slow"
  }.freeze
  COMMS_CSV_IMPORT_STATUS_PREFIX = "csv_import:".freeze
  SMS_CONVERSATION_RESET_DISCOVERY_METADATA_KEYS = %w[
    comms_bot_state
    campaign_fit
    current_next_text
    processing_code
    processing_label
    processing_next_step
    processing_summary
    processing_source
    processing_updated_at
    product_interest_code
    product_interest_label
    product_interest
    captured_contact_name
    captured_company_name
    captured_industry
    captured_email
    captured_phone
    captured_zip
    captured_city
    captured_state
    captured_country
    sms_captured_contact_name
    sms_captured_company_name
    sms_captured_industry
    sms_captured_email
    sms_captured_phone
    sms_captured_zip
    sms_captured_city
    sms_captured_state
    sms_captured_country
    sms_captured_budget
    sms_captured_quantity
    sms_captured_product_interest
    sms_lane_monitor
    sms_lane_monitor_updated_at
    industry
    company_industry
    crm_industry
    industry_strategy_label
    industry_strategy
    business_context
    email_opt_in
    contact_preference
    preferred_contact_window
    preferred_contact_days
    preferred_contact_times
    proof_delivery_email
    proof_delivery_method
    proof_delivery_requested_at
    location_capture_last
    manual_comms_zip
    manual_comms_contact_email
    recipient_email_options
    selected_recipient_email_id
    shopify_link
    shopify_link_sent_at
    comms_link_reached_at
    checkout_url
    product_key
    product_label
    route_code
    comms_command_sms_draft_body
    comms_command_sms_draft
    comms_command_sms_prompt
    comms_command_sms_default_objective
    comms_command_sms_sent_draft_at
    comms_command_sms_sent_draft_sha1
    sms_draft_history
    aircall_composed_sms_body
    composed_sms_body
    selected_sms_id
    sms_options
    comms_command_background_question_id
    comms_command_background_status
    comms_command_background_error
    comms_command_background_at
    comms_command_background_running_at
    comms_command_background_failed_at
    comms_command_background_provider
    comms_command_late_worker_question_id
    comms_command_late_worker_applied_at
    sms_reply_generation
    sms_reply_generation_superseded_at
    sms_reply_generation_superseded_reason
    sms_reply_generation_superseded_by_user_id
    sms_reply_generation_superseded_by
    sms_reply_generation_superseded_question_ids
    sms_reply_generation_at
    sms_reply_generation_inbound_id
    sms_reply_generation_inbound_sid
    sms_reply_job_generation
    sms_reply_job_status
    sms_reply_job_queued_at
    sms_reply_job_running_at
    sms_reply_job_completed_at
    sms_reply_job_failed_at
    sms_reply_jobs_recent
    sms_reply_rate_limited_at
    sms_reply_rate_limited_until
    sms_reply_last_stale_generation
    sms_reply_last_stale_at
    sms_reply_last_stale_provider
    sms_guardrail_retry_key
    sms_guardrail_retry_count
    sms_guardrail_retry_reason
    sms_guardrail_retry_instruction
    sms_guardrail_retry_last_question_id
    sms_guardrail_retry_rejected_question_id
    sms_guardrail_retry_at
    sms_inbound_recovery
    sms_inbound_recovery_count
    ask_autopilot_pending_started_at
    ask_autopilot_pending_phase
    sms_autopilot_completed_at
    sms_autopilot_completion_sent_at
    sms_autopilot_slack_human_requested_at
    sms_autopilot_slack_completion_without_purchase_at
    sms_autopilot_slack_handoff_at
    sms_autopilot_slack_handoff_status
    sms_autopilot_slack_handoff_status_at
    sms_autopilot_slack_handoff_error
    sms_autopilot_slack_handoff_queued_at
    sms_autopilot_slack_pending_body
    sms_autopilot_slack_last_reason
    sms_autopilot_am_support_enabled_at
    sms_autopilot_handoff_contact_pending
    sms_autopilot_handoff_contact_started_at
    sms_autopilot_handoff_contact_updated_at
    sms_autopilot_handoff_contact_latest_body
    sms_autopilot_handoff_contact_reason
    sms_autopilot_handoff_contact_preference
    sms_autopilot_handoff_contact_email
    sms_autopilot_handoff_contact_phone
    sms_autopilot_handoff_contact_time
    sms_autopilot_handoff_contact_permission
    sms_autopilot_handoff_contact_ready_at
    sms_autopilot_handoff_contact_posted_at
    comms_support_state
    comms_support_state_at
    comms_support_reason
    comms_support_source
    comms_support_latest_body
    comms_routed_to_user_id
    comms_routed_to_user_name
    comms_routed_to_user_first_name
    comms_routed_to_user_email
    comms_routed_to_hubspot_owner_id
    comms_route_claimed_at
    comms_route_claim_reason
    comms_route_claim_load
    comms_route_claim_order
    comms_route_claim_cursor
    comms_route_claim_history
    comms_route_claim_pool
    comms_route_previous_user_name
    comms_route_previous_user_id
    contact_owner_code
    contact_owner_status
    contact_owner_source
    contact_owner_assigned_at
    hubspot_owner_property
    hubspot_owner_write_pending
    sms_autopilot_last_error
    sms_autopilot_last_error_at
    sms_autopilot_last_status
    sms_autopilot_last_status_at
    sms_autopilot_sent_count
    sms_autopilot_last_sent_at
    sms_autopilot_started_at
    sms_autopilot_started_with_opener
    sms_autopilot_started_with_data_grab
    sms_autopilot_started_with_next_text
    sms_autopilot_last_reply_to_sid
    sms_copilot_requested_at
    sms_copilot_requested_by_user_id
    sms_copilot_requested_by
    sms_copilot_last_question_id
    comms_support_state
    comms_support_state_at
    comms_support_reason
    comms_support_source
    comms_support_at
    comms_support_latest_body
    comms_route_claim_reason
  ].freeze
  COMMS_EMAIL_FOLLOW_UP_DAY_ACTIONS = [
    ["NO SEND", "none"],
    ["SMS", "sms"],
    ["Email", "email"],
    ["SMS+EMAIL", "both"]
  ].freeze
  COMMS_EMAIL_FOLLOW_UP_PRESETS = {
    "normal" => {
      label: "Normal",
      days: {
        "1" => "both",
        "2" => "none",
        "3" => "email",
        "4" => "both",
        "5" => "none",
        "6" => "none",
        "7" => "email"
      }
    },
    "moderate" => {
      label: "Moderate",
      days: {
        "1" => "both",
        "2" => "both",
        "3" => "none",
        "4" => "email",
        "5" => "both",
        "6" => "none",
        "7" => "email"
      }
    },
    "aggressive" => {
      label: "Aggressive",
      days: {
        "1" => "both",
        "2" => "both",
        "3" => "email",
        "4" => "both",
        "5" => "email",
        "6" => "email",
        "7" => "email"
      }
    },
    "monthly" => {
      label: "Monthly",
      days: {
        "1" => "none",
        "2" => "none",
        "3" => "email",
        "4" => "none",
        "5" => "both",
        "6" => "none",
        "7" => "none"
      }
    }
  }.freeze
  COMMS_BOARD_STATE_OPTIONS = [
    ["active", "Active"],
    ["hold", "Hold"],
    ["hidden", "Hide"],
    ["done", "Done"],
    ["opt_out", "Opt out"]
  ].freeze
  COMMS_STAGE_TYPES = %w[manual_comms storm_watch_comms].freeze
  HUBSPOT_LEAD_PROPERTIES = %w[
    hs_object_id hs_createdate hs_lastmodifieddate hs_lead_name hs_lead_label hs_pipeline_stage hs_lead_quality
    hubspot_owner_id
  ].freeze
  HUBSPOT_COMMS_CONTACT_PROPERTIES = (
    Hubspot::ContactLeadSync::DEFAULT_CONTACT_PROPERTIES + %w[
      industry jobtitle zip city state hs_object_id createdate lastmodifieddate
    ]
  ).uniq.freeze

  before_action :require_organization!
  before_action :set_stage, only: [:show_stage, :copilot_sms, :reset_sms_conversation, :draft_sms, :send_sms, :draft_email, :send_email, :toggle_autopilot, :update_sms_writer_model, :update_rag_profile, :send_to_am, :update_board_state, :destroy]

  helper_method :stage_company_name, :stage_selected_contact, :stage_selected_phone,
    :stage_selected_email, :stage_sms_body, :stage_email_subject, :stage_email_body,
    :stage_sms_thread, :stage_email_thread, :stage_processing_code, :stage_processing_summary,
    :stage_recent_inbound_sms?, :stage_latest_inbound_sms_event, :stage_recent_client_sms_response?,
    :stage_sms_autopilot_enabled?,
    :stage_sms_do_not_contact?, :stage_first_sms_sent?, :stage_follow_up_timer,
    :stage_call_status, :stage_last_sms_at, :stage_last_sms_label, :stage_manual_board_state,
    :stage_link_sent?, :stage_am_support?, :stage_sms_background_drafting?,
    :stage_sms_draft_progress_signals,
    :stage_sms_conversation_reset_time, :stage_sms_events_after_reset,
    :deletable_comms_stage?,
    :comms_board_state_options,
    :tel_href_for,
    :industry_strategy_lens_options, :report_local_model_options, :report_embedder_model_options, :report_challenger_model_options,
    :comms_challenger_model_options, :comms_run_all_cadence_options,
    :comms_email_follow_up_preset_options, :comms_email_follow_up_day_action_options,
    :comms_email_follow_up_day_labels, :comms_email_follow_up_day_plan,
    :comms_email_follow_up_preset_day_plans,
    :comms_email_follow_up_preset_label, :comms_email_follow_up_monthly_week_options,
    :normalize_run_all_cadence,
    :comms_run_all_cadence_label, :stage_sms_challenger_model,
    :comms_sms_writer_model_options, :stage_sms_writer_model,
    :comms_rag_profile_options, :stage_rag_profile,
    :comms_batch_template_settings, :comms_batch_template_token_options,
    :comms_batch_template_active,
    :comms_sms_language_settings

  def index
    warm_thumper_context_cache_later!("leads_comms")
    @twilio_status = Comms::SmsProvider.public_status(user: current_user)
    @postmark_configured = Postmark::OutboundClient.configured?
    @follow_up_settings = comms_follow_up_settings
    @batch_template_settings = comms_batch_template_settings
    @sms_language_settings = comms_sms_language_settings
    @comms_lightweight_refresh = comms_board_refresh_request?
    load_lightweight_storm_watch_summary
    console_state = comms_console_state
    @comms_query = comms_requested_query(console_state)
    @comms_status_filter = comms_requested_status(console_state)
    @comms_page = comms_page(console_state)
    @comms_page_size = comms_index_display_limit
    @comms_offset = (@comms_page - 1) * @comms_page_size
    @comms_board_change_token = comms_board_change_token
    @comms_status_filter_options = comms_status_filter_options
    searched_scope = search_staged_scope(staged_scope, @comms_query)
    @comms_status_counts = {}
    @owner_queue_available_count = nil
    @owner_queue_staged_count = nil
    @bulk_autopilot_status = current_organization.settings.to_h.fetch("comms_bulk_autopilot_run", {}).to_h
    @bulk_copilot_status = current_organization.settings.to_h.fetch("comms_bulk_copilot_run", {}).to_h
    @csv_import_status = comms_csv_import_status_for(params[:csv_import_job])
    flash_completed_owner_queue_refresh!
    scope = scoped_staged_index_scope(searched_scope, @comms_status_filter)
      .includes(:user, crm_record: [:owner, { deal_media_attachments: :blob }])
      .order(updated_at: :desc)
    if params[:open_stage].present? || params[:open_ai_lab_stage].present?
      open_stage_id = params[:open_stage].presence || params[:open_ai_lab_stage]
      @stages = staged_scope
        .includes(:user, crm_record: [:owner, { deal_media_attachments: :blob }])
        .where(id: open_stage_id)
        .limit(1)
      @comms_status_counts = comms_status_counts_with_global_lanes(comms_status_counts_from_stages(@stages))
      @comms_has_previous_page = false
      @comms_has_next_page = false
      @comms_page_start = @stages.present? ? 1 : 0
      @comms_page_end = @stages.size
      @run_all_blocked_by_visible_dnc = false
      @run_all_visible_eligible_count = 0
      @copilot_visible_eligible_count = @stages.count { |stage| !skip_bulk_copilot_stage?(stage) }
      @remove_all_visible_eligible_count = @stages.count { |stage| purge_actionable_comms_stage?(stage, status_filter: @comms_status_filter) }
      @claim_visible_eligible_count = @stages.count { |stage| claimable_comms_stage?(stage) }
      prepare_comms_report_artifacts!
    elsif params[:open_sms_stage].present? && request.xhr?
      @stages = staged_scope
        .includes(:user, crm_record: [:owner, { deal_media_attachments: :blob }])
        .where(id: params[:open_sms_stage])
        .limit(1)
      @comms_status_counts = comms_status_counts_with_global_lanes(comms_status_counts_from_stages(@stages))
      @comms_has_previous_page = false
      @comms_has_next_page = false
      @comms_page_start = @stages.present? ? 1 : 0
      @comms_page_end = @stages.size
      @run_all_blocked_by_visible_dnc = false
      @run_all_visible_eligible_count = 0
      @copilot_visible_eligible_count = @stages.count { |stage| !skip_bulk_copilot_stage?(stage) }
      @remove_all_visible_eligible_count = @stages.count { |stage| purge_actionable_comms_stage?(stage, status_filter: @comms_status_filter) }
      @claim_visible_eligible_count = @stages.count { |stage| claimable_comms_stage?(stage) }
      prepare_comms_report_artifacts!
      render :index, layout: false if request.xhr?
    else
      candidates = scope.offset(@comms_offset).limit(@comms_page_size + 1).to_a
      sorted_candidates = sort_comms_stages(filter_comms_stages(candidates, @comms_status_filter))
      @stages = sorted_candidates.first(@comms_page_size)
      count_source = @comms_lightweight_refresh ? comms_status_counts_from_stages(@stages) : comms_board_status_counts
      @comms_status_counts = comms_status_counts_with_global_lanes(count_source)
      @comms_has_previous_page = @comms_page > 1
      @comms_has_next_page = candidates.size > @comms_page_size || sorted_candidates.size > @comms_page_size
      @comms_page_start = @stages.present? ? @comms_offset + 1 : 0
      @comms_page_end = @comms_offset + @stages.size
      @run_all_blocked_by_visible_dnc = @stages.any? { |stage| stage_sms_do_not_contact?(stage) }
      @run_all_visible_eligible_count = @stages.count { |stage| !skip_bulk_autopilot_stage?(stage) }
      @copilot_visible_eligible_count = @stages.count { |stage| !skip_bulk_copilot_stage?(stage) }
      @remove_all_visible_eligible_count = @stages.count { |stage| purge_actionable_comms_stage?(stage, status_filter: @comms_status_filter) }
      @claim_visible_eligible_count = @stages.count { |stage| claimable_comms_stage?(stage) }
      prepare_comms_report_artifacts!
      persist_comms_console_state!
    end
    @purge_eligible_count = purge_eligible_count_for_action(query: @comms_query, status_filter: @comms_status_filter, visible_count: @remove_all_visible_eligible_count)
  end

  def show_stage
    render_comms_stage_fragment(@stage.reload)
  end

  def board_version
    response.headers["Cache-Control"] = "no-store, max-age=0"
    render json: { version: comms_board_change_token }
  end

  def create_manual
    return_status = normalize_comms_status_filter(params[:status].presence || COMMS_DEFAULT_STATUS_FILTER)
    return_page = params[:page].to_i.clamp(1, 10_000)
    return_query = params[:q].to_s.squish
    claim_for_current_user = return_status == "claimed_by_me"
    value = params[:contact_value].to_s.squish
    label = params[:contact_label].to_s.squish.presence || "WIZWIKI COMMS"
    raise ArgumentError, "Enter a phone number or email." if value.blank?

    phone = extract_phone(value)
    email = extract_email(value)
    raise ArgumentError, "Enter a usable phone number or email." if phone.blank? && email.blank?

    duplicate_stage = nil
    stage = nil
    CrmRecordArtifact.transaction do
      with_manual_comms_contact_lock(phone: phone, email: email) do
        duplicate_stage = duplicate_active_comms_stage(phone: phone, email: email)
        next if duplicate_stage.present?

        contact_name = manual_label_contact_name(label)
        company_name = contact_name.present? ? nil : label
        record = manual_crm_record!(label: label, phone: phone, email: email, contact_name: contact_name, company_name: company_name, claim_by_current_user: claim_for_current_user)
        stage = manual_stage!(record: record, label: label, phone: phone, email: email, contact_name: contact_name, company_name: company_name, claim_by_current_user: claim_for_current_user, duplicate_checked: true)
        if stage.respond_to?(:csv_import_created?) && stage.csv_import_created?
          stage.update!(
            metadata: stage.metadata.to_h.merge(
              "sms_autopilot_enabled" => false,
              "sms_autopilot_sent_count" => 0,
              "comms_command_last_status" => "staged"
            )
          )
        end
      end
    end

    if duplicate_stage.present?
      redirect_to comms_manual_return_path(duplicate_stage, status: return_status, page: return_page, query: return_query), alert: duplicate_contact_message(duplicate_stage)
      return
    end

    refresh_comms_board_counts_later!

    redirect_to comms_manual_return_path(stage, status: return_status, page: return_page, query: return_query), notice: "WIZWIKI COMMS created and staged. Open SMS or email when you are ready."
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence || COMMS_DEFAULT_STATUS_FILTER, page: params[:page].presence), alert: "Could not stage WIZWIKI COMMS: #{error.message}"
  end

  def import_csv
    upload = params[:call_csv]
    raise ArgumentError, "Choose a CSV file first." unless upload.respond_to?(:read)

    import_id = SecureRandom.uuid
    import_title = normalize_csv_import_title(params[:call_csv_title])
    claim_by_current_user = ActiveModel::Type::Boolean.new.cast(params[:call_csv_claim_by_me])
    import_status_key = import_title.present? ? csv_import_status_key(import_id) : nil
    job_id = SecureRandom.uuid
    path = persist_csv_upload_for_job!(upload, job_id: job_id)
    Comms::CsvImportStatus.initialize!(
      current_organization,
      job_id: job_id,
      import_id: import_id,
      status_key: import_status_key,
      title: import_title,
      filename: upload.original_filename,
      user: current_user,
      claim_by_current_user: claim_by_current_user
    )
    job = Comms::CsvImportJob.perform_later(
      organization_id: current_organization.id,
      user_id: current_user.id,
      path: path,
      job_id: job_id,
      import_id: import_id,
      title: import_title,
      status_key: import_status_key,
      claim_by_current_user: claim_by_current_user
    )
    Rails.logger.info("[CommsCommands] CSV import queued user=#{current_user.id} job=#{job_id} active_job=#{job.job_id} title=#{import_title.inspect} claim_by_current_user=#{claim_by_current_user}")
    redirect_params = { csv_import_job: job_id }
    redirect_params[:status] = import_status_key if import_status_key.present?
    redirect_params[:status] ||= "all"
    redirect_to comms_command_path(redirect_params), notice: "CSV call block import queued. The loader will keep updating while Thumper builds the blocks."
  rescue StandardError => error
    redirect_to comms_command_path, alert: "Could not import call CSV: #{error.message}"
  end

  def sync_owner_owner
    with_expensive_action_gate("comms_owner_queue", ttl: 2.minutes) do |acquired|
      unless acquired
        redirect_to comms_command_path, notice: "Owner Queue is already loading. The board will update when the current load finishes."
        return
      end

      job = Comms::OwnerQueueRefreshJob.perform_later(
        organization_id: current_organization.id,
        requested_by_user_id: current_user.id
      )
      session[:comms_owner_queue_refresh_requested_at] = Time.current.iso8601
      session.delete(:comms_owner_queue_last_refresh_seen_at)
      redirect_to comms_command_path(status: "owner_queue"), notice: "Owner Queue rebuild queued. Thumper will hydrate Sample Owner-owned source records into local COMMS blocks, then flash the final skipped count when it finishes. Job #{job.job_id}."
    end
  rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError, StandardError => error
    redirect_to comms_command_path, alert: "Could not queue Owner Queue rebuild: #{error.message}"
  end

  def sync_storm_watch
    request_id = nil
    scan_status = Weather::ScanStatus.for(current_organization)
    if scan_status[:active]
      return redirect_to comms_command_path(status: "storm_watch"), notice: "Storm Watch is already #{scan_status[:state_label]}. The loader will keep updating; no duplicate scan was queued."
    end

    with_expensive_action_gate("comms_storm_watch", ttl: 2.minutes) do |acquired|
      unless acquired
        redirect_to comms_command_path(status: "storm_watch"), notice: "Storm Watch is already being started. The loader will update shortly."
        return
      end

      staged = stage_storm_watch_comms!(limit: params[:limit])
      scan_status = Weather::ScanStatus.for(current_organization)
      queued_scan = false

      unless scan_status[:fresh_today]
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
        queued_scan = true
      end

      message = queued_scan ? "Storm Watch scan queued and current blocks loaded" : "Storm Watch blocks loaded from today's shared scan"
      message += ": #{staged[:created]} created, #{staged[:updated]} updated"
      message += ", #{staged[:skipped]} skipped" if staged[:skipped].positive?
      message += " (#{staged[:duplicate_contact]} duplicate phone/email)" if staged[:duplicate_contact].positive?
      message += " (#{staged[:missing_contact]} missing phone/email)" if staged[:missing_contact].positive?
      refresh_comms_board_counts_later!(force: true)
      redirect_to comms_command_path(status: "storm_watch"), notice: message
    end
  rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError, Weather::LeadSignalSync::Error, StandardError => error
    Weather::ScanStatus.mark_failed!(organization: current_organization, error: error, request_id: request_id, job_id: nil) if defined?(request_id) && request_id.present?
    Rails.logger.warn("[CommsCommands] Storm Watch enqueue failed: #{error.class}: #{error.message}")
    redirect_to comms_command_path, alert: "Storm Watch scan could not start: #{error.message}"
  end

  def claim_visible
    page = comms_page
    @comms_query = params[:q].to_s.squish
    status_filter = normalize_comms_status_filter(params[:status])
    visible_stages = visible_comms_stages_for_action(query: @comms_query, status_filter: status_filter, page: page)
    result = claim_visible_comms_stages!(visible_stages)

    refresh_comms_board_counts_later!(force: true) if result[:claimed].positive?

    message = "Claimed #{result[:claimed]} visible call block#{'s' unless result[:claimed] == 1} for your queue."
    message += " #{result[:already_mine]} already belonged to you." if result[:already_mine].positive?
    message += " #{result[:skipped]} skipped because #{result[:skipped] == 1 ? 'it was' : 'they were'} already claimed, protected, or no longer visible." if result[:skipped].positive?
    flash[:comms_claim_report] = [
      "Claim report",
      "",
      "Checked #{result[:visible]} visible call block#{'s' unless result[:visible] == 1}.",
      "Claimed #{result[:claimed]} for your queue.",
      ("Already yours: #{result[:already_mine]}." if result[:already_mine].positive?),
      ("Skipped: #{result[:skipped]} already claimed, protected, or no longer visible." if result[:skipped].positive?),
      "Claimed blocks moved to Claimed by me."
    ].compact.join("\n")

    redirect_to comms_command_path(q: @comms_query.presence, status: "claimed_by_me", page: 1), notice: message
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), alert: "Could not claim visible call blocks: #{error.message}"
  end

  def run_all_autopilot
    page = comms_page
    with_expensive_action_gate("comms_run_all:#{params[:status].presence || 'active'}:#{params[:q].presence || 'all'}:page-#{page}", ttl: 3.minutes) do |acquired|
      unless acquired
        redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: page), notice: "FULL AUTO is already processing this visible board. Let the current run finish before starting another."
        return
      end
      if bulk_autopilot_active?
        redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: page), notice: "FULL AUTO is already queued or running. Let the current background run finish before starting another."
        return
      end

      @comms_query = params[:q].to_s.squish
      status_filter = normalize_comms_status_filter(params[:status])
      sms_writer_model = comms_sms_writer_model_param
      sms_writer_label = WizwikiSettings.sms_writer_model_label(sms_writer_model)
      sms_challenger_model = comms_challenger_model_param
      sms_challenger_label = WizwikiSettings.challenger_model_label(sms_challenger_model)
      launch_cadence = comms_run_all_cadence_param
      launch_cadence_label = comms_run_all_cadence_label(launch_cadence)
      launch_cadence_delay_seconds = comms_run_all_cadence_delay_seconds(launch_cadence)
      batch_template_source = comms_batch_template_bulk_source
      visible_stages = visible_comms_stages_for_action(query: @comms_query, status_filter: status_filter, page: page)

      if visible_stages.any? { |stage| stage_sms_do_not_contact?(stage) }
        redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), alert: "FULL AUTO blocked: a visible call block is marked DO NOT CONTACT. Hide or filter opt-outs before running bulk autopilot."
        return
      end

      eligible_stages = visible_stages.reject { |stage| skip_bulk_autopilot_stage?(stage) }
      if eligible_stages.blank?
        redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), notice: "FULL AUTO found no eligible visible call blocks on this page."
        return
      end

      run_id = SecureRandom.uuid
      eligible_stage_ids = snapshot_bulk_run_stages!(
        eligible_stages,
        run_id: run_id,
        mode: "full_auto",
        status_filter: status_filter,
        page: page,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds
      )
      bulk_source = {
        q: @comms_query,
        status: status_filter,
        page: page,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        stage_ids: eligible_stage_ids,
        sms_writer_model: sms_writer_model,
        sms_writer_model_label: sms_writer_label,
        sms_challenger_model: sms_challenger_model,
        sms_challenger_model_label: sms_challenger_label,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds
      }.merge(batch_template_source)
      job = Comms::BulkAutopilotJob.perform_later(
        organization_id: current_organization.id,
        user_id: current_user.id,
        stage_ids: eligible_stage_ids,
        run_id: run_id,
        delay_seconds: launch_cadence_delay_seconds,
        source: bulk_source
      )
      mark_bulk_autopilot_queued!(
        run_id: run_id,
        job_id: job.job_id,
        stage_ids: eligible_stage_ids,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        status_filter: status_filter,
        page: page,
        sms_writer_model: sms_writer_model,
        sms_writer_model_label: sms_writer_label,
        sms_challenger_model: sms_challenger_model,
        sms_challenger_model_label: sms_challenger_label,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds,
        batch_template_source: batch_template_source
      )
      refresh_comms_board_counts_later!(force: true)
      redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), notice: "FULL AUTO queued for #{eligible_stages.length} eligible visible call block#{'s' unless eligible_stages.length == 1}. Job #{job.job_id} will process one-by-one at #{launch_cadence_label}."
    end
  end

  def run_all_copilot
    page = comms_page
    with_expensive_action_gate("comms_copilot_run_all:#{params[:status].presence || 'active'}:#{params[:q].presence || 'all'}:page-#{page}", ttl: 3.minutes) do |acquired|
      unless acquired
        redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: page), notice: "COPILOT is already queuing drafts for this visible board."
        return
      end
      if bulk_copilot_active?
        redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: page), notice: "COPILOT is already queued or running. Let the current draft run finish before starting another."
        return
      end

      @comms_query = params[:q].to_s.squish
      status_filter = normalize_comms_status_filter(params[:status])
      sms_writer_model = comms_sms_writer_model_param
      sms_writer_label = WizwikiSettings.sms_writer_model_label(sms_writer_model)
      sms_challenger_model = comms_challenger_model_param
      sms_challenger_label = WizwikiSettings.challenger_model_label(sms_challenger_model)
      launch_cadence = comms_run_all_cadence_param
      launch_cadence_label = comms_run_all_cadence_label(launch_cadence)
      launch_cadence_delay_seconds = comms_run_all_cadence_delay_seconds(launch_cadence)
      batch_template_source = comms_batch_template_bulk_source
      visible_stages = visible_comms_stages_for_action(query: @comms_query, status_filter: status_filter, page: page)

      eligible_stages = visible_stages.reject { |stage| skip_bulk_copilot_stage?(stage) }
      if eligible_stages.blank?
        redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), notice: "COPILOT found no eligible visible call blocks on this page. Opt-outs, completed blocks, active autopilot blocks, already-drafting blocks, and no-phone blocks were skipped."
        return
      end

      run_id = SecureRandom.uuid
      eligible_stage_ids = snapshot_bulk_run_stages!(
        eligible_stages,
        run_id: run_id,
        mode: "copilot",
        status_filter: status_filter,
        page: page,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds
      )
      bulk_source = {
        q: @comms_query,
        status: status_filter,
        page: page,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        stage_ids: eligible_stage_ids,
        sms_writer_model: sms_writer_model,
        sms_writer_model_label: sms_writer_label,
        sms_challenger_model: sms_challenger_model,
        sms_challenger_model_label: sms_challenger_label,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds
      }.merge(batch_template_source)
      job = Comms::BulkCopilotJob.perform_later(
        organization_id: current_organization.id,
        user_id: current_user.id,
        stage_ids: eligible_stage_ids,
        run_id: run_id,
        delay_seconds: launch_cadence_delay_seconds,
        source: bulk_source
      )
      mark_bulk_copilot_queued!(
        run_id: run_id,
        job_id: job.job_id,
        stage_ids: eligible_stage_ids,
        visible_count: visible_stages.length,
        eligible_count: eligible_stages.length,
        status_filter: status_filter,
        page: page,
        sms_writer_model: sms_writer_model,
        sms_writer_model_label: sms_writer_label,
        sms_challenger_model: sms_challenger_model,
        sms_challenger_model_label: sms_challenger_label,
        launch_cadence: launch_cadence,
        launch_cadence_label: launch_cadence_label,
        launch_cadence_delay_seconds: launch_cadence_delay_seconds,
        batch_template_source: batch_template_source
      )
      redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), notice: "COPILOT queued draft work for #{eligible_stages.length} eligible visible call block#{'s' unless eligible_stages.length == 1}. Drafts will queue one-by-one at #{launch_cadence_label}. No SMS will send until a human approves."
    end
  end

  def update_board_state
    state = normalize_comms_board_state(params[:board_state])
    metadata = @stage.metadata.to_h.deep_dup
    updates = {
      "comms_board_state" => state,
      "comms_board_state_updated_at" => Time.current.iso8601,
      "comms_board_state_updated_by_user_id" => current_user.id,
      "comms_board_state_updated_by" => current_user.display_name
    }
    if state == "opt_out"
      updates.merge!(
        "sms_do_not_contact" => true,
        "sms_do_not_contact_at" => metadata["sms_do_not_contact_at"].presence || Time.current.iso8601,
        "sms_do_not_contact_reason" => metadata["sms_do_not_contact_reason"].presence || "operator_opt_out",
        "sms_sending_disabled" => true,
        "sms_autopilot_enabled" => false,
        "sms_autopilot_disabled_at" => Time.current.iso8601,
        "sms_autopilot_disabled_reason" => "operator_opt_out",
        "sms_listener_active" => false,
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "do_not_contact",
        "comms_command_last_at" => Time.current.iso8601
      )
    end
    @stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(updates)
    )
    refresh_comms_board_counts_later!(force: true)

    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, anchor: "stage-#{@stage.id}"), notice: "#{stage_company_name(@stage)} moved to #{state.tr('_', ' ')}."
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, anchor: "stage-#{@stage&.id}"), alert: "Could not update call status: #{error.message}"
  end

  def send_to_am
    reason = params[:reason].to_s.squish.presence || "manual_am_support"
    metadata = @stage.reload.metadata.to_h.deep_dup
    now = Time.current
    @stage.update!(
      generated_at: now,
      metadata: metadata.merge(
        "comms_support_state" => "am_support",
        "comms_support_state_at" => metadata["comms_support_state_at"].presence || now.iso8601,
        "comms_support_reason" => reason,
        "comms_command_last_status" => "am_support",
        "comms_command_last_at" => now.iso8601,
        "sms_autopilot_enabled" => false,
        "sms_autopilot_disabled_at" => metadata["sms_autopilot_disabled_at"].presence || now.iso8601,
        "sms_autopilot_disabled_reason" => reason,
        "sms_autopilot_slack_handoff_status" => "queued",
        "sms_autopilot_slack_handoff_queued_at" => now.iso8601,
        "sms_autopilot_slack_handoff_requested_by_user_id" => current_user.id,
        "sms_autopilot_slack_handoff_requested_by" => current_user.display_name
      ).compact_blank
    )

    enqueue_slack_handoff!(@stage.reload, reason: reason)
    refresh_comms_board_counts_later!(force: true)

    redirect_to comms_command_path(q: params[:q].presence, status: "am_support", anchor: "stage-#{@stage.id}"), notice: "#{stage_company_name(@stage)} moved to AM support. Slack wall post queued."
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, anchor: "stage-#{@stage&.id}"), alert: "Could not send call to AM help: #{error.message}"
  end

  def update_follow_up_settings
    settings = sanitize_follow_up_settings(params.fetch(:follow_up, {}), existing: comms_follow_up_settings)
    current_organization.update!(
      settings: current_organization.settings.to_h.deep_merge("comms_follow_up_automation" => settings)
    )
    if ActiveModel::Type::Boolean.new.cast(settings.dig("email", "enabled")) && defined?(Comms::EmailDraftWarmupJob)
      Comms::EmailDraftWarmupJob.perform_later(organization_id: current_organization.id, limit: 8)
    end

    redirect_to comms_command_path, notice: "Thumper scheduler saved for SMS/email follow-ups in CST send windows."
  rescue StandardError => error
    redirect_to comms_command_path, alert: "Could not save Thumper follow-up automation: #{error.message}"
  end

  def update_batch_templates
    raw = permitted_batch_template_params
    new_template_error = validate_new_batch_template(raw["new"])
    if new_template_error.present?
      redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), alert: new_template_error
      return
    end

    settings = Comms::BatchTemplates.sanitize(raw, existing: comms_batch_template_settings, user: current_user)
    current_organization.update!(
      settings: current_organization.settings.to_h.deep_merge("comms_batch_templates" => settings)
    )
    sms_template = Comms::BatchTemplates.active_template(settings, "sms")
    email_template = Comms::BatchTemplates.active_template(settings, "email")
    active = []
    active << "SMS: #{sms_template["title"]}" if sms_template.present?
    active << "Email: #{email_template["title"]}" if email_template.present?
    notice = active.present? ? "Batch templates saved. Active #{active.join(' // ')}." : "Batch templates saved. Static templates are OFF; dynamic Thumper autopilot stays in standby."
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), notice: notice
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), alert: "Could not save batch templates: #{error.message}"
  end

  def update_sms_language_settings
    settings = sanitize_sms_language_settings(params.fetch(:sms_language, {}), existing: comms_sms_language_settings)
    current_organization.update!(
      settings: current_organization.settings.to_h.deep_merge(Comms::SmsLanguageSupport::SETTINGS_KEY => settings)
    )

    status = ActiveModel::Type::Boolean.new.cast(settings["enabled"]) ? "ON" : "OFF"
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), notice: "Multilingual SMS is #{status}. Wiring stays installed."
  rescue StandardError => error
    redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence), alert: "Could not save multilingual SMS setting: #{error.message}"
  end

  def destroy
    label = stage_company_name(@stage)
    unless deletable_comms_stage?(@stage)
      redirect_to comms_command_path(q: params[:q].presence, status: params[:status].presence, page: params[:page].presence, anchor: "stage-#{@stage.id}"), alert: "#{label} is source-managed. Use Hold, Hide, or Done instead of deleting Owner Queue or Storm Watch source blocks."
      return
    end

    CrmRecordArtifact.transaction do
      destroy_comms_stage!(@stage)
    end
    refresh_comms_board_counts_later!(force: true)

    redirect_to comms_command_path, notice: "#{label} comms block removed from the board."
  rescue StandardError => error
    redirect_to comms_command_path, alert: "Could not delete comms block: #{error.message}"
  end

  def destroy_all
    @comms_query = params[:q].to_s.squish
    status_filter = normalize_comms_status_filter(params[:status])
    page = comms_page
    purge_csv_lane = csv_import_status_key_format?(status_filter)
    Comms::CsvImportStatus.mark_purged!(current_organization, status_key: status_filter, user: current_user) if purge_csv_lane
    stages = purge_csv_lane ? csv_import_lane_stages_for_purge(query: @comms_query, status_filter: status_filter) : visible_comms_stages_for_action(query: @comms_query, status_filter: status_filter, page: page)
    releasable_stages = stages.select { |stage| releasable_claimed_source_managed_stage?(stage, status_filter: status_filter) }
    delete_stages = stages.select { |stage| deletable_comms_stage?(stage) }
    protected_count = stages.size - delete_stages.size - releasable_stages.size
    removed = 0
    released = 0
    records_removed = 0

    CrmRecordArtifact.transaction do
      delete_stages.each do |stage|
        records_removed += 1 if destroy_comms_stage!(stage)
        removed += 1
      end
      releasable_stages.each do |stage|
        released += 1 if release_claimed_source_managed_comms_stage!(stage)
      end
    end
    refresh_comms_board_counts_later!(force: true)

    if removed.zero? && released.zero? && protected_count.positive?
      redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), alert: "No blocks removed. Owner Queue and Storm Watch blocks are protected; use Hold, Hide, or Done for source-managed lists."
    else
      scope_label = purge_csv_lane ? "CSV status" : "visible"
      message = "Removed #{removed} #{scope_label} manual WIZWIKI COMMS block#{'s' unless removed == 1} and #{records_removed} related manual CRM record#{'s' unless records_removed == 1}."
      message += " Released #{released} source-managed block#{'s' unless released == 1} from Claimed by me." if released.positive?
      message += " Active CSV importer canceled for this status." if purge_csv_lane
      message += " Skipped #{protected_count} protected source block#{'s' unless protected_count == 1}." if protected_count.positive?
      redirect_to comms_command_path(q: @comms_query.presence, status: status_filter, page: page), notice: message
    end
  rescue StandardError => error
    redirect_to comms_command_path, alert: "Could not remove all COMMS blocks: #{error.message}"
  end

  def copilot_sms
    with_expensive_action_gate("comms_copilot_sms:#{@stage.id}", ttl: 3.minutes) do |acquired|
      unless acquired
        if request.xhr?
          render_comms_stage_fragment(@stage.reload)
          return
        end

        redirect_to copilot_redirect_path(@stage), notice: "COPILOT is already drafting the next text for #{stage_company_name(@stage)}."
        return
      end

      if stage_sms_do_not_contact?(@stage)
        if request.xhr?
          render_comms_stage_fragment(@stage.reload)
          return
        end

        redirect_to copilot_redirect_path(@stage), alert: "COPILOT is locked because this block is marked DO NOT CONTACT."
        return
      end

      user_prompt = params[:sms_prompt].to_s.strip.presence
      sms_writer_model = comms_sms_writer_model_param(@stage)
      sms_challenger_model = comms_challenger_model_param(@stage)
      result = Comms::CopilotDraft.call(
        stage: @stage.reload,
        user: current_user,
        operator_prompt: copilot_sms_operator_prompt(@stage, user_prompt),
        writer_model: sms_writer_model,
        challenger_model: sms_challenger_model,
        user_prompt: user_prompt
      )
      defer_stage_memory!(@stage.reload)

      if request.xhr?
        render_comms_stage_fragment(@stage.reload)
        return
      end

      redirect_to copilot_redirect_path(@stage), notice: copilot_notice(@stage, result)
    end
  rescue StandardError => error
    if request.xhr? && @stage.present?
      Rails.logger.warn("[CommsCommands] XHR Copilot draft failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to copilot_redirect_path(@stage), alert: "COPILOT could not draft the SMS: #{error.message}"
  end

  def reset_sms_conversation
    with_expensive_action_gate("comms_reset_sms:#{@stage.id}", ttl: 3.minutes) do |acquired|
      unless acquired
        @stage = @stage.reload
        if request.xhr?
          render_comms_stage_fragment(@stage)
          return
        end

        redirect_to copilot_redirect_path(@stage), notice: "Thumper is already resetting and drafting the next text for #{stage_company_name(@stage)}."
        return
      end

      if stage_sms_do_not_contact?(@stage)
        redirect_to copilot_redirect_path(@stage), alert: "Conversation reset is locked because this block is marked DO NOT CONTACT."
        return
      end

      @stage = reset_sms_conversation_state!(@stage.reload)
      sms_writer_model = comms_sms_writer_model_param(@stage)
      sms_challenger_model = comms_challenger_model_param(@stage)
      result = Comms::CopilotDraft.call(
        stage: @stage.reload,
        user: current_user,
        operator_prompt: reset_sms_conversation_operator_prompt(@stage),
        writer_model: sms_writer_model,
        challenger_model: sms_challenger_model,
        user_prompt: nil
      )
      defer_stage_memory!(@stage.reload)

      if request.xhr?
        render_comms_stage_fragment(@stage.reload)
        return
      end

      redirect_to copilot_redirect_path(@stage), notice: reset_sms_conversation_notice(@stage, result)
    end
  rescue StandardError => error
    if request.xhr? && @stage.present?
      Rails.logger.warn("[CommsCommands] XHR SMS reset failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to copilot_redirect_path(@stage), alert: "Thumper could not reset the conversation: #{error.message}"
  end

  def draft_sms
    with_expensive_action_gate("comms_draft_sms:#{@stage.id}", ttl: 3.minutes) do |acquired|
      unless acquired
        @stage = @stage.reload
        if request.xhr?
          render_comms_stage_fragment(@stage)
          return
        end

        redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Thumper is already drafting the next text for #{stage_company_name(@stage)}."
        return
      end

    @stage = @stage.reload
    user_prompt = params[:sms_prompt].to_s.strip.presence
    operator_prompt = sms_draft_operator_prompt(@stage, user_prompt)
    sms_writer_model = comms_sms_writer_model_param(@stage)
    sms_writer_label = WizwikiSettings.sms_writer_model_label(sms_writer_model)
    sms_challenger_model = comms_challenger_model_param(@stage)
    sms_challenger_label = WizwikiSettings.challenger_model_label(sms_challenger_model)
    result = DealReports::CommsDraftWriter.queue_background(
      stage: @stage,
      user: current_user,
      operator_prompt: operator_prompt,
      writer_model: sms_writer_model,
      challenger_model: sms_challenger_model
    )
    metadata = @stage.metadata.to_h.deep_dup
    if ActiveModel::Type::Boolean.new.cast(result["pending"])
      current_draft_source = metadata.dig("comms_command_sms_draft", "draft_source").to_s
      pending_body = current_draft_source == "fallback" ? nil : safe_customer_sms_body(metadata["comms_command_sms_draft_body"])
      @stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_sms_draft_body" => pending_body,
          "comms_command_sms_prompt" => user_prompt,
          "comms_command_sms_default_objective" => user_prompt.blank? ? operator_prompt : nil,
          "comms_command_sms_draft" => result.merge(
            "writer_model" => result["writer_model"].presence || sms_writer_model,
            "writer_model_label" => result["writer_model_label"].presence || sms_writer_label,
            "challenger_model" => result["challenger_model"].presence || sms_challenger_model,
            "challenger_model_label" => result["challenger_model_label"].presence || sms_challenger_label,
            "draft_source" => "pending",
            "created_at" => Time.current.iso8601
          ),
          "sms_writer_model" => sms_writer_model,
          "sms_writer_model_label" => sms_writer_label,
          "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(sms_writer_model),
          "sms_challenger_model" => sms_challenger_model,
          "sms_challenger_model_label" => sms_challenger_label,
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "drafting",
          "comms_command_last_at" => Time.current.iso8601,
          "comms_command_background_question_id" => result["autos_question_id"],
          "comms_command_background_status" => "queued",
          "comms_command_background_at" => Time.current.iso8601
        ).compact_blank
      )

      if request.xhr?
        render_comms_stage_fragment(@stage.reload)
        return
      end

      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Thumper is still composing the next text for #{stage_company_name(@stage)}."
      return
    end

    raw_body = result["body"].to_s.strip.presence
    body = safe_customer_sms_body(raw_body)
    if raw_body.present? && body.blank?
      reason = sms_body_safety_reason(raw_body)
      Rails.logger.warn("[CommsCommands] blocked unsafe drafted SMS stage=#{@stage&.id} reason=#{reason}")
      result = result.except("body").merge(
        "error" => [result["error"], "sms_body_safety_rejected: #{reason}"].compact_blank.join(" | "),
        "sms_quality_gate" => "blocked",
        "draft_source" => "safety_rejected"
      )
    end

    processing = body.present? ? processing_payload(@stage, metadata: metadata, latest_body: latest_inbound_sms_body(@stage)) : {}
    history = Array(metadata["sms_draft_history"]).last(24)
    if body.present?
      history << {
        "id" => SecureRandom.uuid,
        "body" => body,
        "provider" => result["provider"],
        "model" => result["model"],
        "writer_model" => result["writer_model"].presence || sms_writer_model,
        "writer_model_label" => result["writer_model_label"].presence || sms_writer_label,
        "challenger_model" => result["challenger_model"].presence || sms_challenger_model,
        "challenger_model_label" => result["challenger_model_label"].presence || sms_challenger_label,
        "draft_source" => result["draft_source"].presence || (result["provider"].to_s.include?("fallback") ? "fallback" : "thumper"),
        "reason" => result["reason"],
        "operator_prompt" => result["operator_prompt"],
        "error" => result["error"],
        "user_id" => current_user.id,
        "user_name" => current_user.display_name,
        "created_at" => Time.current.iso8601
      }.compact_blank
    end

    @stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "comms_command_sms_draft_body" => body,
        "comms_command_sms_prompt" => user_prompt,
        "comms_command_sms_default_objective" => user_prompt.blank? ? operator_prompt : nil,
        "comms_command_sms_draft" => result.except("body").merge(
          "body" => body,
          "writer_model" => result["writer_model"].presence || sms_writer_model,
          "writer_model_label" => result["writer_model_label"].presence || sms_writer_label,
          "challenger_model" => result["challenger_model"].presence || sms_challenger_model,
          "challenger_model_label" => result["challenger_model_label"].presence || sms_challenger_label,
          "draft_source" => result["draft_source"].presence || (result["provider"].to_s.include?("fallback") ? "fallback" : "thumper"),
          "created_at" => Time.current.iso8601
        ),
        "sms_writer_model" => sms_writer_model,
        "sms_writer_model_label" => sms_writer_label,
        "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(sms_writer_model),
        "sms_challenger_model" => sms_challenger_model,
        "sms_challenger_model_label" => sms_challenger_label,
        "sms_draft_history" => history,
        "comms_bot_state" => result["conversation_state"].presence,
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => body.present? ? "drafted" : "draft_failed",
        "comms_command_last_at" => Time.current.iso8601,
        "comms_command_background_question_id" => result["autos_question_id"],
        "comms_command_background_status" => result["background_queued"] ? "queued" : nil,
        "comms_command_background_at" => result["background_queued"] ? Time.current.iso8601 : nil
      ).compact_blank.merge(processing)
    )
    defer_stage_memory!(@stage)

    if request.xhr?
      render_comms_stage_fragment(@stage.reload)
      return
    end

      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Thumper rebuilt the next text for #{stage_company_name(@stage)}."
    end
  rescue StandardError => error
    if request.xhr? && @stage.present?
      Rails.logger.warn("[CommsCommands] XHR SMS draft failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to comms_command_path(open_sms_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "Thumper could not rebuild the SMS: #{error.message}"
  end

  def send_sms
    raw_body = params[:sms_body].to_s.strip.presence || stage_sms_body(@stage)
    body = safe_customer_sms_body(raw_body)
    phone = params[:phone_number].to_s.strip.presence || stage_selected_phone(@stage)["value"].to_s
    persist_sms_writer_model!(@stage, writer_model: comms_sms_writer_model_param(@stage))
    if raw_body.blank?
      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), alert: "SMS did not send: there is no reviewed next text yet."
      return
    end
    if body.blank? || unsafe_outbound_sms_body?(body)
      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), alert: "SMS did not send: Thumper caught an internal note or route code in the message body."
      return
    end
    if (stale_reason = stale_sms_draft_send_reason(@stage.reload, body)).present?
      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), alert: "SMS did not send: #{stale_reason}"
      return
    end
    if (fingerprint_reason = sms_draft_fingerprint_mismatch_reason(@stage.reload, params[:sms_draft_sha1], params[:sms_reply_generation])).present?
      redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), alert: "SMS did not send: #{fingerprint_reason}"
      return
    end

    supersede_inflight_sms_draft!(@stage, reason: "operator_sent_reviewed_sms")
    body = sms_delivery_body_for_stage(@stage, body)
    result = Comms::SmsProvider.deliver!(
      to: phone,
      body: body,
      from_number: twilio_sender_profile["from_number"],
      messaging_service_sid: twilio_sender_profile["messaging_service_sid"]
    )
    append_stage_event!(
      @stage,
      "sms_thread",
      event_payload(channel: "sms", direction: "outbound", status: "sent", body: body, to: phone, provider_result: result)
        .merge(sms_delivery_language_event_payload)
        .compact_blank
    )
    mark_sms_draft_sent!(@stage, body, clear_any: true)
    queue_stage_memory!(@stage)

    redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "SMS sent for #{stage_company_name(@stage)}."
  rescue StandardError => error
    append_stage_event!(
      @stage,
      "sms_thread",
      event_payload(channel: "sms", direction: "outbound", status: "failed", body: body, to: phone, error: error.message)
    ) if @stage.present?
    queue_stage_memory!(@stage) if @stage.present?

    redirect_to comms_command_path(open_sms_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "SMS did not send: #{error.message}"
  end

  def draft_email
    user_prompt = params[:email_prompt].to_s.strip.presence
    operator_prompt = email_comm_kit_operator_prompt(@stage.reload, user_prompt)
    result = DealReports::CommsEmailDraftWriter.call(
      stage: @stage,
      user: current_user,
      operator_prompt: operator_prompt
    )
    unless result.to_h["subject"].to_s.squish.present? && result.to_h["body"].to_s.squish.present?
      redirect_to comms_command_path(open_email_stage: @stage.id, anchor: "stage-#{@stage.id}"), alert: "Thumper could not build a complete email kit: #{result.to_h['error'].presence || result.to_h['reason'].presence || 'blank draft'}"
      return
    end

    metadata = @stage.metadata.to_h.deep_dup
    history = Array(metadata["email_draft_history"]).last(24)
    history << {
      "id" => SecureRandom.uuid,
      "subject" => result["subject"],
      "body" => result["body"],
      "provider" => result["provider"],
      "model" => result["model"],
      "reason" => result["reason"],
      "operator_prompt" => operator_prompt,
      "user_prompt" => user_prompt,
      "error" => result["error"],
      "user_id" => current_user.id,
      "user_name" => current_user.display_name,
      "created_at" => Time.current.iso8601
    }.compact_blank

    @stage.update!(
      generated_at: Time.current,
      metadata: metadata.merge(
        "comms_command_email_prompt" => user_prompt,
        "comms_command_email_operator_prompt" => operator_prompt,
        "comms_command_email_draft" => result.merge("created_at" => Time.current.iso8601),
        "email_draft_history" => history,
        "composed_email_subject" => result["subject"],
        "composed_email_body" => result["body"],
        "selected_email_id" => nil,
        "comms_command_last_channel" => "email",
        "comms_command_last_status" => "email_drafted",
        "comms_command_last_at" => Time.current.iso8601
      ).compact_blank
    )
    queue_stage_memory!(@stage)

    redirect_to comms_command_path(open_email_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Thumper rebuilt the email for #{stage_company_name(@stage)}."
  rescue StandardError => error
    redirect_to comms_command_path(open_email_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "Thumper could not rebuild the email: #{error.message}"
  end

  def send_email
    to = params[:email_to].to_s.strip.presence || stage_selected_email(@stage)["value"].to_s
    subject = params[:email_subject].to_s.strip.presence || stage_email_subject(@stage)
    body = params[:email_body].to_s.strip.presence || stage_email_body(@stage)
    raise "Build or enter an email subject and body before sending." if subject.blank? || body.blank?

    mail = ThumperMailer.comms_command_email(
      to: to,
      subject: subject,
      body: body,
      stage: @stage,
      sender: current_user
    )
    result = if Postmark::OutboundClient.configured?
      Postmark::OutboundClient.deliver_mail(mail, message_stream: ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound")
    else
      mail.deliver_now
      { "provider" => "action_mailer" }
    end

    append_stage_event!(
      @stage,
      "email_thread",
      event_payload(channel: "email", direction: "outbound", status: "sent", subject: subject, body: body, to: to, provider_result: result)
    )
    queue_stage_memory!(@stage)

    redirect_to comms_command_path(open_email_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Email sent for #{stage_company_name(@stage)}."
  rescue StandardError => error
    append_stage_event!(
      @stage,
      "email_thread",
      event_payload(channel: "email", direction: "outbound", status: "failed", subject: subject, body: body, to: to, error: error.message)
    ) if @stage.present?
    queue_stage_memory!(@stage) if @stage.present?

    redirect_to comms_command_path(open_email_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "Email did not send: #{error.message}"
  end

  def toggle_autopilot
    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    sms_writer_model = comms_sms_writer_model_param(@stage)
    sms_challenger_model = comms_challenger_model_param(@stage)
    ignore_first_stop_for_bot_bridge = ActiveModel::Type::Boolean.new.cast(params[:ignore_first_stop_for_bot_bridge])

    enabled ? start_autopilot_for_stage!(@stage, writer_model: sms_writer_model, challenger_model: sms_challenger_model, ignore_first_stop_for_bot_bridge: ignore_first_stop_for_bot_bridge) : pause_autopilot_for_stage!(@stage, reason: params[:reason], writer_model: sms_writer_model, challenger_model: sms_challenger_model)
    defer_stage_memory!(@stage)

    redirect_to autopilot_redirect_path(@stage), notice: autopilot_notice(enabled, :listening)
  rescue StandardError => error
    redirect_to autopilot_redirect_path(@stage), alert: "Could not update autopilot: #{error.message}"
  end

  def update_sms_writer_model
    sms_writer_model = comms_sms_writer_model_param(@stage)
    sms_challenger_model = comms_challenger_model_param(@stage)
    persist_sms_writer_model!(@stage, writer_model: sms_writer_model, challenger_model: sms_challenger_model, save_user: true)

    if request.xhr?
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "Thumper SMS writer set to #{WizwikiSettings.sms_writer_model_label(sms_writer_model)}."
  rescue StandardError => error
    if request.xhr? && @stage.present?
      Rails.logger.warn("[CommsCommands] SMS writer model save failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      response.status = 422
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to comms_command_path(open_sms_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "Could not update Thumper SMS writer: #{error.message}"
  end

  def update_rag_profile
    profile = Comms::RagProfile.fetch(params[:rag_profile], organization: current_organization)
    previous = Comms::RagProfile.for_stage(@stage)
    if previous.fetch("key") != profile.fetch("key")
      supersede_inflight_sms_draft!(@stage, reason: "rag_profile_changed")
      metadata = @stage.reload.metadata.to_h.deep_dup
      metadata.delete("comms_command_sms_draft_body")
      metadata.delete("comms_command_sms_draft")
      metadata.delete("current_next_text")
      @stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(Comms::RagProfile.metadata_for(profile.fetch("key"), user: current_user, organization: current_organization))
      )
    end

    if request.xhr?
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to comms_command_path(open_sms_stage: @stage.id, anchor: "stage-#{@stage.id}"), notice: "SMS RAG set to #{profile.fetch('label')}."
  rescue StandardError => error
    if request.xhr? && @stage.present?
      Rails.logger.warn("[CommsCommands] RAG profile save failed stage=#{@stage&.id} #{error.class}: #{error.message}")
      response.status = 422
      render_comms_stage_fragment(@stage.reload)
      return
    end

    redirect_to comms_command_path(open_sms_stage: @stage&.id, anchor: "stage-#{@stage&.id}"), alert: "Could not update SMS RAG: #{error.message}"
  end

private

def permitted_batch_template_params
  raw = params.fetch(:batch_templates, {})
  return raw.to_h unless raw.respond_to?(:permit)

  permitted = raw.permit(
    :selected_sms_template_id,
    :selected_email_template_id,
    new: [:type, :title, :subject, :body, :activate]
  ).to_h
  permitted["templates"] = permitted_batch_template_rows(raw[:templates])
  permitted
end

def permitted_batch_template_rows(raw_templates)
  rows_by_type = {}
  return rows_by_type unless raw_templates.respond_to?(:[])

  Comms::BatchTemplates::TYPES.each do |type|
    submitted_rows = raw_templates[type] || raw_templates[type.to_sym]
    next unless submitted_rows.respond_to?(:each)

    rows_by_type[type] = {}
    submitted_rows.each do |template_id, row|
      rows_by_type[type][template_id.to_s] = permitted_batch_template_row(row)
    end
  end
  rows_by_type
end

def permitted_batch_template_row(row)
  if row.respond_to?(:permit)
    row.permit(:id, :title, :subject, :body, :delete).to_h
  else
    row.to_h.slice("id", "title", "subject", "body", "delete")
  end
end

def validate_new_batch_template(raw)
  new_template = raw.to_h
  body = new_template["body"].to_s.strip
  subject = new_template["subject"].to_s.strip
  title = new_template["title"].to_s.strip
  activated = ActiveModel::Type::Boolean.new.cast(new_template["activate"])
  touched = body.present? || subject.present? || title.present? || activated
  return unless touched

  type = Comms::BatchTemplates.normalize_type(new_template["type"]) || "sms"
  return "Add template copy before saving a new #{type.upcase} template." if body.blank?
  "Add an email subject before saving a new EMAIL template." if type == "email" && subject.blank?
end

def warm_thumper_context_cache_later!(surface)
  Autos::ContextCache.warm_later(organization: current_organization, user: current_user, surface: surface) if defined?(Autos::ContextCache)
end

def unsafe_outbound_sms_body?(body)
  text = body.to_s.squish
  return true if text.blank?
  return false if safe_reset_conversation_opener_sms?(text)
  return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.unsafe_outbound?(text)
  return true if text.match?(/\A(?:starter_pack|pro_pack|lawn_signs|eddm|neighborhood_blitz|custom_artwork)\z/i)
  return true if text.match?(/\A[a-z0-9]+(?:_[a-z0-9]+)+\z/i)
  return true if text.match?(%r{https?://(?:shop\.)?wizwikimarketing\.com/products/[^ \t\r\n]*\bdane\b}i)
  return true if defined?(Autos::WorkerQueue) && Autos::WorkerQueue.send(:invalid_comms_sms_answer?, text)

  false
rescue StandardError => error
  Rails.logger.warn("[CommsCommands] outbound SMS safety check failed stage=#{@stage&.id} #{error.class}: #{error.message}")
  true
end

def safe_customer_sms_body(value)
  return if value.blank?
  return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

  value.to_s.strip.presence
end

def sms_delivery_body_for_stage(stage, value)
  @last_sms_delivery_language_event = nil
  body = value.to_s.squish
  return body if body.blank?
  if defined?(Comms::SmsBodySafety)
    body = Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage&.metadata)
  end
  if defined?(Comms::SmsPreSendVerifier)
    verification = Comms::SmsPreSendVerifier.call(stage: stage, body: body, source: "comms_commands_pre_send")
    persist_sms_language_metadata!(stage, verification.to_h["metadata"])
    raise "Thumper pre-send verifier blocked SMS: #{verification.reason}" unless verification.allowed

    body = verification.body.to_s.squish.presence || body
  end
  return body unless defined?(Comms::SmsLanguageSupport)

  result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
  @last_sms_delivery_language_event = result.to_h["event"]
  persist_sms_language_metadata!(stage, result.to_h["metadata"])
  result.to_h["body"].presence || body
end

def sms_delivery_language_event_payload
  @last_sms_delivery_language_event.to_h.compact_blank
end

def persist_sms_language_metadata!(stage, updates)
  return if stage.blank? || updates.to_h.blank?

  metadata = stage.reload.metadata.to_h.deep_dup
  stage.update!(metadata: metadata.merge(updates.to_h).compact_blank)
rescue StandardError => error
  Rails.logger.warn("[CommsCommands] SMS language metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
end

def sms_body_safety_reason(value)
  return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

  "unsafe_sms_body"
end

def persist_sms_writer_model!(stage, writer_model:, challenger_model: nil, save_user: false)
  metadata = stage.metadata.to_h.deep_dup
  normalized_writer = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.sms_writer_model_from_metadata(metadata))
  normalized_challenger = WizwikiSettings.normalize_challenger_model(challenger_model.presence || metadata["sms_challenger_model"].presence || WizwikiSettings.default_challenger_model)
  metadata["sms_writer_model"] = normalized_writer
  metadata["sms_writer_model_label"] = WizwikiSettings.sms_writer_model_label(normalized_writer)
  metadata["sms_writer_model_explicit"] = WizwikiSettings.sms_writer_model_explicit?(normalized_writer)
  metadata["sms_writer_model_saved_at"] = Time.current.iso8601
  metadata["sms_writer_model_saved_by_user_id"] = current_user.id if save_user
  metadata["sms_writer_model_saved_by"] = current_user.display_name if save_user
  metadata["sms_challenger_model"] = normalized_challenger
  metadata["sms_challenger_model_label"] = WizwikiSettings.challenger_model_label(normalized_challenger)
  stage.update!(metadata: metadata)
end

def safe_reset_conversation_opener_sms?(text)
  metadata = @stage&.metadata.to_h
  draft = metadata.to_h["comms_command_sms_draft"].to_h
  draft_body = draft["body"].presence || metadata.to_h["comms_command_sms_draft_body"]
  return false unless draft["draft_source"].to_s == "reset_conversation_opener"
  return false unless normalize_sms_body_for_compare(draft_body) == normalize_sms_body_for_compare(text)
  return false unless text.match?(/\Ahi\b/i)
  return false unless text.match?(/\b(?:i'm|i am)\s+thumper\b/i)
  return false unless text.match?(/\bwizwiki marketing\b/i)
  return false unless text.match?(/\banswer\b.*\bquestions?\b|\bquestions?\b.*\banswer\b/i)
  return false unless text.match?(/\bpostcards?\b/i) && text.match?(/\byard signs?\b/i)

  true
end

def industry_strategy_lens_options
  DealReports::IndustryStrategyPlaybook.options
end

def report_local_model_options
  WizwikiSettings.report_local_model_options
end

def report_embedder_model_options
  WizwikiSettings.report_embedder_model_options
end

def comms_challenger_model_options
  WizwikiSettings.challenger_model_options
end

def comms_sms_writer_model_options
  WizwikiSettings.sms_writer_model_options
end

def comms_rag_profile_options
  Comms::RagProfile.options(organization: current_organization)
end

def stage_rag_profile(stage)
  Comms::RagProfile.for_stage(stage).fetch("key")
end

def comms_batch_template_settings
  @comms_batch_template_settings ||= Comms::BatchTemplates.settings_for(current_organization)
end

def comms_batch_template_token_options
  Comms::BatchTemplates.token_options
end

def comms_batch_template_active(type)
  Comms::BatchTemplates.active_template(comms_batch_template_settings, type)
end

def comms_batch_template_bulk_source
  Comms::BatchTemplates.source_payload(comms_batch_template_settings)
end

def comms_sms_language_settings
  if defined?(Comms::SmsLanguageSupport)
    return Comms::SmsLanguageSupport.settings_for(current_organization)
  end

  { "enabled" => false }
end

def sanitize_sms_language_settings(raw, existing: {})
  raw = if raw.respond_to?(:permit)
    raw.permit(:enabled).to_h
  else
    raw.to_h
  end
  existing = existing.to_h
  {
    "enabled" => raw.key?("enabled") ? ActiveModel::Type::Boolean.new.cast(raw["enabled"]) : ActiveModel::Type::Boolean.new.cast(existing["enabled"]),
    "updated_at" => Time.current.iso8601,
    "updated_by_user_id" => current_user.id,
    "updated_by" => current_user.display_name
  }
end

def comms_run_all_cadence_options
  COMMS_RUN_ALL_CADENCES.map { |value, config| [config[:label], value] }
end

def comms_run_all_cadence_param
  normalize_run_all_cadence(params[:run_all_cadence])
end

def comms_run_all_cadence_label(value)
  COMMS_RUN_ALL_CADENCES.fetch(normalize_run_all_cadence(value))[:label]
end

def comms_run_all_cadence_delay_seconds(value)
  COMMS_RUN_ALL_CADENCES.fetch(normalize_run_all_cadence(value))[:delay_seconds]
end

def normalize_run_all_cadence(value)
  key = COMMS_RUN_ALL_CADENCE_ALIASES.fetch(value.to_s, value.to_s)
  COMMS_RUN_ALL_CADENCES.key?(key) ? key : COMMS_RUN_ALL_DEFAULT_CADENCE
end

def report_challenger_model_options
  WizwikiSettings.challenger_model_options
end

def stage_sms_challenger_model(stage)
  WizwikiSettings.normalize_challenger_model(stage.metadata.to_h["sms_challenger_model"].presence || WizwikiSettings.default_challenger_model)
end

def stage_sms_writer_model(stage)
  WizwikiSettings.sms_writer_model_from_metadata(stage.metadata)
end

def comms_challenger_model_param(stage = nil)
  WizwikiSettings.normalize_challenger_model(
    params[:sms_challenger_model].presence ||
      stage&.metadata.to_h["sms_challenger_model"].presence ||
      WizwikiSettings.default_challenger_model
  )
end

def comms_sms_writer_model_param(stage = nil)
  WizwikiSettings.sms_writer_model_from_request(
    params[:sms_writer_model].presence,
    fallback: (stage.present? ? stage_sms_writer_model(stage) : nil) || WizwikiSettings.default_sms_writer_model
  )
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
  Rails.logger.warn("[CommsCommands] fine training status failed #{error.class}: #{error.message}")
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


  def load_storm_watch_summary
    @weather_scan_status = Weather::ScanStatus.for(current_organization)
    @weather_signal_summary = cached_storm_watch_signal_summary
    @storm_watch_count = storm_watch_count_from_status(@weather_scan_status)
    @storm_watch_staged_count = storm_watch_staged_count
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] Storm Watch summary unavailable: #{error.class}: #{error.message}")
    @weather_scan_status = {
      active: false,
      state_label: "storm watch idle",
      detail_label: "Storm Watch summary is temporarily unavailable.",
      counts_label: nil
    }
    @weather_signal_summary = {}
    @storm_watch_count = 0
    @storm_watch_staged_count = 0
  end

  def load_lightweight_storm_watch_summary
    @weather_scan_status = {
      active: false,
      state_label: "storm watch idle",
      detail_label: "Storm Watch refresh is running in the background.",
      counts_label: nil
    }
    @weather_signal_summary = {}
    @storm_watch_count = Rails.cache.read(["storm_watch_flagged_count", current_organization.id]).to_i
    @storm_watch_staged_count = Rails.cache.read(["storm_watch_staged_comms_count", current_organization.id, current_user.id]).to_i
  end

  def cached_storm_watch_signal_summary
    Rails.cache.fetch(["storm_watch_signal_summary", current_organization.id], expires_in: 60.seconds) do
      Weather::LeadMatcher.signal_summary_for(current_organization)
    end
  end

  def storm_watch_count_from_status(status)
    counts = status.to_h[:last_success_counts].presence || status.to_h["last_success_counts"].presence || {}
    value = counts.to_h["matched_lead_count"].presence || counts.to_h["flagged_lead_count"].presence
    return value.to_i if value.present?

    Rails.cache.fetch(["storm_watch_flagged_count", current_organization.id], expires_in: 60.seconds) do
      Weather::LeadMatcher.flagged_scope_for(current_organization).count
    end
  end

  def storm_watch_staged_count
    Rails.cache.fetch(["storm_watch_staged_comms_count", current_organization.id, current_user.id], expires_in: 30.seconds) do
      staged_scope.where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "storm_watch_comms").count
    end
  end

  def stage_storm_watch_comms!(limit:)
    current_scope = Weather::LeadMatcher.scope_for(current_organization)
    limit = limit.to_i
    stage_scope = current_scope.order(updated_at: :desc)
    stage_scope = stage_scope.limit(limit) if limit.positive?
    import_id = "storm-watch-#{Time.current.to_i}"
    result = {
      matched: 0,
      created: 0,
      updated: 0,
      skipped: 0,
      duplicate_contact: 0,
      missing_contact: 0,
      archived_stale: 0,
      errors: 0
    }
    contact_index = Comms::ContactDeduper.key_index(organization: current_organization)

    stage_scope
      .includes(:crm_record_artifacts)
      .each_with_index do |record, index|
        result[:matched] += 1
        attrs = storm_watch_comms_attrs(record)
        if attrs[:phone].blank? && attrs[:email].blank?
          result[:skipped] += 1
          result[:missing_contact] += 1
          next
        end

        existing_stage = active_comms_stage_for(record, "storm_watch_comms")
        if Comms::ContactDeduper.duplicate_in_index?(
          contact_index,
          phone: attrs[:phone],
          email: attrs[:email],
          except_keys: Comms::ContactDeduper.stage_keys(existing_stage)
        )
          result[:skipped] += 1
          result[:duplicate_contact] += 1
          next
        end

        stage = storm_watch_stage!(
          record: record,
          attrs: attrs,
          import_id: import_id,
          row_number: index + 1
        )
        Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
        stage.respond_to?(:storm_watch_created?) && stage.storm_watch_created? ? result[:created] += 1 : result[:updated] += 1
      rescue StandardError => error
        result[:skipped] += 1
        result[:errors] += 1
        Rails.logger.warn("[CommsCommands] Storm Watch comms block skipped record=#{record&.id} #{error.class}: #{error.message}")
      end

    Rails.cache.delete(["storm_watch_staged_comms_count", current_organization.id, current_user.id])
    result
  end

  def archive_stale_storm_watch_comms!(current_record_ids)
    scope = current_organization.crm_record_artifacts
      .where(artifact_type: "comm_staging")
      .where.not(status: "archived")
      .where("metadata ->> 'stage_type' = ?", "storm_watch_comms")
    scope = if current_record_ids.present?
      scope.where("crm_record_id IS NULL OR crm_record_id NOT IN (?)", current_record_ids)
    else
      scope
    end

    archived = 0
    now = Time.current
    scope.find_each do |stage|
      metadata = stage.metadata.to_h.merge(
        "storm_watch_archived_at" => now.iso8601,
        "storm_watch_archive_reason" => "not present in current Weather.gov CRM match set"
      )
      stage.update!(status: "archived", metadata: metadata)
      archived += 1
    end
    archived
  end

  def storm_watch_stage!(record:, attrs:, import_id:, row_number:)
    metadata = manual_stage_metadata(
      label: attrs[:label],
      phone: attrs[:phone],
      email: attrs[:email],
      contact_name: attrs[:contact_name],
      company_name: attrs[:company_name],
      industry: attrs[:industry],
      zip: attrs[:zip],
      notes: attrs[:notes],
      source: "storm_watch",
      lead_attrs: attrs[:lead_attrs],
      import_id: import_id,
      row_number: row_number,
      raw_row: attrs[:raw_row]
    ).merge(
      "stage_type" => "storm_watch_comms",
      "weather_comms_import" => true,
      "weather_storm_watch" => true,
      "weather_storm_watch_loaded_at" => Time.current.iso8601,
      "weather_source_crm_record_id" => record.id,
      "weather_source_crm_record_type" => record.record_type,
      "weather_source_crm_record_name" => record.name,
      "weather_lead" => record.properties.to_h["weather_lead"],
      "csv_call_import" => false,
      "csv_call_import_source" => nil,
      "recipient_selection_summary" => "Storm Watch matched #{record.name} from active weather signals near known CRM address data.",
      "aircall_status" => "storm_watch",
      "aircall_ready" => false
    ).compact_blank

    stage = record.crm_record_artifacts.where(
      organization: current_organization,
      artifact_type: "comm_staging"
    )
      .where.not(status: "archived")
      .where("metadata ->> 'stage_type' = ?", "storm_watch_comms")
      .order(updated_at: :desc)
      .first
    stage ||= record.crm_record_artifacts.build(
      organization: current_organization,
      user: current_user,
      artifact_type: "comm_staging",
      title: "Storm Watch COMMS: #{attrs[:label]}"
    )
    was_new = stage.new_record?
    stage.update!(
      status: "staged",
      user: current_user,
      generated_at: Time.current,
      content_type: "application/json",
      metadata: was_new ? metadata : stage.metadata.to_h.merge(metadata)
    )
    stage.define_singleton_method(:storm_watch_created?) { was_new }
    stage
  end

  def storm_watch_comms_attrs(record)
    props = record.properties.to_h
    hubspot_props = props.fetch("hubspot", {}).to_h.fetch("properties", {}).to_h
    weather = props.fetch("weather_lead", {}).to_h
    contact_name = storm_contact_name(record, hubspot_props)
    company_name = storm_company_name(record, hubspot_props)
    label = company_name.presence || contact_name.presence || record.name.presence || "Storm Watch COMMS"
    phone = record.phone.presence || first_present_value(hubspot_props, "phone", "mobilephone", "hs_calculated_phone_number", "hs_searchable_calculated_phone_number")
    email = record.email.presence || first_present_value(hubspot_props, "email")
    industry = first_present_value(hubspot_props, "industry", "business_type")
    zip = first_present_value(hubspot_props, "zip", "postal_code", "postalcode")

    {
      label: label,
      phone: phone,
      email: email,
      contact_name: contact_name,
      company_name: company_name,
      industry: industry,
      zip: zip,
      notes: storm_watch_notes(weather),
      lead_attrs: {
        hubspot_lead_id: record.record_type == "deal" ? hubspot_props["hs_object_id"] : nil,
        hubspot_contact_id: record.record_type == "contact" ? hubspot_props["hs_object_id"] : nil,
        hubspot_company_id: record.record_type == "company" ? hubspot_props["hs_object_id"] : nil,
        hubspot_owner_id: hubspot_props["hubspot_owner_id"],
        hubspot_lead_label: "Storm Watch",
        hubspot_lead_stage: record.stage,
        hubspot_lead_quality: record.priority_source,
        weather_source_record_id: record.id,
        weather_source_record_type: record.record_type,
        weather_events: Array(weather["signals"]).first(5).map { |signal| signal.to_h.slice("event", "severity", "urgency", "certainty", "states", "postal_codes", "expires_at") }
      }.compact_blank,
      raw_row: {
        "crm_record_id" => record.id,
        "crm_record_type" => record.record_type,
        "crm_record_name" => record.name,
        "hubspot_object_id" => hubspot_props["hs_object_id"],
        "weather_lead" => weather
      }
    }
  end

  def storm_contact_name(record, hubspot_props)
    if record.record_type == "contact"
      [hubspot_props["firstname"], hubspot_props["lastname"]].compact_blank.join(" ").presence || record.name
    else
      first_present_value(hubspot_props, "contact_name", "firstname")
    end
  end

  def storm_company_name(record, hubspot_props)
    return record.name if record.record_type == "company"

    first_present_value(hubspot_props, "company_name", "company", "associated_company_name") ||
      (record.record_type == "deal" ? first_present_value(hubspot_props, "dealname") : nil)
  end

  def storm_watch_notes(weather)
    signals = Array(weather["signals"]).first(3)
    return "Storm Watch match from current weather signals." if signals.blank?

    signals.map do |signal|
      signal = signal.to_h
      event = signal["event"].presence || "Weather signal"
      severity = [signal["severity"], signal["urgency"], signal["certainty"]].compact_blank.join("/")
      zips = Array(signal["postal_codes"]).first(8).join(", ")
      state = Array(signal["states"]).join(", ")
      [event, severity.presence, state.presence, zips.present? ? "ZIP #{zips}" : nil].compact.join(" // ")
    end.join("\n")
  end

  def first_present_value(hash, *keys)
    keys.each do |key|
      value = hash[key.to_s].to_s.squish.presence
      return value if value.present?
    end
    nil
  end

  def comms_assigned_owner(stage)
    metadata = stage.metadata.to_h
    name = metadata["comms_routed_to_user_name"].to_s.squish.presence
    return if name.blank?

    owner = OpenStruct.new(
      id: metadata["comms_routed_to_user_id"].presence || "manual:#{name.parameterize}",
      display_name: name,
      email_address: metadata["comms_routed_to_user_email"].presence,
      hubspot_owner_id: metadata["comms_routed_to_hubspot_owner_id"].presence,
      source: metadata["contact_owner_source"].presence || "comms_route_metadata"
    )
    return if defined?(Comms::SlackNotifier) && Comms::SlackNotifier.disallowed_owner?(owner)

    owner
  end


  def render_comms_stage_fragment(stage)
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    @twilio_status = Comms::SmsProvider.public_status(user: current_user)
    @postmark_configured = Postmark::OutboundClient.configured?
    @follow_up_settings = comms_follow_up_settings
    @comms_query = params[:q].to_s.squish
    @comms_status_filter = normalize_comms_status_filter(params[:status])
    @comms_status_filter_options = comms_status_filter_options
    @comms_status_counts = {}
    @bulk_autopilot_status = current_organization.settings.to_h.fetch("comms_bulk_autopilot_run", {}).to_h
    @bulk_copilot_status = current_organization.settings.to_h.fetch("comms_bulk_copilot_run", {}).to_h
    @comms_open_sms_stage_id = stage.id.to_s
    @run_all_blocked_by_visible_dnc = false
    @run_all_visible_eligible_count = 0
    @stages = staged_scope.includes(:user, crm_record: [:owner, { deal_media_attachments: :blob }]).where(id: stage.id).limit(1)
    @copilot_visible_eligible_count = @stages.count { |visible_stage| !skip_bulk_copilot_stage?(visible_stage) }
    prepare_comms_report_artifacts!
    render :index, layout: false
  end

  def prepare_comms_report_artifacts!
    record_ids = Array(@stages).map(&:crm_record_id).compact.uniq
    @report_artifacts_by_record_id = Hash.new { |hash, key| hash[key] = [] }
    return if record_ids.blank?

    reports = current_organization.crm_record_artifacts
      .where(crm_record_id: record_ids, artifact_type: "market_report")
      .includes(:user)
      .order(created_at: :desc)
      .to_a
    @report_artifacts_by_record_id = reports.group_by(&:crm_record_id)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] report artifact preload failed: #{error.class}: #{error.message}")
    @report_artifacts_by_record_id = Hash.new { |hash, key| hash[key] = [] }
  end

  def autopilot_redirect_path(stage)
    anchor = stage&.id.present? ? "stage-#{stage.id}" : nil
    options = {}
    options[:open_sms_stage] = stage.id if stage&.id.present? && !ActiveModel::Type::Boolean.new.cast(params[:return_to_board])
    options[:anchor] = anchor if anchor.present?
    comms_command_path(options)
  end

  def copilot_redirect_path(stage)
    anchor = stage&.id.present? ? "stage-#{stage.id}" : nil
    options = {}
    options[:open_sms_stage] = stage.id if stage&.id.present?
    options[:anchor] = anchor if anchor.present?
    comms_command_path(options)
  end

  def comms_follow_up_settings
    defaults = {
      "enabled" => false,
      "frequency_hours" => 24,
      "duration_days" => 14,
      "max_per_day" => 2,
      "quick_nudge_count" => 2,
      "quick_nudge_minutes" => 15,
      "send_window_start" => "09:00",
      "send_window_end" => "17:00",
      "timezone" => "America/Chicago",
      "email" => comms_email_follow_up_defaults
    }
    saved = current_organization.settings.to_h.fetch("comms_follow_up_automation", {}).to_h
    defaults.merge(saved).tap do |settings|
      settings["email"] = comms_email_follow_up_defaults.deep_merge(saved["email"].to_h)
    end
  end

  def sanitize_follow_up_settings(raw, existing: {})
    raw = if raw.respond_to?(:permit)
      raw.permit(
        :enabled,
        :frequency_hours,
        :duration_days,
        :max_per_day,
        :quick_nudge_count,
        :quick_nudge_minutes,
        :send_window_start,
        :send_window_end,
        email: [
          :enabled,
          :preset,
          :cadence,
          :schedule_mode,
          { daily_plan: comms_email_follow_up_day_labels.map(&:first) },
          { selected_weeks: [] }
        ]
      ).to_h
    else
      raw.to_h
    end
    existing = existing.to_h
    sms_keys = %w[enabled frequency_hours duration_days max_per_day quick_nudge_count quick_nudge_minutes send_window_start send_window_end]
    sms_present = sms_keys.any? { |key| raw.key?(key) }
    existing_email = comms_email_follow_up_defaults.deep_merge(existing["email"].to_h)
    email_settings = raw.key?("email") ? sanitize_email_follow_up_settings(raw["email"].to_h, existing: existing_email) : existing_email
    {
      "enabled" => sms_present ? ActiveModel::Type::Boolean.new.cast(raw["enabled"]) : ActiveModel::Type::Boolean.new.cast(existing["enabled"]),
      "frequency_hours" => (sms_present ? raw["frequency_hours"] : existing["frequency_hours"]).to_i.clamp(2, 168),
      "duration_days" => (sms_present ? raw["duration_days"] : existing["duration_days"]).to_i.clamp(1, 90),
      "max_per_day" => (sms_present ? raw["max_per_day"] : existing["max_per_day"]).to_i.clamp(1, 12),
      "quick_nudge_count" => ((sms_present ? raw["quick_nudge_count"] : existing["quick_nudge_count"]).to_s.presence || "2").to_i.clamp(0, 6),
      "quick_nudge_minutes" => ((sms_present ? raw["quick_nudge_minutes"] : existing["quick_nudge_minutes"]).to_s.presence || "15").to_i.clamp(5, 240),
      "send_window_start" => normalize_time_field(sms_present ? raw["send_window_start"] : existing["send_window_start"], "09:00"),
      "send_window_end" => normalize_time_field(sms_present ? raw["send_window_end"] : existing["send_window_end"], "17:00"),
      "timezone" => "America/Chicago",
      "email" => email_settings,
      "updated_at" => Time.current.iso8601,
      "updated_by_user_id" => current_user.id,
      "updated_by" => current_user.display_name
    }
  end

  def comms_email_follow_up_defaults
    {
      "enabled" => false,
      "preset" => "normal",
      "cadence" => "off",
      "schedule_mode" => "preset",
      "business_days" => true,
      "send_window_start" => "09:00",
      "send_window_end" => "17:00",
      "daily_plan" => comms_email_follow_up_day_plan("normal"),
      "selected_weeks" => [],
      "subject_prompt" => "",
      "body_prompt" => ""
    }
  end

  def sanitize_email_follow_up_settings(raw, existing:)
    raw_preset = raw["preset"].to_s
    email_enabled = raw_preset != "off"
    preset = COMMS_EMAIL_FOLLOW_UP_PRESETS.key?(raw_preset) ? raw_preset : "normal"
    schedule_mode = email_enabled && raw["schedule_mode"].to_s == "custom" ? "custom" : "preset"
    selected_weeks = sanitize_email_follow_up_selected_weeks(raw["selected_weeks"], existing: existing["selected_weeks"], preset: preset, enabled: email_enabled)
    daily_plan = if !email_enabled
      comms_email_follow_up_day_plan("off")
    elsif schedule_mode == "custom"
      sanitize_email_follow_up_day_plan(raw["daily_plan"].to_h, fallback: existing["daily_plan"].to_h)
    else
      comms_email_follow_up_day_plan(preset)
    end
    {
      "enabled" => email_enabled,
      "preset" => preset,
      "cadence" => email_enabled ? (preset == "monthly" ? "monthly" : "weekly") : "off",
      "schedule_mode" => schedule_mode,
      "business_days" => true,
      "send_window_start" => existing["send_window_start"].presence || "09:00",
      "send_window_end" => existing["send_window_end"].presence || "17:00",
      "daily_plan" => daily_plan,
      "selected_weeks" => selected_weeks,
      "subject_prompt" => "",
      "body_prompt" => "",
      "updated_at" => Time.current.iso8601,
      "updated_by_user_id" => current_user.id,
      "updated_by" => current_user.display_name
    }
  end

  def sanitize_email_follow_up_day_plan(raw, fallback:)
    allowed = (COMMS_EMAIL_FOLLOW_UP_DAY_ACTIONS.map(&:last) + %w[sms final_both]).uniq
    comms_email_follow_up_day_labels.each_with_object({}) do |(day, _label), plan|
      value = raw[day].to_s.presence || fallback[day].to_s.presence || "none"
      value = allowed.include?(value) ? value : "none"
      plan[day] = weekend_sms_safe_day_action(day, value)
    end
  end

  def weekend_sms_safe_day_action(day, value)
    return value unless %w[6 7].include?(day.to_s)

    case value
    when "sms"
      "none"
    when "both", "final_both"
      "email"
    else
      value
    end
  end

  def sanitize_email_follow_up_selected_weeks(raw, existing:, preset:, enabled:)
    return [] unless enabled && preset.to_s == "monthly"

    available = comms_email_follow_up_monthly_week_options.map { |week| week[:key] }
    selected = Array(raw.presence || existing).map(&:to_s).select { |week| available.include?(week) }.uniq
    selected.presence || comms_email_follow_up_default_selected_weeks
  end

  def comms_email_follow_up_preset_options
    [["Off", "off"]] + COMMS_EMAIL_FOLLOW_UP_PRESETS.map { |value, payload| [payload[:label], value] }
  end

  def comms_email_follow_up_day_action_options
    COMMS_EMAIL_FOLLOW_UP_DAY_ACTIONS
  end

  def comms_email_follow_up_day_labels
    %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].map.with_index(1) do |label, day|
      [day.to_s, label]
    end
  end

  def comms_email_follow_up_day_plan(preset)
    return comms_email_follow_up_empty_day_plan if preset.to_s == "off"

    selected = COMMS_EMAIL_FOLLOW_UP_PRESETS[preset.to_s] || COMMS_EMAIL_FOLLOW_UP_PRESETS["normal"]
    selected[:days].deep_dup
  end

  def comms_email_follow_up_preset_day_plans
    COMMS_EMAIL_FOLLOW_UP_PRESETS.transform_values { |payload| payload[:days] }.merge("off" => comms_email_follow_up_empty_day_plan)
  end

  def comms_email_follow_up_preset_label(value)
    return "Off" if value.to_s == "off"
    return "Custom" if value.to_s == "custom"

    COMMS_EMAIL_FOLLOW_UP_PRESETS.dig(value.to_s, :label).presence || COMMS_EMAIL_FOLLOW_UP_PRESETS.dig("normal", :label)
  end

  def comms_email_follow_up_empty_day_plan
    comms_email_follow_up_day_labels.to_h { |day, _label| [day, "none"] }
  end

  def comms_email_follow_up_monthly_week_options
    zone = ActiveSupport::TimeZone["America/Chicago"] || Time.zone
    today = Time.current.in_time_zone(zone).to_date
    start_date = today.beginning_of_week(:monday)
    (0...8).map do |offset|
      week_start = start_date + offset.weeks
      week_end = week_start + 6.days
      {
        key: week_start.iso8601,
        label: "#{week_start.strftime('%b %-d')} - #{week_end.strftime('%b %-d')}",
        month: week_start.month == week_end.month ? week_start.strftime("%B") : "#{week_start.strftime('%b')} / #{week_end.strftime('%b')}",
        range: "#{week_start.strftime('%a %-m/%-d')} - #{week_end.strftime('%a %-m/%-d')}",
        offset: offset + 1
      }
    end
  end

  def comms_email_follow_up_default_selected_weeks
    comms_email_follow_up_monthly_week_options.map { |week| week[:key] }
  end

  def normalize_time_field(value, fallback)
    text = value.to_s.squish
    return text if text.match?(/\A(?:[01]?\d|2[0-3]):[0-5]\d\z/)

    fallback
  end

  def manual_sms_draft_wait_seconds
    ENV.fetch("WIZWIKI_COMMS_MANUAL_DRAFT_WAIT_SECONDS", "60").to_i.clamp(2, 120)
  end

  def sms_draft_operator_prompt(stage, user_prompt)
    base_prompt = user_prompt.presence || manual_sms_draft_operator_prompt(stage)
    metadata = stage.metadata.to_h
    previous_drafts = recent_unsent_sms_drafts(metadata)
    guard = [
      "Manual rewrite id: #{SecureRandom.hex(4)}.",
      "This click must produce a materially different next SMS than the current draft.",
      "Do not return the current draft or any recent unsent draft verbatim or with only minor word swaps."
    ]
    if previous_drafts.present?
      guard << "Recent unsent drafts to avoid: #{previous_drafts.map.with_index(1) { |body, index| "#{index}) #{body}" }.join(" | ")}"
    end

    [base_prompt, guard.join(" ")].compact_blank.join(" ")
  end

  def copilot_sms_operator_prompt(stage, user_prompt)
    base_prompt = sms_draft_operator_prompt(stage, user_prompt)
    [
      "COPILOT MODE: create the next SMS draft only for human approval. Do not send automatically.",
      "The draft will appear in the NEXT TEXT box where a human can edit and approve it.",
      "Answer the latest customer message first, keep it short, and ask at most one useful next question.",
      base_prompt
    ].join(" ")
  end

  def copilot_notice(stage, result)
    name = stage_company_name(stage)
    return "COPILOT is drafting the next text for #{name}. No SMS will send until a human approves it." if result.queued
    return "COPILOT saved a NEXT TEXT draft for #{name}. Review it before sending." if result.drafted

    "COPILOT queued for #{name}, but no draft body is ready yet."
  end

  def reset_sms_conversation_notice(stage, result)
    name = stage_company_name(stage)
    return "Conversation reset for #{name}. COPILOT is drafting a fresh NEXT TEXT for manual approval; no SMS was sent." if result.queued
    return "Conversation reset for #{name}. A fresh NEXT TEXT is ready for manual approval; no SMS was sent." if result.drafted

    "Conversation reset for #{name}. No SMS was sent, but Thumper did not return a draft yet."
  end

  def reset_sms_conversation_operator_prompt(stage)
    [
      "CONVERSATION RESET MODE: the operator clicked reset to clear stale discovery and start this SMS call anew.",
      "Draft only for human approval in the NEXT TEXT box. Do not send automatically.",
      "Treat messages before sms_conversation_reset_at as historical notes only. Do not use pre-reset product route, budget, size, artwork, industry, business type, link-sent, completion, proof, contact preference, or AM-support state as current discovery.",
      "If no post-reset customer reply exists, the NEXT TEXT must be a simple reset opener: say Hi plus the customer's first name when available, introduce yourself as Thumper from WIZWIKI Marketing, say you are here to answer as many questions as you can and support them in becoming a WIZWIKI client, then ask one simple product-direction question: postcards, yard signs, or both.",
      "Keep reset openers short, warm, and focused. Vary the exact wording slightly, but do not skip the greeting, Thumper/WIZWIKI intro, support/questions line, or the one product-direction question.",
      "You may use the CRM first name naturally in the greeting, but do not treat CRM company, industry, product route, quantity, artwork, proof, or contact preference as discovered reset-state facts.",
      manual_sms_draft_operator_prompt(stage)
    ].join(" ")
  end

  def reset_sms_conversation_state!(stage)
    now = Time.current
    metadata = stage.metadata.to_h.deep_dup
    reset_count = metadata["sms_conversation_reset_count"].to_i + 1
    reset_metadata = sms_conversation_reset_preserved_metadata(metadata)
    reset_identity = sms_conversation_reset_identity(metadata, reset_metadata)
    previous_thread = Array(metadata["sms_thread"]).map(&:to_h)
    canceled_question_ids = cancel_inflight_sms_draft_questions!(stage, reason: "conversation_reset", at: now)
    Comms::ConversationMemoryReset.clear_record!(stage.crm_record)

    stage.update!(
      generated_at: now,
      metadata: reset_metadata.merge(
        "comms_bot_state" => reset_identity,
        "sms_thread" => [],
        "sms_draft_history" => [],
        "sms_autopilot_enabled" => false,
        "sms_autopilot_disabled_reason" => "conversation_reset",
        "sms_discovery_reset" => true,
        "sms_conversation_reset_at" => now.iso8601,
        "sms_conversation_reset_count" => reset_count,
        "sms_conversation_reset_by_user_id" => current_user.id,
        "sms_conversation_reset_by" => current_user.display_name,
        "sms_conversation_reset_previous_thread_count" => previous_thread.length,
        "sms_conversation_reset_previous_thread_digest" => Digest::SHA1.hexdigest(previous_thread.map { |event| event.slice("direction", "status", "provider_message_id", "created_at") }.to_json),
        "sms_reply_generation" => SecureRandom.uuid,
        "sms_reply_generation_at" => now.iso8601,
        "sms_reply_generation_superseded_at" => now.iso8601,
        "sms_reply_generation_superseded_reason" => "conversation_reset",
        "sms_reply_generation_superseded_by_user_id" => current_user.id,
        "sms_reply_generation_superseded_by" => current_user.display_name,
        "sms_reply_generation_superseded_question_ids" => canceled_question_ids.presence,
        "sms_listener_last_inbound_at" => nil,
        "sms_listener_last_inbound_sid" => nil,
        "sms_listener_last_outbound_at" => nil,
        "sms_listener_last_outbound_sid" => nil,
        "sms_follow_up_sent_count" => 0,
        "sms_follow_up_last_sent_at" => nil,
        "sms_follow_up_last_status" => nil,
        "sms_follow_up_last_reason" => nil,
        "sms_follow_up_last_error" => nil,
        "sms_follow_up_last_error_at" => nil,
        "sms_follow_up_daily_counts" => {},
        "comms_command_last_channel" => "sms",
        "comms_command_last_status" => "conversation_reset",
        "comms_command_last_at" => now.iso8601
      ).compact
    )
    stage.reload
  end

  def sms_conversation_reset_preserved_metadata(metadata)
    metadata = metadata.to_h.deep_dup
    preserved = metadata.slice(*sms_conversation_reset_preserved_metadata_keys)

    sms_conversation_reset_preserved_metadata_prefixes.each do |prefix|
      metadata.each do |key, value|
        preserved[key] = value if key.to_s.start_with?(prefix)
      end
    end

    preserved.except(*SMS_CONVERSATION_RESET_DISCOVERY_METADATA_KEYS).compact
  end

  def sms_conversation_reset_preserved_metadata_keys
    %w[
      stage_type
      company_name
      deal_name
      comm_kit_direction
      comm_kit_direction_label
      contact_options
      phone_options
      email_options
      selected_contact_id
      selected_phone_id
      selected_email_id
      manual_comms_company_name
      sender_name
      sender_phone
      sender_profile
      staged_at
      staged_by_user_id
      staged_by
      aircall_status
      aircall_ready
      comms_board_state
      sms_listener_active
      sms_listener_from
      sms_listener_to
      sms_listener_started_at
      sms_listener_until
      sms_writer_model
      sms_writer_model_label
      sms_writer_model_explicit
      sms_writer_model_saved_at
      sms_writer_model_saved_by_user_id
      sms_writer_model_saved_by
      sms_challenger_model
      sms_challenger_model_label
      sms_sending_disabled
      sms_do_not_contact
      sms_do_not_contact_at
      sms_do_not_contact_reason
      sms_do_not_contact_by_user_id
      sms_do_not_contact_by
      do_not_contact
      do_not_contact_at
      do_not_contact_reason
      ask_autopilot_test
      comms_simulation_mode
    ]
  end

  def sms_conversation_reset_preserved_metadata_prefixes
    %w[
      manual_comms_contact_
      csv_call_
      hubspot_
      claimed_
    ]
  end

  def sms_conversation_reset_identity(metadata, preserved_metadata)
    metadata = metadata.to_h
    preserved_metadata = preserved_metadata.to_h
    selected_contact = Array(preserved_metadata["contact_options"]).find do |option|
      option.to_h["id"].to_s == preserved_metadata["selected_contact_id"].to_s
    end.to_h
    selected_contact = Array(preserved_metadata["contact_options"]).first.to_h if selected_contact.blank?

    contact_name = selected_contact["name"].presence
    company_name = selected_contact["company"].presence ||
      preserved_metadata["company_name"].presence
    company_name = distinct_comms_company_name(contact_name, company_name)

    {
      "contact_name" => contact_name,
      "company_name" => company_name
    }.compact_blank
  end

  def manual_sms_draft_operator_prompt(stage)
    metadata = stage.metadata.to_h
    objective = metadata["sms_autopilot_objective"].presence || default_autopilot_objective
    contact_first_name = comms_first_name(
      metadata["captured_contact_name"].presence ||
        metadata.dig("comms_bot_state", "contact_name").presence ||
        stage_selected_contact(stage).to_h["name"].presence
    )
    empty_thread_first_name_rule = if stage_sms_thread(stage).blank? && contact_first_name.present?
      "The SMS thread is empty; open naturally with #{contact_first_name}'s first name in the first outbound text."
    end
    Comms::SmsOperatorPrompt.manual_next_text(
      objective: objective,
      empty_thread_first_name_rule: empty_thread_first_name_rule
    )
  end

  def recent_unsent_sms_drafts(metadata)
    history = Array(metadata["sms_draft_history"]).filter_map { |entry| entry.to_h["body"].to_s.squish.presence }
    current = metadata["comms_command_sms_draft_body"].to_s.squish.presence
    ([current] + history).compact_blank.reverse.uniq.first(5).reverse
  end

  def staged_scope
    manual_comms_stage_scope
      .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
  end

  def scoped_staged_index_scope(scope, status_filter)
    return comms_csv_import_status_scope(scope, status_filter) if csv_import_status_key_format?(status_filter)

    case status_filter
    when "all"
      scope
    when "claimed_by_me"
      comms_claimed_by_me_scope(scope)
    when "owner_queue"
      comms_owner_queue_scope(scope)
    when "storm_watch"
      storm_watch_comms_scope(scope)
    when "active"
      comms_active_scope(scope)
    when "new"
      comms_new_scope(scope)
    when "hold"
      scope.where("crm_record_artifacts.metadata ->> 'comms_board_state' = ?", "hold")
    when "hidden"
      scope.where("crm_record_artifacts.metadata ->> 'comms_board_state' = ?", "hidden")
    when "opt_out"
      comms_opt_out_scope(scope)
    when "link_sent"
      comms_link_sent_scope(scope)
    when "am_support"
      comms_am_support_scope(scope)
    when "autopilot"
      comms_autopilot_scope(scope)
    when "complete"
      comms_complete_scope(scope)
    when "needs_reply"
      comms_needs_reply_scope(scope)
    when "waiting"
      comms_waiting_scope(scope)
    when "stale_due"
      comms_active_scope(scope)
    else
      scope
    end
  end

  def comms_index_candidate_limit(status_filter)
    default = status_filter == "active" ? COMMS_INDEX_DEFAULT_CANDIDATE_LIMIT : COMMS_INDEX_WIDE_CANDIDATE_LIMIT
    ENV.fetch("WIZWIKI_COMMS_INDEX_CANDIDATE_LIMIT", default).to_i.clamp(40, 100)
  end

  def comms_index_display_limit
    ENV.fetch("WIZWIKI_COMMS_INDEX_DISPLAY_LIMIT", COMMS_INDEX_DEFAULT_DISPLAY_LIMIT).to_i.clamp(24, 100)
  end

  def comms_console_state
    current_organization.settings.to_h
      .fetch("comms_console_state_by_user", {})
      .to_h
      .fetch(current_user.id.to_s, {})
      .to_h
  end

  def comms_reset_console_state?
    ActiveModel::Type::Boolean.new.cast(params[:reset])
  end

  def comms_default_landing_request?
    request.get? && request.query_parameters.except("reset").blank?
  end

  def comms_requested_query(console_state)
    return "" if comms_default_landing_request?
    return "" if comms_reset_console_state?
    return params[:q].to_s.squish if params.key?(:q)

    console_state.to_h["q"].to_s.squish
  end

  def comms_requested_status(console_state)
    return COMMS_DEFAULT_STATUS_FILTER if comms_default_landing_request?
    return COMMS_DEFAULT_STATUS_FILTER if comms_reset_console_state?

    raw_status = if params.key?(:status)
      params[:status]
    else
      console_state.to_h["status"]
    end
    normalize_comms_status_filter(raw_status.presence || COMMS_DEFAULT_STATUS_FILTER)
  end

  def comms_page(console_state = nil)
    raw_page = if comms_reset_console_state?
      1
    elsif comms_default_landing_request?
      1
    elsif params.key?(:page)
      params[:page]
    elsif params.key?(:status) || params.key?(:q)
      1
    else
      console_state.to_h["page"].presence || 1
    end
    raw_page.to_i.clamp(1, 10_000)
  end

  def persist_comms_console_state!
    return if request.xhr?

    settings = current_organization.settings.to_h.deep_dup
    user_key = current_user.id.to_s
    states = settings.fetch("comms_console_state_by_user", {}).to_h
    previous = states[user_key].to_h.slice("q", "status", "page", "updated_at").compact_blank
    history = ([previous] + Array(states[user_key].to_h["history"]).map(&:to_h))
      .select { |entry| entry["updated_at"].present? }
      .uniq
      .first(8)
    states[user_key] = {
      "q" => @comms_query.to_s,
      "status" => @comms_status_filter.to_s,
      "page" => @comms_page.to_i,
      "updated_at" => Time.current.iso8601,
      "history" => history
    }.compact_blank
    settings["comms_console_state_by_user"] = states
    current_organization.update_column(:settings, settings)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] console state save failed user=#{current_user&.id}: #{error.class}: #{error.message}")
  end

  def comms_manual_return_path(stage, status:, page:, query:)
    comms_command_path(
      {
        q: query.presence,
        status: normalize_comms_status_filter(status),
        page: page.to_i.clamp(1, 10_000),
        open_stage: stage.id,
        anchor: "stage-#{stage.id}"
      }.compact
    )
  end

  def visible_comms_stages_for_action(query:, status_filter:, page:)
    page_size = comms_index_display_limit
    offset = ([page.to_i, 1].max - 1) * page_size
    candidates = search_staged_scope(staged_scope, query.to_s.squish)
      .then { |relation| scoped_staged_index_scope(relation, status_filter) }
      .includes(:user, crm_record: [:owner, { deal_media_attachments: :blob }])
      .order(updated_at: :desc)
      .offset(offset)
      .limit(page_size + 1)
      .to_a
    sort_comms_stages(filter_comms_stages(candidates, status_filter)).first(page_size)
  end

  def claim_visible_comms_stages!(stages)
    now = Time.current
    claimed_stage_ids = []
    stamp_stage_ids = []
    already_mine = 0
    skipped = 0
    candidate_stages_by_record_id = Hash.new { |hash, key| hash[key] = [] }

    Array(stages).each do |stage|
      unless comms_stage_active_visible?(stage) && stage.crm_record_id.present?
        skipped += 1
        next
      end

      record_owner_id = stage.crm_record&.owner_id
      metadata_owner_id = stage.metadata.to_h["claimed_by_user_id"].presence

      if record_owner_id.to_s == current_user.id.to_s
        already_mine += 1
        stamp_stage_ids << stage.id
      elsif record_owner_id.present? || (metadata_owner_id.present? && metadata_owner_id.to_s != current_user.id.to_s)
        skipped += 1
      else
        candidate_stages_by_record_id[stage.crm_record_id] << stage
      end
    end

    CrmRecord.transaction do
      records = current_organization.crm_records
        .where(id: candidate_stages_by_record_id.keys)
        .lock
        .index_by(&:id)

      candidate_stages_by_record_id.each do |record_id, record_stages|
        record = records[record_id]
        if record.blank?
          skipped += record_stages.size
        elsif record.owner_id.blank?
          record.update!(owner: current_user)
          claimed_stage_ids.concat(record_stages.map(&:id))
        elsif record.owner_id == current_user.id
          already_mine += record_stages.size
          stamp_stage_ids.concat(record_stages.map(&:id))
        else
          skipped += record_stages.size
        end
      end

      stamp_claimed_comms_stages!((claimed_stage_ids + stamp_stage_ids).uniq, now: now)
    end

    {
      claimed: claimed_stage_ids.size,
      already_mine: already_mine,
      skipped: skipped,
      visible: Array(stages).size
    }
  end

  def stamp_claimed_comms_stages!(stage_ids, now:)
    return if stage_ids.blank?

    current_organization.crm_record_artifacts.where(id: stage_ids).find_each do |stage|
      metadata = stage.metadata.to_h
      stage.update!(
        generated_at: now,
        metadata: metadata.merge(
          "claimed_by_user_id" => current_user.id.to_s,
          "claimed_by_user_name" => current_user.display_name,
          "claimed_at" => metadata["claimed_at"].presence || now.iso8601,
          "claimed_last_confirmed_at" => now.iso8601,
          "claimed_source" => "comms_claim_visible_page"
        )
      )
    end
  end

  def manual_comms_stage_scope
    current_organization.crm_record_artifacts
      .joins(:crm_record)
      .where(artifact_type: "comm_staging")
      .where("crm_record_artifacts.metadata ->> 'stage_type' IN (?)", COMMS_STAGE_TYPES)
  end

  def comms_board_change_token
    latest_at, row_count, latest_id = current_organization.crm_record_artifacts
      .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
      .where("crm_record_artifacts.metadata ->> 'stage_type' IN (?)", COMMS_STAGE_TYPES)
      .reorder(nil)
      .pick(
        Arel.sql("MAX(crm_record_artifacts.updated_at)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("MAX(crm_record_artifacts.id)")
      )

    Digest::SHA1.hexdigest([latest_at&.to_f, row_count.to_i, latest_id.to_i].join(":"))
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] board change token unavailable: #{error.class}: #{error.message}")
    "unavailable"
  end

  def search_staged_scope(scope, query)
    return scope if query.blank?

    exact = query.to_s.squish
    if exact.match?(/\Amanual-comms-[a-f0-9]{16,}\z/i)
      return scope.where("crm_records.source_uid = ?", exact)
    end

    query.split(/\s+/).first(8).reduce(scope) do |relation, term|
      like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      relation.where(
        <<~SQL.squish,
          crm_record_artifacts.title ILIKE :q
          OR crm_record_artifacts.status ILIKE :q
          OR crm_record_artifacts.metadata ->> 'company_name' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'deal_name' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'captured_contact_name' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'captured_company_name' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'captured_email' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'hubspot_lead_id' ILIKE :q
          OR crm_record_artifacts.metadata ->> 'hubspot_contact_id' ILIKE :q
          OR crm_records.name ILIKE :q
          OR crm_records.email ILIKE :q
          OR crm_records.phone ILIKE :q
          OR crm_records.domain ILIKE :q
          OR crm_records.source_uid ILIKE :q
          OR crm_records.stage ILIKE :q
        SQL
        q: like
      )
    end
  end

  def comms_board_state_options
    COMMS_BOARD_STATE_OPTIONS
  end

  def comms_status_filter_options
    options = COMMS_STATUS_FILTER_OPTIONS + comms_csv_import_status_options
    if csv_import_status_key_format?(@comms_status_filter) && options.none? { |value, _label| value == @comms_status_filter }
      options << [@comms_status_filter, "CSV import"]
    end
    options
  end

  def comms_csv_import_status_options
    comms_csv_import_lanes.map { |lane| [lane[:key], lane[:label]] }
  end

  def normalize_comms_status_filter(value)
    key = value.to_s.presence || COMMS_DEFAULT_STATUS_FILTER
    return key if COMMS_STATUS_FILTER_OPTIONS.any? { |candidate, _label| candidate == key }
    return key if csv_import_status_key_format?(key)

    COMMS_DEFAULT_STATUS_FILTER
  end

  def normalize_comms_board_state(value)
    key = value.to_s.presence || "active"
    COMMS_BOARD_STATE_OPTIONS.any? { |candidate, _label| candidate == key } ? key : "active"
  end

  def enqueue_slack_handoff!(stage, reason:)
    if defined?(Comms::SlackHandoffJob)
      Comms::SlackHandoffJob.perform_later(stage_id: stage.id, reason: reason)
    elsif defined?(Comms::SlackNotifier)
      owner = Comms::SlackNotifier.safe_owner(comms_assigned_owner(stage)) || Comms::SlackNotifier.safe_owner(stage.user)
      Comms::SlackNotifier.post_handoff!(stage: stage, owner: owner, reason: "Manual AM help requested from WIZWIKI COMMS.")
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] Slack handoff enqueue failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def comms_board_refresh_request?
    request.xhr? &&
      params[:open_sms_stage].blank? &&
      (ActiveModel::Type::Boolean.new.cast(params[:board_refresh]) || params[:open_email_stage].blank?)
  end

  def comms_status_counts(source)
    return comms_status_counts_from_stages(source) if source.is_a?(Array)

    comms_sql_status_counts(source)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] status counts fell back to visible sample: #{error.class}: #{error.message}")
    comms_status_counts_from_stages(source.limit(COMMS_INDEX_WIDE_CANDIDATE_LIMIT).to_a)
  end

  def comms_status_counts_for_scope(scope)
    query_key = Digest::SHA1.hexdigest(@comms_query.to_s)
    Rails.cache.fetch(["comms_status_counts_v3", current_organization.id, query_key], expires_in: 30.seconds) do
      comms_status_counts(scope)
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] status counts unavailable: #{error.class}: #{error.message}")
    {}
  end

  def comms_status_counts_with_global_lanes(counts)
    totals = counts.to_h.with_indifferent_access
    comms_csv_import_lanes.each { |lane| totals[lane[:key]] = lane[:count].to_i }
    totals
  end

  def comms_csv_import_lanes
    @comms_csv_import_lanes ||= begin
      Rails.cache.fetch(["comms_csv_import_lanes_v4", current_organization.id], expires_in: 5.minutes, race_condition_ttl: 30.seconds) do
        lane_counts = Hash.new(0)
        lane_titles = {}

        current_organization.crm_record_artifacts
          .where(artifact_type: "comm_staging", status: %w[staged aircall_ready aircall_sent aircall_failed])
          .where("crm_record_artifacts.metadata ->> 'stage_type' IN (?)", COMMS_STAGE_TYPES)
          .order(updated_at: :desc)
          .limit(250)
          .pluck(
            Arel.sql("crm_record_artifacts.metadata ->> 'csv_call_import_status_key'"),
            Arel.sql("crm_record_artifacts.metadata ->> 'csv_call_import_title'"),
            Arel.sql("crm_record_artifacts.metadata ->> 'claimed_by_user_id'"),
            Arel.sql("COALESCE(crm_record_artifacts.metadata ->> 'comms_board_state', 'active')")
          )
          .each do |key, title, claimed_by_user_id, board_state|
            key = key.to_s.presence
            title = title.to_s.squish.presence
            next if key.blank? || title.blank?
            next if claimed_by_user_id.present?
            next if %w[hidden hold done opt_out].include?(board_state.to_s)

            lane_counts[key] += 1
            lane_titles[key] ||= title
          end

        lane_counts.map do |key, count|
          title = lane_titles[key].to_s
          {
            key: key,
            title: title,
            label: "CSV: #{title.truncate(42)}",
            count: count.to_i
          }
        end.sort_by { |lane| lane[:title].downcase }
      end
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] CSV import lanes unavailable: #{error.class}: #{error.message}")
    []
  end

  def comms_board_status_counts
    snapshot = comms_board_status_counts_snapshot
    refresh_comms_board_counts_later! if comms_board_status_counts_stale?(snapshot)

    counts = snapshot.fetch("counts", {}).to_h
    counts["claimed_by_me"] = comms_claimed_by_me_count
    COMMS_STATUS_FILTER_OPTIONS.each { |key, _label| counts[key] ||= 0 }
    counts
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] board status counts unavailable: #{error.class}: #{error.message}")
    comms_status_counts_from_stages(@stages.to_a)
  end

  def comms_board_status_counts_snapshot
    Rails.cache.fetch(["comms_board_status_counts_snapshot", current_organization.id], expires_in: 10.seconds) do
      current_organization.reload.settings.to_h.fetch("comms_board_status_counts", {}).to_h
    end
  end

  def comms_board_status_counts_stale?(snapshot)
    updated_at = Time.zone.parse(snapshot.to_h["updated_at"].to_s)
    updated_at.blank? || updated_at < 30.minutes.ago
  rescue ArgumentError, TypeError
    true
  end

  def refresh_comms_board_counts_later!(force: false)
    return unless defined?(Comms::BoardStatusCountsRefreshJob)

    invalidate_comms_claimed_count_cache!
    job_class = Comms::BoardStatusCountsRefreshJob
    lock_key = job_class.lock_key(current_organization.id)
    dirty_key = job_class.dirty_key(current_organization.id)
    acquired = Rails.cache.write(lock_key, true, expires_in: 15.minutes, unless_exist: true)
    unless acquired
      Rails.cache.write(dirty_key, true, expires_in: 30.minutes)
      return
    end

    enqueue = force ? job_class : job_class.set(wait: 15.seconds)
    enqueue.perform_later(organization_id: current_organization.id)
  rescue StandardError
    Rails.cache.delete(lock_key) if defined?(lock_key) && lock_key.present?
    raise
  end

  def comms_claimed_by_me_count
    Rails.cache.fetch(
      ["comms_claimed_by_me_count_v1", current_organization.id, current_user.id],
      expires_in: 30.seconds,
      race_condition_ttl: 5.seconds
    ) do
      comms_claimed_by_me_scope(staged_scope).count
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] claimed-by-me count unavailable user=#{current_user&.id}: #{error.class}: #{error.message}")
    0
  end

  def invalidate_comms_claimed_count_cache!
    Rails.cache.delete(["comms_claimed_by_me_count_v1", current_organization.id, current_user.id])
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] claimed-by-me cache invalidation failed user=#{current_user&.id}: #{error.class}: #{error.message}")
  end

  def snapshot_bulk_run_stages!(stages, run_id:, mode:, status_filter:, page:, visible_count:, eligible_count:, launch_cadence:, launch_cadence_label:, launch_cadence_delay_seconds:)
    now = Time.current.iso8601
    Array(stages).each_with_index.map do |stage, index|
      metadata = stage.metadata.to_h.deep_dup
      metadata["comms_bulk_run"] = {
        "run_id" => run_id,
        "mode" => mode,
        "status" => "queued",
        "position" => index + 1,
        "stage_count" => stages.length,
        "visible_count" => visible_count,
        "eligible_count" => eligible_count,
        "stage_id" => stage.id,
        "page" => page,
        "status_filter" => status_filter,
        "launch_cadence" => launch_cadence,
        "launch_cadence_label" => launch_cadence_label,
        "launch_cadence_delay_seconds" => launch_cadence_delay_seconds,
        "requested_by_user_id" => current_user.id,
        "requested_by" => current_user.display_name,
        "queued_at" => now,
        "updated_at" => now
      }.compact_blank
      metadata["comms_bulk_run_id"] = run_id
      metadata["comms_bulk_run_mode"] = mode
      metadata["comms_bulk_run_position"] = index + 1
      metadata["comms_bulk_run_stage_count"] = stages.length
      metadata["comms_bulk_run_status"] = "queued"
      metadata["comms_bulk_run_updated_at"] = now
      stage.update_columns(metadata: metadata, updated_at: Time.current)
      stage.id
    rescue StandardError => error
      Rails.logger.warn("[CommsCommands] bulk snapshot failed stage=#{stage&.id} run=#{run_id}: #{error.class}: #{error.message}")
      stage.id
    end
  end

  def mark_bulk_autopilot_queued!(run_id:, job_id:, stage_ids:, visible_count:, eligible_count:, status_filter:, page:, sms_writer_model:, sms_writer_model_label:, sms_challenger_model:, sms_challenger_model_label:, launch_cadence:, launch_cadence_label:, launch_cadence_delay_seconds:, batch_template_source: {})
    settings = current_organization.settings.to_h.deep_dup
    settings["comms_bulk_autopilot_run"] = {
      "run_id" => run_id,
      "job_id" => job_id,
      "state" => "queued",
      "stage_count" => eligible_count,
      "visible_count" => visible_count,
      "started" => 0,
      "skipped" => 0,
      "failed" => 0,
      "current_index" => 0,
      "source" => {
        "q" => params[:q].to_s.squish,
        "status" => status_filter,
        "page" => page,
        "stage_ids" => Array(stage_ids).map(&:to_i),
        "sms_writer_model" => sms_writer_model,
        "sms_writer_model_label" => sms_writer_model_label,
        "sms_challenger_model" => sms_challenger_model,
        "sms_challenger_model_label" => sms_challenger_model_label,
        "launch_cadence" => launch_cadence,
        "launch_cadence_label" => launch_cadence_label,
        "launch_cadence_delay_seconds" => launch_cadence_delay_seconds
      }.merge(batch_template_source.to_h),
      "requested_by_user_id" => current_user.id,
      "requested_by" => current_user.display_name,
      "queued_at" => Time.current.iso8601,
      "updated_at" => Time.current.iso8601
    }
    current_organization.update_column(:settings, settings)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] bulk autopilot queue status failed user=#{current_user&.id}: #{error.class}: #{error.message}")
  end

  def mark_bulk_copilot_queued!(run_id:, job_id:, stage_ids:, visible_count:, eligible_count:, status_filter:, page:, sms_writer_model:, sms_writer_model_label:, sms_challenger_model:, sms_challenger_model_label:, launch_cadence:, launch_cadence_label:, launch_cadence_delay_seconds:, batch_template_source: {})
    settings = current_organization.settings.to_h.deep_dup
    settings["comms_bulk_copilot_run"] = {
      "run_id" => run_id,
      "job_id" => job_id,
      "state" => "queued",
      "stage_count" => eligible_count,
      "visible_count" => visible_count,
      "queued" => 0,
      "drafted" => 0,
      "skipped" => 0,
      "failed" => 0,
      "current_index" => 0,
      "source" => {
        "q" => params[:q].to_s.squish,
        "status" => status_filter,
        "page" => page,
        "stage_ids" => Array(stage_ids).map(&:to_i),
        "sms_writer_model" => sms_writer_model,
        "sms_writer_model_label" => sms_writer_model_label,
        "sms_challenger_model" => sms_challenger_model,
        "sms_challenger_model_label" => sms_challenger_model_label,
        "launch_cadence" => launch_cadence,
        "launch_cadence_label" => launch_cadence_label,
        "launch_cadence_delay_seconds" => launch_cadence_delay_seconds
      }.merge(batch_template_source.to_h),
      "requested_by_user_id" => current_user.id,
      "requested_by" => current_user.display_name,
      "queued_at" => Time.current.iso8601,
      "updated_at" => Time.current.iso8601
    }
    current_organization.update_column(:settings, settings)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] bulk copilot queue status failed user=#{current_user&.id}: #{error.class}: #{error.message}")
  end

  def bulk_autopilot_active?
    status = current_organization.settings.to_h.fetch("comms_bulk_autopilot_run", {}).to_h
    return false unless status["state"].to_s.in?(%w[queued running])

    updated_at = Time.zone.parse(status["updated_at"].to_s)
    updated_at.present? && updated_at > 2.hours.ago
  rescue ArgumentError, TypeError
    false
  end

  def bulk_copilot_active?
    status = current_organization.settings.to_h.fetch("comms_bulk_copilot_run", {}).to_h
    return false unless status["state"].to_s.in?(%w[queued running])

    updated_at = Time.zone.parse(status["updated_at"].to_s)
    updated_at.present? && updated_at > 2.hours.ago
  rescue ArgumentError, TypeError
    false
  end

  def comms_status_counts_from_stages(stages)
    counts = Hash.new(0)
    stages.each do |stage|
      comms_increment_status_counts!(counts, stage)
    end
    COMMS_STATUS_FILTER_OPTIONS.each { |key, _label| counts[key] ||= 0 }
    counts
  end

  def comms_sql_status_counts(source)
    counts = Hash.new(0)
    base_sql = source
      .reselect(
        "crm_record_artifacts.id AS artifact_id",
        "crm_record_artifacts.metadata AS metadata",
        "crm_records.owner_id AS record_owner_id",
        "crm_records.properties AS record_properties"
      )
      .reorder(nil)
      .to_sql

    rows = ActiveRecord::Base.connection.select_rows(<<~SQL.squish)
      WITH comms AS (#{base_sql}),
      flags AS (
        SELECT
          metadata,
          record_owner_id,
          record_properties,
          COALESCE(metadata ->> 'comms_board_state', 'active') AS board_state,
          (
            record_owner_id = #{current_user.id.to_i}
            OR metadata ->> 'claimed_by_user_id' = '#{current_user.id}'
          ) AS claimed_by_me,
          (
            record_owner_id IS NOT NULL
            OR NULLIF(metadata ->> 'claimed_by_user_id', '') IS NOT NULL
          ) AS claimed_any,
          (
            COALESCE(metadata ->> 'comms_board_state', 'active') = 'opt_out'
            OR
            COALESCE(metadata ->> 'sms_do_not_contact', 'false') = 'true'
            OR metadata ->> 'sms_do_not_contact_at' IS NOT NULL
            OR COALESCE(metadata ->> 'comms_command_last_status', '') = 'do_not_contact'
          ) AS opt_out,
          (
            metadata ->> 'csv_call_import_source' = 'hubspot_owner_lead'
          ) AS owner_queue,
          (metadata ->> 'stage_type' = 'storm_watch_comms') AS storm_watch,
          (
            metadata ->> 'comms_support_state' = 'am_support'
            OR metadata ->> 'comms_command_last_status' IN ('human_requested', 'account_manager_support', 'am_support')
            OR metadata ? 'sms_autopilot_slack_human_requested_at'
            OR metadata ? 'sms_autopilot_slack_completion_without_purchase_at'
            OR metadata ? 'sms_autopilot_slack_handoff_at'
            OR COALESCE(metadata ->> 'comms_route_claim_reason', '') ~* '(human_requested|account_manager_answer_needed)'
          ) AS am_support,
          (
            metadata ? 'shopify_link_sent_at'
            OR metadata ? 'comms_link_reached_at'
          ) AS link_sent,
          (
            metadata ? 'sms_autopilot_completed_at'
            OR metadata ? 'sms_autopilot_completion_sent_at'
            OR metadata #>> '{comms_bot_state,autopilot_complete}' = 'true'
          ) AS autopilot_complete,
          (
            metadata ->> 'comms_command_last_channel' = 'sms'
            AND metadata ->> 'comms_command_last_status' IN ('received', 'inbound')
          ) AS needs_reply,
          (metadata ->> 'sms_autopilot_enabled' = 'true') AS autopilot,
          (
            metadata ->> 'comms_command_last_channel' = 'sms'
            AND metadata ->> 'comms_command_last_status' IN ('sent', 'follow_up_sent')
          ) AS waiting,
          COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(metadata -> 'sms_thread') = 'array' THEN metadata -> 'sms_thread' ELSE '[]'::jsonb END), 0) AS sms_events
        FROM comms
      ),
      classified AS (
        SELECT
          *,
          (NOT opt_out AND board_state NOT IN ('hidden', 'hold', 'done', 'opt_out')) AS active_visible,
          CASE
            WHEN opt_out THEN 'opt_out'
            WHEN board_state = 'hidden' THEN 'hidden'
            WHEN board_state = 'hold' THEN 'hold'
            WHEN board_state = 'done' THEN 'complete'
            WHEN am_support THEN 'am_support'
            WHEN link_sent THEN 'link_sent'
            WHEN autopilot_complete AND NOT needs_reply THEN 'complete'
            WHEN needs_reply THEN 'needs_reply'
            WHEN autopilot THEN 'autopilot'
            WHEN waiting THEN 'waiting'
            WHEN sms_events = 0 THEN 'new'
            ELSE 'active'
          END AS status_key
        FROM flags
      )
      SELECT key, total FROM (
        SELECT status_key AS key, COUNT(*)::bigint AS total FROM classified GROUP BY status_key
        UNION ALL SELECT 'all', COUNT(*)::bigint FROM classified
        UNION ALL SELECT 'active', COUNT(*)::bigint FROM classified WHERE active_visible
        UNION ALL SELECT 'claimed_by_me', COUNT(*)::bigint FROM classified WHERE claimed_by_me AND active_visible
        UNION ALL SELECT 'owner_queue', COUNT(*)::bigint FROM classified WHERE owner_queue AND active_visible AND NOT claimed_any
        UNION ALL SELECT 'storm_watch', COUNT(*)::bigint FROM classified WHERE storm_watch
      ) totals
    SQL

    rows.each { |key, total| counts[key.to_s] = total.to_i }
    COMMS_STATUS_FILTER_OPTIONS.each { |key, _label| counts[key] ||= 0 }
    counts
  end

  def comms_increment_status_counts!(counts, stage)
    status = stage_call_status(stage)[:key].to_s
    counts[status] += 1
    counts["all"] += 1
    counts["active"] += 1 if comms_stage_active_visible?(stage)
    counts["claimed_by_me"] += 1 if comms_claimed_by_me_stage?(stage) && comms_stage_active_visible?(stage)
    counts["owner_queue"] += 1 if owner_queue_comms_stage?(stage) && claimable_comms_stage?(stage)
    counts["storm_watch"] += 1 if storm_watch_comms_stage?(stage)
  end

  def owner_queue_available_count
    owner_id = ENV["WIZWIKI_COMMS_SOURCE_OWNER_ID"].presence || ENV["HUBSPOT_COMMS_OWNER_ID"].presence
    return 0 if owner_id.blank?
    current_organization.crm_records
      .where(record_type: "contact")
      .where.not(source: "manual_comms")
      .where.not(status: "archived")
      .where(
        <<~SQL.squish,
          crm_records.properties #>> '{hubspot,properties,hubspot_owner_id}' = :owner_id
          OR crm_records.properties #>> '{hubspot_owner_id}' = :owner_id
          OR crm_records.properties #>> '{contact_owner_id}' = :owner_id
        SQL
        owner_id: owner_id
      )
      .where(facebook_contact_source_sql)
      .count
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] Owner Queue available count unavailable: #{error.class}: #{error.message}")
    0
  end

  def facebook_contact_source_sql
    <<~SQL.squish
      crm_records.properties #>> '{hubspot,lead_source}' = 'facebook'
      OR (crm_records.properties #> '{hubspot,lead_sources}') @> '["facebook"]'::jsonb
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_click_id}', '') <> ''
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebookid}', '') <> ''
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_facebook_ad_clicked}', '') = 'true'
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_inquiry}', '') = 'true'
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,facebook_messenger_conversion}', '') <> ''
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_1}', '') ILIKE '%facebook%'
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_analytics_source_data_2}', '') ILIKE '%facebook%'
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_1}', '') ILIKE '%facebook%'
      OR COALESCE(crm_records.properties #>> '{hubspot,properties,hs_latest_source_data_2}', '') ILIKE '%facebook%'
    SQL
  end

  def comms_active_scope(scope)
    comms_not_opt_out_scope(scope)
      .where("COALESCE(crm_record_artifacts.metadata ->> 'comms_board_state', 'active') NOT IN (?)", %w[hidden hold done opt_out])
  end

  def comms_unclaimed_scope(scope)
    scope
      .where("crm_records.owner_id IS NULL")
      .where("NULLIF(crm_record_artifacts.metadata ->> 'claimed_by_user_id', '') IS NULL")
  end

  def comms_csv_import_status_scope(scope, status_key = nil)
    relation = comms_unclaimed_scope(comms_active_scope(scope))
      .where("NULLIF(crm_record_artifacts.metadata ->> 'csv_call_import_status_key', '') IS NOT NULL")
      .where("NULLIF(crm_record_artifacts.metadata ->> 'csv_call_import_title', '') IS NOT NULL")
    status_key.present? ? relation.where("crm_record_artifacts.metadata ->> 'csv_call_import_status_key' = ?", status_key) : relation
  end

  def comms_owner_queue_scope(scope)
    comms_unclaimed_scope(comms_active_scope(scope)).where("crm_record_artifacts.metadata ->> 'csv_call_import_source' = ?", "hubspot_owner_lead")
  end

  def comms_claimed_by_me_scope(scope)
    comms_not_opt_out_scope(scope).where("COALESCE(crm_record_artifacts.metadata ->> 'comms_board_state', 'active') NOT IN (?)", %w[hidden hold done opt_out]).where(
      "crm_records.owner_id = :user_id OR crm_record_artifacts.metadata ->> 'claimed_by_user_id' = :user_id_text",
      user_id: current_user.id,
      user_id_text: current_user.id.to_s
    )
  end

  def storm_watch_comms_scope(scope)
    scope.where("crm_record_artifacts.metadata ->> 'stage_type' = ?", "storm_watch_comms")
  end

  def comms_needs_reply_scope(scope)
    comms_active_scope(scope).where(
      "crm_record_artifacts.metadata ->> 'comms_command_last_channel' = ? AND crm_record_artifacts.metadata ->> 'comms_command_last_status' IN (?)",
      "sms",
      %w[received inbound]
    )
  end

  def comms_waiting_scope(scope)
    comms_active_scope(scope).where(
      "crm_record_artifacts.metadata ->> 'comms_command_last_channel' = ? AND crm_record_artifacts.metadata ->> 'comms_command_last_status' IN (?)",
      "sms",
      %w[sent follow_up_sent]
    )
  end

  def comms_autopilot_scope(scope)
    comms_active_scope(scope).where("crm_record_artifacts.metadata ->> 'sms_autopilot_enabled' = ?", "true")
  end

  def comms_not_opt_out_scope(scope)
    scope.where(
      "COALESCE(crm_record_artifacts.metadata ->> 'comms_board_state', 'active') != ? AND COALESCE(crm_record_artifacts.metadata ->> 'sms_do_not_contact', 'false') != ? AND crm_record_artifacts.metadata ->> 'sms_do_not_contact_at' IS NULL AND COALESCE(crm_record_artifacts.metadata ->> 'comms_command_last_status', '') != ?",
      "opt_out",
      "true",
      "do_not_contact"
    )
  end

  def comms_opt_out_scope(scope)
    scope.where(
      "crm_record_artifacts.metadata ->> 'comms_board_state' = ? OR crm_record_artifacts.metadata ->> 'sms_do_not_contact' = ? OR crm_record_artifacts.metadata ->> 'sms_do_not_contact_at' IS NOT NULL OR crm_record_artifacts.metadata ->> 'comms_command_last_status' = ?",
      "opt_out",
      "true",
      "do_not_contact"
    )
  end

  def comms_link_sent_scope(scope)
    comms_active_scope(scope).where(
      "crm_record_artifacts.metadata ? 'shopify_link_sent_at' OR crm_record_artifacts.metadata ? 'comms_link_reached_at'"
    )
  end

  def comms_am_support_scope(scope)
    comms_active_scope(scope).where(
      "crm_record_artifacts.metadata ->> 'comms_support_state' = :support OR crm_record_artifacts.metadata ->> 'comms_command_last_status' IN (:statuses) OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_human_requested_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_completion_without_purchase_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_handoff_at' OR crm_record_artifacts.metadata ->> 'comms_route_claim_reason' ~* :reason",
      support: "am_support",
      statuses: %w[human_requested account_manager_support am_support],
      reason: "(human_requested|account_manager_answer_needed)"
    )
  end

  def comms_complete_scope(scope)
    comms_not_opt_out_scope(scope).where(
      "crm_record_artifacts.metadata ->> 'comms_board_state' = :done OR crm_record_artifacts.metadata ? 'sms_autopilot_completed_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_completion_sent_at' OR crm_record_artifacts.metadata #>> '{comms_bot_state,autopilot_complete}' = :true_value",
      done: "done",
      true_value: "true"
    )
  end

  def comms_new_scope(scope)
    comms_active_scope(scope)
      .where("COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(crm_record_artifacts.metadata -> 'sms_thread') = 'array' THEN crm_record_artifacts.metadata -> 'sms_thread' ELSE '[]'::jsonb END), 0) = 0")
      .where("NOT (crm_record_artifacts.metadata ? 'shopify_link_sent_at' OR crm_record_artifacts.metadata ? 'comms_link_reached_at')")
      .where(
        "NOT (COALESCE(crm_record_artifacts.metadata ->> 'comms_support_state', '') = :support OR COALESCE(crm_record_artifacts.metadata ->> 'comms_command_last_status', '') IN (:statuses) OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_human_requested_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_completion_without_purchase_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_slack_handoff_at' OR COALESCE(crm_record_artifacts.metadata ->> 'comms_route_claim_reason', '') ~* :reason)",
        support: "am_support",
        statuses: %w[human_requested account_manager_support am_support],
        reason: "(human_requested|account_manager_answer_needed)"
      )
      .where(
        "NOT (COALESCE(crm_record_artifacts.metadata ->> 'comms_board_state', '') = :done OR crm_record_artifacts.metadata ? 'sms_autopilot_completed_at' OR crm_record_artifacts.metadata ? 'sms_autopilot_completion_sent_at' OR COALESCE(crm_record_artifacts.metadata #>> '{comms_bot_state,autopilot_complete}', 'false') = :true_value)",
        done: "done",
        true_value: "true"
      )
      .where("COALESCE(crm_record_artifacts.metadata ->> 'sms_autopilot_enabled', 'false') != ?", "true")
  end

  def filter_comms_stages(stages, status_filter)
    return stages.select { |stage| csv_import_status_stage?(stage, status_filter) && claimable_comms_stage?(stage) } if csv_import_status_key_format?(status_filter)
    return stages if status_filter == "all"
    return stages.select { |stage| comms_claimed_by_me_stage?(stage) && comms_stage_active_visible?(stage) } if status_filter == "claimed_by_me"
    return stages.select { |stage| owner_queue_comms_stage?(stage) && claimable_comms_stage?(stage) } if status_filter == "owner_queue"
    return stages.select { |stage| comms_stage_active_visible?(stage) } if status_filter == "active"
    return stages.select { |stage| storm_watch_comms_stage?(stage) } if status_filter == "storm_watch"

    stages.select { |stage| stage_call_status(stage)[:key].to_s == status_filter }
  end

  def sort_comms_stages(stages)
    stages.sort_by do |stage|
      status = stage_call_status(stage)
      [
        comms_open_stage_sort_rank(stage),
        status[:rank].to_i,
        -(stage_last_sms_at(stage)&.to_f || stage.updated_at.to_f),
        -stage.updated_at.to_f
      ]
    end
  end

  def comms_open_stage_sort_rank(stage)
    return 0 if params[:open_sms_stage].to_s == stage.id.to_s
    return 0 if params[:open_email_stage].to_s == stage.id.to_s

    1
  end

  def comms_stage_active_visible?(stage)
    return false if stage_sms_do_not_contact?(stage)
    return false if stage_manual_board_state(stage).in?(%w[hidden hold done opt_out])

    true
  end

  def storm_watch_comms_stage?(stage)
    stage.metadata.to_h["stage_type"].to_s == "storm_watch_comms"
  end

  def owner_queue_comms_stage?(stage)
    metadata = stage.metadata.to_h
    metadata["csv_call_import_source"].to_s == "hubspot_owner_lead"
  end

  def csv_import_status_stage?(stage, status_key)
    return false unless csv_import_status_key_format?(status_key)

    stage.metadata.to_h["csv_call_import_status_key"].to_s == status_key.to_s
  end

  def comms_claimed_by_me_stage?(stage)
    stage.crm_record&.owner_id == current_user.id ||
      stage.metadata.to_h["claimed_by_user_id"].to_s == current_user.id.to_s
  end

  def claimable_comms_stage?(stage)
    return false unless comms_stage_active_visible?(stage)
    return false if stage.crm_record_id.blank?
    return false if stage.crm_record&.owner_id.present?

    stage.metadata.to_h["claimed_by_user_id"].blank?
  end

  def csv_import_status_key(import_id)
    "#{COMMS_CSV_IMPORT_STATUS_PREFIX}#{import_id}"
  end

  def csv_import_status_key_format?(value)
    value.to_s.match?(/\A#{Regexp.escape(COMMS_CSV_IMPORT_STATUS_PREFIX)}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  def normalize_csv_import_title(value)
    value.to_s.squish.gsub(/[^a-zA-Z0-9 #&_.:-]/, "").squish[0, 80].presence
  end

  def persist_csv_upload_for_job!(upload, job_id:)
    dir = Rails.root.join("tmp", "comms_csv_imports")
    FileUtils.mkdir_p(dir)
    filename = upload.respond_to?(:original_filename) ? upload.original_filename.to_s : "upload.csv"
    ext = File.extname(filename).presence || ".csv"
    path = dir.join("#{job_id}#{ext}")
    File.binwrite(path, upload.read)
    path.to_s
  end

  def comms_csv_import_status_for(job_id)
    status = Comms::CsvImportStatus.job(current_organization, job_id) if job_id.present?
    status = Comms::CsvImportStatus.latest_active_for_user(current_organization, current_user.id) if status.blank?
    status.to_h
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] CSV import status unavailable user=#{current_user&.id}: #{error.class}: #{error.message}")
    {}
  end

  def purge_eligible_count_for_action(query:, status_filter:, visible_count:)
    return visible_count.to_i unless csv_import_status_key_format?(status_filter)

    csv_import_lane_stages_for_purge(query: query, status_filter: status_filter).count { |stage| purge_actionable_comms_stage?(stage, status_filter: status_filter) }
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] CSV purge count unavailable status=#{status_filter}: #{error.class}: #{error.message}")
    visible_count.to_i
  end

  def csv_import_lane_stages_for_purge(query:, status_filter:)
    comms_csv_import_status_scope(search_staged_scope(staged_scope, query), status_filter)
      .includes(:user, :crm_record)
      .order(updated_at: :desc)
      .to_a
  end

  def stage_manual_board_state(stage)
    normalize_comms_board_state(stage.metadata.to_h["comms_board_state"])
  end

  def stage_call_status(stage, follow_up_timer: nil)
    metadata = stage.metadata.to_h
    manual_state = stage_manual_board_state(stage)
    timer = follow_up_timer || stage_follow_up_timer(stage)
    key = if stage_sms_do_not_contact?(stage)
      "opt_out"
    elsif manual_state.in?(%w[hidden hold done])
      manual_state == "done" ? "complete" : manual_state
    elsif stage_am_support?(stage)
      "am_support"
    elsif stage_link_sent?(stage)
      "link_sent"
    elsif stage_autopilot_complete?(metadata) && !stage_recent_inbound_sms?(stage)
      "complete"
    elsif stage_recent_inbound_sms?(stage)
      "needs_reply"
    elsif stage_sms_autopilot_enabled?(stage)
      "autopilot"
    elsif timer[:state].to_s.in?(%w[due outside_window])
      "stale_due"
    elsif stage_first_sms_sent?(stage)
      "waiting"
    else
      "new"
    end

    {
      key: key,
      label: comms_status_label(key),
      rank: comms_status_rank(key),
      last_label: stage_last_sms_label(stage),
      next_label: timer[:label],
      next_detail: timer[:detail],
      due_at: timer[:due_at],
      timer_state: timer[:state]
    }
  end

  def comms_status_label(key)
    {
      "new" => "NEW",
      "needs_reply" => "NEEDS REPLY",
      "autopilot" => "PROMPTING",
      "stale_due" => "STALE DUE",
      "waiting" => "WAITING",
      "link_sent" => "LINK SENT",
      "am_support" => "AM SUPPORT",
      "complete" => "COMPLETE",
      "hold" => "ON HOLD",
      "hidden" => "HIDDEN",
      "opt_out" => "DO NOT CONTACT"
    }.fetch(key.to_s, key.to_s.tr("_", " ").upcase)
  end

  def comms_status_rank(key)
    {
      "needs_reply" => 0,
      "stale_due" => 1,
      "new" => 2,
      "autopilot" => 3,
      "waiting" => 4,
      "link_sent" => 5,
      "am_support" => 6,
      "complete" => 7,
      "hold" => 8,
      "hidden" => 9,
      "opt_out" => 10
    }.fetch(key.to_s, 20)
  end

  def set_stage
    @stage = staged_scope.find(params[:id])
  end

  def destroy_comms_stage!(stage)
    record = stage.crm_record
    stage_id = stage.id

    purge_comms_artifact_storage!(stage)
    delete_autos_embedding_source!(stage)
    stage.destroy!

    destroy_manual_comms_record_if_unused!(record, except_artifact_id: stage_id)
  end

  def deletable_comms_stage?(stage)
    metadata = stage.metadata.to_h
    metadata["stage_type"].to_s == "manual_comms" && !source_managed_comms_stage?(stage)
  end

  def purge_actionable_comms_stage?(stage, status_filter:)
    deletable_comms_stage?(stage) || releasable_claimed_source_managed_stage?(stage, status_filter: status_filter)
  end

  def releasable_claimed_source_managed_stage?(stage, status_filter:)
    status_filter.to_s == "claimed_by_me" &&
      source_managed_comms_stage?(stage) &&
      comms_claimed_by_me_stage?(stage)
  end

  def release_claimed_source_managed_comms_stage!(stage)
    return false unless releasable_claimed_source_managed_stage?(stage, status_filter: "claimed_by_me")

    record = stage.crm_record
    metadata = stage.metadata.to_h.except(
      "claimed_by_user_id",
      "claimed_by_user_name",
      "claimed_at",
      "claimed_last_confirmed_at",
      "claimed_source"
    )
    now = Time.current
    metadata = metadata.merge(
      "claimed_released_at" => now.iso8601,
      "claimed_released_by_user_id" => current_user.id.to_s,
      "claimed_released_by_user_name" => current_user.display_name,
      "claimed_release_source" => "comms_claimed_by_me_purge"
    )

    record.update!(owner: nil) if record&.owner_id == current_user.id
    stage.update!(generated_at: now, metadata: metadata)
    true
  end

  def source_managed_comms_stage?(stage)
    metadata = stage.metadata.to_h
    metadata["stage_type"].to_s == "storm_watch_comms" ||
      metadata["csv_call_import_source"].to_s == "hubspot_owner_lead" ||
      metadata["owner_queue_source_uid"].present?
  end

  def destroy_manual_comms_record_if_unused!(record, except_artifact_id: nil)
    return false unless record&.source.to_s == "manual_comms"

    purge_manual_comms_record_outputs!(record, except_artifact_id: except_artifact_id)
    return false if record.crm_record_artifacts.where.not(id: except_artifact_id).exists?

    purge_manual_comms_record_media!(record)
    delete_autos_embedding_source!(record)
    record.crm_address_records.destroy_all
    record.destroy!
    true
  end

  def purge_manual_comms_record_outputs!(record, except_artifact_id: nil)
    record.crm_record_artifacts.where.not(id: except_artifact_id).find_each do |artifact|
      purge_comms_artifact_storage!(artifact)
      delete_autos_embedding_source!(artifact)
      artifact.destroy!
    end
  end

  def purge_manual_comms_record_media!(record)
    record.deal_media.attachments.to_a.each do |attachment|
      attachment.purge
    rescue StandardError => error
      Rails.logger.warn("[CommsCommands] media purge failed record=#{record.id} attachment=#{attachment.id}: #{error.class}: #{error.message}")
    end
  end

  def purge_comms_artifact_storage!(artifact)
    keys = comms_artifact_storage_keys(artifact)
    return if keys.blank? || !defined?(DealReports::Publisher)

    DealReports::Publisher.delete_keys!(artifact: artifact, keys: keys)
  end

  def comms_artifact_storage_keys(artifact)
    ([artifact.storage_key] + metadata_storage_keys(artifact.metadata.to_h))
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end

  def metadata_storage_keys(value)
    case value
    when Hash
      value.flat_map do |key, nested|
        key.to_s == "storage_key" ? [nested] : metadata_storage_keys(nested)
      end
    when Array
      value.flat_map { |nested| metadata_storage_keys(nested) }
    else
      []
    end
  end

  def delete_autos_embedding_source!(source)
    Autos::EmbeddingQueue.delete_source!(source) if defined?(Autos::EmbeddingQueue)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] embedding cleanup failed source=#{source.class.name}##{source.id}: #{error.class}: #{error.message}")
  end

  def destroy_orphan_manual_comms_records!
    removed = 0
    current_organization.crm_records.where(source: "manual_comms").find_each do |record|
      removed += 1 if destroy_manual_comms_record_if_unused!(record)
    end
    removed
  end

  def import_call_csv!(upload, title: nil)
    content = upload.read.to_s
    content = content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rows = CSV.parse(content, headers: true, skip_blanks: true)
    raise ArgumentError, "CSV must include a header row." if rows.headers.blank?

    import_id = SecureRandom.uuid
    import_title = normalize_csv_import_title(title)
    import_status_key = import_title.present? ? csv_import_status_key(import_id) : nil
    result = { rows: rows.length, created: 0, updated: 0, skipped: 0, duplicate_contact: 0, missing_contact: 0, errors: 0, import_id: import_id, title: import_title, status_key: import_status_key }
    contact_index = Comms::ContactDeduper.key_index(organization: current_organization)
    rows.each_with_index do |row, index|
      attrs = csv_call_attrs(row)
      if attrs[:phone].blank? && attrs[:email].blank?
        result[:skipped] += 1
        result[:missing_contact] += 1
        next
      end
      if Comms::ContactDeduper.duplicate_in_index?(contact_index, phone: attrs[:phone], email: attrs[:email])
        result[:skipped] += 1
        result[:duplicate_contact] += 1
        next
      end

      label = attrs[:company_name].presence || attrs[:contact_name].presence || attrs[:email].presence || attrs[:phone].presence || "WIZWIKI COMMS"
      record = manual_crm_record!(
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        import_title: import_title,
        import_status_key: import_status_key,
        row_number: index + 2,
        raw_row: row.to_h
      )
      stage = manual_stage!(
        record: record,
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        import_title: import_title,
        import_status_key: import_status_key,
        row_number: index + 2,
        raw_row: row.to_h
      )
      Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
      stage.respond_to?(:csv_import_created?) && stage.csv_import_created? ? result[:created] += 1 : result[:updated] += 1
    rescue StandardError => error
      result[:skipped] += 1
      result[:errors] += 1
      Rails.logger.warn("[CommsCommands] CSV row skipped index=#{index + 2}: #{error.class}: #{error.message}")
    end
    result
  end

  def sync_hubspot_owner_comms!(owner_name:)
    client = Hubspot::Client.new
    owner = hubspot_comms_owner(client, owner_name)
    raise ArgumentError, "Could not find HubSpot owner #{owner_name}." if owner.blank?

    result = { created: 0, updated: 0, skipped: 0, duplicate_contact: 0, cached: 0, hydrated: 0 }
    import_id = "hubspot-leads-#{owner["id"]}-#{Time.current.to_i}"
    contact_index = Comms::ContactDeduper.key_index(organization: current_organization)
    hubspot_owner_leads(client, owner_id: owner["id"]).each_with_index do |payload, index|
      attrs = cached_hubspot_lead_comms_attrs(payload, owner: owner)
      if attrs.present?
        result[:cached] += 1
      else
        attrs = hubspot_lead_comms_attrs(client, payload, owner: owner)
        result[:hydrated] += 1
      end
      if attrs[:phone].blank? && attrs[:email].blank?
        result[:skipped] += 1
        next
      end
      if Comms::ContactDeduper.duplicate_in_index?(contact_index, phone: attrs[:phone], email: attrs[:email])
        result[:skipped] += 1
        result[:duplicate_contact] += 1
        next
      end

      label = attrs[:company_name].presence || attrs[:contact_name].presence || attrs[:email].presence || attrs[:phone].presence || "HubSpot COMMS"
      record = manual_crm_record!(
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        row_number: index + 1,
        raw_row: attrs[:raw_row].presence || payload
      )
      stage = manual_stage!(
        record: record,
        label: label,
        phone: attrs[:phone],
        email: attrs[:email],
        contact_name: attrs[:contact_name],
        company_name: attrs[:company_name],
        industry: attrs[:industry],
        zip: attrs[:zip],
        notes: attrs[:notes],
        source: attrs[:source],
        lead_attrs: attrs.slice(:hubspot_lead_id, :hubspot_contact_id, :hubspot_lead_owner, :hubspot_owner_id, :hubspot_lead_label, :hubspot_lead_stage, :hubspot_lead_quality),
        import_id: import_id,
        row_number: index + 1,
        raw_row: attrs[:raw_row].presence || payload
      )
      Comms::ContactDeduper.add_keys(contact_index, phone: attrs[:phone], email: attrs[:email])
      stage.respond_to?(:csv_import_created?) && stage.csv_import_created? ? result[:created] += 1 : result[:updated] += 1
    rescue StandardError => error
      result[:skipped] += 1
      Rails.logger.warn("[CommsCommands] HubSpot owner lead skipped index=#{index + 1}: #{error.class}: #{error.message}")
    end
    result
  end

  def hubspot_comms_owner(client, owner_name)
    explicit_owner_id = ENV["WIZWIKI_COMMS_SOURCE_OWNER_ID"].presence || ENV["HUBSPOT_COMMS_OWNER_ID"].presence
    return explicit_hubspot_owner(owner_name, explicit_owner_id) if explicit_owner_id.present?

    hubspot_owner_for(client, owner_name)
  end

  def hubspot_owner_for(client, owner_name)
    explicit_owner_id = ENV["WIZWIKI_COMMS_SOURCE_OWNER_ID"].presence || ENV["HUBSPOT_COMMS_OWNER_ID"].presence
    return explicit_hubspot_owner(owner_name, explicit_owner_id) if explicit_owner_id.present?

    needle = owner_name.to_s.squish.downcase
    owners = Array(client.get("/crm/v3/owners", archived: false)["results"])
    owners.find do |owner|
      full_name = [owner["firstName"], owner["lastName"]].compact_blank.join(" ").downcase
      [full_name, owner["email"].to_s.downcase, owner["id"].to_s.downcase].include?(needle)
    end
  rescue Hubspot::Error => error
    raise unless error.message.include?("HubSpot 403")

    raise Hubspot::Error, "HubSpot owner lookup needs the owners read scope, or set WIZWIKI_COMMS_SOURCE_OWNER_ID to the HubSpot owner id for #{owner_name}. Contact read can still work without this scope."
  end

  def explicit_hubspot_owner(owner_name, owner_id)
    parts = owner_name.to_s.squish.split(/\s+/, 2)
    {
      "id" => owner_id.to_s,
      "firstName" => parts.first,
      "lastName" => parts.second,
      "email" => ENV["WIZWIKI_COMMS_SOURCE_OWNER_EMAIL"].presence || ENV["HUBSPOT_COMMS_OWNER_EMAIL"].presence
    }.compact_blank
  end

  def hubspot_owner_leads(client, owner_id:)
    requested_limit = params[:limit].to_i
    configured_limit = ENV.fetch("WIZWIKI_COMMS_OWNER_LEAD_LIMIT", "0").to_i
    limit = if requested_limit.positive?
      requested_limit
    elsif configured_limit.positive?
      configured_limit
    end
    rows = []
    after = nil
    loop do
      page_limit = limit.present? ? [limit - rows.length, 100].min : 100
      break if page_limit <= 0

      body = {
        filterGroups: [
          {
            filters: [
              { propertyName: "hubspot_owner_id", operator: "EQ", value: owner_id.to_s }
            ]
          }
        ],
        sorts: [{ propertyName: "hs_lastmodifieddate", direction: "DESCENDING" }],
        properties: HUBSPOT_LEAD_PROPERTIES,
        limit: page_limit
      }
      body[:after] = after if after.present?
      response = client.post("/crm/v3/objects/leads/search", body)
      rows.concat(Array(response["results"]).select do |row|
        row.to_h.dig("properties", "hubspot_owner_id").to_s == owner_id.to_s
      end)
      break if limit.present? && rows.length >= limit

      after = response.dig("paging", "next", "after")
      break if after.blank?
    end
    limit.present? ? rows.first(limit) : rows
  rescue Hubspot::Error => error
    if error.message.include?("403")
      raise Hubspot::Error, "HubSpot Leads sync needs crm.objects.leads.read plus contacts read. It will not fall back to all contacts because this lane is Sample Owner leads only."
    end

    raise
  end

  def hubspot_owner_contacts(client, owner_id:)
    limit = params[:limit].to_i.positive? ? params[:limit].to_i.clamp(1, 200) : 200
    rows = []
    after = nil
    properties = Hubspot::ContactLeadSync::DEFAULT_CONTACT_PROPERTIES
    loop do
      body = {
        filterGroups: [
          {
            filters: [
              { propertyName: "hubspot_owner_id", operator: "EQ", value: owner_id.to_s }
            ]
          }
        ],
        sorts: [{ propertyName: "lastmodifieddate", direction: "DESCENDING" }],
        properties: properties,
        limit: [limit - rows.length, 100].min
      }
      body[:after] = after if after.present?
      response = client.post("/crm/v3/objects/contacts/search", body)
      rows.concat(Array(response["results"]))
      break if rows.length >= limit

      after = response.dig("paging", "next", "after")
      break if after.blank?
    end
    rows
  end

  def hubspot_lead_comms_attrs(client, payload, owner:)
    lead_properties = payload.fetch("properties", {}).to_h
    return {} unless lead_properties["hubspot_owner_id"].to_s == owner["id"].to_s

    lead_id = payload["id"].presence || lead_properties["hs_object_id"].presence
    contact_id = hubspot_lead_contact_ids(client, lead_id).first
    contact_payload = contact_id.present? ? hubspot_contact_by_id(client, contact_id) : {}
    contact_properties = contact_payload.fetch("properties", {}).to_h

    first_name = contact_properties["firstname"].to_s.squish
    last_name = contact_properties["lastname"].to_s.squish
    contact_name = [first_name, last_name].compact_blank.join(" ").presence ||
      contact_properties["email"].presence ||
      lead_properties["hs_lead_name"].presence
    phone = extract_phone([
      contact_properties["phone"],
      contact_properties["mobilephone"],
      contact_properties["hs_calculated_phone_number"],
      contact_properties["hs_calculated_mobile_number"]
    ].compact_blank.first.to_s)
    lead_owner_name = [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence || owner["email"].presence || "Sample Owner"
    lead_name = lead_properties["hs_lead_name"].presence
    lead_label = lead_properties["hs_lead_label"].presence
    lead_stage = lead_properties["hs_pipeline_stage"].presence
    lead_quality = lead_properties["hs_lead_quality"].presence

    {
      contact_name: contact_name,
      company_name: contact_properties["company"].presence || lead_name,
      phone: phone,
      email: extract_email(contact_properties["email"].to_s),
      industry: contact_properties["industry"].presence,
      zip: contact_properties["zip"].presence,
      notes: [
        "HubSpot Lead owned by #{lead_owner_name}.",
        lead_name.present? ? "Lead: #{lead_name}." : nil,
        lead_label.present? ? "Label: #{lead_label}." : nil,
        lead_stage.present? ? "Stage: #{lead_stage}." : nil,
        lead_quality.present? ? "Quality: #{lead_quality}." : nil
      ].compact.join(" "),
      source: "hubspot_owner_lead",
      hubspot_lead_id: lead_id,
      hubspot_contact_id: contact_id,
      hubspot_owner_id: owner["id"],
      hubspot_lead_owner: lead_owner_name,
      hubspot_lead_label: lead_label,
      hubspot_lead_stage: lead_stage,
      hubspot_lead_quality: lead_quality,
      raw_row: {
        "lead" => payload,
        "contact" => contact_payload,
        "associated_contact_id" => contact_id
      }.compact_blank
    }.compact_blank
  end

  def cached_hubspot_lead_comms_attrs(payload, owner:)
    lead_properties = payload.fetch("properties", {}).to_h
    return {} unless lead_properties["hubspot_owner_id"].to_s == owner["id"].to_s

    lead_id = payload["id"].presence || lead_properties["hs_object_id"].presence
    return {} if lead_id.blank?

    stage = current_organization.crm_record_artifacts
      .where(artifact_type: "comm_staging")
      .where.not(status: "archived")
      .where("metadata ->> 'stage_type' = ?", "manual_comms")
      .where("metadata ->> 'hubspot_lead_id' = ?", lead_id.to_s)
      .order(updated_at: :desc)
      .first
    return {} if stage.blank?

    metadata = stage.metadata.to_h
    phone_option = Array(metadata["phone_options"]).find { |option| option.to_h["value"].present? }.to_h
    email_option = Array(metadata["recipient_email_options"]).find { |option| option.to_h["value"].present? }.to_h
    contact_option = Array(metadata["contact_options"]).find { |option| option.to_h["name"].present? || option.to_h["company"].present? }.to_h
    phone = extract_phone(phone_option["value"].to_s)
    email = extract_email(email_option["value"].to_s)
    return {} if phone.blank? && email.blank?

    lead_owner_name = [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence ||
      metadata["hubspot_lead_owner"].presence ||
      owner["email"].presence ||
      "Sample Owner"
    lead_name = lead_properties["hs_lead_name"].presence
    lead_label = lead_properties["hs_lead_label"].presence || metadata.dig("hubspot_lead", "hubspot_lead_label").presence
    lead_stage = lead_properties["hs_pipeline_stage"].presence || metadata.dig("hubspot_lead", "hubspot_lead_stage").presence
    lead_quality = lead_properties["hs_lead_quality"].presence || metadata["hubspot_lead_quality"].presence || metadata.dig("hubspot_lead", "hubspot_lead_quality").presence
    contact_name = metadata["captured_contact_name"].presence ||
      metadata.dig("comms_bot_state", "contact_name").presence ||
      contact_option["name"].presence ||
      email.presence ||
      lead_name
    company_name = metadata["captured_company_name"].presence ||
      metadata.dig("comms_bot_state", "company_name").presence ||
      contact_option["company"].presence ||
      lead_name

    {
      contact_name: contact_name,
      company_name: company_name,
      phone: phone,
      email: email,
      industry: metadata["captured_industry"].presence || metadata["industry"].presence,
      zip: metadata["manual_comms_zip"].presence,
      notes: [
        "HubSpot Lead owned by #{lead_owner_name}.",
        lead_name.present? ? "Lead: #{lead_name}." : nil,
        lead_label.present? ? "Label: #{lead_label}." : nil,
        lead_stage.present? ? "Stage: #{lead_stage}." : nil,
        lead_quality.present? ? "Quality: #{lead_quality}." : nil,
        "Reused local COMMS hydration from block ##{stage.id}."
      ].compact.join(" "),
      source: "hubspot_owner_lead",
      hubspot_lead_id: lead_id,
      hubspot_contact_id: metadata["hubspot_contact_id"].presence,
      hubspot_owner_id: owner["id"],
      hubspot_lead_owner: lead_owner_name,
      hubspot_lead_label: lead_label,
      hubspot_lead_stage: lead_stage,
      hubspot_lead_quality: lead_quality,
      raw_row: {
        "lead" => payload,
        "cached_comm_stage_id" => stage.id
      }.compact_blank
    }.compact_blank
  end

  def hubspot_lead_contact_ids(client, lead_id)
    return [] if lead_id.blank?

    response = client.get("/crm/v4/objects/leads/#{lead_id}/associations/contacts")
    Array(response["results"])
      .sort_by { |row| Array(row["associationTypes"]).any? { |type| type.to_h["label"].to_s.casecmp("Primary").zero? } ? 0 : 1 }
      .filter_map { |row| row.to_h["toObjectId"].presence&.to_s }
      .uniq
  rescue Hubspot::Error
    response = client.get("/crm/v3/objects/leads/#{lead_id}/associations/contacts")
    Array(response["results"]).filter_map { |row| row.to_h["id"].presence&.to_s }.uniq
  end

  def hubspot_contact_by_id(client, contact_id)
    return {} if contact_id.blank?

    client.get("/crm/v3/objects/contacts/#{contact_id}", properties: HUBSPOT_COMMS_CONTACT_PROPERTIES.join(","))
  end

  def hubspot_contact_attrs(payload, owner:)
    properties = payload.fetch("properties", {}).to_h
    first_name = properties["firstname"].to_s.squish
    last_name = properties["lastname"].to_s.squish
    contact_name = [first_name, last_name].compact_blank.join(" ").presence || properties["email"].presence
    phone = extract_phone([
      properties["phone"],
      properties["mobilephone"],
      properties["hs_calculated_phone_number"],
      properties["hs_calculated_mobile_number"]
    ].compact_blank.first.to_s)
    {
      contact_name: contact_name,
      company_name: properties["company"].presence,
      phone: phone,
      email: extract_email(properties["email"].to_s),
      industry: properties["industry"].presence,
      notes: "HubSpot contact owned by #{[owner["firstName"], owner["lastName"]].compact_blank.join(" ")}.",
      hubspot_contact_id: payload["id"].presence || properties["hs_object_id"].presence,
      hubspot_owner_id: owner["id"],
      hubspot_lead_owner: [owner["firstName"], owner["lastName"]].compact_blank.join(" ").presence || owner["email"]
    }.compact_blank
  end

  def csv_call_attrs(row)
    associated_contact = parse_associated_contact(csv_value(row, "associated_contact_primary", "associated_contact", "associated_contact_ids_primary"))
    contact_name = csv_value(row, "contact_name", "contact", "name", "full_name", "customer_name", "person", "first_name").presence || associated_contact[:name]
    company_name = csv_value(row, "company_name", "company", "account", "business", "business_name", "organization", "lead_name")
    company_name = distinct_comms_company_name(contact_name, company_name)
    phone = extract_phone(csv_value(row, "phone", "phone_number", "mobile", "mobile_phone", "cell", "cell_phone", "number", "contact_phone").to_s)
    email = extract_email(csv_value(row, "email", "email_address", "contact_email").to_s).presence || associated_contact[:email]
    zip = csv_value(row, "zip", "zipcode", "zip_code", "postal", "postal_code", "service_zip", "service_area")
    {
      contact_name: contact_name,
      company_name: company_name,
      phone: phone,
      email: email,
      zip: zip.to_s[/\b\d{5}(?:-\d{4})?\b/].presence || zip,
      industry: csv_value(row, "industry", "business_type", "vertical", "trade", "category"),
      notes: csv_value(row, "notes", "note", "note_for_rep", "summary", "call_notes", "call_summary", "description", "message"),
      source: csv_value(row, "source", "lead_source", "campaign", "channel").presence || "csv_call_import",
      hubspot_lead_id: csv_value(row, "record_id", "lead_id", "hs_object_id"),
      hubspot_contact_id: csv_value(row, "associated_contact_ids_primary", "associated_contact_id").presence || associated_contact[:contact_id],
      hubspot_lead_owner: csv_value(row, "lead_owner", "contact_owner", "owner"),
      hubspot_owner_id: csv_value(row, "hubspot_owner_id", "contact_owner_id", "lead_owner_id", "owner_id"),
      hubspot_lead_label: csv_value(row, "lead_label"),
      hubspot_lead_stage: csv_value(row, "lead_stage"),
      hubspot_lead_quality: csv_value(row, "lead_quality")
    }.compact_blank
  end

  def parse_associated_contact(value)
    text = value.to_s.squish
    return {} if text.blank?

    email = extract_email(text)
    name = text.sub(/\([^)]*@[^)]*\)/, "").squish.presence
    contact_id = text[/\b\d{6,}\b/]
    {
      name: name,
      email: email,
      contact_id: contact_id
    }.compact_blank
  end

  def csv_value(row, *names)
    normalized = row.headers.compact.index_by { |header| normalize_csv_header(header) }
    names.each do |name|
      header = normalized[normalize_csv_header(name)]
      value = row[header].to_s.squish if header.present?
      return value if value.present?
    end
    nil
  end

  def normalize_csv_header(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end

  def start_autopilot_for_stage!(stage, writer_model: nil, challenger_model: nil, ignore_first_stop_for_bot_bridge: false)
    metadata = stage.metadata.to_h.deep_dup
    normalized_writer = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.sms_writer_model_from_metadata(metadata))
    normalized_challenger = WizwikiSettings.normalize_challenger_model(challenger_model.presence || metadata["sms_challenger_model"].presence)
    metadata["sms_autopilot_enabled"] = true
    metadata["sms_autopilot_updated_at"] = Time.current.iso8601
    metadata["sms_autopilot_updated_by_user_id"] = current_user.id
    metadata["sms_autopilot_updated_by"] = current_user.display_name
    metadata["sms_writer_model"] = normalized_writer
    metadata["sms_writer_model_label"] = WizwikiSettings.sms_writer_model_label(normalized_writer)
    metadata["sms_writer_model_explicit"] = WizwikiSettings.sms_writer_model_explicit?(normalized_writer)
    metadata["sms_challenger_model"] = normalized_challenger
    metadata["sms_challenger_model_label"] = WizwikiSettings.challenger_model_label(normalized_challenger)
    metadata["sms_autopilot_objective"] = default_autopilot_objective
    metadata["sms_autopilot_turn_limit"] = metadata["sms_autopilot_turn_limit"].presence || ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_TURN_LIMIT", "16").to_i
    metadata["sms_autopilot_started_at"] ||= Time.current.iso8601
    if ignore_first_stop_for_bot_bridge
      metadata["sms_autopilot_ignore_first_stop_for_bot_bridge"] = true
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_at")
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_sid")
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_provider")
      metadata.delete("sms_autopilot_ignore_first_stop_body")
      metadata = stage_bot_bridge_first_stop_next_text(metadata, writer_model: normalized_writer, challenger_model: normalized_challenger)
    else
      metadata.delete("sms_autopilot_ignore_first_stop_for_bot_bridge")
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_at")
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_sid")
      metadata.delete("sms_autopilot_ignore_first_stop_consumed_provider")
      metadata.delete("sms_autopilot_ignore_first_stop_body")
    end
    metadata.delete("sms_autopilot_disabled_at")
    metadata.delete("sms_autopilot_disabled_reason")
    stage.update!(generated_at: Time.current, metadata: metadata)
  end

  def stage_bot_bridge_first_stop_next_text(metadata, writer_model:, challenger_model:)
    body = bot_bridge_first_stop_text
    now = Time.current.iso8601
    writer_label = WizwikiSettings.sms_writer_model_label(writer_model)
    challenger_label = WizwikiSettings.challenger_model_label(challenger_model)
    history = Array(metadata["sms_draft_history"]).last(24)
    history << {
      "id" => SecureRandom.uuid,
      "body" => body,
      "provider" => "operator/bot_bridge",
      "model" => "ignore-first-stop",
      "writer_model" => writer_model,
      "writer_model_label" => writer_label,
      "challenger_model" => challenger_model,
      "challenger_model_label" => challenger_label,
      "draft_source" => "bot_bridge_first_stop",
      "reason" => "Operator checked Ignore first STOP in SMS overlay for bot-to-bot connection.",
      "user_id" => current_user.id,
      "user_name" => current_user.display_name,
      "created_at" => now
    }.compact_blank

    metadata.merge(
      "comms_command_sms_draft_body" => body,
      "comms_command_sms_draft" => {
        "body" => body,
        "provider" => "operator/bot_bridge",
        "model" => "ignore-first-stop",
        "writer_model" => writer_model,
        "writer_model_label" => writer_label,
        "challenger_model" => challenger_model,
        "challenger_model_label" => challenger_label,
        "draft_source" => "bot_bridge_first_stop",
        "reason" => "Operator checked Ignore first STOP in SMS overlay for bot-to-bot connection.",
        "created_at" => now
      }.compact_blank,
      "sms_draft_history" => history,
      "comms_command_last_channel" => "sms",
      "comms_command_last_status" => "bot_bridge_next_text_staged",
      "comms_command_last_at" => now
    )
  end

  def bot_bridge_first_stop_text
    "My human half added an ignore 1 STOP so we can connect and train together if you like"
  end

  def pause_autopilot_for_stage!(stage, reason: nil, writer_model: nil, challenger_model: nil)
    metadata = stage.metadata.to_h.deep_dup
    normalized_writer = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.sms_writer_model_from_metadata(metadata))
    normalized_challenger = WizwikiSettings.normalize_challenger_model(challenger_model.presence || metadata["sms_challenger_model"].presence)
    metadata["sms_autopilot_enabled"] = false
    metadata["sms_autopilot_updated_at"] = Time.current.iso8601
    metadata["sms_autopilot_updated_by_user_id"] = current_user.id
    metadata["sms_autopilot_updated_by"] = current_user.display_name
    metadata["sms_writer_model"] = normalized_writer
    metadata["sms_writer_model_label"] = WizwikiSettings.sms_writer_model_label(normalized_writer)
    metadata["sms_writer_model_explicit"] = WizwikiSettings.sms_writer_model_explicit?(normalized_writer)
    metadata["sms_challenger_model"] = normalized_challenger
    metadata["sms_challenger_model_label"] = WizwikiSettings.challenger_model_label(normalized_challenger)
    metadata["sms_autopilot_objective"] = default_autopilot_objective
    metadata["sms_autopilot_turn_limit"] = metadata["sms_autopilot_turn_limit"].presence || ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_TURN_LIMIT", "16").to_i
    metadata["sms_autopilot_disabled_at"] = Time.current.iso8601
    metadata["sms_autopilot_disabled_reason"] = reason.to_s.presence || "operator_disabled"
    metadata.delete("sms_autopilot_ignore_first_stop_for_bot_bridge")
    stage.update!(generated_at: Time.current, metadata: metadata)
  end

  def skip_bulk_autopilot_stage?(stage)
    metadata = stage.metadata.to_h
    !comms_stage_active_visible?(stage) ||
      stage_link_sent?(stage) ||
      stage_am_support?(stage) ||
      ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"]) ||
      ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) ||
      metadata["sms_autopilot_completed_at"].present? ||
      metadata["sms_autopilot_completion_sent_at"].present? ||
      stage_selected_phone(stage)["value"].to_s.blank?
  end

  def skip_bulk_copilot_stage?(stage)
    metadata = stage.metadata.to_h
    !comms_stage_active_visible?(stage) ||
      stage_sms_background_drafting?(stage) ||
      ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) ||
      (stage_autopilot_complete?(metadata) && !stage_recent_inbound_sms?(stage)) ||
      stage_selected_phone(stage)["value"].to_s.blank?
  end

  def stage_company_name(stage)
    stage.metadata.to_h["company_name"].presence || stage.crm_record&.name.to_s.presence || stage.title
  end

  def stage_selected_contact(stage)
    selected_option(stage, "contact_options", "selected_contact_id")
  end

  def stage_selected_phone(stage)
    selected_option(stage, "phone_options", "selected_phone_id")
  end

  def stage_selected_email(stage)
    selected_option(stage, "recipient_email_options", "selected_recipient_email_id")
  end

  def stage_sms_body(stage)
    metadata = stage.metadata.to_h
    body = metadata["comms_command_sms_draft_body"].presence ||
      metadata["aircall_composed_sms_body"].presence ||
      metadata["composed_sms_body"].presence ||
      selected_option(stage, "sms_options", "selected_sms_id")["body"].to_s
    post_reset_sms_events = stage_sms_events_after_reset(stage)
    body = nil if stale_sms_draft_send_reason(stage, body).present?
    body = nil if sent_sms_body?(stage, body, events: post_reset_sms_events)
    return sms_preview_body_for_stage(stage, body) unless post_reset_sms_events.blank?

    draft_body = metadata["comms_command_sms_draft_body"].to_s.squish
    draft_at = parse_event_time(
      metadata.dig("comms_command_sms_draft", "created_at").presence ||
        metadata["comms_command_background_at"].presence ||
        metadata["comms_command_last_at"].presence
    )
    reset_at = stage_sms_conversation_reset_time(stage)
    if draft_body.present? &&
        reset_at.present? &&
        draft_at.present? &&
        draft_at >= reset_at &&
        normalize_sms_body_for_compare(draft_body) == normalize_sms_body_for_compare(body)
      return body
    end

    contact_name = metadata["captured_contact_name"].presence ||
      metadata.dig("comms_bot_state", "contact_name").presence ||
      stage_selected_contact(stage).to_h["name"].presence
    named_opener = comms_opening_sms_body(contact_name, stage: stage)
    first_name = comms_first_name(contact_name)
    return sms_preview_body_for_stage(stage, body) if first_name.blank?
    return sms_preview_body_for_stage(stage, named_opener) if body.blank?
    return sms_preview_body_for_stage(stage, named_opener) if body.to_s.squish == DealReports::CommsDraftWriter::OPENING_OFFER
    return sms_preview_body_for_stage(stage, named_opener) if body.to_s.match?(/\AHi,\s*I'm Thumper from WIZWIKI Marketing\./i)
    return sms_preview_body_for_stage(stage, named_opener) unless body.to_s.match?(/\b#{Regexp.escape(first_name)}\b/i)

    sms_preview_body_for_stage(stage, body)
  end

  def sms_preview_body_for_stage(stage, value)
    body = value.to_s.squish
    return body if body.blank?
    return body unless defined?(Comms::SmsBodySafety)

    Comms::SmsBodySafety.prepare_outbound_body(body, metadata: stage&.metadata)
  end

  def sent_sms_body?(stage, body, events: nil)
    normalized = normalize_sms_body_for_compare(body)
    return false if normalized.blank?

    latest_outbound = Array(events || stage_sms_events_after_reset(stage)).reverse.find do |event|
      event = event.to_h
      channel = event["channel"].to_s
      (channel.blank? || channel == "sms") &&
        event["direction"].to_s == "outbound" &&
        event["body"].to_s.squish.present? &&
        !event["status"].to_s.in?(%w[failed canceled])
    end
    normalize_sms_body_for_compare(latest_outbound.to_h["body"]) == normalized
  end

  def stale_sms_draft_send_reason(stage, body)
    normalized = normalize_sms_body_for_compare(body)
    return if normalized.blank?

    metadata = stage.metadata.to_h
    events = stage_sms_events_after_reset(stage)
    latest_inbound = latest_sms_event(events, direction: "inbound")
    return if latest_inbound.blank?
    return if latest_sms_event(events).to_h["direction"].to_s != "inbound"

    latest_inbound_at = parse_event_time(latest_inbound.to_h["created_at"].presence || latest_inbound.to_h["at"].presence || latest_inbound.to_h["timestamp"].presence)
    return if latest_inbound_at.blank?

    draft_body = metadata["comms_command_sms_draft_body"].to_s.squish
    draft_at = parse_event_time(
      metadata.dig("comms_command_sms_draft", "created_at").presence ||
        metadata["comms_command_background_at"].presence ||
        metadata["comms_command_last_at"].presence
    )

    if draft_body.blank?
      return "a newer inbound text cleared the staged draft. Rebuild the next text so Thumper answers the latest message."
    end

    if draft_at.blank? || draft_at < latest_inbound_at
      return "the staged draft is older than the latest inbound text. Rebuild the next text so Thumper answers the latest message."
    end

    nil
  end

  def sms_draft_fingerprint_mismatch_reason(stage, submitted_sha1, submitted_generation)
    submitted_sha1 = submitted_sha1.to_s.squish
    submitted_generation = submitted_generation.to_s.squish
    return if submitted_sha1.blank? && submitted_generation.blank?

    metadata = stage.metadata.to_h
    draft_body = metadata["comms_command_sms_draft_body"].to_s
    current_sha1 = Digest::SHA1.hexdigest(draft_body)
    current_generation = metadata["sms_reply_generation"].to_s

    if submitted_sha1.present? && (draft_body.blank? || current_sha1 != submitted_sha1)
      return "the reviewed draft changed or was cleared after this page loaded. Rebuild the next text before sending."
    end

    if submitted_generation.present? && current_generation.present? && current_generation != submitted_generation
      return "a newer inbound generation exists. Rebuild the next text before sending."
    end

    nil
  end

  def latest_sms_event(events, direction: nil)
    Array(events).map(&:to_h).reverse.find do |event|
      channel = event["channel"].to_s
      next false unless channel.blank? || channel == "sms"
      next false if direction.present? && event["direction"].to_s != direction.to_s

      event["body"].to_s.squish.present?
    end
  end

  def normalize_sms_body_for_compare(value)
    body = value.to_s.squish
    body = Comms::SmsBodySafety.without_opt_out_notice(body) if defined?(Comms::SmsBodySafety)
    body.downcase.gsub(/\s+/, " ")
  end

  def stage_email_subject(stage)
    metadata = stage.metadata.to_h
    draft = completed_email_draft(metadata)
    return draft["subject"].to_s if draft["subject"].present?
    return nil if starter_email_placeholder?(metadata)

    metadata["aircall_composed_email_subject"].presence ||
      metadata["composed_email_subject"].presence
  end

  def stage_email_body(stage)
    metadata = stage.metadata.to_h
    draft = completed_email_draft(metadata)
    return draft["body"].to_s if draft["body"].present?
    return nil if starter_email_placeholder?(metadata)

    metadata["aircall_composed_email_body"].presence ||
      metadata["composed_email_body"].presence
  end

  def email_comm_kit_operator_prompt(stage, user_prompt)
    metadata = stage.metadata.to_h
    latest_customer_sms = stage_sms_thread(stage).reverse.find { |event| event.to_h["direction"].to_s == "inbound" }.to_h["body"].to_s.squish
    discovery = metadata.slice(
      "captured_contact_name",
      "captured_company_name",
      "captured_industry",
      "captured_email",
      "manual_comms_zip",
      "campaign_fit",
      "contact_intelligence",
      "processing_code",
      "processing_label",
      "processing_summary",
      "recipient_selection_summary",
      "sms_captured_budget",
      "sms_captured_quantity",
      "sms_captured_product_interest",
      "sms_captured_company_name",
      "sms_captured_industry"
    ).merge(
      "company_name" => stage_company_name(stage),
      "selected_contact" => stage_selected_contact(stage).to_h["name"],
      "selected_email" => stage_selected_email(stage).to_h["value"],
      "latest_customer_sms" => latest_customer_sms.presence
    ).compact_blank

    direction = user_prompt.presence || "No extra operator direction was supplied. Build the best useful email from the call block, discovery context, SMS thread, product offerings, and Thumper voice guide."
    <<~PROMPT.squish
      FOCUSED EMAIL COMM KIT MODE. Create one review-ready sales email for this exact call block. Treat the email as a targeted marketing plan, not a generic sample: identify the client's likely need, recommend the best-fit package/deal/special when the data supports it, explain one practical reason it fits, and give one soft next step. Use discovery mode, the SMS thread, product docs, fine training, and the Thumper/Thumper voice guide as authority. If the operator provided direction, follow it as the campaign angle. Keep subject/body blank only if you cannot generate a valid draft; otherwise return one complete email for human approval. Do not send, schedule, claim follow-up happened, copy old starter samples, or invent unsupported pricing.

      Operator direction: #{direction}

      Discovery summary: #{JSON.generate(discovery)}
    PROMPT
  end

  def completed_email_draft(metadata)
    draft = metadata.to_h["comms_command_email_draft"].to_h
    return {} if ActiveModel::Type::Boolean.new.cast(draft["pending"])

    draft
  end

  def starter_email_placeholder?(metadata)
    metadata = metadata.to_h
    return false if completed_email_draft(metadata)["subject"].present?
    return false if Array(metadata["email_draft_history"]).present?

    subject = [
      metadata["composed_email_subject"],
      metadata["aircall_composed_email_subject"],
      selected_option_from_metadata(metadata, "email_options", "selected_email_id")["subject"]
    ].compact.map(&:to_s)
    return false unless subject.any? { |value| value.squish == "A practical next step from WIZWIKI" }

    option_ids = Array(metadata["email_options"]).map { |option| option.to_h["id"].to_s }
    selected_id = metadata["selected_email_id"].to_s
    ([selected_id] + option_ids).any? { |id| id.match?(/\b(?:manual|claimed|wob)-email-draft\b/) }
  end

  def selected_option_from_metadata(metadata, options_key, selected_key)
    selected_id = metadata.to_h[selected_key].to_s
    options = Array(metadata.to_h[options_key])
    selected = options.find { |option| option.to_h["id"].to_s == selected_id }
    candidate = selected || options.first
    candidate.respond_to?(:to_h) ? candidate.to_h : {}
  end

  def stage_sms_thread(stage)
    Array(stage.metadata.to_h["sms_thread"])
  end

  def stage_sms_conversation_reset_time(stage)
    value = stage.metadata.to_h["sms_conversation_reset_at"].to_s
    return if value.blank?

    parse_event_time(value)
  end

  def stage_sms_events_after_reset(stage)
    events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
    reset_at = stage_sms_conversation_reset_time(stage)
    return events if reset_at.blank?

    events.select do |event|
      event_time = parse_event_time(event["created_at"].presence || event["at"].presence || event["timestamp"].presence)
      event_time.present? && event_time >= reset_at
    end
  end

  def stage_email_thread(stage)
    Array(stage.metadata.to_h["email_thread"])
  end

  def stage_processing_code(stage)
    stage.metadata.to_h["processing_code"].presence
  end

  def stage_processing_summary(stage)
    stage.metadata.to_h["processing_summary"].presence || "Route pending. Thumper is waiting for a customer signal in the chat."
  end

  def stage_recent_inbound_sms?(stage)
    events = stage_sms_events_after_reset(stage).map(&:to_h)
    latest_inbound = events.reverse_each.find { |event| attention_sms_event?(event, direction: "inbound") }
    return false if latest_inbound.blank?

    latest_inbound_at = attention_sms_event_time(latest_inbound)
    return false if latest_inbound_at.blank? || latest_inbound_at < 24.hours.ago

    latest_outbound = events.reverse_each.find { |event| attention_sms_event?(event, direction: "outbound") }
    latest_outbound_at = attention_sms_event_time(latest_outbound)
    latest_inbound_at.present? && (latest_outbound_at.blank? || latest_inbound_at > latest_outbound_at)
  end

  def stage_latest_inbound_sms_event(stage)
    stage_sms_events_after_reset(stage).reverse_each.find do |event|
      attention_sms_event?(event.to_h, direction: "inbound")
    end
  end

  def stage_recent_client_sms_response?(stage, within: 24.hours)
    return false unless stage_recent_inbound_sms?(stage)

    event = stage_latest_inbound_sms_event(stage)
    return false if event.blank?

    event_at = attention_sms_event_time(event)
    event_at.present? && event_at >= within.ago
  end

  def attention_sms_event?(event, direction:)
    item = event.to_h
    channel = item["channel"].to_s
    status = item["status"].to_s
    return false unless channel.blank? || channel == "sms"
    return false unless item["direction"].to_s == direction.to_s
    return false if status.in?(%w[failed canceled cancelled])

    item["body"].to_s.squish.present?
  end

  def attention_sms_event_time(event)
    item = event.to_h
    parse_event_time(item["created_at"].presence || item["at"].presence || item["timestamp"].presence)
  end

  def stage_first_sms_sent?(stage)
    stage_sms_events_after_reset(stage).any? do |event|
      event = event.to_h
      next false unless event["channel"].to_s == "sms"
      next false unless event["direction"].to_s == "outbound"

      !event["status"].to_s.in?(%w[failed canceled])
    end
  end

  def stage_sms_autopilot_enabled?(stage)
    ActiveModel::Type::Boolean.new.cast(stage.metadata.to_h["sms_autopilot_enabled"])
  end

  def stage_sms_background_drafting?(stage)
    metadata = stage.metadata.to_h
    last_status = metadata["comms_command_last_status"].to_s
    background_status = metadata["comms_command_background_status"].to_s
    return false unless last_status == "drafting" || background_status.in?(%w[queued running pending claimed])

    background_at = begin
      Time.zone.parse(metadata["comms_command_background_at"].to_s)
    rescue StandardError
      nil
    end
    if background_status.in?(%w[queued running pending claimed]) && (background_at.blank? || background_at > 8.minutes.ago)
      return true
    end

    question_id = metadata["comms_command_background_question_id"].presence ||
      metadata.dig("comms_command_sms_draft", "autos_question_id").presence
    return false if question_id.blank? || !defined?(AutosQuestion)

    question = AutosQuestion.find_by(id: question_id)
    return false if question.blank?
    return false unless question.metadata.to_h["surface"].to_s == "comms_sms_draft"
    return false if question.created_at < 8.minutes.ago

    last_error = question.metadata.to_h.dig("local_worker", "last_error").to_s
    return false if last_error.present? && question.updated_at < 30.seconds.ago

    !question.status.to_s.in?(%w[answered failed canceled complete completed])
  end

  def stage_sms_draft_progress_signals(stage)
    metadata = stage.metadata.to_h
    draft = metadata["comms_command_sms_draft"].to_h
    question = stage_sms_draft_question(metadata)
    retry_count = [
      metadata["sms_guardrail_retry_count"],
      draft["guardrail_retry_count"]
    ].map(&:to_i).max.to_i
    retry_limit = ENV.fetch("WIZWIKI_COMMS_GUARDRAIL_RETRY_LIMIT", "15").to_i.clamp(0, 15)
    attempt = retry_count + 1
    status = metadata["sms_reply_job_status"].presence ||
      metadata["comms_command_background_status"].presence ||
      "draft_pending"
    background_status = metadata["comms_command_background_status"].presence
    gate = [
      draft["sms_quality_gate"].presence,
      ActiveModel::Type::Boolean.new.cast(draft["ask_quality_gate"]) ? "ask gate" : nil
    ].compact.join(" / ").presence
    reason = [
      metadata["sms_guardrail_retry_reason"],
      draft["guardrail_retry_reason"],
      draft["error"],
      metadata["comms_command_background_error"],
      metadata["sms_autopilot_last_error"]
    ].compact_blank.first
    rag = stage_sms_draft_rag_trace(question, metadata)
    latest_inbound_at = stage_latest_inbound_sms_event(stage).to_h["created_at"].presence
    current_started_at = metadata["comms_command_background_at"].presence ||
      metadata["sms_reply_job_queued_at"].presence ||
      draft["created_at"].presence
    queued_at = metadata["sms_reply_job_queued_at"].presence || metadata["comms_command_background_at"].presence
    question_metadata = question.present? ? question.metadata.to_h : {}
    source = [
      draft["provider"].presence || question_metadata.dig("local_worker", "provider").presence,
      draft["model"].presence || question_metadata.dig("local_worker", "model").presence || metadata["sms_writer_model"].presence
    ].compact_blank.join(" // ")

    [
      { "label" => "attempt", "value" => "#{attempt}/#{retry_limit + 1}" },
      { "label" => "time", "value" => stage_sms_progress_time_line(latest_inbound_at, current_started_at, queued_at) },
      { "label" => "job", "value" => [human_progress_value(status), background_status.present? && background_status != status ? "queue #{human_progress_value(background_status)}" : nil, question.present? ? "q##{question.id} #{human_progress_value(question.status)}" : nil].compact_blank.join(" // ") },
      { "label" => "rag", "value" => [rag["route"], rag["fine_training"], rag["current_next_text_skipped"].present? ? "stale draft skipped" : nil].compact_blank.join(" // ").presence || "training context loading" },
      { "label" => "gate", "value" => human_progress_note(gate.presence || reason.presence || source.presence || "waiting on customer-facing body") }
    ].compact_blank.first(5)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] sms draft progress signals failed stage=#{stage&.id} #{error.class}: #{error.message}")
    []
  end

  def stage_sms_draft_question(metadata)
    question_id = metadata["comms_command_background_question_id"].presence ||
      metadata.dig("comms_command_sms_draft", "autos_question_id").presence
    return if question_id.blank? || !defined?(AutosQuestion)

    AutosQuestion.find_by(id: question_id)
  end

  def stage_sms_draft_rag_trace(question, metadata)
    qmd = question.present? ? question.metadata.to_h : {}
    trace = qmd["rag_trace"].to_h
    return trace if trace.present?

    retrieval = qmd["retrieval"].to_h
    query = retrieval["query"].to_s.squish
    route = query[/\bRoute:\s*([A-Z_]+)/, 1].presence || metadata["product_interest_code"].presence || qmd["model_lane"].presence
    docs = qmd["fine_training_documents"].to_i
    chunks = qmd["fine_training_chunks"].to_i
    {
      "route" => route,
      "fine_training" => (docs.positive? || chunks.positive? ? "#{docs} docs / #{chunks} chunks" : nil),
      "current_next_text_skipped" => qmd.dig("rag_trace", "current_next_text_skipped")
    }.compact_blank
  end

  def stage_sms_progress_time_line(total_started_at, current_started_at, queued_at)
    [
      total_started_at.present? ? "total #{progress_duration_from(total_started_at)}" : nil,
      current_started_at.present? ? "current #{progress_duration_from(current_started_at)}" : nil,
      queued_at.present? ? "queued #{progress_duration_from(queued_at)}" : nil
    ].compact_blank.join(" // ").presence || "starting"
  end

  def progress_duration_from(started_at)
    started = Time.zone.parse(started_at.to_s)
    seconds = [(Time.current - started).to_i, 0].max
    minutes, remainder = seconds.divmod(60)
    "#{minutes.to_s.rjust(2, '0')}:#{remainder.to_s.rjust(2, '0')}"
  rescue StandardError
    "00:00"
  end

  def human_progress_value(value)
    value.to_s.tr("_", " ").squish
  end

  def human_progress_note(value)
    text = human_progress_value(value)
    return if text.blank?
    return "simulator rejected non-customer-facing draft" if text.match?(/non-customer-facing worker reply/i)
    return "retrying after SMS guardrail feedback" if text.match?(/guardrail retry|retrying after/i)

    text.truncate(110, separator: " ")
  end

  def stage_sms_do_not_contact?(stage)
    metadata = stage.metadata.to_h
    metadata["comms_board_state"].to_s == "opt_out" ||
      ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) ||
      metadata["sms_do_not_contact_at"].present? ||
      metadata["comms_command_last_status"].to_s == "do_not_contact"
  end

  def stage_link_sent?(stage)
    metadata = stage.metadata.to_h
    return true if metadata["shopify_link_sent_at"].present? || metadata["comms_link_reached_at"].present?

    shopify_links = metadata["shopify_links"].respond_to?(:to_h) ? metadata["shopify_links"].to_h : {}
    links = [
      metadata["shopify_link"].to_s.squish,
      shopify_links.values
    ].flatten.compact_blank.map(&:to_s)

    stage_sms_events_after_reset(stage).any? do |event|
      event = event.to_h
      next false unless event["channel"].to_s == "sms"
      next false unless event["direction"].to_s == "outbound"
      next false if event["status"].to_s.in?(%w[failed canceled])

      body = event["body"].to_s
      links.any? { |link| link.present? && body.include?(link) } ||
        body.match?(%r{https?://\S*(?:shopify|shop\.wizwikimarketing|wizwikimarketing\.com/products)\S*}i)
    end
  end

  def stage_am_support?(stage)
    metadata = stage.metadata.to_h
    metadata["sms_autopilot_slack_human_requested_at"].present? ||
      metadata["sms_autopilot_slack_completion_without_purchase_at"].present? ||
      metadata["sms_autopilot_slack_handoff_at"].present? ||
      metadata["comms_support_state"].to_s == "am_support" ||
      metadata["comms_command_last_status"].to_s.in?(%w[human_requested account_manager_support am_support]) ||
      metadata["comms_route_claim_reason"].to_s.match?(/\b(human_requested|account_manager_answer_needed)\b/)
  end

  def stage_last_sms_at(stage)
    event = stage_last_sms_event(stage)
    parse_event_time(event.to_h["created_at"])
  end

  def stage_last_sms_label(stage)
    time = stage_last_sms_at(stage)
    return "no text yet" if time.blank?

    "#{helpers.distance_of_time_in_words(time, Time.current)} ago"
  rescue StandardError
    "recently"
  end

  def stage_last_sms_event(stage)
    Array(stage.metadata.to_h["sms_thread"]).reverse_each do |event|
      event = event.to_h
      next unless event["channel"].to_s == "sms"
      next if event["status"].to_s.in?(%w[failed canceled])

      return event
    end
    nil
  end

  def stage_follow_up_timer(stage)
    settings = comms_follow_up_settings
    metadata = stage.metadata.to_h
    zone = ActiveSupport::TimeZone[settings["timezone"].presence || "America/Chicago"] || Time.zone
    now = Time.current
    local_now = now.in_time_zone(zone)
    frequency = settings["frequency_hours"].to_i.clamp(2, 168)
    duration = settings["duration_days"].to_i.clamp(1, 90)
    max_daily = settings["max_per_day"].to_i.clamp(1, 12)
    quick_limit = settings["quick_nudge_count"].to_i.clamp(0, 6)
    quick_interval = settings["quick_nudge_minutes"].to_i.clamp(5, 240).minutes

    payload = ->(state, label, detail, due_at = nil) do
      {
        state: state,
        label: label,
        detail: detail,
        due_at: due_at&.iso8601,
        frequency_hours: frequency,
        max_per_day: max_daily,
        quick_nudge_count: quick_limit,
        quick_nudge_minutes: quick_interval.to_i / 60
      }
    end

    return payload.call("off", "FOLLOW-UP OFF", "Global automation is disabled.") unless ActiveModel::Type::Boolean.new.cast(settings["enabled"])
    return payload.call("blocked", "DO NOT CONTACT", "Customer opted out. Follow-ups are locked.") if stage_sms_do_not_contact?(stage)
    return payload.call("complete", "COMPLETE", "Discovery is complete. No stale follow-up needed.") if stage_autopilot_complete?(metadata)
    return payload.call("paused", "AUTOPILOT OFF", "Turn on autopilot before scheduled follow-ups.") unless stage_sms_autopilot_enabled?(stage)
    return payload.call("blocked", "NO PHONE", "Add/select a phone number before follow-ups.") if stage_selected_phone(stage)["value"].to_s.blank?

    events = follow_up_sms_events(metadata)
    return payload.call("idle", "NO THREAD", "Send the first SMS to start the stale timer.") if events.blank?

    last_event = events.reverse.find { |event| event["status"].to_s != "failed" }
    return payload.call("idle", "NO ACTIVITY", "Waiting for usable SMS activity.") if last_event.blank?
    return payload.call("operator", "CUSTOMER REPLIED", "Open the thread or let autopilot answer before a stale follow-up.") if last_event["direction"].to_s == "inbound"
    return payload.call("waiting", "WAITING", "Timer starts after the last outbound SMS.") unless last_event["direction"].to_s == "outbound"
    return payload.call("waiting", "NO QUESTION", "Last outbound did not ask for a reply, so no stale follow-up is due.") unless follow_up_outbound_question?(last_event)

    first_outbound_at = follow_up_first_outbound_time(events)
    if first_outbound_at.present? && first_outbound_at < (now - duration.days)
      return payload.call("expired", "WINDOW EXPIRED", "Past the #{duration}-day follow-up duration.")
    end

    today_count = follow_up_daily_count(metadata, local_now)
    quick_follow_ups_sent = follow_ups_since_last_inbound(events)
    quick_phase = quick_follow_ups_sent < quick_limit
    interval = quick_phase ? quick_interval : frequency.hours
    phase_detail = if quick_phase
      "Post-last-message nudge #{quick_follow_ups_sent + 1}/#{quick_limit}."
    else
      "Daily cadence after #{quick_limit} post-last-message nudges."
    end

    if !quick_phase && today_count >= max_daily
      next_window = follow_up_window_open_at_or_after((local_now + 1.day).beginning_of_day, settings, zone)
      return payload.call("capped", "DAILY CAP #{today_count}/#{max_daily}", "#{today_count}/#{max_daily} follow-ups sent today.", next_window)
    end

    last_activity_at = parse_event_time(last_event["created_at"]) || stage.updated_at || now
    raw_due_at = last_activity_at + interval
    effective_due_at = follow_up_window_open_at_or_after([raw_due_at, now].max, settings, zone)

    if raw_due_at <= now && follow_up_within_window?(local_now, settings)
      payload.call("due", "STALE NOW", "#{phase_detail} Eligible on the next follow-up pass.")
    elsif raw_due_at <= now
      payload.call("outside_window", "WINDOW CLOSED", "#{phase_detail} Stale, sends when the CST window opens.", effective_due_at)
    else
      payload.call("countdown", "STALE IN #{helpers.distance_of_time_in_words(now, effective_due_at)}", "#{phase_detail} Last outbound question is waiting on customer.", effective_due_at)
    end
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] follow-up timer failed stage=#{stage&.id} #{error.class}: #{error.message}")
    { state: "unknown", label: "TIMER UNKNOWN", detail: "Refresh or check logs.", due_at: nil }
  end

  def selected_option(stage, options_key, selected_key)
    metadata = stage.metadata.to_h
    selected_id = metadata[selected_key].to_s
    options = Array(metadata[options_key])
    selected = options.find { |option| option.to_h["id"].to_s == selected_id }
    fallback = options.first
    candidate = selected || fallback
    candidate.respond_to?(:to_h) ? candidate.to_h : {}
  end

  def tel_href_for(value)
    phone = value.to_s.squish.gsub(/[^\d+]/, "")
    phone.present? ? "tel:#{phone}" : nil
  end

  def append_stage_event!(stage, key, payload)
    metadata = stage.metadata.to_h.deep_dup
    thread = Array(metadata[key]).last(50)
    thread << payload
    pending_metadata = metadata.merge(key => thread)
    processing = processing_payload(stage, metadata: pending_metadata, latest_body: payload["body"])
    thread[-1] = thread.last.to_h.merge(
      "processing_code" => processing["processing_code"],
      "processing_label" => processing["processing_label"]
    ).compact_blank
    stage.update!(
      status: payload.fetch("status") == "failed" ? "aircall_failed" : "aircall_sent",
      generated_at: Time.current,
      metadata: metadata.merge(
        key => thread,
        "comms_command_last_channel" => payload["channel"],
        "comms_command_last_status" => payload["status"],
        "comms_command_last_at" => Time.current.iso8601,
        "comms_command_last_error" => payload["error"].presence
      ).merge(processing).merge(listener_payload(payload)).merge(checkout_link_sent_payload(metadata, payload))
    )
    run_post_send_supervisor!(stage.reload, outbound_event: thread.last, source: "comms_commands_append_stage_event")
    send_language_preference_notice_if_needed!(stage.reload, payload: payload)
  end

  def send_language_preference_notice_if_needed!(stage, payload:)
    return false unless defined?(Comms::SmsLanguageSupport)
    return false unless payload.to_h["channel"].to_s == "sms"
    return false unless payload.to_h["direction"].to_s == "outbound"
    return false unless payload.to_h["status"].to_s.in?(%w[queued accepted scheduled sending sent delivered sent])
    stage.reload
    metadata = stage.metadata.to_h.deep_dup
    return false unless Comms::SmsLanguageSupport.should_send_preference_notice?(metadata, stage: stage)

    body = Comms::SmsLanguageSupport.preference_notice_body
    profile = twilio_sender_profile
    result = Comms::SmsProvider.deliver!(
      to: payload["to"].to_s,
      body: body,
      from_number: payload["from"].presence || profile["from_number"].presence,
      messaging_service_sid: profile["messaging_service_sid"].presence
    )
    append_language_preference_notice!(stage, body: body, to: payload["to"], from: result.to_h["from"].presence || payload["from"], provider_result: result)
    true
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] language preference notice failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def append_language_preference_notice!(stage, body:, to:, from:, provider_result:)
    metadata = stage.reload.metadata.to_h.deep_dup
    thread = Array(metadata["sms_thread"]).last(50)
    event = {
      "id" => SecureRandom.uuid,
      "channel" => "sms",
      "direction" => "outbound",
      "status" => "sent",
      "to" => to.to_s,
      "from" => provider_result.to_h["from"].presence || from.to_s,
      "body" => body,
      "provider" => provider_result.to_h["provider"].presence || "twilio",
      "provider_message_id" => provider_result.to_h["sid"].presence,
      "provider_status" => provider_result.to_h["status"].presence,
      "user_id" => current_user.id,
      "user_name" => current_user.display_name,
      "language_preference_notice" => true,
      "created_at" => Time.current.iso8601
    }.compact_blank
    thread << event
    stage.update!(
      status: "aircall_sent",
      generated_at: Time.current,
      metadata: metadata.merge(
        "sms_thread" => thread,
        "sms_language_preference_notice_sent_at" => Time.current.iso8601,
        "sms_language_preference_notice_body" => body,
        "sms_language_preference_notice_sid" => event["provider_message_id"],
        "sms_listener_active" => true,
        "sms_listener_until" => 7.days.from_now.iso8601,
        "sms_listener_from" => event["from"],
        "sms_listener_to" => to,
        "sms_listener_last_outbound_sid" => event["provider_message_id"],
        "sms_listener_last_outbound_at" => Time.current.iso8601
      ).compact_blank
    )
  end

  def run_post_send_supervisor!(stage, outbound_event:, source:)
    return unless defined?(Comms::PostSendSupervisor)
    return unless outbound_event.to_h["channel"].to_s == "sms"
    return unless outbound_event.to_h["direction"].to_s == "outbound"
    return unless outbound_event.to_h["status"].to_s.in?(%w[queued accepted scheduled sending sent delivered])

    Comms::PostSendSupervisor.call(
      stage: stage,
      outbound_event: outbound_event,
      source: source,
      sender_profile: twilio_sender_profile
    )
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] post-send supervisor failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def mark_sms_draft_sent!(stage, body, clear_any: false)
    sent_body = body.to_s.squish
    return if sent_body.blank?

    metadata = stage.reload.metadata.to_h.deep_dup
    draft_body = metadata["comms_command_sms_draft_body"].to_s.squish
    return unless clear_any || normalize_sms_body_for_compare(draft_body) == normalize_sms_body_for_compare(sent_body)

    stage.update!(
      metadata: metadata.merge(
        "comms_command_sms_draft_body" => nil,
        "comms_command_sms_draft" => nil,
        "comms_command_sms_sent_draft_at" => Time.current.iso8601,
        "comms_command_sms_sent_draft_sha1" => Digest::SHA1.hexdigest(sent_body)
      ).compact_blank
    )
  end

  def supersede_inflight_sms_draft!(stage, reason:)
    return if stage.blank?

    now = Time.current
    canceled_question_ids = cancel_inflight_sms_draft_questions!(stage, reason: reason, at: now)
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      generated_at: now,
      metadata: metadata.merge(
        "sms_reply_generation" => SecureRandom.uuid,
        "sms_reply_generation_at" => now.iso8601,
        "sms_reply_generation_superseded_at" => now.iso8601,
        "sms_reply_generation_superseded_reason" => reason,
        "sms_reply_generation_superseded_by_user_id" => current_user&.id,
        "sms_reply_generation_superseded_by" => current_user&.display_name,
        "sms_reply_generation_superseded_question_ids" => canceled_question_ids.presence,
        "comms_command_background_status" => "operator_override",
        "comms_command_background_at" => now.iso8601,
        "sms_reply_job_status" => "operator_override",
        "ask_autopilot_pending_started_at" => nil,
        "ask_autopilot_pending_phase" => nil
      ).compact_blank
    )
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] failed to supersede SMS draft stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def cancel_inflight_sms_draft_questions!(stage, reason:, at:)
    return [] unless defined?(AutosQuestion)

    canceled = []
    AutosQuestion
      .where(status: %w[queued claimed])
      .where("metadata ->> 'surface' = ?", "comms_sms_draft")
      .where("metadata ->> 'comms_stage_id' = ?", stage.id.to_s)
      .find_each do |question|
        question_metadata = question.metadata.to_h.deep_dup
        worker = question_metadata["local_worker"].to_h
        worker.merge!(
          "status" => "canceled",
          "canceled_at" => at.iso8601,
          "cancel_reason" => reason
        )
        question.update_columns(
          status: "canceled",
          metadata: question_metadata.merge(
            "local_worker" => worker,
            "canceled_at" => at.iso8601,
            "cancel_reason" => reason
          ),
          updated_at: at
        )
        canceled << question.id
      end
    canceled
  end

  def checkout_link_sent_payload(metadata, payload)
    return {} unless payload["channel"].to_s == "sms"
    return {} unless payload["direction"].to_s == "outbound"
    return {} unless payload["status"].to_s == "sent"

    body = payload["body"].to_s
    configured_link = metadata["shopify_link"].to_s.squish
    link_sent = if configured_link.present?
      body.include?(configured_link)
    else
      body.match?(%r{https?://\S*(?:shopify|shop\.wizwikimarketing|wizwikimarketing\.com/products)\S*}i)
    end
    return {} unless link_sent

    {
      "shopify_link_sent_at" => metadata["shopify_link_sent_at"].presence || Time.current.iso8601,
      "comms_link_reached_at" => metadata["comms_link_reached_at"].presence || Time.current.iso8601
    }
  end

  def event_payload(channel:, direction:, status:, body:, to:, subject: nil, provider_result: nil, error: nil)
    {
      "id" => SecureRandom.uuid,
      "channel" => channel,
      "direction" => direction,
      "status" => status,
      "to" => to.to_s,
      "subject" => subject.to_s.presence,
      "body" => body.to_s,
      "provider" => provider_result.to_h["provider"].presence || channel,
      "provider_message_id" => provider_result.to_h["sid"].presence || provider_result.to_h["message_id"].presence,
      "provider_status" => provider_result.to_h["status"].presence,
      "from" => provider_result.to_h["from"].presence,
      "error" => error.to_s.presence,
      "user_id" => current_user.id,
      "user_name" => current_user.display_name,
      "created_at" => Time.current.iso8601
    }.compact_blank
  end

  def twilio_sender_profile
    current_user.twilio_profile.to_h
  end

  def processing_payload(stage, metadata:, latest_body:)
    DealReports::CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: latest_body)
  end

  def listener_payload(payload)
    return {} unless payload["channel"].to_s == "sms"
    return {} unless payload["direction"].to_s == "outbound"
    return {} unless payload["status"].to_s == "sent"

    {
      "sms_listener_active" => true,
      "sms_listener_started_at" => Time.current.iso8601,
      "sms_listener_until" => 7.days.from_now.iso8601,
      "sms_listener_from" => payload["from"].presence || Comms::SmsProvider.public_status(user: current_user)[:sender_number],
      "sms_listener_to" => payload["to"],
      "sms_listener_last_outbound_sid" => payload["provider_message_id"],
      "sms_listener_last_outbound_at" => Time.current.iso8601
    }.compact_blank
  end

  def send_autopilot_reply_to_pending_inbound!(stage)
    reply_key = nil
    pending = pending_inbound_sms(stage)
    return false if pending.blank?

    from = pending["from"].to_s
    body = pending["body"].to_s
    return false if from.blank? || body.blank? || stop_intent?(body)
    handoff_result = handoff_pending_inbound_if_needed!(stage, body, source: "manual_autopilot_enable")
    return handoff_result if handoff_result

    reply_key = Comms::AutopilotReplyLock.reserve!(
      stage,
      inbound_sid: pending["provider_message_id"],
      inbound_body: body,
      from: from,
      source: "manual_autopilot_enable"
    )
    return false if reply_key.blank?

    result = DealReports::CommsDraftWriter.call(
        stage: stage.reload,
        user: current_user,
        operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: body, from: from),
        wait_seconds: ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_ENABLE_WAIT_SECONDS", "75").to_i,
        writer_model: stage_sms_writer_model(stage),
        challenger_model: stage_sms_challenger_model(stage)
    )
    raw_reply = result["body"].to_s.strip
    reply = safe_customer_sms_body(raw_reply)
    if raw_reply.present? && reply.blank?
      Rails.logger.warn("[CommsCommands] blocked unsafe autopilot pending reply stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_reply)}")
    end
    if reply.blank?
      Comms::AutopilotReplyLock.clear!(stage, key: reply_key)
      return false
    end

    reply = sms_delivery_body_for_stage(stage, reply)
    delivery = Comms::SmsProvider.deliver!(
      to: from,
      body: reply,
      from_number: twilio_sender_profile["from_number"],
      messaging_service_sid: twilio_sender_profile["messaging_service_sid"]
    )
    append_stage_event!(
      stage,
        "sms_thread",
      event_payload(channel: "sms", direction: "outbound", status: "sent", body: reply, to: from, provider_result: delivery).merge(sms_delivery_language_event_payload).merge(
        "autopilot" => true,
        "autopilot_reply_to_sid" => reply_key,
        "autopilot_reply_key" => reply_key,
        "draft_provider" => result["provider"],
        "draft_model" => result["model"],
        "draft_source" => result["draft_source"],
        "writer_model" => result["writer_model"],
        "writer_model_label" => result["writer_model_label"]
      ).compact_blank
    )
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
        "sms_autopilot_last_sent_at" => Time.current.iso8601,
        "sms_autopilot_last_reply_to_sid" => reply_key,
        "sms_autopilot_last_error" => nil
      )
    )
    Comms::AutopilotReplyLock.clear!(stage.reload, key: reply_key)
    :replied
  rescue StandardError => error
    Comms::AutopilotReplyLock.clear!(stage, key: reply_key) if reply_key.present?
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_last_error" => error.message,
        "sms_autopilot_last_error_at" => Time.current.iso8601
      )
    )
    Rails.logger.warn("[CommsCommands] autopilot pending reply failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def send_autopilot_staged_next_text!(stage)
    reply_key = nil
    return false if stage_sms_do_not_contact?(stage)
    return false if ActiveModel::Type::Boolean.new.cast(stage.metadata.to_h["sms_sending_disabled"])
    return false if stop_intent?(latest_inbound_sms_body(stage).to_s)

    pending = pending_inbound_sms(stage)
    if pending.present?
      handoff_result = handoff_pending_inbound_if_needed!(stage, pending["body"].to_s, source: "manual_autopilot_staged_next_text")
      return handoff_result if handoff_result
    end

    phone = pending.to_h["from"].to_s.presence || stage_selected_phone(stage)["value"].to_s.strip
    raise ArgumentError, "recipient phone required before Thumper autopilot can start" if phone.blank?
    if pending.present?
      reply_key = Comms::AutopilotReplyLock.reserve!(
        stage,
        inbound_sid: pending["provider_message_id"],
        inbound_body: pending["body"],
        from: pending["from"],
        source: "manual_autopilot_staged_next_text"
      )
      return false if reply_key.blank?
    end

    raw_body = stage_sms_body(stage).to_s.strip.presence
    body = safe_customer_sms_body(raw_body)
    if raw_body.present? && body.blank?
      Rails.logger.warn("[CommsCommands] blocked unsafe staged autopilot SMS stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_body)}")
    end
    if body.blank?
      Comms::AutopilotReplyLock.clear!(stage, key: reply_key) if reply_key.present?
      return false
    end

    supersede_inflight_sms_draft!(stage, reason: "autopilot_sent_staged_next_text")
    body = sms_delivery_body_for_stage(stage, body)
    delivery = Comms::SmsProvider.deliver!(
      to: phone,
      body: body,
      from_number: twilio_sender_profile["from_number"],
      messaging_service_sid: twilio_sender_profile["messaging_service_sid"]
    )
    append_stage_event!(
      stage,
      "sms_thread",
      event_payload(channel: "sms", direction: "outbound", status: "sent", body: body, to: phone, provider_result: delivery).merge(sms_delivery_language_event_payload).merge(
        "autopilot" => true,
        "autopilot_start" => true,
        "autopilot_staged_next_text" => true,
        "autopilot_reply_to_sid" => reply_key.presence || pending.to_h["provider_message_id"].presence,
        "autopilot_reply_key" => reply_key.presence,
        "draft_provider" => stage.metadata.to_h.dig("comms_command_sms_draft", "provider").presence || "operator/staged_next_text",
        "draft_model" => stage.metadata.to_h.dig("comms_command_sms_draft", "model").presence || "reviewed-next-text"
      ).compact_blank
    )
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
        "sms_autopilot_last_sent_at" => Time.current.iso8601,
        "sms_autopilot_last_reply_to_sid" => pending.to_h["provider_message_id"].presence || metadata["sms_autopilot_last_reply_to_sid"],
        "sms_autopilot_last_error" => nil,
        "sms_autopilot_started_with_opener" => false,
        "sms_autopilot_started_with_data_grab" => false,
        "sms_autopilot_started_with_next_text" => true
      ).compact_blank
    )
    Comms::AutopilotReplyLock.clear!(stage.reload, key: reply_key) if reply_key.present?
    pending.present? ? :staged_reply : :staged
  rescue StandardError => error
    Comms::AutopilotReplyLock.clear!(stage, key: reply_key) if reply_key.present?
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_last_error" => error.message,
        "sms_autopilot_last_error_at" => Time.current.iso8601
      )
    )
    Rails.logger.warn("[CommsCommands] autopilot staged next text failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def send_autopilot_start_text!(stage)
    return false if stage_sms_do_not_contact?(stage)
    return false if ActiveModel::Type::Boolean.new.cast(stage.metadata.to_h["sms_sending_disabled"])
    return false if stop_intent?(latest_inbound_sms_body(stage).to_s)

    phone = stage_selected_phone(stage)["value"].to_s.strip
    raise ArgumentError, "recipient phone required before Thumper autopilot can start" if phone.blank?

    opening_thread = !stage_first_sms_sent?(stage)
    result = if opening_thread
      {
        "body" => autopilot_opening_body(stage),
        "provider" => "deterministic/autopilot_opening",
        "model" => "autos-opener"
      }
    else
      DealReports::CommsDraftWriter.call(
        stage: stage.reload,
        user: current_user,
        operator_prompt: Comms::SmsOperatorPrompt.proactive_start(
          objective: stage.metadata.to_h["sms_autopilot_objective"].presence || default_autopilot_objective
        ),
        wait_seconds: ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_START_WAIT_SECONDS", "35").to_i,
        writer_model: stage_sms_writer_model(stage),
        challenger_model: stage_sms_challenger_model(stage)
      )
    end

    raw_body = result.to_h["body"].to_s.strip.presence
    body = safe_customer_sms_body(raw_body)
    if raw_body.present? && body.blank?
      Rails.logger.warn("[CommsCommands] blocked unsafe autopilot start SMS stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_body)}")
    end
    body ||= autopilot_opening_body(stage) if opening_thread
    raise ArgumentError, "opening SMS body required before Thumper autopilot can start" if body.blank?

    body = sms_delivery_body_for_stage(stage, body)
    delivery = Comms::SmsProvider.deliver!(
      to: phone,
      body: body,
      from_number: twilio_sender_profile["from_number"],
      messaging_service_sid: twilio_sender_profile["messaging_service_sid"]
    )
    append_stage_event!(
      stage,
      "sms_thread",
      event_payload(channel: "sms", direction: "outbound", status: "sent", body: body, to: phone, provider_result: delivery).merge(sms_delivery_language_event_payload).merge(
        "autopilot" => true,
        "autopilot_start" => true,
        "autopilot_opening" => opening_thread,
        "draft_provider" => result["provider"],
        "draft_model" => result["model"],
        "draft_source" => result["draft_source"],
        "writer_model" => result["writer_model"],
        "writer_model_label" => result["writer_model_label"]
      ).compact_blank
    )
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
        "sms_autopilot_last_sent_at" => Time.current.iso8601,
        "sms_autopilot_last_error" => nil,
        "sms_autopilot_started_with_opener" => opening_thread,
        "sms_autopilot_started_with_data_grab" => !opening_thread
      )
    )
    opening_thread ? :opened : :started
  rescue StandardError => error
    metadata = stage.reload.metadata.to_h.deep_dup
    stage.update!(
      metadata: metadata.merge(
        "sms_autopilot_last_error" => error.message,
        "sms_autopilot_last_error_at" => Time.current.iso8601
      )
    )
    Rails.logger.warn("[CommsCommands] autopilot start text failed stage=#{stage&.id} #{error.class}: #{error.message}")
    false
  end

  def autopilot_notice(enabled, result)
    return "Thumper autopilot paused for #{stage_company_name(@stage)}." unless enabled
    return "Thumper autopilot is listening for #{stage_company_name(@stage)}. It will not send the current NEXT TEXT; new inbound SMS can trigger automation." if result == :listening
    return "#{stage_company_name(@stage)} moved to AM support. Slack wall post queued." if result == :am_support
    return "Thumper autopilot started and sent the reviewed NEXT TEXT for #{stage_company_name(@stage)}." if result == :staged
    return "Thumper autopilot started and sent the reviewed NEXT TEXT reply for #{stage_company_name(@stage)}." if result == :staged_reply
    return "Thumper autopilot started and sent the first SMS for #{stage_company_name(@stage)}." if result == :opened
    return "Thumper autopilot started and sent a data-grab SMS for #{stage_company_name(@stage)}." if result == :started
    return "Thumper autopilot started and replied to the waiting SMS for #{stage_company_name(@stage)}." if result == :replied
    return "Thumper autopilot enabled and listening for #{stage_company_name(@stage)}." if stage_first_sms_sent?(@stage.reload)

    "Thumper autopilot enabled for #{stage_company_name(@stage)}, but no first SMS was sent. Check the selected phone number and SMS provider sender."
  end

  def handoff_pending_inbound_if_needed!(stage, body, source:)
    return false unless defined?(Comms::InboundSmsHandoff)
    return false unless Comms::InboundSmsHandoff.required?(body, stage: stage) ||
      Comms::InboundSmsHandoff.contact_collection_response?(stage.reload, body) ||
      Comms::InboundSmsHandoff.accepted_recent_contact_offer?(stage.reload, body)

    result = Comms::InboundSmsHandoff.call(stage: stage.reload, body: body, source: source)
    defer_stage_memory!(stage.reload)
    if ActiveModel::Type::Boolean.new.cast(result&.handled) ||
        ActiveModel::Type::Boolean.new.cast(result&.review_draft_saved)
      :am_support
    else
      false
    end
  end

  def bulk_autopilot_delay_seconds
    ENV.fetch("WIZWIKI_COMMS_RUN_ALL_DELAY_SECONDS", "12").to_f.clamp(0.0, 120.0)
  end

  def autopilot_error_notice(stage)
    error = stage.reload.metadata.to_h["sms_autopilot_last_error"].to_s.squish
    return "Thumper autopilot could not start for #{stage_company_name(stage)}." if error.blank?

    "Thumper autopilot could not start for #{stage_company_name(stage)}: #{error.truncate(220)}"
  end

  def pending_inbound_sms(stage)
    events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
    last_outbound_time = nil
    events.reverse_each do |event|
      next unless event["direction"].to_s == "outbound"

      last_outbound_time = parse_event_time(event["created_at"])
      break
    end

    events.reverse_each do |event|
      next unless event["direction"].to_s == "inbound"
      next if event["autopilot"].present?

      inbound_time = parse_event_time(event["created_at"])
      return event if last_outbound_time.blank? || inbound_time.blank? || inbound_time > last_outbound_time
      return nil
    end
    nil
  end

  def latest_inbound_sms_body(stage)
    Array(stage.metadata.to_h["sms_thread"]).reverse_each do |event|
      event = event.to_h
      next unless event["channel"].to_s == "sms"
      next unless event["direction"].to_s == "inbound"

      return event["body"].to_s
    end
    nil
  end

  def parse_event_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def stage_autopilot_complete?(metadata)
    metadata["sms_autopilot_completed_at"].present? ||
      metadata["sms_autopilot_completion_sent_at"].present? ||
      ActiveModel::Type::Boolean.new.cast(metadata.dig("comms_bot_state", "autopilot_complete"))
  end

  def follow_up_sms_events(metadata)
    Array(metadata["sms_thread"]).map(&:to_h).select { |event| event["channel"].to_s == "sms" }
  end

  def follow_up_first_outbound_time(events)
    event = events.find { |item| item["direction"].to_s == "outbound" && item["status"].to_s != "failed" }
    parse_event_time(event.to_h["created_at"])
  end

  def follow_up_daily_count(metadata, local_now)
    metadata["sms_follow_up_daily_counts"].to_h[local_now.to_date.iso8601].to_i
  end

  def follow_up_outbound_question?(event)
    body = event.to_h["body"].to_s.squish
    return true if body.include?("?")

    body.match?(/\b(?:can you|could you|would you|do you|are you|what|which|when|where|how many|how much|want me to|should i|does that|would that|is that)\b/i)
  end

  def follow_ups_since_last_inbound(events)
    latest_inbound_at = events.reverse_each.lazy.filter_map do |event|
      next unless event["direction"].to_s == "inbound"

      parse_event_time(event["created_at"])
    end.first

    events.count do |event|
      next false unless event["direction"].to_s == "outbound"
      next false unless ActiveModel::Type::Boolean.new.cast(event["follow_up"])

      event_time = parse_event_time(event["created_at"])
      latest_inbound_at.blank? || event_time.blank? || event_time > latest_inbound_at
    end
  end

  def follow_up_within_window?(local_time, settings)
    start_minutes = follow_up_window_minutes(settings["send_window_start"], "09:00")
    end_minutes = follow_up_window_minutes(settings["send_window_end"], "17:00")
    now_minutes = (local_time.hour * 60) + local_time.min

    if start_minutes <= end_minutes
      now_minutes >= start_minutes && now_minutes <= end_minutes
    else
      now_minutes >= start_minutes || now_minutes <= end_minutes
    end
  end

  def follow_up_window_open_at_or_after(time, settings, zone)
    local_time = time.in_time_zone(zone)
    return local_time if follow_up_within_window?(local_time, settings)

    start_minutes = follow_up_window_minutes(settings["send_window_start"], "09:00")
    end_minutes = follow_up_window_minutes(settings["send_window_end"], "17:00")
    now_minutes = (local_time.hour * 60) + local_time.min
    target_date = local_time.to_date

    if start_minutes <= end_minutes
      target_date += 1 if now_minutes > end_minutes
    elsif now_minutes > end_minutes && now_minutes < start_minutes
      # Same-day evening start for overnight windows.
      target_date = local_time.to_date
    end

    follow_up_time_for_date(zone, target_date, start_minutes)
  end

  def follow_up_window_minutes(value, fallback)
    text = value.to_s.match?(/\A(?:[01]?\d|2[0-3]):[0-5]\d\z/) ? value.to_s : fallback
    hour, minute = text.split(":").map(&:to_i)
    (hour * 60) + minute
  end

  def follow_up_time_for_date(zone, date, minutes)
    zone.local(date.year, date.month, date.day, minutes / 60, minutes % 60)
  end

  def stop_intent?(body)
    text = body.to_s.downcase.squish
    return false if text.blank?
    return true if text.match?(/\A(?:stop|unsubscribe|quit|end|cancel)\s*[.!]?\z/i)

    text.match?(/\b(?:unsubscribe|opt\s*-?\s*out|remove me|take me off)\b/i) ||
      text.match?(/\b(?:do not|don't|dont)\s+(?:text|message|contact|sms)\b/i) ||
      text.match?(/\b(?:stop|quit|end|cancel)\s+(?:texting|messaging|messages?|texts?|sms)\b/i)
  end

  def default_autopilot_objective
    Thumper::VoiceGuide.autopilot_objective
  end

  def autopilot_opening_body(stage)
    first_name = autopilot_contact_first_name(stage)
    Thumper::VoiceGuide.starter_sms(first_name, product_lane: comms_opening_product_lane(stage))
  end

  def autopilot_contact_first_name(stage)
    name = stage_selected_contact(stage)["name"].to_s.squish
    name = stage.metadata.to_h["captured_contact_name"].to_s.squish if generic_comms_identity?(name)
    comms_first_name(name)
  end

  def comms_opening_sms_body(contact_name, stage: nil, product_lane: nil)
    first_name = comms_first_name(contact_name)
    lane = product_lane.presence || comms_opening_product_lane(stage)

    Thumper::VoiceGuide.starter_sms(first_name, product_lane: lane)
  end

  def comms_opening_product_lane(stage)
    metadata = stage&.metadata
    metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
    return if metadata.blank?
    return if stage.present? && ActiveModel::Type::Boolean.new.cast(metadata["sms_discovery_reset"]) && stage_sms_events_after_reset(stage).none? { |event| event.to_h["direction"].to_s == "inbound" }

    [
      metadata["product_interest_code"],
      metadata["product_interest_label"],
      metadata["product_interest"],
      metadata["sms_captured_product_interest"],
      metadata.dig("comms_bot_state", "route_code"),
      metadata.dig("comms_bot_state", "product_interest_code"),
      metadata.dig("comms_bot_state", "product_interest"),
      metadata.dig("sms_lane_monitor", "route_code")
    ].compact_blank.first
  end

  def comms_first_name(value)
    text = value.to_s.squish
    return if generic_comms_identity?(text)
    return if text.match?(/@/)

    first_name = text.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
    return if first_name.blank? || first_name.length < 2

    first_name
  end

  def generic_comms_identity?(value)
    text = value.to_s.squish.downcase
    text.blank? ||
      %w[wizwiki\ comms sample\ comms manual\ comms choose\ in\ lab contact customer].include?(text) ||
      text.match?(/\A(?:wizwiki\s*)?comms\b/) ||
      text.match?(/\Asample\b/)
  end

  def distinct_comms_company_name(contact_name, company_name)
    company = company_name.to_s.squish.presence
    return if company.blank? || generic_comms_identity?(company)

    contact_key = comms_identity_key(contact_name)
    company_key = comms_identity_key(company)
    return if contact_key.present? && company_key.present? && contact_key == company_key

    company
  end

  def comms_identity_key(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, "").presence
  end

  def manual_crm_record!(label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, row_number: nil, raw_row: nil, claim_by_current_user: false)
    company_name = distinct_comms_company_name(contact_name, company_name)
    source_uid = manual_comms_source_uid(phone: phone, email: email)
    record = current_organization.crm_records.find_by(source: "manual_comms", source_uid: source_uid) ||
      find_manual_comms_record(phone: phone, email: email) ||
      current_organization.crm_records.new(source: "manual_comms", source_uid: source_uid)
    base_properties = clean_manual_comms_properties(record.properties.to_h, source: source)
    record.assign_attributes(
      record_type: "contact",
      status: "open",
      name: label,
      phone: phone.presence || record.phone,
      email: email.presence || record.email,
      stage: "manual_comms",
      properties: base_properties.merge(
        "manual_comms" => true,
        "manual_comms_created_by_user_id" => current_user.id,
        "manual_comms_contact_value" => [phone, email].compact.join(" / "),
        "manual_comms_contact_keys" => manual_comms_contact_keys(phone: phone, email: email),
        "manual_comms_contact_phone_digits" => normalized_phone_digits(phone),
        "manual_comms_contact_email" => normalized_email(email),
        "manual_comms_contact_name" => contact_name,
        "manual_comms_company_name" => company_name,
        "industry" => industry,
        "sms_captured_industry" => industry,
        "manual_comms_zip" => zip,
        "manual_comms_notes" => notes,
        "manual_comms_source" => source,
        "manual_comms_hubspot_lead" => lead_attrs.to_h.compact_blank,
        "contact_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
        "contact_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
        "hubspot_lead_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
        "hubspot_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
        "manual_comms_import_id" => import_id,
        "manual_comms_import_title" => import_title,
        "manual_comms_import_status_key" => import_status_key,
        "manual_comms_import_row" => row_number,
        "manual_comms_raw_row" => raw_row
      ).compact_blank
    )
    record.owner = current_user if claim_by_current_user
    record.save!
    record
  end

  def clean_manual_comms_properties(properties, source:)
    return properties if source.present?

    properties.except(
      "manual_comms_source",
      "manual_comms_import_id",
      "manual_comms_import_title",
      "manual_comms_import_status_key",
      "manual_comms_import_row",
      "manual_comms_raw_row",
      "owner_queue_source_uid",
      "owner_queue_refreshed_at"
    )
  end

  def manual_stage!(record:, label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, row_number: nil, raw_row: nil, claim_by_current_user: false, duplicate_checked: false)
    was_new = false
    metadata = manual_stage_metadata(label: label, phone: phone, email: email, contact_name: contact_name, company_name: company_name, industry: industry, zip: zip, notes: notes, source: source, lead_attrs: lead_attrs, import_id: import_id, import_title: import_title, import_status_key: import_status_key, row_number: row_number, raw_row: raw_row, claim_by_current_user: claim_by_current_user)
    stage = if source.present?
      record.crm_record_artifacts.where(
        organization: current_organization,
        artifact_type: "comm_staging"
      )
        .where.not(status: "archived")
        .where("metadata ->> 'stage_type' = ?", "manual_comms")
        .order(updated_at: :desc)
        .first
    end
    stage ||= record.crm_record_artifacts.build(
      organization: current_organization,
      user: current_user,
      artifact_type: "comm_staging",
      title: "WIZWIKI COMMS: #{label}"
    )
    if !duplicate_checked && (duplicate_stage = duplicate_active_comms_stage(phone: phone, email: email, except_stage: stage))
      raise Comms::ContactDeduper::DuplicateContactError, "duplicate phone/email already staged in COMMS block ##{duplicate_stage.id}"
    end
    was_new = stage.new_record?
    base_metadata = clean_manual_comms_stage_metadata(stage.metadata.to_h, source: source)
    stage.update!(
      status: "staged",
      user: current_user,
      generated_at: Time.current,
      content_type: "application/json",
      metadata: was_new ? metadata : base_metadata.merge(metadata)
    )
    stage.define_singleton_method(:csv_import_created?) { was_new }
    stage
  end

  def clean_manual_comms_stage_metadata(metadata, source:)
    return metadata if source.present?

    metadata.except(
      "csv_call_import",
      "csv_call_import_source",
      "csv_call_import_id",
      "csv_call_import_title",
      "csv_call_import_status_key",
      "csv_call_import_row",
      "csv_call_raw_row",
      "owner_queue_source_uid",
      "owner_queue_source_record_id",
      "owner_queue_refreshed_at",
      "owner_queue_archived_at",
      "owner_queue_archive_reason"
    )
  end

  def manual_stage_metadata(label:, phone:, email:, contact_name: nil, company_name: nil, industry: nil, zip: nil, notes: nil, source: nil, lead_attrs: {}, import_id: nil, import_title: nil, import_status_key: nil, row_number: nil, raw_row: nil, claim_by_current_user: false)
    contact_label = contact_name.presence || "Contact"
    company_name = distinct_comms_company_name(contact_name, company_name)
    company_label = company_name.presence || (contact_name.present? ? nil : label)
    display_label = company_label.presence || contact_label.presence || label
    phone_option = phone.present? ? { "id" => "manual-phone", "name" => contact_label, "value" => phone, "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" } : nil
    email_option = email.present? ? { "id" => "manual-email", "name" => contact_label, "value" => email, "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" } : nil
    sms_body = comms_opening_sms_body(contact_name)
    metadata = {
      "stage_type" => "manual_comms",
      "company_name" => company_label,
      "deal_name" => display_label,
      "comm_kit_direction" => "wizwiki_out",
      "comm_kit_direction_label" => "WIZWIKI COMMS",
      "contact_options" => [{ "id" => "manual-contact", "name" => contact_label, "company" => company_label, "record_type" => "manual", "reason" => source.present? ? "CSV call import" : "Manual COMMS launcher" }],
      "phone_options" => [phone_option].compact,
      "recipient_email_options" => [email_option].compact,
      "manual_comms_contact_keys" => manual_comms_contact_keys(phone: phone, email: email),
      "manual_comms_contact_phone_digits" => normalized_phone_digits(phone),
      "manual_comms_contact_email" => normalized_email(email),
      "selected_contact_id" => "manual-contact",
      "selected_phone_id" => phone_option.to_h["id"],
      "selected_recipient_email_id" => email_option.to_h["id"],
      "recipient_selection_summary" => source.present? ? "CSV call import staged by #{current_user.display_name}." : "Manual WIZWIKI COMMS created by #{current_user.display_name}.",
      "sender_name" => current_user.display_name,
      "sender_phone" => current_user.display_phone_number,
      "sender_profile" => {
        "name" => current_user.display_name,
        "phone" => current_user.display_phone_number,
        "email" => current_user.email_address,
        "twilio" => current_user.twilio_profile
      }.compact_blank,
      "sms_options" => [{ "id" => "manual-opener", "tone" => "Thumper opener", "body" => sms_body }],
      "selected_sms_id" => "manual-opener",
      "composed_sms_body" => sms_body,
      "aircall_status" => "manual_comms",
      "aircall_ready" => false,
      "captured_contact_name" => contact_name,
      "captured_company_name" => company_name,
      "captured_industry" => industry,
      "captured_email" => email,
      "industry" => industry,
      "csv_call_import" => source.present?,
      "csv_call_import_source" => source,
      "csv_call_import_id" => import_id,
      "csv_call_import_title" => import_title,
      "csv_call_import_status_key" => import_status_key,
      "csv_call_import_row" => row_number,
      "csv_call_notes" => notes,
      "hubspot_lead" => lead_attrs.to_h.compact_blank,
      "hubspot_lead_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
      "hubspot_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
      "contact_owner" => lead_attrs.to_h[:hubspot_lead_owner].presence,
      "contact_owner_id" => lead_attrs.to_h[:hubspot_owner_id].presence,
      "hubspot_lead_id" => lead_attrs.to_h[:hubspot_lead_id].presence,
      "hubspot_contact_id" => lead_attrs.to_h[:hubspot_contact_id].presence,
      "hubspot_lead_quality" => lead_attrs.to_h[:hubspot_lead_quality].presence,
      "csv_call_raw_row" => raw_row,
      "comms_bot_state" => {
        "contact_name" => contact_name,
        "company_name" => company_name
      }.compact_blank,
      "staged_at" => Time.current.iso8601,
      "staged_by_user_id" => current_user.id,
      "staged_by" => current_user.display_name,
      "sms_sending_disabled" => false
    }.compact_blank
    if claim_by_current_user
      metadata.merge!(
        "claimed_by_user_id" => current_user.id.to_s,
        "claimed_by_user_name" => current_user.display_name,
        "claimed_at" => Time.current.iso8601
      )
    end
    metadata.merge(processing_payload(OpenStruct.new(crm_record: nil, title: label), metadata: metadata, latest_body: sms_body))
  end

  def extract_phone(value)
    return if value.match?(/@/)

    cleaned = value.gsub(/[^\d+]/, "")
    digits = cleaned.gsub(/\D/, "")
    digits.length >= 7 ? cleaned : nil
  end

  def extract_email(value)
    value.to_s[/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i].to_s.downcase.presence
  end

  def normalized_email(value)
    extract_email(value.to_s).to_s.downcase.presence
  end

  def normalized_phone_digits(value)
    digits = value.to_s.gsub(/\D/, "")
    return if digits.blank?

    digits.length >= 10 ? digits.last(10) : digits
  end

  def manual_label_contact_name(label)
    text = label.to_s.squish
    return if text.blank?
    return if text.match?(/\b(?:llc|inc|corp|co\.?|company|marketing|roofing|plumbing|hvac|electric|landscap|cleaning|restaurant|shop|store|agency|services?|solutions|group|studio|clinic|church|school|auto|construction|contracting|remodel|painting|signs?|print|printing)\b/i)
    return unless text.match?(/\A[a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,2}\z/i)

    text.split.map { |part| part.match?(/\A[A-Z.'-]+\z/) ? part : part.capitalize }.join(" ")
  end

  def manual_comms_contact_keys(phone:, email:)
    [
      (digits = normalized_phone_digits(phone)).present? ? "phone:#{digits}" : nil,
      (address = normalized_email(email)).present? ? "email:#{address}" : nil
    ].compact
  end

  def with_manual_comms_contact_lock(phone:, email:)
    lock_value = [current_organization.id, *manual_comms_contact_keys(phone: phone, email: email).sort].join(":")
    quoted_value = ActiveRecord::Base.connection.quote(lock_value)
    ActiveRecord::Base.connection.select_value(
      "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_value}, 0))"
    )
    yield
  end

  def duplicate_active_comms_stage(phone:, email:, except_stage: nil, except_record: nil)
    Comms::ContactDeduper.duplicate_stage(
      organization: current_organization,
      phone: phone,
      email: email,
      except_stage: except_stage,
      except_record: except_record
    )
  end

  def duplicate_contact_message(stage)
    label = stage.metadata.to_h["deal_name"].presence || stage.title.presence || "this contact"
    "Skipped duplicate: #{label} already has an active COMMS block with that phone/email."
  end

  def flash_completed_owner_queue_refresh!
    result = current_organization.settings.to_h.fetch("comms_owner_queue_last_refresh", {}).to_h
    return if result.blank?
    return if result["requested_by_user_id"].present? && result["requested_by_user_id"].to_i != current_user.id

    stored_at = result["stored_at"].to_s
    requested_at = session[:comms_owner_queue_refresh_requested_at].to_s
    return if stored_at.blank? || requested_at.blank?
    stored_time = Time.zone.parse(stored_at)
    requested_time = Time.zone.parse(requested_at)
    return if stored_time.blank? || requested_time.blank? || stored_time <= requested_time
    return if session[:comms_owner_queue_last_refresh_seen_at].to_s == stored_at
    return if flash[:notice].present? || flash[:alert].present?

    message = "Owner Queue rebuild complete: #{result["created"].to_i} created, #{result["updated"].to_i} updated"
    message += ", #{result["skipped"].to_i} skipped" if result["skipped"].to_i.positive?
    message += " (#{result["duplicate_contact"].to_i} duplicate phone/email)" if result["duplicate_contact"].to_i.positive?
    message += " (#{result["missing_contact"].to_i} missing phone/email)" if result["missing_contact"].to_i.positive?
    flash.now[:notice] = message
    session[:comms_owner_queue_last_refresh_seen_at] = stored_at
  rescue ArgumentError
    nil
  end

  def active_comms_stage_for(record, stage_type)
    record.crm_record_artifacts
      .where(organization: current_organization, artifact_type: "comm_staging")
      .where.not(status: "archived")
      .where("metadata ->> 'stage_type' = ?", stage_type)
      .order(updated_at: :desc)
      .first
  end

  def manual_comms_source_uid(phone:, email:)
    key = manual_comms_contact_keys(phone: phone, email: email).first.presence ||
      [phone, email].compact.join("|").presence ||
      SecureRandom.uuid
    "manual-comms-#{Digest::SHA256.hexdigest(key).first(24)}"
  end

  def find_manual_comms_record(phone:, email:)
    email_value = normalized_email(email)
    phone_digits = normalized_phone_digits(phone)
    return if email_value.blank? && phone_digits.blank?

    conditions = []
    binds = {}
    if email_value.present?
      conditions << <<~SQL.squish
        properties ->> 'manual_comms_contact_email' = :email
          AND NULLIF(properties ->> 'manual_comms_contact_email', '') IS NOT NULL
      SQL
      binds[:email] = email_value
    end
    if phone_digits.present?
      conditions << <<~SQL.squish
        properties ->> 'manual_comms_contact_phone_digits' = :phone_digits
          AND NULLIF(properties ->> 'manual_comms_contact_phone_digits', '') IS NOT NULL
      SQL
      binds[:phone_digits] = phone_digits
    end

    record = current_organization.crm_records
      .where(source: "manual_comms")
      .where(conditions.map { |condition| "(#{condition})" }.join(" OR "), binds)
      .order(updated_at: :desc)
      .first
    return record if record.present?
    return unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_LEGACY_CONTACT_SCAN_ENABLED", "0"))

    legacy_conditions = []
    legacy_binds = {}
    if email_value.present?
      legacy_conditions << "LOWER(COALESCE(email, '')) = :email"
      legacy_conditions << "jsonb_exists(properties -> 'manual_comms_contact_keys', :email_key)"
      legacy_binds[:email] = email_value
      legacy_binds[:email_key] = "email:#{email_value}"
    end
    if phone_digits.present?
      legacy_conditions << "RIGHT(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10) = :phone_digits"
      legacy_conditions << "jsonb_exists(properties -> 'manual_comms_contact_keys', :phone_key)"
      legacy_binds[:phone_digits] = phone_digits
      legacy_binds[:phone_key] = "phone:#{phone_digits}"
    end

    current_organization.crm_records
      .where(source: "manual_comms")
      .where(legacy_conditions.map { |condition| "(#{condition})" }.join(" OR "), legacy_binds)
      .order(updated_at: :desc)
      .first
  end

  def ensure_location_token!(stage)
    metadata = stage.metadata.to_h
    token = metadata["location_capture_token"].to_s.presence
    if token.present?
      stage.update!(metadata: metadata.merge("location_capture_url" => public_location_url(token))) if metadata["location_capture_url"].blank?
      return token
    end

    token = SecureRandom.urlsafe_base64(24)
    stage.update!(
      metadata: metadata.merge(
        "location_capture_token" => token,
        "location_capture_url" => public_location_url(token)
      )
    )
    token
  end

  def public_location_url(token)
    base_url = ENV["WIZWIKI_PUBLIC_URL"].presence || ENV["APP_HOST"].presence
    if base_url.present?
      "#{base_url.to_s.chomp('/')}/comms/location/#{token}"
    else
      comms_location_url(token)
    end
  end

  def defer_stage_memory!(stage)
    stage.update!(
      metadata: stage.metadata.to_h.merge(
        "comms_embedding_deferred" => true,
        "comms_embedding_deferred_until" => "evening_batch",
        "comms_embedding_deferred_at" => Time.current.iso8601
      )
    )
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] embedding defer mark failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end

  def queue_stage_memory!(stage)
    return defer_stage_memory!(stage) unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_EMBED_IMMEDIATE", "0"))
    return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

    Autos::EmbeddingQueue.enqueue_source!(stage, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
  rescue StandardError => error
    Rails.logger.warn("[CommsCommands] embedding queue failed stage=#{stage&.id} #{error.class}: #{error.message}")
  end
end
