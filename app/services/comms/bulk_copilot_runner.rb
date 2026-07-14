module Comms
  class BulkCopilotRunner
    DEFAULT_DELAY_SECONDS = 15.0

    Result = Data.define(:queued, :drafted, :skipped, :failed, :errors, :stage_count, :run_id) do
      def to_h
        {
          queued: queued,
          drafted: drafted,
          skipped: skipped,
          failed: failed,
          errors: errors,
          stage_count: stage_count,
          run_id: run_id
        }
      end
    end

    def self.call(organization:, user:, stage_ids:, run_id: nil, delay_seconds: nil, source: {})
      new(
        organization: organization,
        user: user,
        stage_ids: stage_ids,
        run_id: run_id,
        delay_seconds: delay_seconds,
        source: source
      ).call
    end

    def initialize(organization:, user:, stage_ids:, run_id:, delay_seconds:, source:)
      @organization = organization
      @user = user
      @stage_ids = Array(stage_ids).map(&:to_i).select(&:positive?).uniq
      @run_id = run_id.presence || SecureRandom.uuid
      @source = source.to_h
      @delay_seconds = normalize_delay(delay_seconds)
    end

    def call
      counts = { queued: 0, drafted: 0, skipped: 0, failed: 0 }
      errors = []
      write_status!("running", counts: counts, current_index: 0)

      stage_ids.each_with_index do |stage_id, index|
        stage = organization.crm_record_artifacts.includes(:crm_record).find_by(id: stage_id, artifact_type: "comm_staging")
        if stage.blank? || skip_bulk_copilot_stage?(stage)
          counts[:skipped] += 1
          mark_stage_bulk_status!(stage, "skipped", index: index + 1, detail: stage.blank? ? "stage missing" : "not eligible at run time")
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
          next
        end

        begin
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
          mark_stage_bulk_status!(stage, "running", index: index + 1, detail: "drafting COPILOT next text")
          if static_sms_template_enabled?
            drafted = draft_static_sms_template!(stage.reload)
            if drafted
              counts[:drafted] += 1
              mark_stage_bulk_status!(stage.reload, "drafted", index: index + 1, detail: "static template draft ready")
            else
              counts[:failed] += 1
              errors << "#{stage_company_name(stage)}: static template draft was blank".first(180)
              mark_stage_bulk_status!(stage.reload, "failed", index: index + 1, detail: "static template draft was blank")
            end
          else
            result = Comms::CopilotDraft.call(
              stage: stage,
              user: user,
              operator_prompt: copilot_operator_prompt(stage),
              writer_model: bulk_sms_writer_model,
              challenger_model: bulk_sms_challenger_model
            )
            if result.queued
              counts[:queued] += 1
              mark_stage_bulk_status!(stage.reload, "queued", index: index + 1, detail: "draft job queued")
            elsif result.drafted
              counts[:drafted] += 1
              mark_stage_bulk_status!(stage.reload, "drafted", index: index + 1, detail: "draft ready")
            else
              counts[:failed] += 1
              errors << "#{stage_company_name(stage)}: draft was blank".first(180)
              mark_stage_bulk_status!(stage.reload, "failed", index: index + 1, detail: "draft was blank")
            end
          end
          sleep(delay_seconds) if delay_seconds.positive?
        rescue StandardError => error
          counts[:failed] += 1
          errors << "#{stage_company_name(stage)}: #{error.message}".first(180)
          mark_stage_error(stage, error)
          mark_stage_bulk_status!(stage, "failed", index: index + 1, detail: error.message)
          Rails.logger.warn("[Comms::BulkCopilotRunner] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
        ensure
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
        end
      end

      result = Result.new(
        queued: counts[:queued],
        drafted: counts[:drafted],
        skipped: counts[:skipped],
        failed: counts[:failed],
        errors: errors.first(8),
        stage_count: stage_ids.length,
        run_id: run_id
      )
      write_status!("finished", counts: counts, errors: errors, current_index: stage_ids.length, finished_at: Time.current)
      result
    rescue StandardError => error
      write_status!("failed", counts: counts || {}, errors: [error.message], finished_at: Time.current)
      raise
    end

    private

    attr_reader :organization, :user, :stage_ids, :run_id, :source, :delay_seconds

    def bulk_sms_writer_model
      @bulk_sms_writer_model ||= WizwikiSettings.normalize_sms_writer_model(source["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model)
    end

    def bulk_sms_challenger_model
      @bulk_sms_challenger_model ||= WizwikiSettings.normalize_challenger_model(source["sms_challenger_model"].presence || WizwikiSettings.default_challenger_model)
    end

    def static_sms_template
      @static_sms_template ||= source["static_sms_template"].to_h
    end

    def static_sms_template_enabled?
      static_sms_template["id"].present? && static_sms_template["body"].to_s.strip.present?
    end

    def normalize_delay(value)
      raw = value.presence || source["launch_cadence_delay_seconds"].presence || ENV.fetch("WIZWIKI_COMMS_COPILOT_QUEUE_DELAY_SECONDS", DEFAULT_DELAY_SECONDS.to_s)
      raw.to_f.clamp(0.0, 120.0)
    end

    def write_status!(state, counts:, current_index: nil, current_stage: nil, errors: [], finished_at: nil)
      settings = organization.settings.to_h.deep_dup
      started_at = settings.dig("comms_bulk_copilot_run", "started_at").presence || Time.current.iso8601
      settings["comms_bulk_copilot_run"] = {
        "run_id" => run_id,
        "state" => state,
        "stage_count" => stage_ids.length,
        "queued" => counts[:queued].to_i,
        "drafted" => counts[:drafted].to_i,
        "skipped" => counts[:skipped].to_i,
        "failed" => counts[:failed].to_i,
        "current_index" => current_index.to_i,
        "current_stage_id" => current_stage&.id,
        "current_stage_name" => current_stage ? stage_company_name(current_stage) : nil,
        "source" => source,
        "requested_by_user_id" => user.id,
        "requested_by" => user.display_name,
        "started_at" => started_at,
        "updated_at" => Time.current.iso8601,
        "finished_at" => finished_at&.iso8601,
        "errors" => Array(errors).first(5)
      }.compact_blank
      organization.update_column(:settings, settings)
    rescue StandardError => error
      Rails.logger.warn("[Comms::BulkCopilotRunner] status update failed organization=#{organization&.id}: #{error.class}: #{error.message}")
    end

    def skip_bulk_copilot_stage?(stage)
      metadata = stage.metadata.to_h
      !comms_stage_active_visible?(stage) ||
        stage_sms_background_drafting?(stage) ||
        ActiveModel::Type::Boolean.new.cast(metadata["sms_autopilot_enabled"]) ||
        stage_autopilot_complete?(metadata) && !latest_unanswered_inbound_sms?(stage) ||
        stage_selected_phone(stage)["value"].to_s.blank?
    end

    def mark_stage_bulk_status!(stage, status, index:, detail: nil)
      return if stage.blank?

      now = Time.current.iso8601
      metadata = stage.reload.metadata.to_h.deep_dup
      current = metadata["comms_bulk_run"].to_h
      current = {} if current["run_id"].present? && current["run_id"].to_s != run_id.to_s
      current = current.merge(
        "run_id" => run_id,
        "mode" => "copilot",
        "status" => status,
        "position" => current["position"].presence || index,
        "stage_count" => current["stage_count"].presence || stage_ids.length,
        "stage_id" => stage.id,
        "updated_at" => now,
        "detail" => detail.to_s.presence
      ).compact_blank
      metadata["comms_bulk_run"] = current
      metadata["comms_bulk_run_id"] = run_id
      metadata["comms_bulk_run_mode"] = "copilot"
      metadata["comms_bulk_run_position"] = current["position"]
      metadata["comms_bulk_run_stage_count"] = current["stage_count"]
      metadata["comms_bulk_run_status"] = status
      metadata["comms_bulk_run_updated_at"] = now
      stage.update_columns(metadata: metadata, updated_at: Time.current)
    rescue StandardError => error
      Rails.logger.warn("[Comms::BulkCopilotRunner] bulk stage status failed stage=#{stage&.id} run=#{run_id}: #{error.class}: #{error.message}")
    end

    def comms_stage_active_visible?(stage)
      return false if stage_sms_do_not_contact?(stage)
      return false if stage_manual_board_state(stage).in?(%w[hidden hold done opt_out])

      true
    end

    def stage_manual_board_state(stage)
      value = stage.metadata.to_h["comms_board_state"].to_s
      value.in?(%w[active hold hidden done opt_out]) ? value : "active"
    end

    def stage_sms_do_not_contact?(stage)
      metadata = stage.metadata.to_h
      metadata["comms_board_state"].to_s == "opt_out" ||
        ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) ||
        metadata["sms_do_not_contact_at"].present? ||
        metadata["comms_command_last_status"].to_s == "do_not_contact"
    end

    def stage_sms_background_drafting?(stage)
      metadata = stage.metadata.to_h
      last_status = metadata["comms_command_last_status"].to_s
      background_status = metadata["comms_command_background_status"].to_s
      return false unless last_status == "drafting" || background_status.in?(%w[queued running pending claimed])

      background_at = parse_time(metadata["comms_command_background_at"])
      background_at.blank? || background_at > 8.minutes.ago
    end

    def stage_autopilot_complete?(metadata)
      metadata["sms_autopilot_completed_at"].present? ||
        metadata["sms_autopilot_completion_sent_at"].present? ||
        ActiveModel::Type::Boolean.new.cast(metadata.dig("comms_bot_state", "autopilot_complete"))
    end

    def latest_unanswered_inbound_sms?(stage)
      events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
      latest_inbound_at = nil
      latest_outbound_at = nil
      events.each do |event|
        next unless event["channel"].to_s == "sms"
        next if event["status"].to_s.in?(%w[failed canceled])

        event_time = parse_time(event["created_at"])
        if event["direction"].to_s == "inbound" && event["body"].to_s.squish.present?
          latest_inbound_at = event_time || Time.at(0)
        elsif event["direction"].to_s == "outbound"
          latest_outbound_at = event_time || Time.at(0)
        end
      end
      latest_inbound_at.present? && (latest_outbound_at.blank? || latest_inbound_at > latest_outbound_at)
    end

    def stage_selected_phone(stage)
      selected_option(stage, "phone_options", "selected_phone_id")
    end

    def selected_option(stage, collection_key, selected_key)
      metadata = stage.metadata.to_h
      options = Array(metadata[collection_key]).map(&:to_h)
      selected_id = metadata[selected_key].to_s
      options.find { |option| option["id"].to_s == selected_id }.presence || options.first.to_h
    end

    def stage_company_name(stage)
      stage.metadata.to_h["company_name"].presence || stage.crm_record&.name.to_s.presence || stage.title
    end

    def copilot_operator_prompt(stage)
      metadata = stage.metadata.to_h
      objective = metadata["sms_autopilot_objective"].presence || default_copilot_objective
      [
        "Bulk Copilot was requested from the visible COMMS page.",
        "Draft the best next short SMS as Thumper from WIZWIKI Marketing and save it for human approval only.",
        "Do not send automatically.",
        Comms::SmsOperatorPrompt.manual_next_text(objective: objective),
        "Stage: #{stage_company_name(stage)}"
      ].join(" ")
    end

    def draft_static_sms_template!(stage)
      raw_body = Comms::BatchTemplates.render_body(static_sms_template.merge("type" => "sms"), stage)
      body = safe_customer_sms_body(raw_body)
      if raw_body.present? && body.blank?
        Rails.logger.warn("[Comms::BulkCopilotRunner] blocked unsafe static template draft stage=#{stage&.id} template=#{static_sms_template["id"]} reason=#{sms_body_safety_reason(raw_body)}")
      end
      return false if body.blank?

      now = Time.current.iso8601
      metadata = stage.metadata.to_h.deep_dup
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_last_channel" => "sms",
          "comms_command_last_status" => "drafted",
          "comms_command_last_at" => now,
          "comms_command_background_status" => "drafted",
          "comms_command_background_at" => now,
          "comms_command_sms_draft_body" => body,
          "comms_command_sms_draft" => {
            "body" => body,
            "provider" => "operator/static_batch_template",
            "model" => "static-template",
            "draft_source" => "static_batch_template",
            "static_batch_template" => true,
            "static_batch_template_id" => static_sms_template["id"],
            "static_batch_template_title" => static_sms_template["title"],
            "created_at" => now,
            "created_by_user_id" => user.id,
            "created_by" => user.display_name
          }.compact_blank,
          "sms_batch_template_last_id" => static_sms_template["id"],
          "sms_batch_template_last_title" => static_sms_template["title"],
          "sms_batch_template_last_drafted_at" => now
        ).compact_blank
      )
      true
    end

    def safe_customer_sms_body(value)
      return if value.blank?
      return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

      value.to_s.strip.presence
    end

    def sms_body_safety_reason(value)
      return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

      "unsafe_sms_body"
    end

    def default_copilot_objective
      "Keep the SMS conversation helpful and short. Answer WIZWIKI Marketing questions from product data, discover product interest and one practical fit signal, recommend the best checkout link when clear, and use account-manager handoff when custom pricing, order support, proofs, or human help is needed."
    end

    def mark_stage_error(stage, error)
      return if stage.blank?

      metadata = stage.metadata.to_h.deep_dup
      stage.update!(
        generated_at: Time.current,
        metadata: metadata.merge(
          "comms_command_last_status" => "copilot_failed",
          "comms_command_last_error" => error.message,
          "comms_command_last_at" => Time.current.iso8601,
          "sms_copilot_last_error" => error.message,
          "sms_copilot_last_error_at" => Time.current.iso8601
        ).compact_blank
      )
    rescue StandardError => update_error
      Rails.logger.warn("[Comms::BulkCopilotRunner] failed marking stage error stage=#{stage&.id}: #{update_error.class}: #{update_error.message}")
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
