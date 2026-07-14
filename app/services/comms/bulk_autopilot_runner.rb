module Comms
  class BulkAutopilotRunner
    DEFAULT_DELAY_SECONDS = 15.0

    Result = Data.define(:started, :skipped, :failed, :errors, :stage_count, :run_id) do
      def to_h
        {
          started: started,
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
      @delay_seconds = normalize_delay(delay_seconds)
      @source = source.to_h
    end

    def call
      counts = { started: 0, skipped: 0, failed: 0 }
      errors = []
      write_status!("running", counts: counts, current_index: 0)

      stage_ids.each_with_index do |stage_id, index|
        stage = organization.crm_record_artifacts.includes(:crm_record).find_by(id: stage_id, artifact_type: "comm_staging")
        if stage.blank? || skip_bulk_autopilot_stage?(stage)
          counts[:skipped] += 1
          mark_stage_bulk_status!(stage, "skipped", index: index + 1, detail: stage.blank? ? "stage missing" : "not eligible at run time")
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
          next
        end

        begin
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
          mark_stage_bulk_status!(stage, "running", index: index + 1, detail: "starting FULL AUTO")
          start_autopilot_for_stage!(stage)
          result = if static_sms_template_enabled?
            send_static_sms_template!(stage.reload)
          else
            send_autopilot_reply_to_pending_inbound!(stage.reload) || send_autopilot_start_text!(stage.reload)
          end
          if result == :am_support
            counts[:skipped] += 1
            mark_stage_bulk_status!(stage.reload, "skipped", index: index + 1, detail: "routed to AM support")
          elsif result
            counts[:started] += 1
            mark_stage_bulk_status!(stage.reload, "sent", index: index + 1, detail: result.to_s)
            sleep(delay_seconds) if delay_seconds.positive?
          else
            counts[:skipped] += 1
            mark_stage_bulk_status!(stage.reload, "skipped", index: index + 1, detail: "no send needed")
          end
          defer_stage_memory!(stage.reload)
        rescue StandardError => error
          counts[:failed] += 1
          errors << "#{stage_company_name(stage)}: #{error.message}".first(180)
          mark_stage_error(stage, error)
          mark_stage_bulk_status!(stage, "failed", index: index + 1, detail: error.message)
          Rails.logger.warn("[Comms::BulkAutopilotRunner] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
        ensure
          write_status!("running", counts: counts, current_index: index + 1, current_stage: stage)
        end
      end

      result = Result.new(
        started: counts[:started],
        skipped: counts[:skipped],
        failed: counts[:failed],
        errors: errors.first(8),
        stage_count: stage_ids.length,
        run_id: run_id
      )
      write_status!("finished", counts: counts, errors: errors, current_index: stage_ids.length, finished_at: Time.current)
      Comms::BoardStatusCountsRefreshJob.perform_later(organization_id: organization.id) if defined?(Comms::BoardStatusCountsRefreshJob)
      result
    rescue StandardError => error
      write_status!("failed", counts: counts || {}, errors: [error.message], finished_at: Time.current)
      raise
    end

    private

    attr_reader :organization, :user, :stage_ids, :run_id, :delay_seconds, :source

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
      raw = value.presence || ENV.fetch("WIZWIKI_COMMS_RUN_ALL_DELAY_SECONDS", DEFAULT_DELAY_SECONDS.to_s)
      raw.to_f.clamp(0.0, 120.0)
    end

    def write_status!(state, counts:, current_index: nil, current_stage: nil, errors: [], finished_at: nil)
      settings = organization.settings.to_h.deep_dup
      started_at = settings.dig("comms_bulk_autopilot_run", "started_at").presence || Time.current.iso8601
      settings["comms_bulk_autopilot_run"] = {
        "run_id" => run_id,
        "state" => state,
        "stage_count" => stage_ids.length,
        "started" => counts[:started].to_i,
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
      Rails.logger.warn("[Comms::BulkAutopilotRunner] status update failed organization=#{organization&.id}: #{error.class}: #{error.message}")
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

    def mark_stage_bulk_status!(stage, status, index:, detail: nil)
      return if stage.blank?

      now = Time.current.iso8601
      metadata = stage.reload.metadata.to_h.deep_dup
      current = metadata["comms_bulk_run"].to_h
      current = {} if current["run_id"].present? && current["run_id"].to_s != run_id.to_s
      current = current.merge(
        "run_id" => run_id,
        "mode" => "full_auto",
        "status" => status,
        "position" => current["position"].presence || index,
        "stage_count" => current["stage_count"].presence || stage_ids.length,
        "stage_id" => stage.id,
        "updated_at" => now,
        "detail" => detail.to_s.presence
      ).compact_blank
      metadata["comms_bulk_run"] = current
      metadata["comms_bulk_run_id"] = run_id
      metadata["comms_bulk_run_mode"] = "full_auto"
      metadata["comms_bulk_run_position"] = current["position"]
      metadata["comms_bulk_run_stage_count"] = current["stage_count"]
      metadata["comms_bulk_run_status"] = status
      metadata["comms_bulk_run_updated_at"] = now
      stage.update_columns(metadata: metadata, updated_at: Time.current)
    rescue StandardError => error
      Rails.logger.warn("[Comms::BulkAutopilotRunner] bulk stage status failed stage=#{stage&.id} run=#{run_id}: #{error.class}: #{error.message}")
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

    def stage_link_sent?(stage)
      metadata = stage.metadata.to_h
      return true if metadata["shopify_link_sent_at"].present? || metadata["comms_link_reached_at"].present?

      shopify_links = metadata["shopify_links"].respond_to?(:to_h) ? metadata["shopify_links"].to_h : {}
      links = [metadata["shopify_link"].to_s.squish, shopify_links.values].flatten.compact_blank.map(&:to_s)

      Array(metadata["sms_thread"]).any? do |event|
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

    def start_autopilot_for_stage!(stage)
      metadata = stage.metadata.to_h.deep_dup
      metadata["sms_autopilot_enabled"] = true
      metadata["sms_autopilot_updated_at"] = Time.current.iso8601
      metadata["sms_autopilot_updated_by_user_id"] = user.id
      metadata["sms_autopilot_updated_by"] = user.display_name
      metadata["sms_writer_model"] = bulk_sms_writer_model
      metadata["sms_writer_model_label"] = WizwikiSettings.sms_writer_model_label(bulk_sms_writer_model)
      metadata["sms_challenger_model"] = bulk_sms_challenger_model
      metadata["sms_challenger_model_label"] = WizwikiSettings.challenger_model_label(bulk_sms_challenger_model)
      metadata["sms_autopilot_objective"] = default_autopilot_objective
      metadata["sms_autopilot_turn_limit"] = metadata["sms_autopilot_turn_limit"].presence || ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_TURN_LIMIT", "16").to_i
      metadata["sms_autopilot_started_at"] ||= Time.current.iso8601
      metadata.delete("sms_autopilot_disabled_at")
      metadata.delete("sms_autopilot_disabled_reason")
      stage.update!(generated_at: Time.current, metadata: metadata)
    end

    def send_autopilot_reply_to_pending_inbound!(stage)
      reply_key = nil
      pending = pending_inbound_sms(stage)
      return false if pending.blank?

      from = pending["from"].to_s
      body = pending["body"].to_s
      return false if from.blank? || body.blank? || stop_intent?(body)
      handoff_result = handoff_pending_inbound_if_needed!(stage, body, source: "bulk_autopilot_pending_reply")
      return handoff_result if handoff_result

      reply_key = Comms::AutopilotReplyLock.reserve!(
        stage,
        inbound_sid: pending["provider_message_id"],
        inbound_body: body,
        from: from,
        source: "bulk_autopilot_pending_reply"
      )
      return false if reply_key.blank?

      result = DealReports::CommsDraftWriter.call(
        stage: stage.reload,
        user: user,
        operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: body, from: from),
        wait_seconds: ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_ENABLE_WAIT_SECONDS", "75").to_i,
        writer_model: bulk_sms_writer_model,
        challenger_model: bulk_sms_challenger_model
      )
      raw_reply = result.to_h["body"].to_s.strip
      reply = safe_customer_sms_body(raw_reply)
      if raw_reply.present? && reply.blank?
        Rails.logger.warn("[Comms::BulkAutopilotRunner] blocked unsafe pending reply stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_reply)}")
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
          "draft_provider" => result.to_h["provider"],
          "draft_model" => result.to_h["model"],
          "draft_source" => result.to_h["draft_source"],
          "writer_model" => result.to_h["writer_model"],
          "writer_model_label" => result.to_h["writer_model_label"]
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
      mark_stage_error(stage, error)
      Rails.logger.warn("[Comms::BulkAutopilotRunner] pending reply failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def handoff_pending_inbound_if_needed!(stage, body, source:)
      return false unless defined?(Comms::InboundSmsHandoff)
      return false unless Comms::InboundSmsHandoff.required?(body, stage: stage) ||
        Comms::InboundSmsHandoff.contact_collection_response?(stage.reload, body) ||
        Comms::InboundSmsHandoff.accepted_recent_contact_offer?(stage.reload, body)

      result = Comms::InboundSmsHandoff.call(stage: stage.reload, body: body, source: source)
      if ActiveModel::Type::Boolean.new.cast(result&.handled) ||
          ActiveModel::Type::Boolean.new.cast(result&.review_draft_saved)
        :am_support
      else
        false
      end
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
          user: user,
          operator_prompt: Comms::SmsOperatorPrompt.proactive_start(
            objective: stage.metadata.to_h["sms_autopilot_objective"].presence || default_autopilot_objective
          ),
          wait_seconds: ENV.fetch("WIZWIKI_COMMS_AUTOPILOT_START_WAIT_SECONDS", "35").to_i,
          writer_model: bulk_sms_writer_model,
          challenger_model: bulk_sms_challenger_model
        )
      end

      raw_body = result.to_h["body"].to_s.strip.presence
      body = safe_customer_sms_body(raw_body)
      if raw_body.present? && body.blank?
        Rails.logger.warn("[Comms::BulkAutopilotRunner] blocked unsafe start SMS stage=#{stage&.id} reason=#{sms_body_safety_reason(raw_body)}")
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
          "draft_provider" => result.to_h["provider"],
          "draft_model" => result.to_h["model"],
          "draft_source" => result.to_h["draft_source"],
          "writer_model" => result.to_h["writer_model"],
          "writer_model_label" => result.to_h["writer_model_label"]
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
      mark_stage_error(stage, error)
      Rails.logger.warn("[Comms::BulkAutopilotRunner] start text failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def send_static_sms_template!(stage)
      return false if stage_sms_do_not_contact?(stage)
      return false if ActiveModel::Type::Boolean.new.cast(stage.metadata.to_h["sms_sending_disabled"])
      return false if stop_intent?(latest_inbound_sms_body(stage).to_s)

      phone = stage_selected_phone(stage)["value"].to_s.strip
      raise ArgumentError, "recipient phone required before static SMS batch can start" if phone.blank?

      raw_body = Comms::BatchTemplates.render_body(static_sms_template.merge("type" => "sms"), stage)
      body = safe_customer_sms_body(raw_body)
      if raw_body.present? && body.blank?
        Rails.logger.warn("[Comms::BulkAutopilotRunner] blocked unsafe static template SMS stage=#{stage&.id} template=#{static_sms_template["id"]} reason=#{sms_body_safety_reason(raw_body)}")
      end
      raise ArgumentError, "static SMS template body required before FULL AUTO can start" if body.blank?

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
          "static_batch_template" => true,
          "static_batch_template_id" => static_sms_template["id"],
          "static_batch_template_title" => static_sms_template["title"],
          "draft_provider" => "operator/static_batch_template",
          "draft_model" => "static-template"
        ).compact_blank
      )
      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
          "sms_autopilot_last_sent_at" => Time.current.iso8601,
          "sms_autopilot_last_error" => nil,
          "sms_batch_template_last_id" => static_sms_template["id"],
          "sms_batch_template_last_title" => static_sms_template["title"],
          "sms_batch_template_last_sent_at" => Time.current.iso8601
        )
      )
      :static_template_sent
    rescue StandardError => error
      mark_stage_error(stage, error)
      Rails.logger.warn("[Comms::BulkAutopilotRunner] static template SMS failed stage=#{stage&.id} template=#{static_sms_template["id"]} #{error.class}: #{error.message}")
      false
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
    end

    def event_payload(channel:, direction:, status:, body:, to:, provider_result:, error: nil)
      {
        "id" => SecureRandom.uuid,
        "channel" => channel,
        "direction" => direction,
        "status" => status,
        "to" => to.to_s,
        "body" => body.to_s,
        "provider" => provider_result.to_h["provider"].presence || channel,
        "provider_message_id" => provider_result.to_h["sid"].presence || provider_result.to_h["message_id"].presence,
        "provider_status" => provider_result.to_h["status"].presence,
        "from" => provider_result.to_h["from"].presence,
        "error" => error.to_s.presence,
        "user_id" => user.id,
        "user_name" => user.display_name,
        "created_at" => Time.current.iso8601
      }.compact_blank
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

    def listener_payload(payload)
      return {} unless payload["channel"].to_s == "sms"
      return {} unless payload["direction"].to_s == "outbound"
      return {} unless payload["status"].to_s == "sent"

      {
        "sms_listener_active" => true,
        "sms_listener_started_at" => Time.current.iso8601,
        "sms_listener_until" => 7.days.from_now.iso8601,
        "sms_listener_from" => payload["from"].presence || Comms::SmsProvider.public_status(user: user)[:sender_number],
        "sms_listener_to" => payload["to"],
        "sms_listener_last_outbound_sid" => payload["provider_message_id"],
        "sms_listener_last_outbound_at" => Time.current.iso8601
      }.compact_blank
    end

    def processing_payload(stage, metadata:, latest_body:)
      return {} unless defined?(DealReports::CommsProcessingCode)

      DealReports::CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: latest_body)
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

    def stage_first_sms_sent?(stage)
      Array(stage.metadata.to_h["sms_thread"]).any? do |event|
        event = event.to_h
        next false unless event["channel"].to_s == "sms"
        next false unless event["direction"].to_s == "outbound"

        !event["status"].to_s.in?(%w[failed canceled])
      end
    end

    def stage_selected_contact(stage)
      selected_option(stage, "contact_options", "selected_contact_id")
    end

    def stage_selected_phone(stage)
      selected_option(stage, "phone_options", "selected_phone_id")
    end

    def selected_option(stage, options_key, selected_key)
      metadata = stage.metadata.to_h
      selected_id = metadata[selected_key].to_s
      options = Array(metadata[options_key])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      candidate = selected || options.first
      candidate.respond_to?(:to_h) ? candidate.to_h : {}
    end

    def autopilot_opening_body(stage)
      first_name = autopilot_contact_first_name(stage)
      Thumper::VoiceGuide.starter_sms(first_name, product_lane: autopilot_product_lane(stage))
    end

    def autopilot_product_lane(stage)
      metadata = stage&.metadata
      metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}
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

    def autopilot_contact_first_name(stage)
      name = stage_selected_contact(stage)["name"].to_s.squish
      name = stage.metadata.to_h["captured_contact_name"].to_s.squish if generic_comms_identity?(name)
      comms_first_name(name)
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

    def stop_intent?(body)
      text = body.to_s.downcase.squish
      return false if text.blank?
      return true if text.match?(/\A(?:stop|unsubscribe|quit|end|cancel)\s*[.!]?\z/i)

      text.match?(/\b(?:unsubscribe|opt\s*-?\s*out|remove me|take me off)\b/i) ||
        text.match?(/\b(?:do not|don't|dont)\s+(?:text|message|contact|sms)\b/i) ||
        text.match?(/\b(?:stop|quit|end|cancel)\s+(?:texting|messaging|messages?|texts?|sms)\b/i)
    end

    def parse_event_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
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
      if defined?(Comms::SmsLanguageSupport)
        result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: body)
        @last_sms_delivery_language_event = result.to_h["event"]
        persist_sms_language_metadata!(stage, result.to_h["metadata"])
        body = result.to_h["body"].presence || body
      end
      body
    end

    def sms_delivery_language_event_payload
      @last_sms_delivery_language_event.to_h.compact_blank
    end

    def persist_sms_language_metadata!(stage, updates)
      return if stage.blank? || updates.to_h.blank?

      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(generated_at: Time.current, metadata: metadata.merge(updates.to_h).compact_blank)
    rescue StandardError => error
      Rails.logger.warn("[Comms::BulkAutopilotRunner] SMS language metadata update failed stage=#{stage&.id} #{error.class}: #{error.message}")
    end

    def sms_body_safety_reason(value)
      return Comms::SmsBodySafety.leak_reason(value).presence || "unsafe_sms_body" if defined?(Comms::SmsBodySafety)

      "unsafe_sms_body"
    end

    def twilio_sender_profile
      user.twilio_profile.to_h
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
      Rails.logger.warn("[Comms::BulkAutopilotRunner] embedding defer mark failed stage=#{stage&.id} #{error.class}: #{error.message}")
    end

    def mark_stage_error(stage, error)
      return if stage.blank?

      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_last_error" => error.message,
          "sms_autopilot_last_error_at" => Time.current.iso8601
        )
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def stage_company_name(stage)
      stage.metadata.to_h["company_name"].presence || stage.crm_record&.name.to_s.presence || stage.title
    end

    def default_autopilot_objective
      Thumper::VoiceGuide.autopilot_objective
    end
  end
end
