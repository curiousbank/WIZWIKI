# frozen_string_literal: true

require "digest"

module Comms
  class AskAutopilotTest
    SOURCE = "ask_autopilot_test"
    STAGE_TYPE = "ask_autopilot_test"
    SIMULATED_WIZWIKI_NUMBER = "+15550100001"
    SIMULATOR_REPLY_RETRY_LIMIT = 15

    class << self
      def start(user:, organization:, writer_model: nil)
        stage = sandbox_stage!(user: user, organization: organization)
        reset_stage!(stage, user: user, writer_model: writer_model)
        payload_for(stage.reload)
      end

      def load(payload, user:, organization:)
        stage = stage_from(payload, organization: organization)
        if stage.present? && active_stage?(stage)
          recover_stale_recursive_dojo!(stage.reload)
          recover_answered_background_draft!(stage.reload)
          materialize_background_reply!(stage.reload)
          ensure_latest_inbound_has_reply_or_retry!(stage.reload)
          return payload_for(stage.reload)
        end

        nil
      end

      def reply(payload, text:, user:, organization:, async: false, writer_model: nil)
        stage = stage_from(payload, organization: organization) || sandbox_stage!(user: user, organization: organization)
        reset_stage!(stage, user: user, writer_model: writer_model) unless active_stage?(stage)
        persist_writer_model!(stage.reload, writer_model) if writer_model.present?

        inbound_text = text.to_s.squish
        return payload_for(stage.reload) if inbound_text.blank?

        inbound_event = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "inbound",
            status: "received",
            body: inbound_text,
            from: simulated_customer_phone(user),
            to: SIMULATED_WIZWIKI_NUMBER,
            user: user
          )
        )

        if no_reply_needed_for_inbound?(stage.reload, inbound_event)
          record_no_reply_needed!(stage.reload, inbound_event)
          broadcast_stage!(stage.reload, user: user)
          return payload_for(stage.reload)
        end

        if async && !sync_writer_mode? && defined?(Comms::AskAutopilotReplyJob)
          record_reply_queued!(stage.reload, inbound_event)
          broadcast_stage!(stage.reload, user: user)
          Comms::AskAutopilotReplyJob.perform_later(
            stage_id: stage.id,
            inbound_event_id: inbound_event["id"],
            user_id: user.id,
            generation: inbound_event["reply_generation"].presence || stage.reload.metadata.to_h["sms_reply_generation"]
          )
        else
          process_inbound_reply!(stage.reload, user: user, inbound_event: inbound_event)
        end

        payload_for(stage.reload)
      end

      def start_recursive_dojo(payload, guidance:, user:, organization:, async: false, writer_model: nil)
        stage = stage_from(payload, organization: organization) || sandbox_stage!(user: user, organization: organization)
        reset_stage!(stage, user: user, writer_model: writer_model) unless active_stage?(stage)
        persist_writer_model!(stage.reload, writer_model) if writer_model.present?
        requested_guidance = guidance.to_s.squish.presence
        recover_stale_recursive_dojo!(stage.reload)
        if recursive_dojo_active?(stage.reload)
          current_guidance = stage.reload.metadata.to_h["recursive_dojo_guidance"].to_s.squish.presence
          return payload_for(stage.reload) if requested_guidance.blank? || requested_guidance == current_guidance

          supersede_recursive_dojo_for_new_guidance!(
            stage.reload,
            guidance: requested_guidance,
            reason: "Recursive Dojo restarted with new trainer guidance."
          )
        end

        generation = SecureRandom.uuid
        queue_recursive_dojo!(stage.reload, guidance: requested_guidance, user: user, generation: generation)
        broadcast_stage!(stage.reload, user: user)

        if async && defined?(Comms::AskRecursiveDojoJob)
          Comms::AskRecursiveDojoJob.perform_later(
            stage_id: stage.id,
            user_id: user.id,
            guidance: requested_guidance,
            writer_model: writer_model,
            generation: generation
          )
        else
          process_recursive_dojo(
            stage_id: stage.id,
            user_id: user.id,
            guidance: requested_guidance,
            writer_model: writer_model,
            generation: generation
          )
        end

        payload_for(stage.reload)
      end

      def process_reply(stage_id:, inbound_event_id:, user_id:, generation: nil)
        stage = CrmRecordArtifact.find_by(id: stage_id)
        return false if stage.blank? || !active_stage?(stage)

        user = User.find_by(id: user_id) || stage.user
        return false if user.blank?

        inbound_event = find_thread_event(stage, inbound_event_id)
        return false if inbound_event.blank?
        generation ||= inbound_event.to_h["reply_generation"].presence
        return record_stale_reply!(stage.reload, inbound_event, generation: generation) if reply_generation_stale?(stage.reload, generation)
        return false if reply_already_materialized?(stage, inbound_event)

        if no_reply_needed_for_inbound?(stage.reload, inbound_event)
          recorded = record_no_reply_needed!(stage.reload, inbound_event, generation: generation)
          broadcast_stage!(stage.reload, user: user)
          return recorded
        end

        mark_reply_running!(stage.reload, inbound_event, generation: generation)
        broadcast_stage!(stage.reload, user: user)
        processed = process_inbound_reply!(stage.reload, user: user, inbound_event: inbound_event)
        broadcast_stage!(stage.reload, user: user)
        processed
      rescue StandardError => error
        mark_reply_failed!(stage, error) if stage.present?
        broadcast_stage!(stage.reload, user: user) if stage.present? && defined?(user) && user.present?
        Rails.logger.warn("[AskAutopilotTest] async reply failed stage=#{stage_id} inbound=#{inbound_event_id} #{error.class}: #{error.message}")
        false
      end

      def process_recursive_dojo(stage_id:, user_id:, guidance: nil, writer_model: nil, generation: nil)
        stage = CrmRecordArtifact.find_by(id: stage_id)
        return false if stage.blank? || !active_stage?(stage)

        user = User.find_by(id: user_id) || stage.user
        return false if user.blank?

        metadata = stage.reload.metadata.to_h
        generation = generation.to_s.presence || metadata["recursive_dojo_generation"].to_s.presence
        return false if generation.present? && metadata["recursive_dojo_generation"].to_s != generation
        return false if recursive_dojo_canceled?(stage.reload, generation)

        single_turn_scenarios = dojo_scenarios(guidance)
        conversation_scenarios = dojo_conversation_scenarios(guidance)
        total_cycles = single_turn_scenarios.length + conversation_scenarios.length

        mark_recursive_dojo_running!(
          stage.reload,
          user: user,
          generation: generation,
          phase: "recursive_dojo",
          progress: {
            "cycle" => 0,
            "total_cycles" => total_cycles,
            "kind" => "setup",
            "title" => "Preparing Recursive Dojo"
          }
        )
        broadcast_stage!(stage.reload, user: user)
        return false if recursive_dojo_canceled?(stage.reload, generation)

        single_turn_summaries = []
        single_turn_scenarios.each_with_index do |scenario, index|
          break if recursive_dojo_canceled?(stage.reload, generation)

          summary = process_dojo_scenario!(
            stage.reload,
            user: user,
            scenario: scenario,
            cycle: index + 1,
            total_cycles: total_cycles,
            writer_model: writer_model,
            generation: generation
          )
          single_turn_summaries << summary if summary.present?
          broadcast_stage!(stage.reload, user: user)
        end

        conversation_summaries = []
        conversation_scenarios.each_with_index do |conversation, index|
          break if recursive_dojo_canceled?(stage.reload, generation)

          summary = process_dojo_conversation!(
            stage.reload,
            user: user,
            conversation: conversation,
            cycle: single_turn_summaries.length + index + 1,
            total_cycles: total_cycles,
            writer_model: writer_model,
            generation: generation
          )
          conversation_summaries << summary if summary.present?
          broadcast_stage!(stage.reload, user: user)
        end
        cycle_summaries = single_turn_summaries + conversation_summaries
        return false if recursive_dojo_canceled?(stage.reload, generation)

        mark_recursive_dojo_running!(
          stage.reload,
          user: user,
          generation: generation,
          phase: "recursive_dojo_embedding",
          progress: {
            "cycle" => total_cycles,
            "total_cycles" => total_cycles,
            "kind" => "embedding",
            "title" => "Embedding dojo scorecards"
          }
        )
        broadcast_stage!(stage.reload, user: user)
        return false if recursive_dojo_canceled?(stage.reload, generation)

        learning_result = run_recursive_dojo_learning(stage.reload)
        append_dojo_event!(
          stage.reload,
          role: "dojo_summary",
          body: dojo_embedding_summary_body(learning_result, cycle_summaries),
          user: user,
          extra: {
            "dojo_generation" => generation,
            "dojo_cycles" => cycle_summaries,
            "embedding_summary" => learning_result&.to_h
          }
        )
        scroll_result = publish_recursive_dojo_scroll(stage.reload)
        scroll_links = dojo_scroll_links(scroll_result)
        append_dojo_event!(
          stage.reload,
          role: "dojo_scroll_summary",
          body: dojo_scroll_summary_body(scroll_result),
          user: user,
          extra: {
            "dojo_generation" => generation,
            "dojo_scroll_published" => scroll_result,
            "dojo_scroll_links" => scroll_links
          }
        ) if scroll_result.present?
        mark_recursive_dojo_complete!(stage.reload, learning_result: learning_result)
        broadcast_stage!(stage.reload, user: user)
        true
      rescue StandardError => error
        mark_recursive_dojo_failed!(stage, error) if stage.present?
        broadcast_stage!(stage.reload, user: user) if stage.present? && defined?(user) && user.present?
        Rails.logger.warn("[AskAutopilotTest] recursive dojo failed stage=#{stage_id} #{error.class}: #{error.message}")
        false
      end

      def clear(payload, organization:)
        stage = stage_from(payload, organization: organization)
        return nil if stage.blank?

        metadata = stage.metadata.to_h.deep_dup
        now_time = Time.current
        now = now_time.iso8601
        stage.update!(
          generated_at: now_time,
          metadata: metadata.merge(
            recursive_dojo_cancel_metadata(
              metadata,
              now: now,
              reason: "Clear test canceled any active Recursive Dojo run."
            )
          ).merge(
            "ask_autopilot_test_active" => false,
            "ask_autopilot_test_cleared_at" => now,
            "comms_command_last_status" => "ask_test_cleared"
          )
        )
        nil
      end

      def active?(payload)
        payload.to_h["active"] == true && (payload.to_h["stage_id"].present? || payload.to_h["messages"].present?)
      end

      private

      def sandbox_stage!(user:, organization:)
        raise ArgumentError, "organization required for Ask autopilot test" if organization.blank?
        raise ArgumentError, "user required for Ask autopilot test" if user.blank?

        record = organization.crm_records.find_or_initialize_by(
          record_type: "contact",
          source: SOURCE,
          source_uid: "ask-autopilot-test-user-#{user.id}"
        )
        record.assign_attributes(
          name: "Ask Autopilot Test - #{display_name(user)}",
          status: "active",
          owner: user,
          phone: simulated_customer_phone(user),
          email: "ask-test-#{user.id}@example.invalid",
          properties: record.properties.to_h.merge(
            "ask_autopilot_test" => true,
            "test_user_id" => user.id,
            "test_user_name" => display_name(user)
          ).compact_blank
        )
        record.save!

        stage = record.crm_record_artifacts
          .where(organization: organization, artifact_type: "comm_staging")
          .where("metadata ->> 'stage_type' = ?", STAGE_TYPE)
          .order(updated_at: :desc)
          .first
        stage ||= record.crm_record_artifacts.build(
          organization: organization,
          user: user,
          artifact_type: "comm_staging",
          title: "WIZWIKI COMMS TEST: Ask Autopilot"
        )
        stage
      end

      def reset_stage!(stage, user:, writer_model: nil)
        previous_metadata = stage.metadata.to_h
        product_lane = ask_product_lane_from_metadata(stage.metadata.to_h)
        raw_opener = Thumper::VoiceGuide.starter_sms(nil, product_lane: product_lane)
        metadata = base_stage_metadata(stage: stage, user: user, opener: raw_opener, writer_model: writer_model)
        metadata.merge!(
          recursive_dojo_cancel_metadata(
            previous_metadata,
            now: metadata["ask_autopilot_test_started_at"].presence || Time.current.iso8601,
            reason: "Reset test canceled any active Recursive Dojo run."
          )
        )
        metadata["product_interest_code"] = product_lane if product_lane.present?
        metadata["product_interest_label"] = dojo_route_label(product_lane) if product_lane.present?
        opener = simulator_outbound_body(raw_opener, metadata: metadata, include_opt_out_notice: true)
        metadata["composed_sms_body"] = opener
        metadata["sms_options"] = Array(metadata["sms_options"]).map do |option|
          option.to_h["id"].to_s == "ask-test-opener" ? option.to_h.merge("body" => opener) : option
        end
        stage.update!(
          status: "aircall_sent",
          user: stage.user || user,
          generated_at: Time.current,
          content_type: "application/json",
          metadata: metadata
        )
        appended = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "outbound",
            status: "sent",
            body: opener,
            from: SIMULATED_WIZWIKI_NUMBER,
            to: simulated_customer_phone(user),
            user: user
          ).merge(
            "autopilot" => true,
            "autopilot_start" => true,
            "ask_autopilot_test" => true,
            "draft_provider" => "deterministic/autopilot_opening",
            "draft_model" => "autos-opener",
            "draft_source" => "thumper_opening"
          )
        )
      end

      def simulator_outbound_body(value, metadata:, include_opt_out_notice: nil)
        body = value.to_s.squish
        return body if body.blank?
        return body unless defined?(Comms::SmsBodySafety)

        Comms::SmsBodySafety.prepare_outbound_body(
          body,
          metadata: metadata,
          include_opt_out_notice: include_opt_out_notice
        )
      end

      def ask_product_lane_from_metadata(metadata)
        metadata = metadata.to_h
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

      def base_stage_metadata(stage:, user:, opener:, writer_model: nil)
        contact_name = "Customer"
        company_name = "Customer"
        now = Time.current.iso8601
        writer_model = WizwikiSettings.normalize_sms_writer_model(writer_model.presence || WizwikiSettings.default_sms_writer_model)

        {
          "stage_type" => STAGE_TYPE,
          "ask_autopilot_test" => true,
          "ask_autopilot_test_active" => true,
          "ask_autopilot_test_started_at" => now,
          "ask_autopilot_test_user_id" => user.id,
          "ask_autopilot_test_user_name" => display_name(user),
          "comms_simulation_mode" => true,
          "sms_sending_disabled" => true,
          "sms_sending_disabled_reason" => "ask_autopilot_test_skips_twilio",
          "sms_autopilot_enabled" => false,
          "comms_board_state" => "hidden",
          "company_name" => company_name,
          "deal_name" => company_name,
          "captured_contact_name" => contact_name,
          "captured_company_name" => company_name,
          "comm_kit_direction" => "wizwiki_out",
          "comm_kit_direction_label" => "WIZWIKI COMMS TEST",
          "contact_options" => [
            { "id" => "ask-test-contact", "name" => contact_name, "company" => company_name, "record_type" => "ask_test", "reason" => "Ask SMS autopilot simulator" }
          ],
          "phone_options" => [
            { "id" => "ask-test-phone", "name" => contact_name, "value" => simulated_customer_phone(user), "reason" => "Ask SMS autopilot simulator" }
          ],
          "recipient_email_options" => [
            { "id" => "ask-test-email", "name" => contact_name, "value" => user_email(user), "reason" => "Ask SMS autopilot simulator" }
          ].select { |option| option["value"].present? },
          "selected_contact_id" => "ask-test-contact",
          "selected_phone_id" => "ask-test-phone",
          "selected_recipient_email_id" => user_email(user).present? ? "ask-test-email" : nil,
          "recipient_selection_summary" => "Ask simulator staged by #{display_name(user)}. Twilio delivery is disabled.",
          "sender_name" => display_name(user),
          "sender_phone" => user&.try(:display_phone_number).presence || SIMULATED_WIZWIKI_NUMBER,
          "sender_profile" => {
            "name" => display_name(user),
            "phone" => user&.try(:display_phone_number).presence || SIMULATED_WIZWIKI_NUMBER,
            "email" => user_email(user)
          }.compact_blank,
          "sms_options" => [{ "id" => "ask-test-opener", "tone" => "Thumper opener", "body" => opener }],
          "selected_sms_id" => "ask-test-opener",
          "composed_sms_body" => opener,
          "sms_thread" => [],
          "sms_draft_history" => [],
          "comms_bot_state" => {
            "contact_name" => contact_name,
            "company_name" => company_name
          },
          "sms_writer_model" => writer_model,
          "sms_writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
          "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(writer_model),
          "sms_writer_model_saved_at" => now,
          "sms_generation_pipeline" => "single_writer_guardrailed",
          "challenge_policy" => "SMS challenger is disabled. The selected SMS writer drafts once; Rails validates product fit, directness, and non-repetition before applying or sending.",
          "sms_autopilot_objective" => default_objective,
          "staged_at" => now,
          "staged_by_user_id" => user.id,
          "staged_by" => display_name(user),
          "source_crm_record_id" => stage.crm_record_id
        }.compact_blank
      end

      def draft_reply(stage, user:, inbound_event:)
        writer_args = {
          stage: stage.reload,
          user: user,
          operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: inbound_event["body"]),
          writer_model: stage.metadata.to_h["sms_writer_model"]
        }
        if sync_writer_mode?
          return DealReports::CommsDraftWriter.call(
            **writer_args,
            wait_seconds: ENV.fetch("ASK_AUTOPILOT_SYNC_WAIT_SECONDS", "2").to_i
          )
        end

        DealReports::CommsDraftWriter.queue_background(
          **writer_args
        )
      end

      def sync_writer_mode?
        ActiveModel::Type::Boolean.new.cast(ENV["ASK_AUTOPILOT_SYNC_WRITER"]) ||
          ActiveModel::Type::Boolean.new.cast(ENV["THUMPER_TRAINING_SYNC_WRITER"])
      end

      def live_sms_pipeline_mode?
        !ActiveModel::Type::Boolean.new.cast(ENV["ASK_AUTOPILOT_LEGACY_SIMULATOR_GUARDRAILS"])
      end

      def deterministic_simulator_fallbacks_enabled?
        return true unless live_sms_pipeline_mode?

        ActiveModel::Type::Boolean.new.cast(ENV["ASK_AUTOPILOT_DETERMINISTIC_FALLBACKS"])
      end

      def queue_recursive_dojo!(stage, guidance:, user:, generation:)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        last_scoreboard = completed_dojo_scoreboard_snapshot(metadata, completed_at: metadata["recursive_dojo_completed_at"].presence)
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "queued",
            "recursive_dojo_generation" => generation,
            "recursive_dojo_last_scoreboard" => last_scoreboard.presence || metadata["recursive_dojo_last_scoreboard"],
            "recursive_dojo_guidance" => guidance.to_s.squish.presence,
            "recursive_dojo_queued_at" => now,
            "recursive_dojo_running_at" => nil,
            "recursive_dojo_completed_at" => nil,
            "recursive_dojo_failed_at" => nil,
            "recursive_dojo_error" => nil,
            "recursive_dojo_embedding_summary" => nil,
            "recursive_dojo_current_cycle" => nil,
            "recursive_dojo_total_cycles" => nil,
            "recursive_dojo_current_kind" => nil,
            "recursive_dojo_current_title" => nil,
            "recursive_dojo_current_turn" => nil,
            "recursive_dojo_total_turns" => nil,
            "recursive_dojo_progress_at" => nil,
            "comms_command_background_status" => "queued",
            "comms_command_background_at" => now,
            "comms_command_background_running_at" => nil,
            "comms_command_background_error" => nil,
            "comms_command_last_status" => "recursive_dojo_queued",
            "comms_command_last_at" => now,
            "ask_autopilot_pending_started_at" => now,
            "ask_autopilot_pending_phase" => "recursive_dojo"
          ).compact_blank
        )

        append_dojo_event!(
          stage.reload,
          role: "dojo_guidance",
          body: guidance.to_s.squish.presence || "Run a recursive Thumper training cycle from the current simulator context.",
          user: user,
          extra: { "dojo_generation" => generation }
        )
      end

      def supersede_recursive_dojo_for_new_guidance!(stage, guidance:, reason:)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            recursive_dojo_cancel_metadata(
              metadata,
              now: now,
              reason: reason
            )
          ).merge(
            "recursive_dojo_superseded_at" => now,
            "recursive_dojo_superseded_previous_guidance" => metadata["recursive_dojo_guidance"].to_s.squish.presence,
            "recursive_dojo_superseded_by_guidance" => guidance.to_s.squish.presence
          ).compact_blank
        )
      end

      def mark_recursive_dojo_running!(stage, user:, generation:, phase: "recursive_dojo_drafting", progress: {})
        metadata = stage.metadata.to_h.deep_dup
        return false if metadata["recursive_dojo_status"].to_s.in?(%w[canceled cancelled failed])

        now = Time.current.iso8601
        generation = generation.presence || metadata["recursive_dojo_generation"]
        running_at = metadata["recursive_dojo_generation"].to_s == generation.to_s ? metadata["recursive_dojo_running_at"].presence : nil
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "running",
            "recursive_dojo_generation" => generation,
            "recursive_dojo_running_at" => running_at || now,
            "recursive_dojo_last_operator_id" => user&.id,
            "comms_command_background_status" => "running",
            "comms_command_background_running_at" => now,
            "comms_command_last_status" => "recursive_dojo_running",
            "comms_command_last_at" => now,
            "ask_autopilot_pending_started_at" => metadata["ask_autopilot_pending_started_at"].presence || now,
            "ask_autopilot_pending_phase" => phase,
            "recursive_dojo_progress_at" => now
          ).compact_blank
            .merge(recursive_dojo_progress_metadata(progress))
        )
      end

      def recursive_dojo_progress_metadata(progress)
        data = progress.to_h
        return {} if data.blank?

        {
          "recursive_dojo_current_cycle" => data["cycle"].presence || data[:cycle],
          "recursive_dojo_total_cycles" => data["total_cycles"].presence || data[:total_cycles],
          "recursive_dojo_current_kind" => data["kind"].presence || data[:kind],
          "recursive_dojo_current_title" => (data["title"].presence || data[:title]).to_s.squish.truncate(90, separator: " ").presence,
          "recursive_dojo_current_turn" => data["turn"].presence || data[:turn],
          "recursive_dojo_total_turns" => data["total_turns"].presence || data[:total_turns]
        }.compact_blank
      end

      def recursive_dojo_cancel_metadata(metadata, now:, reason:)
        data = metadata.to_h
        {
          "recursive_dojo_status" => "canceled",
          "recursive_dojo_canceled_at" => now,
          "recursive_dojo_cancel_reason" => reason,
          "recursive_dojo_canceled_generation" => data["recursive_dojo_generation"].presence,
          "recursive_dojo_running_at" => nil,
          "recursive_dojo_completed_at" => nil,
          "recursive_dojo_failed_at" => nil,
          "recursive_dojo_error" => nil,
          "recursive_dojo_embedding_summary" => nil,
          "recursive_dojo_current_cycle" => nil,
          "recursive_dojo_total_cycles" => nil,
          "recursive_dojo_current_kind" => nil,
          "recursive_dojo_current_title" => nil,
          "recursive_dojo_current_turn" => nil,
          "recursive_dojo_total_turns" => nil,
          "recursive_dojo_progress_at" => nil,
          "comms_command_sms_draft_body" => nil,
          "comms_command_sms_draft" => nil,
          "comms_command_background_question_id" => nil,
          "comms_command_background_status" => nil,
          "comms_command_background_at" => nil,
          "comms_command_background_running_at" => nil,
          "comms_command_background_error" => nil,
          "sms_reply_job_status" => nil,
          "sms_reply_job_queued_at" => nil,
          "sms_reply_job_running_at" => nil,
          "ask_autopilot_pending_started_at" => nil,
          "ask_autopilot_pending_phase" => nil,
          "ask_autopilot_sim_retry_key" => nil,
          "ask_autopilot_sim_retry_count" => nil,
          "ask_autopilot_sim_retry_reason" => nil,
          "ask_autopilot_sim_retry_previous_question_id" => nil,
          "ask_autopilot_sim_retry_at" => nil
        }
      end

      def mark_recursive_dojo_complete!(stage, learning_result:)
        metadata = stage.metadata.to_h.deep_dup
        completed_at = Time.current.iso8601
        completed_scoreboard = completed_dojo_scoreboard_snapshot(metadata, completed_at: completed_at)
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "complete",
            "recursive_dojo_completed_at" => completed_at,
            "recursive_dojo_last_scoreboard" => completed_scoreboard.presence || metadata["recursive_dojo_last_scoreboard"],
            "recursive_dojo_embedding_summary" => learning_result&.to_h,
            "recursive_dojo_current_cycle" => nil,
            "recursive_dojo_total_cycles" => nil,
            "recursive_dojo_current_kind" => nil,
            "recursive_dojo_current_title" => nil,
            "recursive_dojo_current_turn" => nil,
            "recursive_dojo_total_turns" => nil,
            "comms_command_background_status" => "dojo_complete",
            "comms_command_background_at" => Time.current.iso8601,
            "comms_command_last_status" => "recursive_dojo_complete",
            "comms_command_last_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
      end

      def mark_recursive_dojo_failed!(stage, error)
        return if stage.blank?

        metadata = stage.metadata.to_h.deep_dup
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "failed",
            "recursive_dojo_failed_at" => Time.current.iso8601,
            "recursive_dojo_error" => "#{error.class}: #{error.message}",
            "comms_command_background_status" => "failed",
            "comms_command_background_error" => "#{error.class}: #{error.message}",
            "comms_command_last_status" => "recursive_dojo_failed",
            "comms_command_last_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
      rescue StandardError => update_error
        Rails.logger.warn("[AskAutopilotTest] failed marking recursive dojo failure stage=#{stage&.id} #{update_error.class}: #{update_error.message}")
      end

      def recursive_dojo_active?(stage)
        metadata = stage.metadata.to_h
        metadata["recursive_dojo_status"].to_s.in?(%w[queued running]) &&
          (
            metadata["ask_autopilot_pending_phase"].to_s.start_with?("recursive_dojo") ||
            active_recursive_dojo_pending?(metadata)
          )
      end

      def recursive_dojo_canceled?(stage, generation = nil)
        metadata = stage.metadata.to_h
        return true if metadata["recursive_dojo_status"].to_s.in?(%w[canceled cancelled failed])

        current_generation = metadata["recursive_dojo_generation"].to_s
        generation.present? && current_generation.present? && current_generation != generation.to_s
      end

      def recover_stale_recursive_dojo!(stage)
        metadata = stage.metadata.to_h
        status = metadata["recursive_dojo_status"].to_s
        return false unless status.in?(%w[queued running])

        phase = metadata["ask_autopilot_pending_phase"].to_s
        background_status = metadata["comms_command_background_status"].to_s
        last_activity_at = recursive_dojo_last_activity_at(metadata)
        active_background = phase.start_with?("recursive_dojo") || background_status.in?(%w[queued running])
        active_job = recursive_dojo_active_job_exists?(stage, metadata)

        if active_background && !active_job
          return false if last_activity_at.present? && last_activity_at > recursive_dojo_orphaned_after
          return true if queue_recursive_dojo_resume!(
            stage.reload,
            "Recursive dojo status was still #{status}, but no queued, scheduled, or claimed recursive dojo job was active."
          )

          mark_recursive_dojo_orphaned!(
            stage,
            "Recursive dojo status was still #{status}, but no queued, scheduled, or claimed recursive dojo job was active."
          )
          return true
        end

        unless active_background
          return false if last_activity_at.present? && last_activity_at > recursive_dojo_orphaned_after
          return true if queue_recursive_dojo_resume!(
            stage.reload,
            "Recursive dojo status was still #{status}, but no recursive dojo phase or queued background job was active."
          )

          mark_recursive_dojo_orphaned!(
            stage,
            "Recursive dojo status was still #{status}, but no recursive dojo phase or queued background job was active."
          )
          return true
        end

        return false if last_activity_at.present? && last_activity_at > recursive_dojo_stale_after

        mark_recursive_dojo_failed!(
          stage,
          StandardError.new("Recursive dojo job became stale, likely after a worker restart. Start Recursive Dojo again.")
        )
        true
      end

      def queue_recursive_dojo_resume!(stage, reason)
        return false unless defined?(Comms::AskRecursiveDojoJob)

        metadata = stage.metadata.to_h.deep_dup
        generation = metadata["recursive_dojo_generation"].to_s.presence
        return false if generation.blank?
        return false unless stage.user_id.present?

        attempts = metadata["recursive_dojo_resume_attempt_count"].to_i
        return false if attempts >= recursive_dojo_resume_attempt_limit

        now = Time.current.iso8601
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "queued",
            "recursive_dojo_resume_attempt_count" => attempts + 1,
            "recursive_dojo_resume_queued_at" => now,
            "recursive_dojo_resume_reason" => reason.to_s.squish,
            "recursive_dojo_failed_at" => nil,
            "recursive_dojo_error" => nil,
            "comms_command_background_status" => "queued",
            "comms_command_background_at" => now,
            "comms_command_background_running_at" => nil,
            "comms_command_background_error" => "Recursive dojo resume queued after orphan detection.",
            "comms_command_last_status" => "recursive_dojo_resume_queued",
            "comms_command_last_at" => now,
            "ask_autopilot_pending_started_at" => now,
            "ask_autopilot_pending_phase" => "recursive_dojo_resume"
          ).compact_blank
        )

        Comms::AskRecursiveDojoJob.perform_later(
          stage_id: stage.id,
          user_id: stage.user_id,
          guidance: metadata["recursive_dojo_guidance"].to_s.presence,
          writer_model: metadata["sms_writer_model"].presence,
          generation: generation
        )
        Rails.logger.info("[AskAutopilotTest] queued recursive dojo resume stage=#{stage.id} generation=#{generation} attempts=#{attempts + 1}")
        true
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed queueing recursive dojo resume stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def recursive_dojo_resume_attempt_limit
        ENV.fetch("ASK_RECURSIVE_DOJO_RESUME_ATTEMPTS", "8").to_i.clamp(1, 10)
      end

      def recursive_dojo_active_job_exists?(stage, metadata)
        generation = metadata.to_h["recursive_dojo_generation"].to_s.presence
        return true if generation.blank?
        return true unless defined?(SolidQueue::Job)

        execution_classes = %w[
          SolidQueue::ReadyExecution
          SolidQueue::ClaimedExecution
          SolidQueue::ScheduledExecution
          SolidQueue::BlockedExecution
        ].filter_map { |name| name.safe_constantize }
        return true if execution_classes.blank?

        job_ids = execution_classes.flat_map do |execution_class|
          execution_class
            .joins(:job)
            .where(solid_queue_jobs: { class_name: "Comms::AskRecursiveDojoJob" })
            .pluck("solid_queue_jobs.id")
        end.uniq
        return false if job_ids.blank?

        SolidQueue::Job.where(id: job_ids).any? do |job|
          recursive_dojo_job_matches?(job, stage.id, generation)
        end
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed checking recursive dojo active jobs stage=#{stage&.id} #{error.class}: #{error.message}")
        true
      end

      def recursive_dojo_job_matches?(job, stage_id, generation)
        args = job.arguments.to_h
        payload = Array(args["arguments"] || args[:arguments]).first.to_h
        payload["stage_id"].to_i == stage_id.to_i && payload["generation"].to_s == generation.to_s
      rescue StandardError
        false
      end

      def mark_recursive_dojo_orphaned!(stage, message)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "recursive_dojo_status" => "failed",
            "recursive_dojo_failed_at" => now,
            "recursive_dojo_error" => message,
            "comms_command_last_status" => "recursive_dojo_stale",
            "comms_command_last_at" => now,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed marking orphaned recursive dojo stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def recursive_dojo_stale_after
        ENV.fetch("ASK_RECURSIVE_DOJO_STALE_MINUTES", "10").to_i.clamp(5, 120).minutes.ago
      end

      def recursive_dojo_orphaned_after
        ENV.fetch("ASK_RECURSIVE_DOJO_ORPHANED_MINUTES", "2").to_i.clamp(1, 30).minutes.ago
      end

      def recursive_dojo_last_activity_at(metadata)
        [
          metadata["comms_command_background_running_at"],
          metadata["comms_command_background_at"],
          metadata["ask_autopilot_pending_started_at"],
          metadata["recursive_dojo_progress_at"],
          metadata["recursive_dojo_running_at"],
          metadata["recursive_dojo_queued_at"]
        ].filter_map { |value| parse_simulator_time(value) }.max
      end

      def parse_simulator_time(value)
        return if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def process_dojo_scenario!(stage, user:, scenario:, cycle:, total_cycles: nil, writer_model:, generation:)
        inbound_event = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "inbound",
            status: "received",
            body: scenario,
            from: simulated_customer_phone(user),
            to: SIMULATED_WIZWIKI_NUMBER,
            user: user
          ).merge(
            "ask_autopilot_test" => true,
            "recursive_dojo" => true,
            "role" => "dojo_customer",
            "dojo_cycle" => cycle,
            "dojo_generation" => generation
          )
        )

        install_recursive_dojo_isolated_thread!(stage.reload, inbound_event: inbound_event)
        mark_recursive_dojo_running!(
          stage.reload,
          user: user,
          generation: generation,
          phase: "recursive_dojo_drafting",
          progress: {
            "cycle" => cycle,
            "total_cycles" => total_cycles,
            "kind" => "single",
            "title" => scenario
          }
        )
        begin
          priority_body = recursive_dojo_priority_fallback(stage.reload, inbound_event)
          if priority_body.present?
            reply_body = priority_body
            materialized_answer = nil
            result = {
              "body" => reply_body,
              "provider" => "local/ask_sim_quality_gate",
              "model" => WizwikiSettings.normalize_sms_writer_model(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
              "draft_source" => "thumper_guardrail",
              "reason" => "Recursive dojo used the simulator priority answer before drafting.",
              "writer_model" => WizwikiSettings.normalize_sms_writer_model(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
              "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
              "sms_generation_pipeline" => "single_writer_guardrailed",
              "sms_quality_gate" => "rewritten",
              "ask_quality_gate" => true
            }.compact_blank
          else
            result = draft_dojo_reply(stage.reload, user: user, inbound_event: inbound_event, writer_model: writer_model)
            materialized_answer = active_background_dojo_result?(stage.reload, result) ? wait_for_materialized_dojo_answer(stage.reload, inbound_event, result) : nil
            if materialized_answer.present?
              reply_body = materialized_answer["body"].to_s.squish
              result = result.to_h.merge(
                "body" => reply_body,
                "provider" => materialized_answer["draft_provider"].presence || result.to_h["provider"],
                "model" => materialized_answer["draft_model"].presence || result.to_h["model"],
                "draft_source" => materialized_answer["draft_source"].presence || result.to_h["draft_source"],
                "sms_quality_gate" => materialized_answer["sms_quality_gate"].presence || result.to_h["sms_quality_gate"],
                "autos_question_id" => materialized_answer["autos_question_id"].presence || result.to_h["autos_question_id"]
              ).compact_blank
              gated = apply_simulator_quality_gate(stage.reload, result, inbound_event)
              gated_body = safe_customer_sms_body(gated.to_h["body"]).presence
              if gated_body.present? && normalize_body(gated_body) != normalize_body(reply_body)
                update_materialized_dojo_answer!(stage.reload, materialized_answer, gated.merge("body" => gated_body))
                reply_body = gated_body
                result = gated.merge("body" => gated_body).compact_blank
                materialized_answer = nil
              end
            else
              result = apply_simulator_quality_gate(stage.reload, result, inbound_event)
              reply_body = safe_customer_sms_body(result.to_h["body"]).presence
              reply_body ||= local_simulator_fallback(inbound_event, metadata: stage.reload.metadata.to_h, stage: stage.reload) if deterministic_simulator_fallbacks_enabled?
              if reply_body.blank?
                recovered = recover_dojo_customer_reply(stage.reload, inbound_event, result, reason: "dojo_scenario_answer_timeout")
                reply_body = safe_customer_sms_body(recovered.to_h["body"]).presence
                result = recovered if reply_body.present?
              end
            end
          end

          priority_body = recursive_dojo_priority_fallback(stage.reload, inbound_event)
          if priority_body.present? && normalize_body(priority_body) != normalize_body(reply_body)
            reply_body = priority_body
            result = result.to_h.merge(
              "body" => reply_body,
              "provider" => "local/ask_sim_quality_gate",
              "model" => result.to_h["model"].presence || "deterministic_route_guardrail",
              "draft_source" => "thumper_guardrail",
              "reason" => "Recursive dojo forced the simulator priority answer before grading.",
              "sms_generation_pipeline" => "single_writer_guardrailed",
              "sms_quality_gate" => "rewritten",
              "ask_quality_gate" => true,
              "ask_quality_gate_replaced_body" => true
            ).compact_blank
            materialized_answer = nil
          end

          grade = grade_dojo_reply(stage.reload, inbound_event, reply_body, result)

          if materialized_answer.blank?
            append_stage_event!(
              stage.reload,
              event_payload(
                direction: "outbound",
                status: "sent",
                body: reply_body,
                from: SIMULATED_WIZWIKI_NUMBER,
                to: simulated_customer_phone(user),
                user: user
              ).merge(
                "autopilot" => true,
                "ask_autopilot_test" => true,
                "recursive_dojo" => true,
                "role" => "dojo_answer",
                "dojo_cycle" => cycle,
                "dojo_generation" => generation,
                "autopilot_reply_to_sid" => inbound_event["provider_message_id"].presence || inbound_event["id"],
                "draft_provider" => result["provider"],
                "draft_model" => result["model"],
                "draft_source" => result["draft_source"],
                "writer_model" => result["writer_model"],
                "writer_model_label" => result["writer_model_label"],
                "sms_generation_pipeline" => result["sms_generation_pipeline"],
                "sms_quality_gate" => result["sms_quality_gate"],
                "autos_question_id" => result["autos_question_id"],
                "dojo_grade" => grade
              ).compact_blank
            )
          end

          trajectory = dojo_single_turn_trajectory(
            stage.reload,
            cycle: cycle,
            generation: generation,
            scenario: scenario,
            inbound_event: inbound_event,
            answer: reply_body,
            draft_result: result,
            grade: grade
          )

          append_dojo_event!(
            stage.reload,
            role: "dojo_grade",
            body: dojo_grade_body(grade),
            user: user,
            extra: {
              "dojo_cycle" => cycle,
              "dojo_generation" => generation,
              "dojo_questions" => [scenario],
              "dojo_grade" => grade,
              "dojo_trajectory" => trajectory,
              "embedding_lesson" => grade["embedding_lesson"]
            }
          )

          {
            "cycle" => cycle,
            "scenario" => scenario,
            "answer" => reply_body,
            "score" => grade["score"],
            "verdict" => grade["verdict"],
            "findings" => grade["findings"],
            "trajectory" => trajectory
          }.compact_blank
        ensure
          clear_recursive_dojo_isolated_thread!(stage.reload, inbound_event: inbound_event)
        end
      end

      def process_dojo_conversation!(stage, user:, conversation:, cycle:, total_cycles: nil, writer_model:, generation:)
        conversation = conversation.to_h.deep_symbolize_keys
        conversation_id = conversation[:id].to_s.parameterize.presence || SecureRandom.hex(6)
        title = conversation[:title].to_s.squish.presence || "Complete conversation"
        turns = dojo_conversation_turn_payloads(conversation).first(dojo_conversation_turn_limit)
        return {} if turns.blank?

        install_dojo_conversation_context!(stage.reload, conversation)
        mark_recursive_dojo_running!(
          stage.reload,
          user: user,
          generation: generation,
          phase: "recursive_dojo_conversation",
          progress: {
            "cycle" => cycle,
            "total_cycles" => total_cycles,
            "kind" => "conversation",
            "title" => title,
            "turn" => 0,
            "total_turns" => turns.length
          }
        )
        conversation_thread = []
        turn_summaries = []
        last_inbound_event = nil

        turns.each_with_index do |turn_payload, turn_index|
          break if recursive_dojo_canceled?(stage.reload, generation)

          customer_messages = Array(turn_payload[:messages]).map { |message| message.to_s.squish }.reject(&:blank?)
          next if customer_messages.blank?

          customer_text = turn_payload[:customer].to_s.squish.presence || dojo_turn_customer_label(turn_payload)
          message_delay_seconds = turn_payload[:delay_seconds].to_i
          inbound_events = customer_messages.each_with_index.map do |message_text, message_index|
            created_at = (Time.current - ((customer_messages.length - message_index - 1) * message_delay_seconds).seconds).iso8601
            existing_dojo_conversation_event(
              stage.reload,
              generation: generation,
              conversation_id: conversation_id,
              cycle: cycle,
              turn_index: turn_index + 1,
              role: "dojo_conversation_customer",
              message_index: message_index + 1
            ) || append_stage_event!(
              stage.reload,
              event_payload(
                direction: "inbound",
                status: "received",
                body: message_text,
                from: simulated_customer_phone(user),
                to: SIMULATED_WIZWIKI_NUMBER,
                user: user
              ).merge(
                "created_at" => created_at,
                "ask_autopilot_test" => true,
                "recursive_dojo" => true,
                "role" => "dojo_conversation_customer",
                "dojo_conversation" => true,
                "dojo_conversation_id" => conversation_id,
                "dojo_conversation_title" => title,
                "dojo_cycle" => cycle,
                "dojo_turn_index" => turn_index + 1,
                "dojo_turn_message_index" => message_index + 1,
                "dojo_turn_message_count" => customer_messages.length,
                "dojo_message_delay_seconds" => message_index.zero? ? 0 : message_delay_seconds,
                "dojo_language_code" => conversation[:language_code].to_s.squish.presence,
                "dojo_language_label" => conversation[:language_label].to_s.squish.presence,
                "language_code" => conversation[:language_code].to_s.squish.presence,
                "language_label" => conversation[:language_label].to_s.squish.presence,
                "dojo_generation" => generation
              )
            )
          end.compact
          inbound_event = inbound_events.last
          next if inbound_event.blank?

          last_inbound_event = inbound_event
          conversation_thread.concat(inbound_events.map(&:to_h))
          grade_customer_messages = dojo_grade_customer_messages(inbound_events, fallback_messages: customer_messages)
          grade_customer_text = dojo_grade_customer_text(
            grade_customer_messages,
            fallback: customer_text,
            delay_seconds: message_delay_seconds
          )

          existing_answer = existing_dojo_conversation_answer(
            stage.reload,
            generation: generation,
            conversation_id: conversation_id,
            cycle: cycle,
            turn_index: turn_index + 1,
            inbound_event: inbound_event
          )
          if existing_answer.present?
            result = dojo_result_from_event(existing_answer)
            reply_body = dojo_grade_answer_body(existing_answer, existing_answer.to_h["body"])
            conversation_thread << existing_answer.to_h
            turn_summaries << {
              "turn" => turn_index + 1,
              "customer" => grade_customer_text,
              "customer_messages" => grade_customer_messages,
              "customer_original" => customer_text,
              "customer_original_messages" => customer_messages,
              "customer_message_count" => customer_messages.length,
              "customer_delay_seconds" => message_delay_seconds,
              "language_code" => conversation[:language_code].to_s.squish.presence,
              "language_label" => conversation[:language_label].to_s.squish.presence,
              "answer" => reply_body,
              "answer_original" => existing_answer.to_h["body"].to_s.squish.presence,
              "provider" => result.to_h["provider"],
              "model" => result.to_h["model"],
              "quality_gate" => result.to_h["sms_quality_gate"]
            }.compact_blank
            next
          end

          install_recursive_dojo_conversation_thread!(
            stage.reload,
            thread: conversation_thread,
            inbound_event: inbound_event,
            conversation_id: conversation_id,
            title: title
          )
          mark_recursive_dojo_running!(
            stage.reload,
            user: user,
            generation: generation,
            phase: "recursive_dojo_conversation_drafting",
            progress: {
              "cycle" => cycle,
              "total_cycles" => total_cycles,
              "kind" => "conversation",
              "title" => title,
              "turn" => turn_index + 1,
              "total_turns" => turns.length
            }
          )

          result, reply_body, materialized_answer = draft_dojo_conversation_turn(
            stage.reload,
            user: user,
            inbound_event: inbound_event,
            writer_model: writer_model
          )
          break if recursive_dojo_canceled?(stage.reload, generation)

          outbound_event = materialized_answer.presence
          if outbound_event.blank?
            outbound_event = existing_dojo_conversation_answer(
              stage.reload,
              generation: generation,
              conversation_id: conversation_id,
              cycle: cycle,
              turn_index: turn_index + 1,
              inbound_event: inbound_event
            )
            if outbound_event.present?
              reply_body = dojo_grade_answer_body(outbound_event, outbound_event.to_h["body"])
              result = dojo_result_from_event(outbound_event)
            else
              outbound_event = append_stage_event!(
                stage.reload,
                event_payload(
                  direction: "outbound",
                  status: "sent",
                  body: reply_body,
                  from: SIMULATED_WIZWIKI_NUMBER,
                  to: simulated_customer_phone(user),
                  user: user
                ).merge(
                  "autopilot" => true,
                  "ask_autopilot_test" => true,
                  "recursive_dojo" => true,
                  "role" => "dojo_conversation_answer",
                  "dojo_conversation" => true,
                  "dojo_conversation_id" => conversation_id,
                  "dojo_conversation_title" => title,
                  "dojo_cycle" => cycle,
                  "dojo_turn_index" => turn_index + 1,
                  "dojo_language_code" => conversation[:language_code].to_s.squish.presence,
                  "dojo_language_label" => conversation[:language_label].to_s.squish.presence,
                  "language_code" => conversation[:language_code].to_s.squish.presence,
                  "language_label" => conversation[:language_label].to_s.squish.presence,
                  "dojo_generation" => generation,
                  "autopilot_reply_to_sid" => inbound_event["provider_message_id"].presence || inbound_event["id"],
                  "draft_provider" => result.to_h["provider"],
                  "draft_model" => result.to_h["model"],
                  "draft_source" => result.to_h["draft_source"],
                  "writer_model" => result.to_h["writer_model"],
                  "writer_model_label" => result.to_h["writer_model_label"],
                  "sms_generation_pipeline" => result.to_h["sms_generation_pipeline"],
                  "sms_quality_gate" => result.to_h["sms_quality_gate"],
                  "autos_question_id" => result.to_h["autos_question_id"]
                ).compact_blank
              )
            end
          end

          outbound_payload = outbound_event.to_h.merge(
            "role" => "dojo_conversation_answer",
            "dojo_conversation" => true,
            "dojo_conversation_id" => conversation_id,
            "dojo_conversation_title" => title,
            "dojo_turn_index" => turn_index + 1
          ).compact_blank
          conversation_thread << outbound_payload
          grade_answer = dojo_grade_answer_body(outbound_event, reply_body)
          turn_summaries << {
            "turn" => turn_index + 1,
            "customer" => grade_customer_text,
            "customer_messages" => grade_customer_messages,
            "customer_original" => customer_text,
            "customer_original_messages" => customer_messages,
            "customer_message_count" => customer_messages.length,
            "customer_delay_seconds" => message_delay_seconds,
            "language_code" => conversation[:language_code].to_s.squish.presence,
            "language_label" => conversation[:language_label].to_s.squish.presence,
            "answer" => grade_answer,
            "answer_original" => outbound_event.to_h["body"].to_s.squish.presence,
            "provider" => result.to_h["provider"],
            "model" => result.to_h["model"],
            "quality_gate" => result.to_h["sms_quality_gate"]
          }.compact_blank
        end
        return {} if turn_summaries.blank? || turn_summaries.length < turns.length || recursive_dojo_canceled?(stage.reload, generation)

        grade = grade_dojo_conversation(stage.reload, conversation, turn_summaries)
        transcript = dojo_conversation_transcript(turn_summaries)
        trajectory = dojo_conversation_trajectory(
          stage.reload,
          cycle: cycle,
          generation: generation,
          conversation: conversation,
          conversation_id: conversation_id,
          title: title,
          turn_summaries: turn_summaries,
          transcript: transcript,
          grade: grade
        )
        append_dojo_conversation_grade_event!(
          stage.reload,
          body: dojo_conversation_grade_body(grade, title),
          user: user,
          generation: generation,
          conversation_id: conversation_id,
          cycle: cycle,
          extra: {
            "dojo_cycle" => cycle,
            "dojo_generation" => generation,
            "dojo_conversation" => true,
            "dojo_conversation_id" => conversation_id,
            "dojo_conversation_title" => title,
            "dojo_route_code" => conversation[:route_code].to_s.squish.presence,
            "dojo_language_code" => conversation[:language_code].to_s.squish.presence,
            "dojo_language_label" => conversation[:language_label].to_s.squish.presence,
            "dojo_conversation_objective" => conversation[:objective].to_s.squish.presence,
            "dojo_conversation_checks" => Array(conversation[:checks]).map { |check| check.to_s.squish }.reject(&:blank?),
            "dojo_conversation_turns" => turns.map { |turn| turn[:customer].presence || dojo_turn_customer_label(turn) },
            "dojo_conversation_transcript" => transcript,
            "dojo_conversation_answer_summary" => dojo_conversation_answer_summary(turn_summaries),
            "dojo_turns" => turn_summaries,
            "dojo_grade" => grade,
            "dojo_trajectory" => trajectory,
            "embedding_lesson" => grade["embedding_lesson"]
          }
        )

        {
          "cycle" => cycle,
          "conversation" => true,
          "conversation_id" => conversation_id,
          "title" => title,
          "turn_count" => turn_summaries.length,
          "transcript" => transcript,
          "score" => grade["score"],
          "verdict" => grade["verdict"],
          "findings" => grade["findings"],
          "trajectory" => trajectory
        }.compact_blank
      ensure
        clear_recursive_dojo_isolated_thread!(stage.reload, inbound_event: last_inbound_event) if last_inbound_event.present?
      end

      def remove_existing_dojo_conversation_grades!(stage, generation:, conversation_id:, cycle:)
        stage.with_lock do
          stage.reload
          metadata = stage.metadata.to_h.deep_dup
          thread = Array(metadata["sms_thread"]).map(&:to_h)
          filtered = thread.reject do |event|
            event["role"].to_s == "dojo_conversation_grade" &&
              event["dojo_generation"].to_s == generation.to_s &&
              event["dojo_conversation_id"].to_s == conversation_id.to_s &&
              event["dojo_cycle"].to_i == cycle.to_i
          end
          scorecards = remove_dojo_scorecard_ledger_entry(metadata, generation: generation, conversation_id: conversation_id, cycle: cycle)
          return false if filtered.length == thread.length && scorecards.length == Array(metadata["recursive_dojo_scorecards"]).length

          stage.update!(
            generated_at: Time.current,
            metadata: metadata.merge(
              "sms_thread" => filtered,
              "recursive_dojo_scorecards" => scorecards
            )
          )
          true
        end
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed removing duplicate dojo grade stage=#{stage&.id} cycle=#{cycle} #{error.class}: #{error.message}")
        false
      end

      def dojo_conversation_turn_payloads(conversation)
        Array(conversation.to_h[:turns] || conversation.to_h["turns"]).filter_map do |turn|
          payload = case turn
          when Hash
            turn.with_indifferent_access
          when Array
            { messages: turn }
          else
            { messages: [turn] }
          end

          messages = Array(payload[:messages].presence || payload[:customer_messages].presence || payload[:body]).map { |message| message.to_s.squish }.reject(&:blank?)
          next if messages.blank?

          delay_seconds = payload[:delay_seconds].presence || payload[:message_delay_seconds].presence || dojo_double_message_delay_seconds
          {
            customer: payload[:customer].to_s.squish.presence || dojo_turn_customer_label(messages: messages, delay_seconds: delay_seconds.to_i),
            messages: messages,
            delay_seconds: delay_seconds.to_i.clamp(0, 300)
          }
        end
      end

      def dojo_turn_customer_label(turn_payload = nil, messages: nil, delay_seconds: nil)
        payload = turn_payload.to_h
        messages = Array(messages.presence || payload[:messages] || payload["messages"]).map { |message| message.to_s.squish }.reject(&:blank?)
        delay_seconds = (delay_seconds.presence || payload[:delay_seconds] || payload["delay_seconds"] || dojo_double_message_delay_seconds).to_i
        return messages.first.to_s if messages.length <= 1

        messages.each_with_index.map do |message, index|
          index.zero? ? message : "+#{delay_seconds * index}s: #{message}"
        end.join(" ")
      end

      def dojo_grade_customer_messages(inbound_events, fallback_messages: [])
        fallbacks = Array(fallback_messages).map { |message| message.to_s.squish }.reject(&:blank?)
        messages = Array(inbound_events).each_with_index.filter_map do |event, index|
          event = event.to_h
          body = event["body"].to_s.squish.presence
          original = event["original_body"].to_s.squish.presence
          translated_to_english = event["translated_to"].to_s.casecmp("English").zero?
          normalized = (translated_to_english || original.present?) ? body : nil

          normalized.presence || body || fallbacks[index]
        end
        messages = fallbacks if messages.blank?
        messages
      end

      def dojo_grade_customer_text(messages, fallback:, delay_seconds:)
        messages = Array(messages).map { |message| message.to_s.squish }.reject(&:blank?)
        return fallback.to_s.squish if messages.blank?
        return messages.first if messages.length == 1

        dojo_turn_customer_label(messages: messages, delay_seconds: delay_seconds)
      end

      def dojo_grade_answer_body(event, fallback)
        event = event.to_h
        event["english_body"].to_s.squish.presence ||
          event["body_for_grade"].to_s.squish.presence ||
          fallback.to_s.squish
      end

      def dojo_double_message_delay_seconds
        ENV.fetch("ASK_RECURSIVE_DOJO_DOUBLE_TEXT_DELAY_SECONDS", "25").to_i.clamp(0, 300)
      end

      def append_dojo_conversation_grade_event!(stage, body:, user:, generation:, conversation_id:, cycle:, extra: {})
        payload = event_payload(
          direction: "outbound",
          status: "logged",
          body: body,
          from: SIMULATED_WIZWIKI_NUMBER,
          to: simulated_customer_phone(user),
          user: user
        ).merge(
          "channel" => "dojo",
          "ask_autopilot_test" => true,
          "recursive_dojo" => true,
          "role" => "dojo_conversation_grade",
          "draft_provider" => "recursive_dojo",
          "draft_model" => "dojo_auditor"
        ).merge(extra.to_h).compact_blank

        insert_dojo_conversation_grade_event!(
          stage,
          payload: payload,
          generation: generation,
          conversation_id: conversation_id,
          cycle: cycle
        )
      end

      def insert_dojo_conversation_grade_event!(stage, payload:, generation:, conversation_id:, cycle:)
        stage.with_lock do
          stage.reload
          metadata = stage.metadata.to_h.deep_dup
          thread = Array(metadata["sms_thread"]).map(&:to_h)
          filtered = thread.reject do |event|
            event["role"].to_s == "dojo_conversation_grade" &&
              event["dojo_generation"].to_s == generation.to_s &&
              event["dojo_conversation_id"].to_s == conversation_id.to_s &&
              event["dojo_cycle"].to_i == cycle.to_i
          end

          insert_index = filtered.rindex do |event|
            event["role"].to_s == "dojo_conversation_answer" &&
              event["dojo_generation"].to_s == generation.to_s &&
              event["dojo_conversation_id"].to_s == conversation_id.to_s &&
              event["dojo_cycle"].to_i == cycle.to_i &&
              !event["status"].to_s.in?(%w[failed canceled])
          end

          insert_index ||= filtered.rindex do |event|
            event["dojo_generation"].to_s == generation.to_s &&
              event["dojo_conversation_id"].to_s == conversation_id.to_s &&
              event["dojo_cycle"].to_i == cycle.to_i &&
              !event["status"].to_s.in?(%w[failed canceled])
          end

          if insert_index.present?
            filtered.insert(insert_index + 1, payload.to_h)
          else
            filtered << payload.to_h
          end

          stage.update!(
            generated_at: Time.current,
            metadata: metadata.merge(
              "sms_thread" => filtered,
              "recursive_dojo_scorecards" => upsert_dojo_scorecard_ledger(metadata, payload.to_h),
              "comms_command_last_channel" => "sms",
              "comms_command_last_status" => payload.to_h["status"],
              "comms_command_last_at" => Time.current.iso8601,
              "ask_autopilot_test_active" => true
            ).compact_blank
          )

          payload.to_h
        end
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed inserting dojo conversation grade stage=#{stage&.id} cycle=#{cycle} #{error.class}: #{error.message}")
        append_dojo_event!(
          stage.reload,
          role: "dojo_conversation_grade",
          body: payload.to_h["body"],
          user: stage.user,
          extra: payload.to_h.slice(
            "dojo_cycle",
            "dojo_generation",
            "dojo_conversation",
            "dojo_conversation_id",
            "dojo_conversation_title",
            "dojo_route_code",
            "dojo_conversation_objective",
            "dojo_conversation_checks",
            "dojo_conversation_turns",
            "dojo_conversation_transcript",
            "dojo_conversation_answer_summary",
            "dojo_questions",
            "dojo_turns",
            "dojo_grade",
            "dojo_trajectory",
            "embedding_lesson"
          )
        )
      end

      def existing_dojo_conversation_event(stage, generation:, conversation_id:, cycle:, turn_index:, role:, message_index: nil)
        Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).find do |event|
          message_matches = if message_index.present?
            event["dojo_turn_message_index"].to_i == message_index.to_i
          else
            true
          end

          event["role"].to_s == role.to_s &&
            event["dojo_generation"].to_s == generation.to_s &&
            event["dojo_conversation_id"].to_s == conversation_id.to_s &&
            event["dojo_cycle"].to_i == cycle.to_i &&
            event["dojo_turn_index"].to_i == turn_index.to_i &&
            message_matches &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
      end

      def existing_dojo_conversation_answer(stage, generation:, conversation_id:, cycle:, turn_index:, inbound_event:)
        explicit = existing_dojo_conversation_event(
          stage,
          generation: generation,
          conversation_id: conversation_id,
          cycle: cycle,
          turn_index: turn_index,
          role: "dojo_conversation_answer"
        )
        return explicit if explicit.present? && explicit.to_h["body"].to_s.squish.present?

        reply_to = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"].to_s
        Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
          event["direction"].to_s == "outbound" &&
            event["autopilot_reply_to_sid"].to_s == reply_to.to_s &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
      end

      def dojo_result_from_event(event)
        event = event.to_h
        {
          "provider" => event["draft_provider"],
          "model" => event["draft_model"],
          "draft_source" => event["draft_source"],
          "writer_model" => event["writer_model"],
          "writer_model_label" => event["writer_model_label"],
          "sms_generation_pipeline" => event["sms_generation_pipeline"],
          "sms_quality_gate" => event["sms_quality_gate"],
          "autos_question_id" => event["autos_question_id"]
        }.compact_blank
      end

      def draft_dojo_conversation_turn(stage, user:, inbound_event:, writer_model:)
        priority_body = recursive_dojo_priority_fallback(stage.reload, inbound_event)
        if priority_body.present?
          reply_body = priority_body
          materialized_answer = nil
          result = {
            "body" => reply_body,
            "provider" => "local/ask_sim_quality_gate",
            "model" => WizwikiSettings.normalize_sms_writer_model(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
            "draft_source" => "thumper_guardrail",
            "reason" => "Recursive dojo conversation used the simulator priority answer before drafting.",
            "writer_model" => WizwikiSettings.normalize_sms_writer_model(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
            "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model),
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "rewritten",
            "ask_quality_gate" => true
          }.compact_blank
        else
          result = draft_dojo_reply(stage.reload, user: user, inbound_event: inbound_event, writer_model: writer_model)
          materialized_answer = active_background_dojo_result?(stage.reload, result) ? wait_for_materialized_dojo_answer(stage.reload, inbound_event, result) : nil
          if materialized_answer.present?
            reply_body = materialized_answer["body"].to_s.squish
            result = result.to_h.merge(
              "body" => reply_body,
              "provider" => materialized_answer["draft_provider"].presence || result.to_h["provider"],
              "model" => materialized_answer["draft_model"].presence || result.to_h["model"],
              "draft_source" => materialized_answer["draft_source"].presence || result.to_h["draft_source"],
              "sms_quality_gate" => materialized_answer["sms_quality_gate"].presence || result.to_h["sms_quality_gate"],
              "autos_question_id" => materialized_answer["autos_question_id"].presence || result.to_h["autos_question_id"]
            ).compact_blank
            gated = apply_simulator_quality_gate(stage.reload, result, inbound_event)
            gated_body = safe_customer_sms_body(gated.to_h["body"]).presence
            if gated_body.present? && normalize_body(gated_body) != normalize_body(reply_body)
              update_materialized_dojo_answer!(stage.reload, materialized_answer, gated.merge("body" => gated_body))
              reply_body = gated_body
              result = gated.merge("body" => gated_body).compact_blank
              materialized_answer = nil
            end
          else
            result = apply_simulator_quality_gate(stage.reload, result, inbound_event)
            reply_body = safe_customer_sms_body(result.to_h["body"]).presence
            reply_body ||= local_simulator_fallback(inbound_event, metadata: stage.reload.metadata.to_h, stage: stage.reload) if deterministic_simulator_fallbacks_enabled?
            if reply_body.blank?
              recovered = recover_dojo_customer_reply(stage.reload, inbound_event, result, reason: "dojo_answer_timeout")
              reply_body = safe_customer_sms_body(recovered.to_h["body"]).presence
              result = recovered if reply_body.present?
            end
          end
        end

        priority_body = recursive_dojo_priority_fallback(stage.reload, inbound_event)
        if priority_body.present? && normalize_body(priority_body) != normalize_body(reply_body)
          reply_body = priority_body
          result = result.to_h.merge(
            "body" => reply_body,
            "provider" => "local/ask_sim_quality_gate",
            "model" => result.to_h["model"].presence || "deterministic_route_guardrail",
            "draft_source" => "thumper_guardrail",
            "reason" => "Recursive dojo conversation forced the simulator priority answer before grading.",
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "rewritten",
            "ask_quality_gate" => true,
            "ask_quality_gate_replaced_body" => true
          ).compact_blank
          materialized_answer = nil
        end

        [result.to_h.merge("body" => reply_body).compact_blank, reply_body.to_s.squish, materialized_answer]
      end

      def recover_dojo_customer_reply(stage, inbound_event, result, reason:)
        metadata = stage.metadata.to_h
        reply_body = local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if deterministic_simulator_fallbacks_enabled?
        reply_body = safe_customer_sms_body(reply_body).presence
        reply_body ||= default_simulator_customer_recovery(inbound_event, metadata: metadata)
        reply_body = safe_customer_sms_body(reply_body).presence
        return result.to_h if reply_body.blank?

        recovered = result.to_h.merge(
          "body" => reply_body,
          "provider" => result.to_h["provider"].presence || "local/dojo_customer_recovery",
          "model" => result.to_h["model"].presence || "deterministic_recovery",
          "draft_source" => "dojo_customer_recovery",
          "sms_quality_gate" => "recovered",
          "ask_quality_gate" => true,
          "error" => result.to_h["error"].presence || reason,
          "reason" => "Recovered a customer-facing simulator reply after Thumper did not materialize a sendable answer."
        ).compact_blank

        gated = apply_simulator_quality_gate(stage.reload, recovered, inbound_event)
        gated_body = safe_customer_sms_body(gated.to_h["body"]).presence
        return recovered if gated_body.blank?

        gated.to_h.merge("body" => gated_body).compact_blank
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] dojo customer recovery failed stage=#{stage&.id} #{error.class}: #{error.message}")
        result.to_h
      end

      def install_recursive_dojo_isolated_thread!(stage, inbound_event:)
        metadata = stage.metadata.to_h.deep_dup
        metadata["recursive_dojo_isolated_thread"] = recursive_dojo_isolated_thread(stage, inbound_event)
        metadata["recursive_dojo_isolated_inbound_id"] = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"]
        metadata["recursive_dojo_isolated_at"] = Time.current.iso8601
        stage.update!(generated_at: Time.current, metadata: metadata.compact_blank)
      end

      def install_recursive_dojo_conversation_thread!(stage, thread:, inbound_event:, conversation_id:, title:)
        metadata = stage.metadata.to_h.deep_dup
        metadata["recursive_dojo_isolated_thread"] = Array(thread).map(&:to_h).last(dojo_conversation_context_limit)
        metadata["recursive_dojo_isolated_inbound_id"] = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"]
        metadata["recursive_dojo_isolated_at"] = Time.current.iso8601
        metadata["recursive_dojo_conversation_id"] = conversation_id
        metadata["recursive_dojo_conversation_title"] = title
        stage.update!(generated_at: Time.current, metadata: metadata.compact_blank)
      end

      def install_dojo_conversation_context!(stage, conversation)
        route = conversation.to_h[:route_code].presence || conversation.to_h["route_code"].presence
        language_code = conversation.to_h[:language_code].presence || conversation.to_h["language_code"].presence
        language_label = conversation.to_h[:language_label].presence || conversation.to_h["language_label"].presence
        metadata = stage.metadata.to_h.deep_dup
        if route.present?
          route = route.to_s
          metadata["product_interest_code"] = route
          metadata["product_interest_label"] = dojo_route_label(route)
          metadata["comms_bot_state"] = metadata["comms_bot_state"].to_h.merge(
            "route_code" => route,
            "product_interest_code" => route,
            "product_interest" => dojo_route_label(route)
          ).compact_blank
          metadata["sms_lane_monitor"] = metadata["sms_lane_monitor"].to_h.merge(
            "route_code" => route,
            "label" => dojo_route_label(route),
            "source" => "recursive_dojo_conversation",
            "confidence" => 1.0,
            "reason" => "Scenario seeded lane context for full-conversation dojo testing."
          ).compact_blank
        else
          metadata.except!("product_interest_code", "product_interest_label")
          metadata["sms_lane_monitor"] = metadata["sms_lane_monitor"].to_h.except("route_code", "label", "source", "confidence", "reason")
        end
        if language_code.present?
          language_code = language_code.to_s
          language_label = language_label.to_s.presence || (defined?(Comms::SmsLanguageSupport) ? Comms::SmsLanguageSupport.language_label(language_code) : language_code.upcase)
          metadata["recursive_dojo_language_code"] = language_code
          metadata["recursive_dojo_language_label"] = language_label
          metadata["sms_language_preferred_code"] = language_code
          metadata["sms_language_preferred_label"] = language_label
          metadata["sms_language_preferred_at"] = Time.current.iso8601
        else
          metadata.except!("recursive_dojo_language_code", "recursive_dojo_language_label")
        end
        stage.update!(generated_at: Time.current, metadata: metadata.compact_blank)
      end

      def dojo_route_label(route)
        case route.to_s
        when "LAWN_SIGNS"
          "Yard Signs"
        when "EDDM"
          "EDDM"
        when "NEIGHBORHOOD_BLITZ"
          "Neighborhood Blitz"
        when "STARTER_PACK"
          "Starter Pack"
        when "PRO_PACK"
          "Pro Pack"
        else
          route.to_s.tr("_", " ").titleize.presence
        end
      end

      def clear_recursive_dojo_isolated_thread!(stage, inbound_event:)
        metadata = stage.metadata.to_h.deep_dup
        expected = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"]
        current = metadata["recursive_dojo_isolated_inbound_id"].to_s
        return false if current.present? && expected.present? && current != expected.to_s

        metadata.except!(
          "recursive_dojo_isolated_thread",
          "recursive_dojo_isolated_inbound_id",
          "recursive_dojo_isolated_at",
          "recursive_dojo_conversation_id",
          "recursive_dojo_conversation_title"
        )
        stage.update!(generated_at: Time.current, metadata: metadata)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed clearing dojo isolated thread stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def dojo_conversation_context_limit
        ENV.fetch("ASK_RECURSIVE_DOJO_CONVERSATION_CONTEXT_LIMIT", "12").to_i.clamp(4, 20)
      end

      def recursive_dojo_isolated_thread(stage, inbound_event)
        baseline = if ActiveModel::Type::Boolean.new.cast(ENV.fetch("ASK_RECURSIVE_DOJO_INCLUDE_BASE_THREAD", "false"))
          Array(stage.metadata.to_h["sms_thread"]).map(&:to_h).reject { |event| recursive_dojo_event?(event) }.last(4)
        else
          []
        end
        (baseline + [inbound_event.to_h]).compact
      end

      def recursive_dojo_event?(event)
        event = event.to_h
        ActiveModel::Type::Boolean.new.cast(event["recursive_dojo"]) ||
          event["role"].to_s.start_with?("dojo_") ||
          event["channel"].to_s == "dojo"
      end

      def draft_dojo_reply(stage, user:, inbound_event:, writer_model:)
        DealReports::CommsDraftWriter.call(
          stage: stage.reload,
          user: user,
          operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: inbound_event["body"]),
          writer_model: WizwikiSettings.normalize_sms_writer_model(
            writer_model.presence || stage.metadata.to_h["sms_writer_model"].presence || WizwikiSettings.default_sms_writer_model
          ),
          wait_seconds: ENV.fetch("ASK_RECURSIVE_DOJO_WAIT_SECONDS", "45").to_i
        )
      end

      def active_background_dojo_result?(stage, result)
        payload = result.to_h
        ActiveModel::Type::Boolean.new.cast(payload["pending"]) ||
          ActiveModel::Type::Boolean.new.cast(payload["background_queued"]) ||
          payload["autos_question_id"].present? ||
          payload["error"].to_s.match?(/\bstill running|timed out|queued in background\b/i) ||
          stage.metadata.to_h["comms_command_background_question_id"].present? ||
          stage.metadata.to_h["comms_command_background_status"].to_s.in?(%w[queued running drafting applied])
      end

      def wait_for_materialized_dojo_answer(stage, inbound_event, result)
        metadata = stage.reload.metadata.to_h
        question_id = result.to_h["autos_question_id"].presence || metadata["comms_command_background_question_id"].presence

        deadline = Time.current + ENV.fetch("ASK_RECURSIVE_DOJO_MATERIALIZE_WAIT_SECONDS", "180").to_i.clamp(1, 240).seconds
        loop do
          return nil if recursive_dojo_canceled?(stage.reload)

          materialized = materialized_dojo_answer_event(stage.reload, inbound_event, question_id)
          return materialized if materialized.present?

          question = AutosQuestion.find_by(id: question_id)
          if question&.status.to_s == "answered" && question.answer.to_s.squish.present? && defined?(DealReports::CommsDraftWriter)
            DealReports::CommsDraftWriter.apply_worker_answer!(question.reload)
          end

          break if Time.current >= deadline

          sleep 1
        end

        nil
      end

      def update_materialized_dojo_answer!(stage, materialized_answer, draft)
        event_id = materialized_answer.to_h["id"].to_s.presence
        provider_id = materialized_answer.to_h["provider_message_id"].to_s.presence
        return false if event_id.blank? && provider_id.blank?

        stage.with_lock do
          stage.reload
          metadata = stage.metadata.to_h.deep_dup
          thread = Array(metadata["sms_thread"]).map(&:to_h)
          index = thread.index do |event|
            event["id"].to_s == event_id.to_s ||
              (provider_id.present? && event["provider_message_id"].to_s == provider_id.to_s)
          end
          return false if index.blank?

          existing_event = thread[index]
          draft_body = draft.to_h["body"].to_s.squish
          language_metadata = {}
          updated_event = existing_event.merge(
            "body" => draft_body,
            "draft_provider" => draft.to_h["provider"].presence || existing_event["draft_provider"],
            "draft_model" => draft.to_h["model"].presence || existing_event["draft_model"],
            "draft_source" => draft.to_h["draft_source"].presence || existing_event["draft_source"],
            "writer_model" => draft.to_h["writer_model"].presence || existing_event["writer_model"],
            "writer_model_label" => draft.to_h["writer_model_label"].presence || existing_event["writer_model_label"],
            "sms_generation_pipeline" => draft.to_h["sms_generation_pipeline"].presence || existing_event["sms_generation_pipeline"],
            "sms_quality_gate" => draft.to_h["sms_quality_gate"].presence || existing_event["sms_quality_gate"],
            "ask_quality_gate" => draft.to_h["ask_quality_gate"],
            "ask_quality_gate_replaced_body" => draft.to_h["ask_quality_gate_replaced_body"],
            "quality_gate_rewritten_at" => Time.current.iso8601
          ).compact_blank

          if preserve_materialized_translation?(existing_event, draft_body)
            updated_event = updated_event.merge("body" => existing_event["body"])
          else
            language_stage = stage_for_materialized_translation(stage, metadata, existing_event)
            language_result = simulator_language_prepared_payload(language_stage, updated_event)
            updated_event = language_result[:payload]
            language_metadata = language_result[:metadata]
          end

          thread[index] = updated_event.compact_blank

          stage.update!(
            generated_at: Time.current,
            metadata: metadata.merge(language_metadata).merge("sms_thread" => thread)
          )
        end
        true
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed updating materialized dojo answer stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def materialized_dojo_answer_event(stage, inbound_event, question_id)
        inbound_id = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"].to_s
        Array(stage.metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
          reply_sid_matches = event["autopilot_reply_to_sid"].to_s == inbound_id.to_s
          recovered_retry_answer = ActiveModel::Type::Boolean.new.cast(event["failed_worker_recovery"]) ||
            ActiveModel::Type::Boolean.new.cast(event["simulator_no_ghost_fallback"])
          question_exact_matches = question_id.present? && event["autos_question_id"].to_s == question_id.to_s
          question_matches = question_id.blank? ||
            question_exact_matches ||
            (reply_sid_matches && recovered_retry_answer)

          event["direction"].to_s == "outbound" &&
            question_matches &&
            event["body"].to_s.squish.present? &&
            event["role"].to_s != "dojo_grade" &&
            !event["status"].to_s.in?(%w[failed canceled]) &&
            (
              reply_sid_matches ||
                (ActiveModel::Type::Boolean.new.cast(event["late_worker_writeback"]) && question_exact_matches)
            )
        end
      end

      def append_dojo_event!(stage, role:, body:, user:, status: "logged", extra: {})
        append_stage_event!(
          stage.reload,
          event_payload(
            direction: "outbound",
            status: status,
            body: body,
            from: SIMULATED_WIZWIKI_NUMBER,
            to: simulated_customer_phone(user),
            user: user
          ).merge(
            "channel" => "dojo",
            "ask_autopilot_test" => true,
            "recursive_dojo" => true,
            "role" => role,
            "draft_provider" => "recursive_dojo",
            "draft_model" => "dojo_auditor"
          ).merge(extra.to_h).compact_blank
        )
      end

      def dojo_single_turn_trajectory(stage, cycle:, generation:, scenario:, inbound_event:, answer:, draft_result:, grade:)
        {
          "schema" => "thumper_dojo_trajectory.v1",
          "kind" => "single_turn",
          "stage_id" => stage.id,
          "organization_id" => stage.organization_id,
          "cycle" => cycle,
          "generation" => generation,
          "created_at" => Time.current.iso8601,
          "input" => {
            "customer" => scenario.to_s.squish,
            "latest_inbound_event" => dojo_trajectory_event(inbound_event)
          }.compact_blank,
          "output" => {
            "answer" => answer.to_s.squish,
            "draft" => dojo_trajectory_draft(draft_result)
          }.compact_blank,
          "quality" => dojo_trajectory_grade(grade),
          "retrieval" => dojo_trajectory_retrieval(draft_result),
          "state" => dojo_trajectory_state(stage, inbound_event)
        }.compact_blank
      end

      def dojo_conversation_trajectory(stage, cycle:, generation:, conversation:, conversation_id:, title:, turn_summaries:, transcript:, grade:)
        {
          "schema" => "thumper_dojo_trajectory.v1",
          "kind" => "complete_conversation",
          "stage_id" => stage.id,
          "organization_id" => stage.organization_id,
          "cycle" => cycle,
          "generation" => generation,
          "conversation_id" => conversation_id,
          "title" => title,
          "created_at" => Time.current.iso8601,
          "input" => {
            "goal" => conversation.to_h[:goal].presence || conversation.to_h["goal"].presence,
            "turn_count" => Array(turn_summaries).length,
            "customer_turns" => Array(turn_summaries).map { |turn| turn.to_h["customer"].to_s.squish }.compact_blank,
            "customer_message_stacks" => Array(turn_summaries).map { |turn| Array(turn.to_h["customer_messages"]).map { |message| message.to_s.squish }.compact_blank }.reject(&:blank?)
          }.compact_blank,
          "output" => {
            "transcript" => transcript.to_s.squish,
            "answers" => Array(turn_summaries).map do |turn|
              {
                "turn" => turn.to_h["turn"],
                "answer" => turn.to_h["answer"],
                "provider" => turn.to_h["provider"],
                "model" => turn.to_h["model"],
                "quality_gate" => turn.to_h["quality_gate"]
              }.compact_blank
            end
          }.compact_blank,
          "quality" => dojo_trajectory_grade(grade),
          "state" => dojo_trajectory_state(stage, nil)
        }.compact_blank
      end

      def dojo_trajectory_event(event)
        payload = event.to_h
        {
          "id" => payload["id"],
          "provider_message_id" => payload["provider_message_id"],
          "direction" => payload["direction"],
          "body" => payload["body"].to_s.squish,
          "processing_code" => payload["processing_code"],
          "processing_label" => payload["processing_label"],
          "lane_monitor_route" => payload["lane_monitor_route"]
        }.compact_blank
      end

      def dojo_trajectory_draft(draft_result)
        result = draft_result.to_h
        {
          "provider" => result["provider"],
          "model" => result["model"],
          "draft_source" => result["draft_source"],
          "writer_model" => result["writer_model"],
          "writer_model_label" => result["writer_model_label"],
          "sms_generation_pipeline" => result["sms_generation_pipeline"],
          "sms_quality_gate" => result["sms_quality_gate"],
          "autos_question_id" => result["autos_question_id"],
          "ask_quality_gate" => result["ask_quality_gate"]
        }.compact_blank
      end

      def dojo_trajectory_grade(grade)
        payload = grade.to_h
        {
          "score" => payload["score"],
          "verdict" => payload["verdict"],
          "findings" => Array(payload["findings"]).map { |finding| finding.to_s.squish }.compact_blank,
          "rewrite" => payload["rewrite"].to_s.squish.presence,
          "embedding_lesson" => payload["embedding_lesson"].to_s.squish.presence,
          "judge_provider" => payload["judge_provider"],
          "judge_model" => payload["judge_model"]
        }.compact_blank
      end

      def dojo_trajectory_retrieval(draft_result)
        result = draft_result.to_h
        trace = result["rag_trace"].to_h
        retrieval = result["retrieval"].to_h
        return nil if trace.blank? && retrieval.blank?

        {
          "rag_trace" => trace.presence,
          "retrieval" => retrieval.slice("mode", "provider", "query", "returned_count", "source_types").compact_blank.presence
        }.compact_blank
      end

      def dojo_trajectory_state(stage, inbound_event)
        metadata = stage.metadata.to_h
        event = inbound_event.to_h
        {
          "product_interest_code" => metadata["product_interest_code"].presence || event["lane_monitor_route"].presence,
          "processing_code" => metadata["processing_code"].presence || event["processing_code"].presence,
          "processing_label" => metadata["processing_label"].presence || event["processing_label"].presence,
          "current_product_lane" => metadata["current_product_lane"].presence || metadata["sms_current_product_lane"].presence,
          "reset_at" => metadata["sms_conversation_reset_at"].presence
        }.compact_blank
      end

      def dojo_scenarios(guidance)
        return [] if review_all_dojo_requested?(guidance)

        guided = guidance_focus_scenario(guidance)
        scenarios = [guided].compact
        scenarios.concat(rotating_dojo_question_batch(guidance, limit: dojo_scenario_limit - scenarios.length))
        scenarios.map { |scenario| scenario.to_s.squish }.reject(&:blank?).uniq.first(dojo_scenario_limit)
      end

      def dojo_conversation_scenarios(guidance)
        limit = dojo_conversation_scenario_limit(guidance)
        return [] if limit <= 0

        required = multilingual_dojo_requested?(guidance) ? multilingual_dojo_conversation_scenarios : owner_yard_sign_conversation_scenarios
        guided = guidance_focus_conversation_scenario(guidance)
        return [guided].compact if review_all_dojo_requested?(guidance)

        scenarios = required.dup
        scenarios << guided if guided.present? && required.none? { |scenario| scenario[:id].to_s == guided[:id].to_s }
        scenarios.concat(rotating_dojo_conversation_batch(guidance, limit: limit - scenarios.length, exclude_ids: scenarios.map { |scenario| scenario[:id].to_s }))
        scenarios.uniq { |scenario| scenario[:id].to_s }.first(limit)
      end

      def rotating_dojo_conversation_batch(guidance, limit:, exclude_ids: [])
        return [] if limit.to_i <= 0

        seed = Digest::SHA1.hexdigest([
          "conversation",
          guidance.to_s.squish,
          Time.current.to_f,
          SecureRandom.hex(6)
        ].join(":")).to_i(16)
        dojo_conversation_bank
          .reject { |scenario| Array(exclude_ids).map(&:to_s).include?(scenario[:id].to_s) }
          .shuffle(random: Random.new(seed % (2**31)))
          .first(limit)
      end

      def rotating_dojo_question_batch(guidance, limit:)
        return [] if limit.to_i <= 0

        seed = Digest::SHA1.hexdigest([
          guidance.to_s.squish,
          Time.current.to_f,
          SecureRandom.hex(6)
        ].join(":")).to_i(16)
        dojo_question_bank.shuffle(random: Random.new(seed % (2**31))).first(limit)
      end

      def dojo_question_bank
        [
          "Before we go further, can you show me the sign package prices in plain English?",
          "What are the actual options I can buy today, with prices, for signs and starter bundles?",
          "Can you break down the $299 starter option versus the $599 pro option?",
          "If signs are the only thing I need, is there any reason to buy the bundle?",
          "I only have about a hundred dollars to test this. What yard-sign quantity fits?",
          "I need signs for lawns. how much r they?",
          "Use 48223. I have around $100 and this is for a local HVAC shop.",
          "Tell me the normal price for 500 yard signs.",
          "I may need around 1,200 pieces printed, but only quote the normal textable options for now.",
          "Can I pay now even if I still need help cleaning up the artwork?",
          "Do I get to review anything before production starts?",
          "Once I pay, where do I send the logo, colors, and notes?",
          "If I only have a headline and a picture idea, can the AI postcard builder help?",
          "The only logo I have is from Facebook and it looks rough. Is that usable?",
          "What is the usual proof timing after I place the order?",
          "I know I want signs, but I might also hit 750 nearby houses. What package should I compare?",
          "You already said Neighborhood Blitz fits my 720-home plan. I agree, please send the link.",
          "The Blitz recommendation is fine. Can you text the checkout now?",
          "Why are we talking postcards if my first question was about yard signs?",
          "Does the yard-sign checkout include door hangers or is that a separate bundle?",
          "If I buy yard signs only, am I also paying for postcards?",
          "What exactly is Neighborhood Blitz, simple version?",
          "For roughly 750 homes, should I pick EDDM or Neighborhood Blitz?",
          "This checkout page is vague. What am I buying if I use it?",
          "The link copy and your text don't match perfectly. Which details should I trust?",
          "I clicked the link and got confused. What is supposed to happen next?",
          "My area code is 48223. Does that change how you set up the order?",
          "48223 is the ZIP, and this is a sign order for a barber shop.",
          "If we're in Detroit, is the yard-sign price still the same?",
          "The number was 500 signs. Please don't ask me again.",
          "Before payment, tell me what this checkout covers.",
          "Can you answer directly whether location changes yard-sign pricing?",
          "Don't end the thread yet. I'm still comparing options.",
          "Could a real person call me if I get stuck ordering?",
          "I'm frustrated. Can someone from your team take over?",
          "If I go up to 2,000 yard signs, is there a standard bulk discount?",
          "Business name is Oak Ridge Roofing. I want signs and need the next step.",
          "Can the proof be sent to orders@example.com after I pay?",
          "Send the payment link and tell me what happens right after checkout."
        ]
      end

      def dojo_conversation_bank
        [
          *multilingual_dojo_conversation_scenarios,
          {
            id: "stop_by_not_stop_optout",
            title: "STOP word inside normal customer language",
            route_code: "LAWN_SIGNS",
            objective: "Treat stop/stop by as normal language unless the customer sends a hard STOP opt-out, answer the yard-sign question, and keep the thread alive.",
            turns: [
              "Sorry, I was under a sink and missed you. This is for my plumbing business.",
              "Can you stop by the shop later? For now, just text me the cheapest yard sign package.",
              "Out of curiosity, what would one sign work out to?",
              "Makes sense if one is not a checkout option. Send me the 10 sign yard-sign link."
            ],
            checks: %w[
              yard_sign_lead_opening
              yard_sign_cheapest_99
              one_unit_yard_sign_math
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "postcard_veteran_discount_special_named",
            title: "Veteran discount question with postcard special",
            route_code: "EDDM",
            objective: "Answer the discount question directly, use the full word veteran, do not invent a veteran discount, and name the postcard special when it fits.",
            turns: [
              "I run a veteran-owned roofing company and we are looking at postcards.",
              "Is there a veteran discount, or do you have a named postcard special running?",
              "If the numbers work, we would mail around 1,000 nearby homes.",
              "Send the 1,000 postcard special checkout."
            ],
            checks: %w[
              veteran_discount_no_fake_discount
              postcard_4th_special
              postcard_special_closest_tier
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          },
          {
            id: "full_pricing_then_narrow_to_signs",
            title: "Customer asks all pricing before narrowing",
            route_code: "GENERAL",
            objective: "When the customer asks for all main options, list the standard lanes and prices clearly, then follow their later yard-sign choice.",
            turns: [
              "I am comparing signs, postcards, and the starter bundle options.",
              "Before I pick a lane, can you give me the main options with prices?",
              "Which one is the lowest total to get started?",
              "Let's keep it signs only. Send the 10 yard sign option."
            ],
            checks: %w[
              full_options_pricing_summary
              yard_sign_cheapest_99
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "eddm_vs_neighborhood_blitz_one_each",
            title: "Plain EDDM versus Neighborhood Blitz comparison",
            route_code: "EDDM",
            objective: "Explain one EDDM route and one Neighborhood Blitz in plain language with prices, then send the selected link when accepted.",
            turns: [
              "We want to hit the streets around a few recent installs.",
              "Explain one EDDM route versus one Neighborhood Blitz in plain English. What do they cost?",
              "If I am aiming at about 650 homes and want more than mailbox-only, which fits?",
              "Blitz sounds right. Text me that checkout."
            ],
            checks: %w[
              eddm_nb_plain_compare
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          },
          {
            id: "rush_before_pricing_or_checkout",
            title: "Rush request before normal checkout",
            route_code: "LAWN_SIGNS",
            objective: "Answer rush timing directly, explain rush depends on product/quantity/timeline, and do not send normal checkout as the rush solution.",
            turns: [
              "I need yard signs fast for an event we are trying to hit.",
              "Could rush production get them done by next Friday?",
              "So the normal Shopify checkout is not the right way to handle rush?",
              "Yes, have a marketing consultant connect with me about rush."
            ],
            checks: %w[
              rush_consultant_no_checkout
              no_repeated_lane_discovery
            ]
          },
          {
            id: "proof_email_logo_cleanup",
            title: "Proof email and rough logo cleanup",
            route_code: "LAWN_SIGNS",
            objective: "Answer proof approval, upload/email, rough-logo cleanup, and 50-sign checkout without resetting discovery.",
            turns: [
              "We need 50 yard signs for a tree service.",
              "Will I get to approve a proof before printing, and can it go to office@example.com?",
              "The logo is just a rough screenshot right now. Can your team clean that up enough?",
              "Good. Send the 50 yard sign checkout."
            ],
            checks: %w[
              design_proof_flow
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "postcard_special_full_sheet_when_asked",
            title: "Full 4th of July postcard price sheet when requested",
            route_code: "EDDM",
            objective: "List every 4th of July postcard special tier only when the customer asks for the full price sheet, then quote the selected 5,000 tier.",
            turns: [
              "I am looking at postcard volumes for a roofing promo.",
              "Can you show the entire 4th of July Block Sale price sheet?",
              "What is the total at 5,000 postcards?",
              "Send me the 5,000 postcard block sale link."
            ],
            checks: %w[
              postcard_special_all_tiers
              postcard_5000_special
              link_after_acceptance
            ]
          },
          {
            id: "bundle_compare_then_signs_only",
            title: "Bundle comparison then signs-only pivot",
            route_code: "LAWN_SIGNS",
            objective: "Compare Starter and Pro bundles accurately, then switch back to signs-only when the customer says signs are all that matters.",
            turns: [
              "I started out looking at yard signs for my pest control company.",
              "Can you compare the $299 Starter Pack and $599 Pro Pack? I want to know what cards and hangers come with them.",
              "If the only thing I really care about is signs, which path is cleaner?",
              "Signs only then. Send the 100 yard sign checkout."
            ],
            checks: %w[
              starter_pro_bundle_compare
              signs_only_bundle_fit
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "answer_price_before_handoff",
            title: "Answer price before offering human help",
            route_code: "LAWN_SIGNS",
            objective: "When a customer asks for a person and a price in the same text, answer the price first, then offer handoff.",
            turns: [
              "Could someone call me, but first what do 500 yard signs cost?",
              "Does that include design, stakes, and shipping?",
              "Yes, have a person follow up on the 500 signs too."
            ],
            checks: %w[
              handoff_answer_first
              yard_sign_500_price
              design_shipping_included
              no_repeated_lane_discovery
            ]
          },
          {
            id: "one_postcard_minimum_path",
            title: "One-postcard question versus real minimum path",
            route_code: "EDDM",
            objective: "Answer one-postcard/per-unit curiosity without inventing a one-postcard checkout, then explain the smallest real postcard paths.",
            turns: [
              "What does one postcard cost by itself?",
              "I know I would probably need more than one. What is the smallest real postcard order path?",
              "If I go with 1,000 postcards, is that the 4th of July Block Sale?",
              "Yes, send the 1,000 postcard checkout link."
            ],
            checks: %w[
              one_postcard_no_single_checkout
              postcard_4th_special
              link_after_acceptance
            ]
          },
          {
            id: "live_double_text_before_reply",
            title: "Double-text before Thumper replies",
            route_code: "LAWN_SIGNS",
            objective: "Simulate two customer SMS messages 25 seconds apart before one Thumper answer; answer both the price and included-items questions in one reply.",
            turns: [
              {
                messages: [
                  "We need yard signs for a roofing push. What are my options?",
                  "Also, how much are 50 signs and do they include stakes?"
                ],
                delay_seconds: 25
              },
              "If that includes design and shipping too, send the 50 sign checkout."
            ],
            checks: %w[
              double_text_before_reply
              yard_sign_50_price
              design_shipping_included
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_triple_text_before_reply",
            title: "Triple-text before Thumper replies",
            route_code: "LAWN_SIGNS",
            objective: "Simulate three customer SMS messages 25 seconds apart before one Thumper answer; cover quantity, proof, and rush without ghosting earlier questions.",
            turns: [
              {
                messages: [
                  "I need signs for my landscaping company.",
                  "What do 100 yard signs cost?",
                  "Can I approve a proof before printing too?"
                ],
                delay_seconds: 25
              },
              "Actually we may need them fast. Can rush go through normal checkout?"
            ],
            checks: %w[
              triple_text_before_reply
              yard_sign_100_price
              design_proof_flow
              rush_consultant_no_checkout
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_customer_changes_lanes_mid_thread",
            title: "Customer changing lanes mid-thread",
            route_code: "LAWN_SIGNS",
            objective: "Start in yard signs, then honor a later actually/nevermind/prefer pivot to postcards instead of sending the older yard-sign link.",
            turns: [
              "I was looking at 50 yard signs for my roofing company.",
              {
                messages: [
                  "Can you send the 50 sign checkout link?",
                  "Actually nevermind, I prefer postcards instead. What is the special for 1,000 homes?"
                ],
                delay_seconds: 25
              },
              "Yes, send the 1,000 postcard special link."
            ],
            checks: %w[
              decision_change_honors_latest
              postcard_4th_special
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_two_questions_one_message",
            title: "Customer asks two questions in one message",
            route_code: "LAWN_SIGNS",
            objective: "When one SMS contains two questions, answer both before asking a follow-up.",
            turns: [
              "How much are 500 yard signs, and does that include design, stakes, and shipping?",
              "Good. Can someone follow up too?"
            ],
            checks: %w[
              two_questions_one_message
              yard_sign_500_price
              design_shipping_included
              handoff_answer_first
            ]
          },
          {
            id: "live_other_print_products",
            title: "Customer asks what other print products we offer",
            route_code: "GENERAL",
            objective: "Answer the product menu question with print-product coverage instead of defaulting straight into Starter/Pro bundles.",
            turns: [
              "Besides yard signs, what other print products do you offer?",
              "Could those include business cards, door hangers, or flyers?"
            ],
            checks: %w[
              print_products_coverage
              no_bundle_overpush
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_other_print_product_details",
            title: "Door hangers, business cards, flyers, and related print",
            route_code: "GENERAL",
            objective: "Handle door hanger, business card, flyer, and related print questions naturally without forcing a bundle unless the fixed bundle fits.",
            turns: [
              "I need door hangers and business cards for a cleaning company.",
              "Maybe flyers too. What can you help with, and when should I talk to a person?"
            ],
            checks: %w[
              print_products_coverage
              messy_print_consultant_handoff
              no_bundle_overpush
            ]
          },
          {
            id: "live_messy_print_consultant_handoff",
            title: "Messy print question should offer consultant",
            route_code: "GENERAL",
            objective: "When the print request is custom, unclear, or consultative, answer what can be answered and offer a marketing consultant instead of forcing checkout.",
            turns: [
              "I need flyers, maybe business cards, maybe door hangers, but I do not know sizes or quantities.",
              "Can Thumper figure all that out or should a real person help me choose?"
            ],
            checks: %w[
              messy_print_consultant_handoff
              no_bundle_overpush
            ]
          },
          {
            id: "live_direct_mail_strategy_boundary",
            title: "Direct-mail strategy question should hand off",
            route_code: "EDDM",
            objective: "Answer simple direct-mail context, then move route/list/software/strategy planning toward a marketing consultant instead of acting like a full consultant.",
            turns: [
              "We want direct mail for our roofing company.",
              "Can Thumper pick the best neighborhoods, routes, list strategy, and tell us exactly what would work for our business?"
            ],
            checks: %w[
              direct_mail_strategy_handoff
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_rush_no_normal_checkout",
            title: "Rush question without normal checkout",
            route_code: "LAWN_SIGNS",
            objective: "Answer rush directly and keep rush outside normal Shopify checkout unless a consultant confirms product, quantity, and timeline.",
            turns: [
              "I need yard signs in a hurry for an event.",
              "Can we rush them by next Friday, and should I use the normal checkout?"
            ],
            checks: %w[
              rush_consultant_no_checkout
              no_repeated_lane_discovery
            ]
          },
          {
            id: "live_proof_design_direct_not_canned",
            title: "Proof/design question answered directly",
            route_code: "LAWN_SIGNS",
            objective: "Answer proof/design questions directly and concisely without repeating the long canned paragraph.",
            turns: [
              "I have a rough logo screenshot for yard signs.",
              "Can I approve a proof before printing, and can your team clean up the logo? Please keep it simple."
            ],
            checks: %w[
              design_proof_flow
              proof_design_concise_not_canned
              no_repeated_lane_discovery
            ]
          },
          {
            id: "review_all",
            title: "Review all",
            route_code: "GENERAL",
            objective: "Replay the Sample Contact-style all-products SMS review as delayed multi-text bursts: honor the latest correction, answer specials and discounts, avoid yard-sign lane snapback, send the door-hanger link after acceptance, and route a frustrated human-handoff request.",
            turns: [
              {
                messages: [
                  "English is good. I'm in need of signs",
                  "I meant to say postcards",
                  "Do you have any specials"
                ],
                delay_seconds: 25
              },
              {
                messages: [
                  "Actually I want to get both",
                  "Do you have veteran discounts?"
                ],
                delay_seconds: 25
              },
              {
                messages: [
                  "Do you have business cards?",
                  "I need this rushed!",
                  "Do I need my own artwork?"
                ],
                delay_seconds: 25
              },
              {
                messages: [
                  "Can i get the business card link",
                  "What about door hangers?"
                ],
                delay_seconds: 25
              },
              {
                messages: [
                  "Yes please",
                  "this is taking too long i want to talke ot a human too"
                ],
                delay_seconds: 25
              }
            ],
            checks: %w[
              review_all_delayed_multi_texts
              review_all_postcard_correction
              review_all_veteran_discount
              review_all_rush_consultant
              review_all_artwork_no_sign_reset
              review_all_business_card_link
              review_all_door_hanger_pricing_prompt
              review_all_door_hanger_acceptance
              review_all_human_handoff
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_lead_pricing_flow",
            title: "Yard-sign lead from first message through pricing",
            route_code: "LAWN_SIGNS",
            objective: "Start in the yard-sign lane, avoid broad product discovery, answer options/pricing before asking another discovery question, and use customer-facing pricing language.",
            turns: [
              "We run a roofing crew and want those 18x24 signs for lawns after jobs wrap up.",
              "Before I pick a count, what are the sign price tiers?",
              "What is the total if we go with 100 signs?",
              "That works. Text me the yard-sign order link."
            ],
            checks: %w[
              yard_sign_lead_opening
              yard_sign_options_language
              yard_sign_100_price
              yard_sign_price_only_no_link
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_design_process",
            title: "Yard-sign lead asks design and artwork process",
            route_code: "LAWN_SIGNS",
            objective: "Keep the yard-sign lane and explain checkout, intake/upload, artwork help, proofing, and approval before print.",
            turns: [
              "I need yard signs for my plumbing company, but the only logo I have is kind of messy.",
              "Do I need finished artwork before I buy, or do I pay first and upload notes after?",
              "I want to make sure nothing prints until I approve the proof. Is that how it works?",
              "Okay, send me the yard-sign checkout link."
            ],
            checks: %w[
              design_proof_flow
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_turnaround",
            title: "Yard-sign lead asks turnaround",
            route_code: "LAWN_SIGNS",
            objective: "Answer turnaround/timing questions from supplied timing context without routing away or inventing unsupported dates.",
            turns: [
              "We're lining up yard signs for a roofing promo next month.",
              "After I place the order, how long is proofing, production, and shipping normally?",
              "If we end up needing them faster, what is the rush option?",
              "That timing is fine. Send the signs checkout."
            ],
            checks: %w[
              yard_sign_lead_opening
              yard_sign_turnaround_answer
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_ready_to_order",
            title: "Yard-sign lead ready to order and gets checkout link",
            route_code: "LAWN_SIGNS",
            objective: "After quantity and business context are known, send the yard-sign checkout link instead of asking to proceed again.",
            turns: [
              "This is for Summit Exterior Pros. We are only doing yard signs right now.",
              "Use the 50-sign option to start.",
              "Great, can you send the checkout link for that?"
            ],
            checks: %w[
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_switches_to_postcards",
            title: "Yard-sign lead switches to postcards/direct mail",
            route_code: "LAWN_SIGNS",
            objective: "Start from yard signs, then follow the customer's pivot to postcards/direct mail and apply postcard-only specials only after that pivot.",
            turns: [
              "I was originally checking yard signs for our roofing jobs.",
              "Actually I might rather mail postcards to 1,000 houses around the neighborhoods we work.",
              "If we do postcards at that size, is the 4th of July special the right pricing?",
              "Yes, let's use that postcard special. Send the link."
            ],
            checks: %w[
              yard_sign_to_postcard_switch
              postcard_4th_special
              postcard_special_closest_tier
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          },
          {
            id: "yard_sign_typo_pricing",
            title: "Yard-sign pronoun pricing with typo",
            route_code: "LAWN_SIGNS",
            objective: "After the customer chooses signs, treat misspelled how-much language as a price question and answer with yard-sign prices before asking quantity.",
            turns: [
              "yard signs only",
              "how mauch do they run?"
            ],
            checks: %w[
              yard_sign_pronoun_typo_price
            ]
          },
          {
            id: "yard_sign_affordability",
            title: "Yard-sign quantity, cheapest option, and specials",
            route_code: "LAWN_SIGNS",
            objective: "Keep the signs route across turns, quote 500 signs accurately, name the cheapest total option, and avoid fake postcard specials.",
            turns: [
              "This is Sample Owner Roofing. I need yard signs for job sites.",
              "Price it at 500 signs.",
              "That may be too much for this first run. What's the cheapest option overall?",
              "Do the 4th of July specials apply to yard signs?"
            ],
            checks: %w[
              yard_sign_500_price
              yard_sign_cheapest_99
              yard_sign_special_no_fake_discount
              no_repeated_lane_discovery
            ]
          },
          {
            id: "postcard_fourth_special",
            title: "Postcard 4th of July special after quantity",
            route_code: "EDDM",
            objective: "Only apply the 4th special when the customer is on postcards and at 1,000 or more.",
            turns: [
              "I want postcards mailed for my roofing business.",
              "Use 1,000 homes as the first count.",
              "Is there 4th of July special pricing for those postcards?"
            ],
            checks: %w[
              postcard_4th_special
              no_repeated_lane_discovery
            ]
          },
          {
            id: "design_proof_flow",
            title: "Artwork, upload, and proof flow",
            route_code: "LAWN_SIGNS",
            objective: "Explain checkout-first design intake over multiple proof questions without inventing manual steps.",
            turns: [
              "I want yard signs, but the artwork is not ready.",
              "After checkout, where do I upload the logo and notes?",
              "Will I approve a proof before anything goes to print?"
            ],
            checks: %w[
              design_proof_flow
              no_repeated_lane_discovery
            ]
          },
          {
            id: "link_after_acceptance",
            title: "Send the checkout link after acceptance",
            route_code: "NEIGHBORHOOD_BLITZ",
            objective: "Do not repeat the proceed question after the customer accepts a route-ready recommendation.",
            turns: [
              "I want to reach about 750 homes and have some local visibility beyond mail.",
              "Neighborhood Blitz sounds right. Please text the checkout link."
            ],
            checks: %w[
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          }
        ]
      end

      def owner_yard_sign_conversation_scenarios
        %w[
          live_double_text_before_reply
          live_triple_text_before_reply
          live_customer_changes_lanes_mid_thread
          live_two_questions_one_message
          live_other_print_products
          live_other_print_product_details
          live_messy_print_consultant_handoff
          live_direct_mail_strategy_boundary
          live_rush_no_normal_checkout
          live_proof_design_direct_not_canned
        ].filter_map { |id| dojo_conversation_by_id(id) }
      end

      def multilingual_dojo_conversation_scenarios
        [
          {
            id: "multilingual_spanish_yard_sign_cheapest",
            title: "Spanish yard-sign cheapest option and one-sign math",
            route_code: "LAWN_SIGNS",
            language_code: "es",
            language_label: "Spanish",
            objective: "Detect Spanish, keep the yard-sign lane, answer cheapest option, one-sign curiosity, included items, and checkout.",
            turns: [
              "Prefiero español. Tengo una compañía de techos y quiero letreros de jardín.",
              "¿Cuál es la opción más barata para empezar?",
              "¿Cuánto saldría cada letrero si solo quiero saber el costo de uno?",
              "¿Incluye diseño, estacas y envío?",
              "Mándame el enlace para 10 letreros."
            ],
            checks: %w[
              yard_sign_cheapest_99
              one_unit_yard_sign_math
              design_shipping_included
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_chinese_postcard_special",
            title: "Chinese postcard special and full price sheet",
            route_code: "EDDM",
            language_code: "zh",
            language_label: "Chinese",
            objective: "Detect Chinese, stay in postcards, answer the 4th of July Block Sale tiers, selected 5,000 tier, and checkout.",
            turns: [
              "请用中文回复。我想给屋顶公司做明信片推广。",
              "现在有没有七月四日的明信片特价？",
              "请列出完整价格表。",
              "如果我要 5,000 张，总价是多少？",
              "请发 5,000 张明信片的付款链接。"
            ],
            checks: %w[
              postcard_4th_special
              postcard_special_all_tiers
              postcard_5000_special
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_vietnamese_rush_handoff",
            title: "Vietnamese rush yard-sign handoff",
            route_code: "LAWN_SIGNS",
            language_code: "vi",
            language_label: "Vietnamese",
            objective: "Detect Vietnamese, quote the known 100-sign price, answer rush timing, avoid normal checkout for rush, and ask for consultant handoff.",
            turns: [
              "Tôi muốn nói tiếng Việt. Tôi cần bảng yard sign cho công ty sửa mái nhà.",
              "Tôi cần 100 bảng, giá bao nhiêu?",
              "Tôi có thể đặt gấp để kịp thứ Sáu tuần sau không?",
              "Vậy tôi có nên dùng checkout bình thường cho đơn gấp không?",
              "Được, hãy cho chuyên viên marketing liên hệ với tôi."
            ],
            checks: %w[
              yard_sign_100_price
              rush_consultant_no_checkout
              handoff_answer_first
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_russian_print_products",
            title: "Russian messy print products and consultant",
            route_code: "GENERAL",
            language_code: "ru",
            language_label: "Russian",
            objective: "Detect Russian, cover business cards, door hangers, flyers, avoid bundle overpush, and offer consultant help for custom print choices.",
            turns: [
              "Пожалуйста, отвечайте по-русски. Мне нужны печатные материалы для клининговой компании.",
              "Какие продукты кроме табличек вы можете предложить?",
              "Нужны визитки, дверные хэнгеры и, возможно, флаеры.",
              "Я не знаю размеры и количество, это слишком кастомно.",
              "Может ли маркетинговый консультант помочь выбрать?"
            ],
            checks: %w[
              print_products_coverage
              no_bundle_overpush
              messy_print_consultant_handoff
            ]
          },
          {
            id: "multilingual_arabic_direct_mail_strategy",
            title: "Arabic direct-mail strategy boundary",
            route_code: "EDDM",
            language_code: "ar",
            language_label: "Arabic",
            objective: "Detect Arabic, compare EDDM and Neighborhood Blitz, then hand off route, list, software, and targeting strategy.",
            turns: [
              "أفضّل العربية. أريد حملة بريد مباشر لشركة ترميم أسقف.",
              "ما الفرق بين EDDM و Neighborhood Blitz؟",
              "إذا كان عندي حوالي 650 منزلًا، أيهما أنسب؟",
              "هل يمكنك اختيار الأحياء والقوائم وخطة الاستهداف بالكامل؟",
              "نعم، وصّلني بمستشار تسويق لبحث التفاصيل."
            ],
            checks: %w[
              eddm_nb_plain_compare
              direct_mail_strategy_handoff
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_tagalog_bundle_to_signs",
            title: "Tagalog bundle comparison then signs-only pivot",
            route_code: "LAWN_SIGNS",
            language_code: "tl",
            language_label: "Tagalog",
            objective: "Detect Tagalog, compare Starter and Pro, pivot to signs-only, quote 100 signs, and send the yard-sign checkout.",
            turns: [
              "Tagalog sana ang sagot. Naghahanap ako ng yard signs para sa pest control business.",
              "Ano ang laman ng Starter Pack na $299 kumpara sa Pro Pack na $599?",
              "Kung signs lang talaga ang kailangan ko, alin ang mas malinaw na piliin?",
              "Magkano ang 100 yard signs?",
              "Sige, ipadala ang link para sa 100 signs."
            ],
            checks: %w[
              starter_pro_bundle_compare
              signs_only_bundle_fit
              yard_sign_100_price
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_korean_proof_design",
            title: "Korean proof and rough logo cleanup",
            route_code: "LAWN_SIGNS",
            language_code: "ko",
            language_label: "Korean",
            objective: "Detect Korean, answer 50-sign price, proof approval, rough-logo cleanup, and checkout without repeating canned design copy.",
            turns: [
              "한국어로 답해 주세요. 조경 회사용 야드 사인이 필요합니다.",
              "50개 가격이 얼마인가요?",
              "인쇄 전에 시안을 승인할 수 있나요?",
              "로고가 페이스북 캡처라 좀 흐린데 정리해 줄 수 있나요?",
              "좋아요. 50개 주문 링크를 보내 주세요."
            ],
            checks: %w[
              yard_sign_50_price
              design_proof_flow
              proof_design_concise_not_canned
              yard_sign_checkout_link
              no_repeated_lane_discovery
            ]
          },
          {
            id: "multilingual_portuguese_one_postcard",
            title: "Portuguese one-postcard minimum path",
            route_code: "EDDM",
            language_code: "pt",
            language_label: "Portuguese",
            objective: "Detect Portuguese, answer one-postcard curiosity, explain the smallest real postcard path, and send the 1,000-postcard special link.",
            turns: [
              "Prefiro português. Estou pensando em cartões postais para minha empresa de encanamento.",
              "Quanto custa um cartão postal sozinho?",
              "Qual é o menor caminho real para pedir postais?",
              "Se eu fizer 1.000 postais, isso entra na promoção 4th of July Block Sale?",
              "Sim, envie o link para 1.000 postais."
            ],
            checks: %w[
              one_postcard_no_single_checkout
              postcard_4th_special
              link_after_acceptance
              no_repeated_lane_discovery
            ]
          }
        ]
      end

      def dojo_conversation_by_id(id)
        dojo_conversation_bank.find { |scenario| scenario[:id].to_s == id.to_s }
      end

      def multilingual_dojo_requested?(guidance)
        topic = guidance.to_s.downcase
        topic.match?(/\b(?:multilingual|multi-language|multi language|languages?|translation|spanish|chinese|vietnamese|russian|arabic|tagalog|korean|portuguese|español|中文|tiếng việt|русский|العربية|한국어|português)\b/)
      end

      def review_all_dojo_requested?(guidance)
        topic = guidance.to_s.squish.downcase
        topic.match?(/\breview[_\s-]*all\b|\brevie\w*\s+all\b|\bsample_contact\b/)
      end

      def guidance_focus_scenario(guidance)
        text = guidance.to_s.squish
        return if text.blank?

        topic = text.downcase
        return "Is EDDM or Neighborhood Blitz better for 750 homes?" if topic.match?(/\b(?:eddm|neighborhood blitz|neighbourhood blitz|mail-only|mail only|750 homes)\b/)
        return "is the Pro Pack a better deal if I only need yard signs?" if topic.match?(/\b(?:signs[-\s]?only|only need signs|only want signs|pro pack.*signs|starter pack.*signs|bundle.*signs)\b/)
        return "I have about $100 to spend. How many yard signs does that get me?" if topic.match?(/\b(?:budget|\$|dolla(?:rs?)?|bucks?|hundred|100|signs?)\b/)
        return "How do I get my artwork, logo, and proof handled after I order?" if topic.match?(/\b(?:design|artwork|logo|proof|creative|ai art|postcard generator|upload)\b/)
        return "Can you give me the main packages and prices for signs, business cards, and postcards?" if topic.match?(/\b(?:all options|options|packages?|pricing|prices?|starter|pro pack|business cards?)\b/)
        return "My zip is 48223. Can you use that for this order?" if topic.match?(/\b(?:zip|zipcode|postal|location|48223)\b/)
        return "I need around 1,200 pieces. What are the standard options, and when would custom pricing make sense?" if topic.match?(/\b(?:large|volume|1200|1,200|bulk|custom quote|custom pricing)\b/)
        return "You already asked if I want to proceed with Neighborhood Blitz for 720 homes. Sounds good, send me the link." if topic.match?(/\b(?:sample_contact|same question|asked again|proceed|sounds good|send.*link|accepted|acceptance|neighborhood blitz)\b/)
        return "I do not understand the checkout link. What exactly am I buying?" if topic.match?(/\b(?:confused|understand|link|checkout|buying)\b/)

        "I am comparing postcards, yard signs, and bundles. What should I know before I order?"
      end

      def guidance_focus_conversation_scenario(guidance)
        text = guidance.to_s.squish
        return if text.blank?
        return if multilingual_dojo_requested?(text)

        topic = text.downcase
        return dojo_conversation_by_id("review_all") if review_all_dojo_requested?(topic)
        return dojo_conversation_by_id("yard_sign_affordability") if topic.match?(/\b(?:sample_contact|yard signs?|signs?|cheapest|cheap|500)\b/)
        return dojo_conversation_by_id("postcard_fourth_special") if topic.match?(/\b(?:postcards?|mailers?|eddm|1,?000|1000|fourth|july)\b/)
        return dojo_conversation_by_id("yard_sign_affordability") if topic.match?(/\b(?:specials?|discount|4th|july|pricing)\b/)
        return dojo_conversation_by_id("design_proof_flow") if topic.match?(/\b(?:design|artwork|logo|proof|upload|creative)\b/)
        return dojo_conversation_by_id("link_after_acceptance") if topic.match?(/\b(?:send.*link|checkout link|accepted|acceptance|proceed|sounds good|neighborhood blitz)\b/)

        nil
      end

      def dojo_scenario_limit
        return 0 unless dojo_single_turn_scenarios_enabled?

        ENV.fetch("ASK_RECURSIVE_DOJO_SCENARIO_LIMIT", "1").to_i.clamp(0, 6)
      end

      def dojo_conversation_scenario_limit(guidance = nil)
        if multilingual_dojo_requested?(guidance)
          configured = ENV["ASK_RECURSIVE_DOJO_CONVERSATION_LIMIT"].presence&.to_i
          floor = multilingual_dojo_conversation_scenarios.length
          return 0 if configured.present? && configured <= 0

          return [configured.presence || floor, floor].max.clamp(0, 24)
        end

        configured = ENV.fetch("ASK_RECURSIVE_DOJO_CONVERSATION_LIMIT", "10").to_i
        return 0 if configured <= 0

        [configured, owner_yard_sign_conversation_scenarios.length].max.clamp(0, 10)
      end

      def dojo_conversation_turn_limit
        ENV.fetch("ASK_RECURSIVE_DOJO_CONVERSATION_TURN_LIMIT", "5").to_i.clamp(2, 8)
      end

      def dojo_single_turn_scenarios_enabled?
        ActiveModel::Type::Boolean.new.cast(ENV["ASK_RECURSIVE_DOJO_SINGLE_TURN_ENABLED"])
      end

      def grade_dojo_reply(stage, inbound_event, reply_body, result)
        fallback_grade = deterministic_dojo_grade(stage, inbound_event, reply_body, result)
        return fallback_grade unless defined?(Comms::DojoJudge)

        Comms::DojoJudge.call(
          stage: stage,
          inbound: inbound_event.to_h["body"],
          answer: reply_body,
          draft_result: result,
          fallback_grade: fallback_grade
        )
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] dojo judge failed stage=#{stage&.id} #{error.class}: #{error.message}")
        fallback_grade || {
          "score" => 0,
          "verdict" => "REVIEW",
          "findings" => ["Dojo judge failed before a grade could be produced."],
          "judge_provider" => "deterministic/rules",
          "judge_model" => "rails_dojo_checklist",
          "judge_error" => "#{error.class}: #{error.message}"
        }
      end

      def grade_dojo_conversation(_stage, conversation, turn_summaries)
        deterministic_dojo_conversation_grade(conversation.to_h.deep_symbolize_keys, turn_summaries)
      end

      def deterministic_dojo_conversation_grade(conversation, turn_summaries)
        title = conversation[:title].to_s.squish.presence || "Complete conversation"
        checks = Array(conversation[:checks]).map(&:to_s)
        findings = []
        score = 92

        if Array(turn_summaries).blank?
          findings << "Complete conversation produced no turns to grade."
          score -= 55
        end

        repeated_findings, repeated_penalty = repeated_answer_findings(turn_summaries)
        findings.concat(repeated_findings)
        score -= repeated_penalty

        Array(turn_summaries).each do |turn|
          customer = dojo_turn_customer_text(turn)
          answer = dojo_turn_value(turn, "answer").to_s.squish
          display_answer = dojo_turn_value(turn, "answer_original").to_s.squish.presence || answer
          if answer.blank?
            findings << "Turn #{dojo_turn_value(turn, 'turn')} produced no customer-facing answer."
            score -= 35
            next
          end

          if dojo_display_failsafe_body?(display_answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} displayed a wait/fallback message instead of the customer-facing answer."
            score -= 34
          elsif dojo_display_language_mismatch?(turn, display_answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} displayed English instead of the customer's preferred language."
            score -= 18
          end

          if internal_leak_body?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} leaked internal reasoning, prompt, or guardrail language."
            score -= 35
          end

          if meta_preface_body?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} described the SMS instead of sending the customer-facing reply."
            score -= 28
          end

          if too_many_customer_questions?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} asked more than one customer question."
            score -= 7
          end

          if dojo_banned_starter?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} used a banned prompt-style starter instead of normal Thumper wording."
            score -= 22
          end

          if dojo_customer_echo_opening?(customer, answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} echoed the customer's message before answering."
            score -= 18
          end

          if dojo_proof_approval_question?(customer) && !dojo_proof_approval_answer?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} asked about proof/approval; answer should explain proof review and no printing before approval."
            score -= 32
          end

          if dojo_turnaround_or_rush_question?(customer) && !dojo_turnaround_or_rush_answer?(customer, answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} asked about timing/rush; answer should lead with timing or rush details, not pricing."
            score -= 32
          end

          if accepted_recommendation_link_request?(customer) && answer !~ %r{https?://|shop\.wizwikimarketing\.com}i
            findings << "Turn #{dojo_turn_value(turn, 'turn')} asked for the checkout link but the answer did not send one."
            score -= 34
          end

          if dojo_eddm_special_confusion?(answer)
            findings << "Turn #{dojo_turn_value(turn, 'turn')} mentioned EDDM pricing and the postcard special without clearly separating the two paths."
            score -= 16
          end
        end

        checks.each do |check|
          finding, penalty = dojo_conversation_check_result(check, turn_summaries)
          next if finding.blank?

          findings << finding
          score -= penalty.to_i
        end

        score = score.clamp(0, 100)
        verdict = score >= 85 ? "PASS" : "REVIEW"
        if findings.blank?
          score = [score + 4, 96].min
          findings << "Complete conversation held context, answered direct questions, and avoided repeated discovery."
        end

        {
          "score" => score,
          "verdict" => verdict,
          "findings" => findings.first(8),
          "provider" => Array(turn_summaries).map { |turn| dojo_turn_value(turn, "provider") }.compact_blank.uniq.join(" / ").presence,
          "model" => Array(turn_summaries).map { |turn| dojo_turn_value(turn, "model") }.compact_blank.uniq.join(" / ").presence,
          "quality_gate" => Array(turn_summaries).map { |turn| dojo_turn_value(turn, "quality_gate") }.compact_blank.tally,
          "judge_provider" => "deterministic/conversation_rules",
          "judge_model" => "rails_dojo_conversation_checklist",
          "embedding_lesson" => dojo_conversation_embedding_lesson(title, turn_summaries, findings, verdict)
        }.compact_blank
      end

      def dojo_conversation_check_result(check, turn_summaries)
        case check.to_s
        when "yard_sign_lead_opening"
          answer = dojo_turn_value(Array(turn_summaries).first, "answer").to_s.squish
          return ["Yard-sign lead opener should start in yard signs, not broad postcards/signs/both discovery.", 28] unless answer.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i)
          return ["Yard-sign lead opener repeated broad product discovery instead of honoring the lead lane.", 28] if broad_lane_discovery_answer?(answer)
          return ["Yard-sign lead opener sounded like a route label instead of a human reply.", 20] if canned_yard_sign_route_language?(answer)
          return ["Yard-sign lead opener should not push links, bundles, postcards, or EDDM before the customer asks.", 24] if premature_yard_sign_opener_close?(answer)
        when "yard_sign_options_language"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:options?|choices?|tiers?|quantit(?:y|ies)|prices?|pricing|costs?|how much)\b/i)
          return ["Yard-sign options turn should answer with listed 18x24 yard-sign tiers before asking another question.", 28] unless answer.match?(/\$\s?99\b/) && answer.match?(/\$\s?159\b/) && answer.match?(/\$\s?249\b/)
          return ["Yard-sign options turn used system/table phrasing like 'I see' or 'ladder' instead of customer-facing language.", 18] if system_table_language?(answer)
        when "yard_sign_100_price"
          answer = answer_after_turn_matching(turn_summaries, /\b100\b/)
          return ["100-sign yard-sign turn should quote the listed 100-sign price of $399.", 26] unless answer.match?(/\$\s?399\b/)
        when "yard_sign_50_price"
          answer = answer_after_turn_matching(turn_summaries, /\b50\b/)
          return ["50-sign yard-sign turn should quote the listed 50-sign price of $249.", 26] unless answer.match?(/\$\s?249\b/)
        when "yard_sign_price_only_no_link"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:total|price|cost|quote|how much)\b.{0,50}\b100\b|\b100\b.{0,50}\b(?:total|price|cost|quote|how much)\b/i)
          return ["Price-only yard-sign turn should quote the price and offer the link, not send a checkout URL before the customer asks for it.", 24] if answer.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
        when "yard_sign_500_price"
          answer = answer_after_turn_matching(turn_summaries, /\b500\b/)
          return ["500-sign yard-sign turn should quote the listed 500-sign price of $1,699 instead of drifting to another tier.", 26] unless answer.match?(/\$\s?1,?699\b/)
        when "yard_sign_cheapest_99"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:cheapest|cheap|least expensive|lowest|budget)\b/i)
          if answer.match?(/\b500\b.{0,80}\$\s?249\b|\$\s?249\b.{0,80}\b500\b/i)
            return ["Cheapest-option turn wrongly mapped the $249 tier to 500 signs; $249 is not the 500-sign price.", 35]
          end
          return ["Cheapest-option turn should say the cheapest total yard-sign entry point is 10 signs for $99 while volume tiers have better per-sign pricing.", 24] unless answer.match?(/\b10\b.{0,80}\$\s?99\b|\$\s?99\b.{0,80}\b10\b/i)
        when "one_unit_yard_sign_math"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:one|1)\s+(?:yard\s+)?sign\b|\bwhat\s+does\s+one\s+cost\b|\b(?:each|per)\s+(?:yard\s+)?sign\b|\bper[-\s]?sign\b|\bhow\s+much\s+would\s+each\b/i)
          return ["One-sign question should get a customer-facing answer instead of going blank.", 24] if answer.blank?
          return ["One-sign question should not send a checkout link or imply a one-sign checkout exists.", 28] if answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i)
          return ["One-sign answer should explain there is not a one-sign checkout and anchor the real entry point at 10 signs for $99.", 26] unless answer.match?(/\b(?:one|1|single|singles?)\b/i) && answer.match?(/\b(?:not|no|don'?t|doesn'?t|isn'?t|minimum|smallest|starts?)\b/i) && answer.match?(/\b10\b.{0,80}\$\s?99\b|\$\s?99\b.{0,80}\b10\b/i)
        when "yard_sign_special_no_fake_discount"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:special|deal|discount|4th|july)\b/i)
          if answer.match?(/\b(?:4th|july)\b/i) && answer.match?(/\$\s?(?:790|1,?725|3,?250|6,?300|14,?750)\b/) && answer.match?(/\byard signs?\b/i)
            return ["Yard-sign special turn applied the postcard-only 4th of July pricing to yard signs.", 30]
          end
          return ["Yard-sign special turn should clarify that the 4th special is postcard-only or that yard signs use listed yard-sign pricing.", 18] unless answer.match?(/\b(?:postcards?|not.*yard|no separate|standard|listed|current)\b/i) && answer.match?(/\byard signs?\b/i)
        when "yard_sign_pronoun_typo_price"
          answer = answer_after_turn_matching(turn_summaries, /\bhow\s+mauch\b/i)
          return ["Misspelled pronoun price turn did not produce an answer.", 22] if answer.blank?
          return ["Misspelled 'how much are they' turn should answer with yard-sign prices, not ask for quantity first.", 26] unless answer.match?(/\$\s?99\b/) && answer.match?(/\$\s?159\b/) && answer.match?(/\$\s?249\b/)
          return ["Misspelled price turn fell back to a quantity/discovery prompt without pricing.", 26] if answer.match?(/\b(?:simple next step is quantity|what sign count should i use|how many signs)\b/i) && !answer.match?(/\$\s?\d/)
        when "veteran_discount_no_fake_discount"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:veteran|vet)\b.{0,120}\b(?:discount|special|deal)\b|\b(?:discount|special|deal)\b.{0,120}\b(?:veteran|vet)\b/i)
          return ["Veteran-discount turn should answer directly and not go blank.", 24] if answer.blank?
          return ["Veteran-discount turn should use the full word veteran, not shorthand like vet.", 14] if answer.match?(/\bvet\b/i) && !answer.match?(/\bveteran\b/i)
          return ["Veteran-discount turn should say there is not a confirmed veteran discount instead of inventing one.", 30] unless answer.match?(/\b(?:do not|don't|doesn'?t|not|no)\b.{0,80}\bveteran\s+discount\b|\bveteran\s+discount\b.{0,80}\b(?:do not|don't|doesn'?t|not|no)\b/i)
          return ["Veteran-discount turn should name the 4th of July postcard special or Block Sale as the relevant active postcard offer.", 20] unless answer.match?(/\b(?:4th|fourth)\s+of\s+july\b/i) && answer.match?(/\b(?:block\s+sale|postcard\s+special|special)\b/i)
        when "full_options_pricing_summary"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:all|main|standard)\b.{0,80}\b(?:options?|prices?|pricing)\b|\bshow\s+me\b.{0,80}\b(?:options?|prices?|pricing)\b/i)
          return ["All-options pricing turn should list Starter, Pro, Yard Signs tiers, EDDM, and Neighborhood Blitz with prices.", 30] unless full_options_pricing_answer?(answer)
        when "postcard_4th_special"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:4th|july|pricing|special)\b/i)
          return ["Postcard 4th special turn should quote the 1,000-postcard special at $790 and keep it tied to postcards.", 26] unless answer.match?(/\bpostcards?\b/i) && answer.match?(/\$\s?790\b/) && answer.match?(/\b(?:1,?000|1k)\b/i)
        when "postcard_special_closest_tier"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:1,?000|1000|1k)\b.{0,80}\b(?:postcards?|homes?|houses?)\b|\b(?:postcards?|homes?|houses?)\b.{0,80}\b(?:1,?000|1000|1k)\b/i)
          return ["1,000-postcard/home turn should stay in postcards/direct mail and quote the 1,000-postcard special at $790.", 28] unless answer.match?(/\b(?:postcards?|postcard-only|block\s+sale|direct mail|mail)\b/i) && answer.match?(/\$\s?790\b/)
          if answer.match?(/\$\s?(?:1,?725|3,?250|6,?300|14,?750)\b/)
            return ["1,000-postcard special turn should lead with the closest tier, not dump every larger special tier unless the customer asks for all pricing.", 20]
          end
        when "postcard_special_all_tiers"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:full|all|price\s+sheet|tiers?)\b.{0,90}\b(?:4th|july|special|postcards?)\b|\b(?:4th|july|special|postcards?)\b.{0,90}\b(?:full|all|price\s+sheet|tiers?)\b|\b(?:full\s+)?price\s+sheet\b|\blist\s+(?:the\s+)?(?:full\s+)?(?:price\s+sheet|prices?|tiers?)\b/i)
          required_pairs = [
            [/\b(?:1,?000|1000|1k)\b/i, /\$\s?790\b/],
            [/\b(?:2,?500|2500|2\.5k)\b/i, /\$\s?1,?725\b/],
            [/\b(?:5,?000|5000|5k)\b/i, /\$\s?3,?250\b/],
            [/\b(?:10,?000|10000|10k)\b/i, /\$\s?6,?300\b/],
            [/\b(?:25,?000|25000|25k)\b/i, /\$\s?14,?750\b/]
          ]
          missing_pair = required_pairs.any? { |quantity_pattern, price_pattern| !answer.match?(quantity_pattern) || !answer.match?(price_pattern) }
          return ["Full postcard special price-sheet turn should include every requested 4th of July tier and price.", 28] if missing_pair
        when "postcard_5000_special"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:5,?000|5000|5k)\b.{0,80}\b(?:postcards?|total|expect|cost|price)\b|\b(?:postcards?|total|expect|cost|price)\b.{0,80}\b(?:5,?000|5000|5k)\b/i)
          return ["5,000-postcard special turn should quote the 4th of July total at $3,250.", 24] unless answer.match?(/\$\s?3,?250\b/)
        when "one_postcard_no_single_checkout"
          answers = answers_after_turns_matching(turn_summaries, /\b(?:one|1)\s+post\s*card\b|\bsmallest\s+real\s+postcard\s+(?:order\s+)?path\b|\bsmallest\b.{0,50}\bpostcards?\b/i)
          return ["One-postcard question should get a practical answer instead of going blank.", 24] if answers.blank?
          return ["One-postcard answer should not send a checkout URL before the customer chooses a real postcard path.", 28] if answers.any? { |answer| answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i) }
          return ["One-postcard answer should explain there is not a one-postcard checkout and anchor the smallest real postcard path.", 28] unless answers.any? { |answer| answer.match?(/\b(?:one|1|single|postcard)\b/i) && answer.match?(/\b(?:not|no|don'?t|doesn'?t|isn'?t|minimum|smallest|starts?|route|block)\b/i) && answer.match?(/\$\s?399\b|\$\s?790\b|\b(?:eddm|1,?000|1k)\b/i) }
        when "double_text_before_reply"
          turn = first_turn_with_customer_message_count(turn_summaries, 2)
          return ["Double-text scenario should create two inbound customer messages before one Thumper answer.", 30] if turn.blank?
          answer = dojo_turn_value(turn, "answer").to_s.squish
          return ["Double-text answer should cover both customer messages in one reply, including the 50-sign price and included stakes.", 32] unless answer.match?(/\$\s?249\b/) && answer.match?(/\bstakes?\b/i)
        when "triple_text_before_reply"
          turn = first_turn_with_customer_message_count(turn_summaries, 3)
          return ["Triple-text scenario should create three inbound customer messages before one Thumper answer.", 34] if turn.blank?
          answer = dojo_turn_value(turn, "answer").to_s.squish
          return ["Triple-text answer should cover the sign quantity and proof question in one reply.", 34] unless answer.match?(/\$\s?399\b/) && dojo_proof_approval_answer?(answer)
        when "decision_change_honors_latest"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:actually|nevermind|never mind|prefer|rather|instead)\b/i)
          return ["Decision-change turn should answer the customer's latest lane, not the older request.", 34] unless answer.match?(/\bpostcards?\b/i) && answer.match?(/\$\s?790\b/)
          return ["Decision-change turn should not send the older yard-sign checkout link after the customer pivoted away.", 34] if answer.match?(%r{/products/24x18-yard-signs}i)
        when "two_questions_one_message"
          answer = answer_after_turn_matching(turn_summaries, /\bhow much\b.{0,120}\band\b.{0,120}\b(?:include|included|design|stakes|shipping)\b/i)
          return ["Two-question SMS should answer both the price question and included-items question.", 34] unless answer.match?(/\$\s?1,?699\b/) && answer.match?(/\bdesign\b/i) && answer.match?(/\bstakes?\b/i) && answer.match?(/\bshipping\b/i)
        when "print_products_coverage"
          answers = answers_after_turns_matching(turn_summaries, /\b(?:other print products|business cards?|door hangers?|flyers?|what can you help)\b/i)
          return ["Print-products turn should mention practical print products beyond yard signs, including business cards, door hangers, and flyers or similar print pieces.", 30] if answers.blank?
          return ["Every print-products follow-up should stay in print products instead of falling back to yard signs, EDDM, or generic discovery.", 30] unless answers.all? { |answer| print_products_coverage_answer?(answer) && !wrong_print_product_lane_answer?(answer) }
        when "no_bundle_overpush"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:other print products|business cards?|door hangers?|flyers?|what can you help)\b/i)
          return ["Print-product answer should not default straight into Starter/Pro bundles without first answering the product question.", 24] if bundle_overpush_answer?(answer)
        when "messy_print_consultant_handoff"
          answers = answers_after_turns_matching(turn_summaries, /\b(?:messy|custom|sizes?|quantit(?:y|ies)|real person|person help|talk to a person|figure all that out|should a real person)\b/i)
          return ["Messy print request should offer a marketing consultant or teammate instead of forcing a checkout path.", 32] if answers.blank?
          return ["Messy print request should keep the answer in flyers, business cards, door hangers, or custom print before offering handoff.", 32] unless answers.all? { |answer| consultant_handoff_answer?(answer) && print_product_context_answer?(answer) && !wrong_print_product_lane_answer?(answer) }
          return ["Messy print request should not send a checkout link before the product, size, and quantity are clear.", 28] if answers.any? { |answer| answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i) }
        when "review_all_delayed_multi_texts"
          stacked_turns = Array(turn_summaries).select { |turn| dojo_turn_value(turn, "customer_message_count").to_i > 1 }
          counts = stacked_turns.map { |turn| dojo_turn_value(turn, "customer_message_count").to_i }
          return ["Review all should run as delayed multi-text SMS bursts before one Thumper answer, not single-message turns.", 34] if stacked_turns.blank?
          return ["Review all should include both 2-text and 3-text customer bursts like the live delayed multi-text tests.", 34] unless counts.include?(2) && counts.include?(3)
          return ["Review all delayed multi-text bursts should use the 25-second spacing from the live double/triple-text tests.", 30] unless stacked_turns.all? { |turn| dojo_turn_value(turn, "customer_delay_seconds").to_i == 25 }
        when "review_all_postcard_correction"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:meant to say postcards|specials?)\b/i)
          return ["Review all opening should answer the postcard/specials correction instead of reverting to yard-sign pricing.", 34] if answer.match?(/\byard\s+signs?\s+package\b|\bhow many signs\b|\bwhat quantity.*signs\b/i)
          return ["Review all opening should mention the postcard-only special or ask for postcard reach after the customer corrected signs to postcards.", 28] unless answer.match?(/\b(?:postcard-only|postcards?|block\s+sale|1,?000|homes?|mail)\b/i)
        when "review_all_veteran_discount"
          answer = answer_after_turn_matching(turn_summaries, /\bveteran\b.{0,80}\bdiscounts?\b|\bdiscounts?\b.{0,80}\bveteran\b/i)
          return ["Review all veteran-discount turn should answer directly, not go blank.", 24] if answer.blank?
          return ["Review all veteran-discount turn should not invent a veteran discount.", 30] unless answer.match?(/\b(?:no|not|do not|don't|doesn'?t|not specifically|not a)\b.{0,80}\bveteran\s+discount\b|\bveteran\s+discount\b.{0,80}\b(?:no|not|do not|don't|doesn'?t|not specifically|not a)\b/i)
        when "review_all_rush_consultant"
          answer = answer_after_turn_matching(turn_summaries, /\brush/i)
          return ["Review all rush turn should route rush handling to a consultant instead of normal checkout.", 34] unless dojo_turnaround_or_rush_answer?("rush", answer) && consultant_handoff_answer?(answer)
          return ["Review all rush turn should not send a normal checkout link as the rush solution.", 34] if answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i)
        when "review_all_artwork_no_sign_reset"
          answer = answer_after_turn_matching(turn_summaries, /\bown artwork\b|\bartwork\b/i)
          return ["Review all artwork turn should answer artwork/intake/proof help directly.", 30] unless answer.match?(/\b(?:artwork|design|logo|images?|intake|upload|proof|approve|approval|checkout|order)\b/i)
          return ["Review all artwork turn should not snap back to asking for sign quantity after business cards/door hangers entered the thread.", 34] if answer.match?(/\b(?:what quantity|how many|price for)\b.{0,40}\bsigns?\b|\bsigns?\b.{0,40}\b(?:what quantity|how many|price for)\b/i)
        when "review_all_business_card_link"
          answer = answer_after_turn_matching(turn_summaries, /\bbusiness\s+card\b.{0,80}\blink\b|\blink\b.{0,80}\bbusiness\s+card\b/i)
          return ["Review all business-card link turn should send the Business Cards checkout URL.", 30] unless answer.match?(%r{shop\.wizwikimarketing\.com/products/business-cards}i)
        when "review_all_door_hanger_pricing_prompt"
          answer = answer_after_turn_matching(turn_summaries, /\bwhat about door\s*hangers?\b/i)
          return ["Review all door-hanger turn should answer door-hanger pricing/details before asking whether to send the link.", 30] unless answer.match?(/\bdoor[-\s]*hangers?\b/i) && answer.match?(/\$\s?270\b|\b500\b/i) && answer.match?(/\bcheckout link\b/i)
        when "review_all_door_hanger_acceptance"
          answer = answer_after_turn_matching(turn_summaries, /\byes please\b/i)
          return ["Review all final acceptance should send the Door Hangers checkout URL.", 36] unless answer.match?(%r{shop\.wizwikimarketing\.com/products/door-hangers}i)
          return ["Review all final acceptance must not send the stale Business Cards checkout URL.", 40] if answer.match?(%r{shop\.wizwikimarketing\.com/products/business-cards|business cards starts}i)
        when "review_all_human_handoff"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:taking too long|talke ot a human|talk to a human|human)\b/i)
          return ["Review all frustrated human request should offer or confirm a marketing consultant/human handoff.", 34] unless consultant_handoff_answer?(answer)
          return ["Review all human-handoff turn should not ask another broad product-discovery question.", 24] if answer.match?(/\b(?:mailboxes|signs in the ground|or both|what product and quantity)\b/i)
          return ["Review all human-handoff turn should not send the stale Business Cards checkout URL.", 40] if answer.match?(%r{shop\.wizwikimarketing\.com/products/business-cards|business cards starts}i)
        when "direct_mail_strategy_handoff"
          strategy_question = /\b(?:choose|pick|select|target(?:ing)?|strategy|plan|handle|do)\b.{0,120}\b(?:neighborhoods?|routes?|lists?|targeting|strategy|software|plan)\b|\b(?:neighborhoods?|routes?|lists?|targeting|strategy|software|plan)\b.{0,120}\b(?:choose|pick|select|target(?:ing)?|handle|do|completely|for\s+me)\b|\bwhat\s+would\s+work\b/i
          answer = answer_after_turn_matching(turn_summaries, strategy_question)
          return ["Direct-mail strategy question should move route/list/software planning toward a marketing consultant.", 34] unless consultant_handoff_answer?(answer) && answer.match?(/\b(?:strategy|routes?|lists?|targeting|neighborhoods?|details)\b/i)
          return ["Direct-mail strategy boundary should not send checkout as the solution for route/list strategy.", 28] if answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i)
        when "proof_design_concise_not_canned"
          proof_design_question = /\b(?:proof|approve|approval|printing|print)\b.{0,160}\b(?:logo|rough|screenshot|clean\s*up|cleaned\s*up|artwork)\b|\b(?:logo|rough|screenshot|clean\s*up|cleaned\s*up|artwork)\b.{0,160}\b(?:proof|approve|approval|printing|print)\b/i
          answer = answer_after_turn_matching(turn_summaries, proof_design_question)
          answer = answer_after_turn_matching(turn_summaries, /\b(?:proof|approve|approval)\b/i) if answer.blank?
          return ["Proof/design answer should answer approval and logo cleanup directly.", 30] unless dojo_proof_approval_answer?(answer) && answer.match?(/\b(?:clean up|use what you have|rough|logo|artwork|design)\b/i)
          return ["Proof/design answer should be concise and not repeat the long canned design paragraph.", 22] if canned_proof_design_paragraph?(answer)
        when "design_proof_flow"
          whole_answer = Array(turn_summaries).map { |turn| dojo_turn_value(turn, "answer").to_s }.join(" ")
          has_checkout = whole_answer.match?(/\b(?:checkout|order|after you place|after checkout)\b/i)
          has_upload = whole_answer.match?(/\b(?:upload|logo|artwork|images?|wording|intake|email)\b/i)
          has_proof = whole_answer.match?(/\b(?:proof|approve|approval|nothing prints|before printing)\b/i)
          return ["Design/proof conversation should cover checkout first, upload or intake after checkout, and proof approval before printing.", 30] unless has_checkout && has_upload && has_proof

          proof_turn_answer = answer_after_turn_matching(turn_summaries, /\b(?:proof|approve|approval|printed|printing|print)\b/i)
          if proof_turn_answer.present? && !dojo_proof_approval_answer?(proof_turn_answer)
            return ["The proof/approval turn should answer proof approval directly, not reset to pricing or quantity discovery.", 34]
          end
        when "yard_sign_turnaround_answer"
          timing_answer = answer_after_turn_matching(turn_summaries, /\b(?:how long|turnaround|take|timeline|paying to proof|print|shipping)\b/i)
          rush_answer = answer_after_turn_matching(turn_summaries, /\b(?:rush|faster|soon|quick|move quicker)\b/i)
          answer = [timing_answer, rush_answer].join(" ").squish
          return ["Yard-sign turnaround conversation should answer timing/rush questions directly instead of routing away or restarting discovery.", 30] unless answer.match?(/\b(?:turnaround|business days?|proof|approval|production|shipping|rush|faster|timeline)\b/i)
          if rush_answer.present? && !dojo_turnaround_or_rush_answer?("rush", rush_answer)
            return ["Rush turn should answer the rush path directly before returning to pricing, checkout, or discovery.", 34]
          end
        when "rush_consultant_no_checkout"
          rush_answers = answers_after_turns_matching(turn_summaries, /\b(?:rush|faster|next\s+friday|normal checkout|checkout for rush|standard checkout|regular checkout)\b/i)
          return ["Rush conversation should answer rush availability and consultant path directly.", 34] if rush_answers.blank?
          return ["Rush answer should not send the normal checkout link as the rush solution.", 34] if rush_answers.any? { |answer| answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i) }
          return ["Rush conversation should answer rush availability and consultant path directly.", 34] unless rush_answers.any? { |answer| dojo_turnaround_or_rush_answer?("rush", answer) }

          boundary_answer = answer_after_turn_matching(turn_summaries, /\b(?:normal checkout|standard checkout|regular checkout|checkout for rush)\b/i)
          if boundary_answer.present? && !boundary_answer.match?(/\b(?:outside|not|do not|don'?t|avoid|instead|consultant|marketing consultant)\b/i)
            return ["Rush checkout-boundary turn should say rush is outside the normal checkout path.", 28]
          end
          accepted_handoff = answer_after_turn_matching(turn_summaries, /\b(?:yes|please|ok|okay).{0,80}\b(?:marketing consultant|someone|person|connect|reach out)\b|\b(?:have|get)\b.{0,80}\b(?:marketing consultant|someone|person)\b.{0,80}\b(?:connect|reach out|follow)/i)
          if accepted_handoff.present? && accepted_handoff.match?(/\b(?:want me to|get someone connected|should i|do you want)\b/i)
            return ["Rush handoff acceptance should confirm the consultant follow-up instead of asking for permission again.", 24]
          end
        when "eddm_nb_plain_compare"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:one\s+eddm|one\s+neighborhood\s+blitz|eddm.*neighborhood\s+blitz|neighborhood\s+blitz.*eddm)\b/i)
          return ["EDDM versus Neighborhood Blitz turn should quote one EDDM route at $399 and Neighborhood Blitz at $699.", 28] unless answer.match?(/\beddm\b/i) && answer.match?(/\$\s?399\b/) && answer.match?(/\bneighborhood\s+blitz\b/i) && answer.match?(/\$\s?699\b/)
          return ["EDDM versus Neighborhood Blitz turn should explain mail-only route versus fuller local visibility.", 18] unless answer.match?(/\b(?:mail-only|mail only|carrier route|postcards?|mailboxes?|usps)\b/i) && answer.match?(/\b(?:fuller|broader|local|visibility|signs?|door hangers?|rack cards?|push)\b/i)
        when "starter_pro_bundle_compare"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:compare|starter\s*pack|pro\s*pack)\b.{0,100}\b(?:cards?|door\s+hangers?|bundle|pack)\b/i)
          return ["Starter/Pro comparison should include $299 Starter, $599 Pro, signs, business cards, and door hangers.", 28] unless answer.match?(/\bstarter\s*pack\b/i) && answer.match?(/\$\s?299\b/) && answer.match?(/\bpro\s*pack\b/i) && answer.match?(/\$\s?599\b/) && answer.match?(/\bbusiness\s+cards?\b/i) && answer.match?(/\bdoor\s+hangers?\b/i)
          if answer.match?(/\b(?:eddm|neighborhood\s+blitz)\b/i) || answer.match?(/\byard\s+signs?:\s*10\b/i)
            return ["Starter/Pro-only comparison should not broaden into EDDM, Neighborhood Blitz, or the full yard-sign ladder unless the customer asks for all options.", 20]
          end
        when "signs_only_bundle_fit"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:only|just)\b.{0,50}\b(?:care|need|want|looking)\b.{0,30}\bsigns?\b|\bsigns[-\s]?only\b/i)
          return ["Signs-only pivot should answer that Yard Signs is cleaner than Starter/Pro bundles, not ask for homes.", 30] if answer.match?(/\bhow many homes\b|\bhomes should i use\b|\bhomes or doors\b/i)
          return ["Signs-only pivot should answer that Yard Signs is cleaner and Starter/Pro add cards and door hangers.", 28] unless signs_only_bundle_fit_answer?(answer)
        when "handoff_answer_first"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:real person|someone|consultant|human)\b.{0,120}\b(?:500|costs?|price|yard signs?)\b|\b(?:500|costs?|price|yard signs?)\b.{0,120}\b(?:real person|someone|consultant|human)\b/i)
          answer = Array(turn_summaries).map { |turn| dojo_turn_value(turn, "answer").to_s.squish }.find { |candidate| candidate.match?(/\b500\b/i) && candidate.match?(/\$\s?1,?699\b/) }.to_s if answer.blank?
          return ["Mixed handoff/price turn should answer 500 yard signs at $1,699 before moving to a link or handoff.", 32] unless answer.match?(/\$\s?1,?699\b/)

          handoff_answer = answer_after_turn_matching(turn_summaries, /\b(?:yes|yep|yeah|ok|okay|please|too|also)\b.{0,100}\b(?:person|someone|consultant|team|teammate|human|follow\s*up|reach out)\b|\b(?:have|get|send|pass)\b.{0,80}\b(?:person|someone|consultant|team|teammate|human)\b/i)
          if handoff_answer.present?
            return ["Explicit handoff turn should confirm a person/team follow-up instead of sending a checkout link.", 30] if handoff_answer.match?(%r{https?://|shop\.wizwikimarketing\.com|/products/}i)
            return ["Explicit handoff turn should confirm a person/team follow-up.", 24] unless handoff_answer.match?(/\b(?:person|someone|consultant|team|teammate|reach out|connect|follow[- ]?up|pass this)\b/i)
          end
        when "design_shipping_included"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:design|shipping|included|stakes)\b/i)
          return ["Included-details turn should say design help, shipping, and stakes are included for yard signs.", 24] unless answer.match?(/\bdesign\b/i) && answer.match?(/\bshipping\b/i) && answer.match?(/\bstakes?\b/i)
        when "link_after_acceptance"
          answer = answer_after_accepted_link_turn(turn_summaries)
          return ["Acceptance turn asked for the checkout link; answer must send a relevant URL instead of re-asking whether to proceed.", 30] unless answer.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
        when "yard_sign_checkout_link"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:checkout link|send.*link|text.*link|share.*link|send.*checkout|text.*checkout|order link|buy link|signs checkout|yard[- ]sign checkout|send.*yard[- ]?sign.*option|text.*yard[- ]?sign.*option|send.*\b10\b.*sign.*option)\b/i)
          return ["Ready-to-order yard-sign turn should send the checkout URL when the customer directly asks for the yard-sign link.", 30] unless answer.match?(%r{https?://|shop\.wizwikimarketing\.com}i)
          return ["Ready-to-order yard-sign turn should use the yard-sign path, not a postcard/blitz/bundle link unless the customer pivoted.", 18] unless answer.match?(/\b(?:yard\s+signs?|signs?|shop\.wizwikimarketing\.com)\b/i)
        when "yard_sign_to_postcard_switch"
          answer = answer_after_turn_matching(turn_summaries, /\b(?:mail|postcards?|homes?)\b/i)
          return ["Lane-switch turn should adapt to postcards/direct mail without losing the prior yard-sign context.", 24] unless answer.match?(/\b(?:postcards?|mail|eddm|homes?)\b/i)
          return ["Lane-switch turn stayed trapped in yard signs after the customer pivoted to postcards/direct mail.", 24] if answer.match?(/\byard\s+signs?\b/i) && !answer.match?(/\b(?:postcards?|mail|eddm|homes?)\b/i)
        when "no_repeated_lane_discovery"
          return ["Conversation repeated broad product discovery after the route was already known.", 18] if repeated_lane_discovery_in_conversation?(turn_summaries)
        end

        nil
      end

      def first_turn_with_customer_message_count(turn_summaries, count)
        Array(turn_summaries).find { |item| dojo_turn_value(item, "customer_message_count").to_i >= count.to_i }
      end

      def print_products_coverage_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        products = []
        products << "business cards" if body.match?(/\bbusiness\s+cards?\b/)
        products << "door hangers" if body.match?(/\bdoor\s+hangers?\b/)
        products << "flyers" if body.match?(/\bflyers?\b/)
        products << "postcards" if body.match?(/\bpostcards?\b/)
        products << "yard signs" if body.match?(/\byard\s+signs?\b|\bsigns?\b/)
        products << "rack cards" if body.match?(/\brack\s+cards?\b/)
        products << "magnets" if body.match?(/\bmagnets?\b/)

        products.uniq.length >= 3 && products.include?("business cards") && products.include?("door hangers")
      end

      def print_product_context_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?|print pieces?|print products?|custom print|custom mix)\b/)
      end

      def wrong_print_product_lane_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        yard_sign_only = body.match?(/\b(?:yard signs?|lawn signs?|signs-only)\b/) &&
          body.match?(/\b(?:10 for \$99|20 for \$159|50 for \$249|100 for \$399|\$\s?1,?699|what quantity|closer to 20)\b/) &&
          !print_product_context_answer?(body)
        direct_mail = body.match?(/\b(?:eddm|direct mail|mail-only|postcard mailing|usps route|mailboxes?)\b/) &&
          !print_product_context_answer?(body)

        yard_sign_only || direct_mail
      end

      def bundle_overpush_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:starter\s*pack|pro\s*pack)\b/)
        return false if body.match?(/\b(?:flyers?|rack cards?|magnets?|postcards?|print products?|other print|also help with)\b/)

        true
      end

      def consultant_handoff_answer?(answer)
        answer.to_s.match?(/\b(?:marketing consultant|consultant|person|someone|teammate|team member|real person|connect|reach out|follow up|go over the details)\b/i)
      end

      def canned_proof_design_paragraph?(answer)
        body = answer.to_s.squish
        body.length > 430 ||
          body.match?(/\AYou do not need finished artwork before ordering\. Complete checkout first; after checkout/i) ||
          body.match?(/\bAI postcard\/art builder\b/i)
      end

      def answer_after_turn_matching(turn_summaries, pattern)
        turn = Array(turn_summaries).find { |item| dojo_turn_customer_text(item).match?(pattern) }
        dojo_turn_value(turn, "answer").to_s.squish
      end

      def answer_after_accepted_link_turn(turn_summaries)
        turn = Array(turn_summaries).find do |item|
          accepted_recommendation_link_request?(dojo_turn_customer_text(item))
        end
        dojo_turn_value(turn, "answer").to_s.squish
      end

      def answers_after_turns_matching(turn_summaries, pattern)
        Array(turn_summaries).filter_map do |item|
          next unless dojo_turn_customer_text(item).match?(pattern)

          dojo_turn_value(item, "answer").to_s.squish.presence
        end
      end

      def dojo_turn_customer_text(turn)
        primary = dojo_turn_value(turn, "customer").to_s.squish
        stack = Array(dojo_turn_value(turn, "customer_messages")).map { |message| message.to_s.squish }.reject(&:blank?)
        ([primary] + stack).reject(&:blank?).uniq.join(" ").squish
      end

      def repeated_answer_findings(turn_summaries)
        normalized = Array(turn_summaries).map do |turn|
          [
            dojo_turn_value(turn, "turn"),
            normalize_body(dojo_turn_value(turn, "answer").to_s)
          ]
        end.reject { |_turn, answer| answer.blank? }

        repeats = normalized.each_cons(2).select { |(_prev_turn, prev), (_turn, current)| prev == current }
        return [[], 0] if repeats.blank?

        turn_numbers = repeats.map { |(_prev_turn, _prev), (turn, _current)| turn }.compact
        [
          ["Conversation repeated the same customer-facing answer on later turns instead of adapting to the customer's new question#{turn_numbers.present? ? " (turns #{turn_numbers.join(', ')})" : ""}."],
          [12 * repeats.length, 36].min
        ]
      end

      def repeated_lane_discovery_in_conversation?(turn_summaries)
        Array(turn_summaries).drop(1).any? do |turn|
          answer = dojo_turn_value(turn, "answer").to_s.downcase.squish
          next false if answer.blank?

          broad_lane_discovery_answer?(answer)
        end
      end

      def broad_lane_discovery_answer?(answer)
        body = answer.to_s.downcase.squish
        body.match?(/\b(?:postcards?|mailboxes?|mailers?),?\s*(?:yard\s*)?signs?,?\s*or both\b/) ||
          body.match?(/\bare you looking for\b.{0,80}\b(?:postcards?|mailboxes?|mailers?|signs?|both)\b/) ||
          body.match?(/\bwhich\s+(?:one|option|path|route|product|lane)\b.{0,60}\b(?:postcards?|mailboxes?|mailers?|signs?|both)\b/) ||
          body.match?(/\bwhich\b.{0,40}\bshould\s+i\s+narrow\b/)
      end

      def canned_yard_sign_route_language?(answer)
        answer.to_s.match?(/\b(?:lawn signs?|yard signs?)\s+is\s+the\s+signs-only\s+(?:option|path)|yard signs package is the signs-only deal|yard signs are the cleanest fit\b/i)
      end

      def premature_yard_sign_opener_close?(answer)
        body = answer.to_s.downcase.squish
        body.match?(%r{https?://|shop\.wizwikimarketing\.com|checkout|use .*link|starter pack|pro pack|bundle|postcards?|eddm|neighborhood blitz})
      end

      def system_table_language?(answer)
        answer.to_s.match?(/\b(?:ladder\s+i\s+see|options\s+i\s+see|pricing\s+i\s+see|from\s+(?:the\s+)?(?:context|product data|table))\b/i)
      end

      def dojo_banned_starter?(answer)
        answer.to_s.match?(/\A(?:quick practical check|one useful detail|still worth asking|one clean next step|small practical check|no rush,?\s+one helpful detail|fresh start here|a simple next step)\b/i)
      end

      def dojo_display_failsafe_body?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?
        return false if body.match?(/\$\s?\d|https?:|shop\.wizwikimarketing|checkout|marketing consultant|yard signs?|postcards?|business cards?|door hangers?|flyers?|eddm|neighborhood blitz|design|shipping|stakes?|proof|price|cost|link/i)

        body.length <= 220 && body.match?(
          /\b(?:one moment|give me (?:a )?moment|hold on|please wait|checking|reviewing)\b|un momento|dame un momento|estoy revisando|um momento|estou verificando|aguarde|sandali lang|tinitingnan ko|vui lòng chờ|đang kiểm tra|xin chờ|请稍等|稍等|正在检查|잠시|확인|لحظة|أتحقق|انتظر|подождите|уточняю детали|проверяю/i
        )
      end

      def dojo_display_language_mismatch?(turn, answer)
        code = dojo_turn_value(turn, "language_code").to_s.downcase.presence
        return false if code.blank? || code == "en"
        return false unless defined?(Comms::SmsLanguageSupport)
        return false unless Comms::SmsLanguageSupport::CUSTOMER_LANGUAGE_CODES.key?(code)

        body = answer.to_s.squish
        return false if body.blank? || Comms::SmsLanguageSupport.preference_notice_body?(body)

        !Comms::SmsLanguageSupport.target_language_signal?(body, code)
      rescue StandardError
        false
      end

      def dojo_customer_echo_opening?(customer, answer)
        inbound = customer.to_s.squish
        body = answer.to_s.squish
        return false if inbound.length < 16 || body.blank?

        first_sentence = body.split(/[.!?]/).first.to_s.squish
        normalized_inbound = normalize_body(inbound)
        normalize_body(first_sentence) == normalized_inbound ||
          normalize_body(body).start_with?(normalized_inbound)
      end

      def dojo_proof_approval_question?(customer)
        body = customer.to_s.downcase.squish
        return false if body.blank?
        return false if body.match?(/\b(?:print(?:ed)?\s+materials?|marketing\s+materials?|print products?|other print|print pieces?|print work|print options?)\b/)

        body.match?(/\b(?:proof|approve|approval|review|printed|printing)\b/i) ||
          (body.match?(/\bprint\b/i) && body.match?(/\b(?:before|until|approve|approval|proof|printing)\b/i))
      end

      def dojo_proof_approval_answer?(answer)
        body = answer.to_s.downcase.squish
        body.match?(/\b(?:proof|review|approve|approval|changes?)\b/) &&
          body.match?(/\b(?:nothing prints|before\s+(?:anything\s+)?prints?|before printing|until you approve|after checkout|intake)\b/)
      end

      def dojo_turnaround_or_rush_question?(customer)
        body = customer.to_s.downcase.squish
        return false if body.blank?
        return false if accepted_recommendation_link_request?(body)
        return false if body.match?(/\b(?:that|the)\s+(?:timing|timeline)\s+(?:is\s+)?(?:fine|works|ok|okay|good)\b/)
        return false if body.match?(/\b(?:shipping|ship)\b.{0,50}\b(?:included|include|comes with|part of|free)\b/) ||
          body.match?(/\b(?:included|include|comes with|part of|free)\b.{0,50}\b(?:shipping|ship)\b/)
        return false if body.match?(/\b(?:in a hurry|hurry|hurray|fast)\b/) &&
          !body.include?("?") &&
          !body.match?(/\b(?:how long|timeline|turnaround|timing|production|shipping|ship|rush|rushed|expedite|faster|quicker|move quicker|next friday|need (?:them|it) by|deadline|normal checkout|standard checkout|regular checkout)\b/)

        body.match?(/\b(?:how long|timeline|turnaround|timing|production|shipping|ship|rush|faster|quicker|move quicker|in a hurry|hurry|hurray|fast|next friday|deadline)\b/i)
      end

      def rush_or_deadline_question?(customer)
        customer.to_s.match?(/\b(?:rush|expedite|asap|faster|quicker|move quicker|in a hurry|hurry|hurray|fast|next friday|need (?:them|it) by|deadline|this week)\b/i)
      end

      def dojo_turnaround_or_rush_answer?(customer, answer)
        body = answer.to_s.downcase.squish
        if customer.to_s.match?(/\b(?:rush|faster|quicker|move quicker|asap|expedite|in a hurry|hurry|hurray|fast|next friday|deadline)\b/i)
          return false if body.match?(%r{shop\.wizwikimarketing\.com|/products/}i)
          return false if body.match?(/\$\s?\d/)

          return body.match?(/\brush\b/) &&
            body.match?(/\b(?:proof approval|proof is approved|after the proof|design\/proof)\b/) &&
            body.match?(/\b(?:production|queue|ahead)\b/) &&
            body.match?(/\b(?:shipping|ups|fedex|ground|2\s*to\s*5|2-5)\b/) &&
            body.match?(/\b(?:marketing consultant|consultant|someone connected|someone reach out|have someone)\b/)
        end

        body.match?(/\b(?:proof|approval)\b/) &&
          body.match?(/\b(?:business days?|production|shipping|ship)\b/)
      end

      def dojo_eddm_special_confusion?(answer)
        body = answer.to_s.downcase.squish
        return false unless body.match?(/\beddm\b/) && body.match?(/\$399\b/) && body.match?(/\$790\b|\b4th\s+of\s+july\b|\bjuly\s*4\b/)

        !body.match?(/\b(?:standard|mail-only|route|separate|different|postcard-only|block sale|special starts)\b/)
      end

      def dojo_conversation_grade_body(grade, title)
        findings = Array(grade.to_h["findings"]).join(" ")
        "Conversation grade: #{grade.to_h['score']}/100 #{grade.to_h['verdict']} for #{title}. #{findings}"
      end

      def dojo_conversation_transcript(turn_summaries)
        Array(turn_summaries).map do |turn|
          customer_messages = Array(dojo_turn_value(turn, "customer_messages")).map { |message| message.to_s.squish }.reject(&:blank?)
          customer = if customer_messages.length > 1
            delay_seconds = dojo_turn_value(turn, "customer_delay_seconds").to_i
            customer_messages.each_with_index.map do |message, index|
              index.zero? ? "Customer: #{message}" : "Customer +#{delay_seconds * index}s: #{message}"
            end.join("\n")
          else
            "Customer: #{dojo_turn_value(turn, 'customer')}"
          end
          [
            "Turn #{dojo_turn_value(turn, 'turn')}",
            customer,
            "Thumper: #{dojo_turn_value(turn, 'answer')}"
          ].join("\n")
        end.join("\n\n")
      end

      def dojo_conversation_answer_summary(turn_summaries)
        Array(turn_summaries).map do |turn|
          "Turn #{dojo_turn_value(turn, 'turn')}: #{dojo_turn_value(turn, 'answer')}"
        end.join("\n")
      end

      def dojo_turn_value(turn, key)
        hash = turn.to_h
        hash[key.to_s].presence || hash[key.to_sym]
      end

      def dojo_conversation_embedding_lesson(title, turn_summaries, findings, verdict)
        [
          "Complete conversation: #{title}",
          dojo_conversation_transcript(turn_summaries),
          "Grade: #{verdict}",
          "Training note: #{Array(findings).join(' ')}"
        ].join("\n")
      end

      def deterministic_dojo_grade(stage, inbound_event, reply_body, result)
        inbound = inbound_event.to_h["body"].to_s.squish
        answer = reply_body.to_s.squish
        findings = []
        score = deterministic_dojo_base_score(inbound, answer, result)

        if answer.blank?
          findings << "No customer-facing answer was produced."
          score -= 45
        end

        if internal_leak_body?(answer)
          findings << "Internal reasoning or guardrail language leaked into the customer answer."
          score -= 40
        end

        if meta_preface_body?(answer)
          findings << "Answer describes the reply instead of just sending the customer-facing SMS."
          score -= 35
        end

        if premature_am_handoff?(inbound, answer)
          findings << "Answer rushed to AM/support instead of answering with standard product guidance first."
          score -= 28
        end

        if direct_price_question?(inbound) && !rush_or_deadline_question?(inbound) && answer !~ /\$\s?\d/
          findings << "Customer asked for price; answer did not include a real dollar amount."
          score -= 22
        end

        if full_options_pricing_question?(inbound) && !full_options_pricing_answer?(answer)
          findings << "Customer asked for the main options/prices; answer needs Starter, Pro, Yard Signs tiers, EDDM, and Neighborhood Blitz pricing instead of a partial quote."
          score -= 24
        end

        if direct_customer_question?(inbound) && !material_answer_anchor?(answer)
          findings << "Customer asked a concrete question; answer did not include a concrete product, price, link, checkout, proof, or package detail."
          score -= 16
        end

        if multi_part_product_question?(inbound) && !answer_mentions_requested_products?(inbound, answer)
          findings << "Customer asked about multiple products; answer did not cover each requested lane."
          score -= 16
        end

        if design_process_question?(inbound) && !design_flow_answer?(answer)
          findings << "Design/proof question needs the order-first intake and proof-before-print flow."
          score -= 18
        end

        if design_process_question?(inbound) && process_answer_should_stand_alone?(inbound) && answer.include?("?")
          findings << "Design/proof process answers should not add an unrelated discovery question; answer the process clearly, then stop or guide back to checkout."
          score -= 10
        end

        if yard_sign_budget_question?(inbound, metadata: stage.metadata.to_h) && !yard_sign_budget_answer?(answer)
          findings << "Budget question should translate dollars into an approximate yard-sign quantity."
          score -= 14
        end

        if checkout_confusion_question?(inbound) && !checkout_confusion_answer?(answer)
          findings << "Checkout-link confusion needs a plain explanation of what the link/package is before asking another question."
          score -= 18
        end

        if accepted_recommendation_link_request?(inbound) && answer !~ %r{https?://}i
          findings << "Customer accepted a route-ready recommendation or asked for the link; answer must send the relevant checkout link instead of repeating the proceed question."
          score -= 24
        end

        if eddm_neighborhood_blitz_question?(inbound) && !eddm_neighborhood_blitz_answer?(answer)
          findings << "Customer asked EDDM versus Neighborhood Blitz; answer needs to compare both and recommend based on mail-only versus fuller local visibility."
          score -= 20
        end

        if signs_only_bundle_fit_question?(inbound) && !signs_only_bundle_fit_answer?(answer)
          findings << "Customer asked whether a bundle fits signs-only; answer needs to say Yard Signs is cleaner for signs-only and Pro/Starter adds cards and door hangers."
          score -= 22
        end

        if too_many_customer_questions?(answer)
          findings << "Answer asks more than one customer question."
          score -= 8
        end

        if patronizing_or_flat?(answer)
          findings << "Tone reads flat, canned, patronizing, or over-guardrailed; needs warmer Thumper-style momentum."
          score -= 12
        end

        if vague_policy_nonanswer?(inbound, answer)
          findings << "Answer uses policy or safety language without enough practical customer guidance."
          score -= 18
        end

        if missing_natural_next_step?(inbound, answer)
          findings << "Answer needs one natural next step after the direct answer."
          score -= 8
        end

        score = score.clamp(0, 100)
        verdict = score >= 85 ? "PASS" : "REVIEW"
        if findings.blank?
          if excellent_dojo_answer?(inbound, answer)
            score = [score + 4, 96].min
            findings << "Excellent answer: direct, grounded, friendly, complete, and customer-facing."
          else
            score = [score, 92].min
            findings << "Clean answer with no hard misses; reserve 95+ for standout usefulness, voice, and specificity."
          end
        end

        {
          "score" => score,
          "verdict" => verdict,
          "findings" => findings,
          "provider" => result.to_h["provider"],
          "model" => result.to_h["model"],
          "quality_gate" => result.to_h["sms_quality_gate"],
          "judge_provider" => "deterministic/rules",
          "judge_model" => "rails_dojo_checklist",
          "embedding_lesson" => dojo_embedding_lesson(inbound, answer, findings, verdict)
        }.compact_blank
      end

      def dojo_grade_body(grade)
        findings = Array(grade.to_h["findings"]).join(" ")
        "Grade: #{grade.to_h['score']}/100 #{grade.to_h['verdict']}. #{findings}"
      end

      def dojo_embedding_lesson(inbound, answer, findings, verdict)
        [
          "Scenario: #{inbound}",
          "Thumper answer: #{answer}",
          "Grade: #{verdict}",
          "Training note: #{Array(findings).join(' ')}"
        ].join("\n")
      end

      def deterministic_dojo_base_score(inbound, answer, result)
        return 40 if answer.blank?

        score = 88
        score += 4 if material_answer_anchor?(answer)
        score += 3 if direct_customer_question?(inbound) && direct_answer_shape?(inbound, answer)
        score += 2 if result.to_h["sms_quality_gate"].to_s.in?(%w[passed rewritten])
        score -= 4 if answer.length < 70 && direct_customer_question?(inbound)
        score.clamp(60, 94)
      end

      def excellent_dojo_answer?(inbound, answer)
        body = answer.to_s.squish
        return false if body.blank?
        return false if too_many_customer_questions?(body)
        return false if patronizing_or_flat?(body)
        return false if vague_policy_nonanswer?(inbound, body)
        return false if full_options_pricing_question?(inbound) && !full_options_pricing_answer?(body)
        return false if direct_customer_question?(inbound) && !direct_answer_shape?(inbound, body)

        material_answer_anchor?(body) &&
          natural_next_step?(body) &&
          body.length.between?(85, 420)
      end

      def direct_answer_shape?(inbound, answer)
        return true unless direct_customer_question?(inbound)

        body = answer.to_s.squish
        first_sentence = body.split(/[.?!]/).first.to_s.downcase
        return false if first_sentence.blank?
        return false if first_sentence.match?(/\A(?:what|which|when|where|how|why|can|could|do|does|would|will)\b/)

        material_answer_anchor?(first_sentence) || first_sentence.match?(/\b(?:yes|no|starter pack|pro pack|yard signs?|neighborhood blitz|eddm|checkout|proof|intake|link)\b/)
      end

      def direct_customer_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.include?("?") ||
          body.match?(/\b(?:how much|cost|price|pricing|quote|what exactly|what is|what are|why|how do|how does|can i|can you|do i|does it|included|comes with|link|checkout|design|artwork|proof|i don'?t understand|dont understand|don't understand)\b/)
      end

      def material_answer_anchor?(text)
        body = text.to_s.downcase.squish
        body.match?(/\$\s?\d/) ||
          body.match?(/\b(?:starter pack|pro pack|yard signs package|neighborhood blitz|eddm|postcards?|business cards?|door hangers?|checkout|intake|proof|approval|nothing prints|link|included|includes|shipping|stakes)\b/)
      end

      def vague_policy_nonanswer?(inbound, answer)
        return false unless direct_customer_question?(inbound)

        body = answer.to_s.downcase.squish
        return false if body.blank?
        policy = body.match?(/\b(?:cannot safely|can safely|quote confidently|exact pricing can vary|standard checkout quantities|off-menu|outside the listed|custom specials?|policy)\b/)
        policy && !body.match?(/\$\s?\d|starter pack|pro pack|yard signs package|neighborhood blitz|eddm|checkout|proof|intake|https?:\/\//)
      end

      def missing_natural_next_step?(inbound, answer)
        return false if answer.blank?
        return false if accepted_recommendation_link_request?(inbound)
        return false if answer.match?(%r{https?://}i)
        return false if answer.include?("?")

        direct_customer_question?(inbound) && !natural_next_step?(answer)
      end

      def natural_next_step?(answer)
        answer.to_s.match?(/\b(?:do you want|want me to|send me|tell me|text me|choose|pick|checkout|order|place the order|upload|after checkout|next step|if you want)\b/i)
      end

      def run_recursive_dojo_learning(stage)
        return unless defined?(Comms::AutopilotLearning)

        Comms::AutopilotLearning.call(
          organization: stage.organization,
          lookback_days: ENV.fetch("ASK_RECURSIVE_DOJO_LOOKBACK_DAYS", "14").to_i,
          limit: ENV.fetch("ASK_RECURSIVE_DOJO_LEARNING_LIMIT", "80").to_i,
          dry_run: false
        )
      end

      def publish_recursive_dojo_scroll(stage)
        return unless defined?(Comms::DojoScrollDocument)

        date = Time.current.in_time_zone("Central Time (US & Canada)").to_date
        metadata = stage.reload.metadata.to_h
        Comms::DojoScrollDocument.publish(
          organization: stage.organization,
          date: date,
          embedding_status: {
            "source" => "recursive_dojo",
            "waiting" => false,
            "published_after_recursive_dojo" => true
          },
          session: {
            "stage_id" => stage.id,
            "generation" => metadata["recursive_dojo_generation"].to_s.presence,
            "guidance" => metadata["recursive_dojo_guidance"].to_s.squish.presence,
            "started_at" => metadata["recursive_dojo_running_at"].presence || metadata["recursive_dojo_queued_at"].presence,
            "completed_at" => Time.current.iso8601
          }.compact_blank
        ).to_h
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] dojo scroll publish failed stage=#{stage&.id} #{error.class}: #{error.message}")
        {
          "ok" => false,
          "date" => Time.current.in_time_zone("Central Time (US & Canada)").to_date.iso8601,
          "error" => "#{error.class}: #{error.message}"
        }
      end

      def dojo_scroll_summary_body(result)
        payload = result.to_h
        return "Thumper Dojo scroll publish skipped or unavailable." if payload.blank?

        if payload[:ok] || payload["ok"]
          links = dojo_scroll_links(payload)
          return [
            "Thumper Dojo scroll published for #{payload[:date] || payload['date']}.",
            *links.map { |link| "#{link['label']}: #{link['url']}" }
          ].compact_blank.join(" ")
        end

        "Thumper Dojo scroll publish did not complete: #{payload[:error] || payload['error'] || payload[:skipped] || payload['skipped'] || 'unknown reason'}"
      end

      def dojo_scroll_links(result)
        payload = result.to_h
        return [] unless payload[:ok] || payload["ok"]

        date = payload[:date].presence || payload["date"].presence
        [
          dojo_scroll_link(payload, :google_doc, kind: "full_day", label: "Full Day scroll", fallback_title: ["Thumper DOJO Scroll", date].compact.join(" - ")),
          dojo_scroll_link(payload, :session_google_doc, kind: "session", label: "Session scroll", fallback_title: ["Thumper DOJO Session", date].compact.join(" - "))
        ].compact
      end

      def dojo_scroll_link(payload, key, kind:, label:, fallback_title:)
        doc = payload[key].presence || payload[key.to_s].presence
        doc = doc.to_h
        url = doc["webViewLink"].presence || doc[:webViewLink].presence || doc["alternateLink"].presence || doc[:alternateLink].presence
        return if url.blank?

        {
          "kind" => kind,
          "label" => label,
          "title" => doc["name"].presence || doc[:name].presence || fallback_title,
          "url" => url
        }.compact_blank
      end

      def dojo_embedding_summary_body(learning_result, cycle_summaries)
        result = learning_result&.to_h || {}
        embedded = result[:lessons_embedded].to_i + result[:quality_documents_embedded].to_i + result[:scorecard_documents_embedded].to_i + result[:judge_documents_embedded].to_i
        created = result[:lessons_created].to_i + result[:quality_documents_created].to_i + result[:scorecard_documents_created].to_i + result[:judge_documents_created].to_i
        updated = result[:lessons_updated].to_i + result[:quality_documents_updated].to_i + result[:scorecard_documents_updated].to_i + result[:judge_documents_updated].to_i
        skipped = result[:lessons_skipped].to_i + result[:quality_documents_skipped].to_i + result[:scorecard_documents_skipped].to_i + result[:judge_documents_skipped].to_i
        errors = Array(result[:errors])
        summaries = Array(cycle_summaries)
        conversation_count = summaries.count { |summary| ActiveModel::Type::Boolean.new.cast(summary.to_h["conversation"]) }
        single_turn_count = summaries.length - conversation_count
        graded_summary =
          if summaries.blank?
            "0 scenarios graded"
          elsif single_turn_count.zero?
            "#{conversation_count} complete conversation#{'s' unless conversation_count == 1} graded"
          elsif conversation_count.positive?
            "#{summaries.length} scenarios graded, including #{conversation_count} complete conversation#{'s' unless conversation_count == 1}"
          else
            "#{summaries.length} single-turn scenario#{'s' unless summaries.length == 1} graded"
          end

        [
          "Recursive Dojo complete: #{graded_summary}.",
          "Training memory: #{created} created, #{updated} updated, #{skipped} skipped, #{embedded} embedding jobs queued, including dojo scorecards and judge calibration.",
          (errors.any? ? "Warnings: #{errors.first(2).join(' | ')}" : "Embedding summary clean.")
        ].compact.join(" ")
      end

      def internal_leak_body?(body)
        text = body.to_s
        return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)

        text.match?(/\b(?:we need to answer|the user is asking|voice rules|context provided|system prompt|developer instruction|guardrail|fallback|analysis|draft candidate|selected answer)\b/i)
      end

      def meta_preface_body?(body)
        text = body.to_s.squish
        text.match?(/\A(?:here'?s|here is|recommended|suggested|best|draft|the best).{0,90}\b(?:sms|reply|response|message|answer|as thumper|from wizwiki|customer-facing)\b/i) ||
          text.match?(/\b(?:best next short sms reply|customer-facing sms|reply as thumper|as thumper from wizwiki marketing)\b/i)
      end

      def premature_am_handoff?(inbound, answer)
        return false unless am_handoff_answer?(answer)
        return false if am_handoff_allowed?(inbound)

        true
      end

      def am_handoff_answer?(body)
        text = body.to_s.downcase.squish
        text.match?(/\b(?:account manager|am support|human|rep|representative|teammate|team member|specialist|someone)\b.{0,90}\b(?:reach out|contact|call|email|text|follow up|confirm|help|pick this up)\b/) ||
          text.match?(/\b(?:reach out|contact|call|email|text|follow up)\b.{0,90}\b(?:account manager|am support|human|rep|representative|teammate|team member|specialist|someone)\b/)
      end

      def am_handoff_allowed?(body)
        text = body.to_s.downcase.squish
        return true if text.match?(/\b(?:rush|expedite|asap|faster|quicker|hurry|hurray|need (?:them|it) by|deadline|this week)\b/)
        return true if text.match?(/\b(?:human|person|rep|representative|sales\s*(?:person|rep)|account\s*manager|manager|someone|team|owner)\b/) &&
          text.match?(/\b(?:talk|speak|call|connect|contact|reach|help|get|want|need|can|please)\b/)
        return true if text.match?(/\b(?:checkout|check out|cart|payment|pay|paid|order|link|url|website|site|shopify)\b/) &&
          text.match?(/\b(?:can'?t|cannot|couldn'?t|won'?t|will not|error|failed|fails|failure|not working|doesn'?t work|isn'?t working|stuck|broken|declined|decline|missing|issue|problem|trouble|won'?t load|will not load)\b/)
        return true if text.match?(/\b(?:frustrated|upset|angry|annoyed|not helping|isn'?t helping|not answering|still confused|still don'?t understand|need support|want support|support person)\b/) &&
          text.match?(/\b(?:human|person|rep|representative|account manager|manager|someone|support|call|contact|reach|help)\b/)

        text.match?(/\b(?:custom|off[- ]?menu|unlisted|not listed|outside (?:the )?(?:deal|deals|package|packages)|specials?|bulk discount|exact custom)\b/) &&
          text.match?(/\b(?:price|pricing|quote|total|deal|package|pack|bundle|setup)\b/)
      end

      def direct_price_question?(text)
        text.to_s.match?(/\b(?:how\s+(?:much|mush|mauch|mutch|muxh)|howmuch|cost|costs|price|pricing|total|rate|rates|quote|quotes|bucks?|dolla(?:rs?)?)\b/i)
      end

      def generic_pricing_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if full_options_pricing_question?(body)
        return false if eddm_neighborhood_blitz_question?(body)
        return false if starter_pro_compare_question?(body)
        return false if simulator_yard_sign_cheapest_question?(body)
        return false if simulator_unit_pricing_question?(body)
        return false if signs_only_bundle_compare_question?(body) || signs_only_pricing_question?(body)

        body.match?(/\b(?:how\s+(?:much|mush|mauch|mutch|muxh)|howmuch|cost|costs|price|prices|pricing|total|rate|rates|quote|quotes)\b/)
      end

      def full_options_pricing_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if starter_pro_compare_question?(body)
        return false if simulator_yard_sign_cheapest_question?(body)

        body.match?(/\b(?:all|every|full|whole|complete)\b.{0,50}\b(?:options?|packages?|packs?|deals?|prices?|pricing|costs?|rates?)\b/) ||
          body.match?(/\b(?:options?|packages?|packs?|deals?)\b.{0,40}\b(?:with|and|plus|including|include)\b.{0,30}\b(?:prices?|pricing|costs?|rates?)\b/) ||
          body.match?(/\b(?:prices?|pricing|costs?|rates?)\b.{0,40}\b(?:for|on|of)\b.{0,30}\b(?:all|every|options?|packages?|packs?|deals?)\b/) ||
          body.match?(/\b(?:tell|show|give|send|list)\b.{0,35}\b(?:options?|packages?|packs?|deals?)\b.{0,60}\b(?:prices?|pricing|costs?|rates?)\b/) ||
          body.match?(/\b(?:all|every|standard|main)\b.{0,35}\b(?:prices?|pricing|costs?|rates?)\b/) ||
          broad_product_options_question?(body) ||
          multi_product_pricing_question?(body)
      end

      def broad_product_options_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if body.match?(/\b(?:specials?|promo|promos|coupon|coupons|discounts?|july\s*4|4th\s+of\s+july)\b/)

        product_specific = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signage|signs?|post\s*cards?|postcards?|eddm|mailers?|direct mail|mailing|mailboxes?|business\s+cards?|door\s+hangers?)\b/)
        return false if product_specific && !body.match?(/\b(?:all|every|everything|standard|main|whole|complete)\b/)

        body.match?(/\b(?:what|which)\b.{0,35}\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b/) ||
          body.match?(/\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b.{0,35}\b(?:what|which|available|do you have|can you do)\b/) ||
          body.match?(/\b(?:show|list|give|send|tell)\b.{0,35}\b(?:options?|packages?|packs?|deals?|products?|services?|offerings?|menu)\b/) ||
          body.match?(/\bwhat\s+(?:do|can)\s+you\s+(?:offer|sell|do|have)\b/) ||
          body.match?(/\bwhat(?:'s| is)\s+(?:available|on the menu)\b/)
      end

      def multi_product_pricing_question?(text)
        body = text.to_s.downcase.squish
        return false unless direct_price_question?(body)

        lanes = [
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signage|signs?)\b/),
          body.match?(/\b(?:business\s+cards?|cards?)\b/),
          body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|mailing|mailboxes?|homes?)\b/),
          body.match?(/\b(?:door\s+hangers?|hangers?)\b/)
        ]
        lanes.count(true) >= 2
      end

      def full_options_pricing_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\bstarter\s*pack\b/) && body.match?(/\$299\b/)
        return false unless body.match?(/\bpro\s*pack\b/) && body.match?(/\$599\b/)
        return false unless body.match?(/\byard\s*signs?\b/) && yard_sign_standard_price_claims(body).length >= 3
        return false unless body.match?(/\bneighborhood\s+blitz\b[^.?!]{0,90}\$\s?699|\$\s?699[^.?!]{0,90}\bneighborhood\s+blitz\b/)
        return false unless body.match?(/\beddm\b[^.?!]{0,90}\$\s?399|\$\s?399[^.?!]{0,90}\beddm\b/)

        true
      end

      def yard_sign_standard_price_claims(text)
        expected = {
          10 => 99,
          20 => 159,
          50 => 249,
          100 => 399,
          250 => 899,
          500 => 1699,
          1000 => 3349
        }
        claims = []
        body = text.to_s.downcase.squish
        body.scan(/\b([\d,]{1,6})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)?\s*(?:are|is|for|at|=|:|-)?\s*\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
          claims << [quantity.delete(",").to_i, price.delete(",").to_f.round]
        end
        body.scan(/\b([\d,]{1,6})\s*\/\s*\$([\d,]+(?:\.\d{2})?)/i) do |quantity, price|
          claims << [quantity.delete(",").to_i, price.delete(",").to_f.round]
        end
        body.scan(/\$([\d,]+(?:\.\d{2})?)\s*(?:for|gets?|covers?|=|:|-)?\s*([\d,]{1,6})\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)?/i) do |price, quantity|
          claims << [quantity.delete(",").to_i, price.delete(",").to_f.round]
        end

        claims.select { |quantity, price| expected[quantity] == price }.uniq
      end

      def multi_part_product_question?(text)
        body = text.to_s.downcase
        products = [
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/),
          body.match?(/\b(?:business\s+cards?|cards?)\b/),
          body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|homes?)\b/),
          body.match?(/\b(?:door\s+hangers?|hangers?)\b/)
        ]
        products.count(true) >= 2
      end

      def answer_mentions_requested_products?(inbound, answer)
        source = inbound.to_s.downcase
        response = answer.to_s.downcase
        checks = []
        checks << response.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) if source.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
        checks << response.match?(/\b(?:business\s+cards?|cards?)\b/) if source.match?(/\b(?:business\s+cards?|cards?)\b/)
        checks << response.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|homes?)\b/) if source.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|homes?)\b/)
        checks << response.match?(/\b(?:door\s+hangers?|hangers?)\b/) if source.match?(/\b(?:door\s+hangers?|hangers?)\b/)
        checks.all?
      end

      def design_flow_answer?(answer)
        text = answer.to_s.downcase
        text.match?(/\b(?:checkout|order|pay|payment)\b/) &&
          text.match?(/\b(?:intake|upload|send|email|form)\b/) &&
          text.match?(/\bproof\b/) &&
          text.match?(/\b(?:approve|approval|print)\b/)
      end

      def yard_sign_budget_answer?(answer)
        answer.to_s.match?(/\b(?:about\s+)?10\s+(?:yard\s+)?signs?\b/i) || answer.to_s.match?(/\$\s?100\b.*\b(?:yard\s+)?signs?\b/i)
      end

      def too_many_customer_questions?(answer)
        answer.to_s.scan("?").length > 1
      end

      def patronizing_or_flat?(answer)
        answer.to_s.match?(/\b(?:obviously|just simply|as i already said|that makes sense\.|solid start\.|exact pricing can vary|I can safely price|I can quote confidently|solutions|leverage|utilize|seamless|elevate|unlock|empower|robust)\b/i) ||
          (answer.to_s.length < 55 && answer.to_s.scan("?").length.positive?)
      end

      def append_stage_event!(stage, payload)
        language_result = simulator_language_prepared_payload(stage, payload)
        payload = language_result[:payload]
        language_metadata = language_result[:metadata]

        stage.with_lock do
          stage.reload
          metadata = stage.metadata.to_h.deep_dup.merge(language_metadata)
          thread = Array(metadata["sms_thread"]).last(50)
          return nil if stale_simulator_outbound_payload?(thread, payload)

          duplicate_dojo = duplicate_dojo_conversation_event(thread, payload)
          return duplicate_dojo if duplicate_dojo.present?

          duplicate = duplicate_outbound_event(thread, payload)
          return duplicate if duplicate.present?

          now = Time.current
          reply_generation = payload.to_h["direction"].to_s == "inbound" ? SecureRandom.uuid : nil
          canceled_question_ids = reply_generation.present? ? cancel_inflight_simulator_questions!(stage, reason: "new_simulator_inbound", at: now) : []
          payload = payload.merge("reply_generation" => reply_generation).compact_blank if reply_generation.present?
          thread << payload
          pending_metadata = metadata.merge("sms_thread" => thread)
          location = location_capture_payload(pending_metadata, payload)
          pending_metadata = pending_metadata.merge(location)
          processing = processing_payload(stage, metadata: pending_metadata, latest_body: payload["body"])
          thread[-1] = thread.last.to_h.merge(
            "processing_code" => processing["processing_code"],
            "processing_label" => processing["processing_label"],
            "lane_monitor_route" => processing.dig("sms_lane_monitor", "route_code"),
            "lane_monitor_source" => processing.dig("sms_lane_monitor", "source"),
            "lane_monitor_confidence" => processing.dig("sms_lane_monitor", "confidence"),
            "lane_monitor_reason" => processing.dig("sms_lane_monitor", "reason")
          ).compact_blank

          stage.update!(
            status: payload["status"].to_s == "failed" ? "aircall_failed" : "aircall_sent",
            generated_at: now,
            metadata: metadata.merge(
              "sms_thread" => thread,
              "comms_command_sms_draft_body" => reply_generation.present? ? nil : metadata["comms_command_sms_draft_body"],
              "comms_command_sms_draft" => reply_generation.present? ? nil : metadata["comms_command_sms_draft"],
              "comms_command_last_channel" => "sms",
              "comms_command_last_status" => payload["status"],
              "comms_command_last_at" => now.iso8601,
              "comms_command_last_error" => payload["error"].presence,
              "ask_autopilot_test_active" => true,
              "sms_reply_generation" => reply_generation.presence || metadata["sms_reply_generation"],
              "sms_reply_generation_at" => reply_generation.present? ? now.iso8601 : metadata["sms_reply_generation_at"],
              "sms_reply_generation_inbound_id" => reply_generation.present? ? payload["id"] : metadata["sms_reply_generation_inbound_id"],
              "sms_reply_generation_inbound_sid" => reply_generation.present? ? payload["provider_message_id"] : metadata["sms_reply_generation_inbound_sid"],
              "sms_reply_generation_superseded_at" => reply_generation.present? ? now.iso8601 : metadata["sms_reply_generation_superseded_at"],
              "sms_reply_generation_superseded_reason" => reply_generation.present? ? "new_simulator_inbound" : metadata["sms_reply_generation_superseded_reason"],
              "sms_reply_generation_superseded_question_ids" => reply_generation.present? ? canceled_question_ids.presence : metadata["sms_reply_generation_superseded_question_ids"]
            ).compact_blank.merge(location).merge(processing).merge(checkout_link_sent_payload(metadata, payload))
          )
          thread.last
        end
      end

      def simulator_language_prepared_payload(stage, payload)
        payload = payload.to_h
        return { payload: payload, metadata: {} } unless simulator_language_event?(payload)
        return { payload: payload, metadata: {} } unless defined?(Comms::SmsLanguageSupport)
        return { payload: payload, metadata: {} } unless Comms::SmsLanguageSupport.enabled_for?(stage: stage, metadata: stage&.metadata.to_h)

        case payload["direction"].to_s
        when "inbound"
          result = Comms::SmsLanguageSupport.prepare_inbound_body(
            stage: stage,
            metadata: stage&.metadata.to_h,
            body: payload["body"]
          )
          {
            payload: payload.merge(result.to_h["event"].to_h).merge(
              "body" => result.to_h["body"].presence || payload["body"],
              "language_processing_status" => "processed",
              "language_processed_at" => Time.current.iso8601
            ).compact_blank,
            metadata: result.to_h["metadata"].to_h
          }
        when "outbound"
          return { payload: payload, metadata: {} } unless simulator_language_outbound_event?(payload)

          result = Comms::SmsLanguageSupport.prepare_outbound_body(stage: stage, body: payload["body"])
          {
            payload: payload.merge(result.to_h["event"].to_h).merge(
              "body" => result.to_h["body"].presence || payload["body"]
            ).compact_blank,
            metadata: result.to_h["metadata"].to_h
          }
        else
          { payload: payload, metadata: {} }
        end
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] simulator language processing failed stage=#{stage&.id} #{error.class}: #{error.message}")
        {
          payload: payload.merge("language_translation_error" => "#{error.class}: #{error.message}").compact_blank,
          metadata: {
            "sms_language_last_error" => "#{error.class}: #{error.message}",
            "sms_language_last_error_at" => Time.current.iso8601
          }
        }
      end

      def preserve_materialized_translation?(event, draft_body)
        event = event.to_h
        return false unless event["direction"].to_s == "outbound"
        return false if ActiveModel::Type::Boolean.new.cast(event["language_failsafe"])
        return false unless ActiveModel::Type::Boolean.new.cast(event["language_translated"])
        return false if event["body"].to_s.squish.blank?
        return false unless event["english_body"].to_s.squish == draft_body.to_s.squish

        event["body"].to_s.squish != draft_body.to_s.squish
      end

      def stage_for_materialized_translation(stage, metadata, event)
        event = event.to_h
        code = event["language_code"].to_s.downcase.presence
        return stage if code.blank? || code == "en"
        return stage unless defined?(Comms::SmsLanguageSupport)
        return stage unless Comms::SmsLanguageSupport::CUSTOMER_LANGUAGE_CODES.key?(code)

        label = event["language_label"].presence || Comms::SmsLanguageSupport.language_label(code)
        Struct.new(:metadata, :id).new(
          metadata.to_h.merge(
            "sms_language_preferred_code" => code,
            "sms_language_preferred_label" => label
          ),
          stage&.id
        )
      rescue StandardError
        stage
      end

      def simulator_language_event?(payload)
        payload = payload.to_h
        return false unless payload["channel"].to_s.in?(["", "sms"])
        return false if ActiveModel::Type::Boolean.new.cast(payload["language_preference_notice"])
        return false if payload["role"].to_s.in?(%w[
          dojo_guidance
          dojo_grade
          dojo_conversation_grade
          dojo_summary
          dojo_scroll_summary
        ])

        payload["direction"].to_s.in?(%w[inbound outbound])
      end

      def simulator_language_outbound_event?(payload)
        payload = payload.to_h
        role = payload["role"].to_s
        return true if role.blank?
        return true if role.in?(%w[dojo_answer dojo_conversation_answer])
        return true if ActiveModel::Type::Boolean.new.cast(payload["autopilot"]) && role.blank?

        false
      end

      def cancel_inflight_simulator_questions!(stage, reason:, at:)
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

      def find_thread_event(stage, event_id)
        needle = event_id.to_s
        return if needle.blank?

        Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
          event["id"].to_s == needle || event["provider_message_id"].to_s == needle
        end
      end

      def reply_already_materialized?(stage, inbound_event)
        reply_to = inbound_event.to_h["provider_message_id"].presence || inbound_event.to_h["id"].presence
        return false if reply_to.blank?

        Array(stage.reload.metadata.to_h["sms_thread"]).map(&:to_h).any? do |event|
          event["direction"].to_s == "outbound" &&
            event["autopilot_reply_to_sid"].to_s == reply_to.to_s &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
      end

      def duplicate_outbound_event(thread, payload)
        return unless payload.to_h["direction"].to_s == "outbound"

        reply_to = payload.to_h["autopilot_reply_to_sid"].to_s.presence
        body = payload.to_h["body"].to_s.squish
        question_id = payload.to_h["autos_question_id"].to_s.presence
        return if reply_to.blank? && question_id.blank?

        Array(thread).reverse.find do |event|
          event = event.to_h
          next false unless event["direction"].to_s == "outbound"
          next false if event["status"].to_s.in?(%w[failed canceled])

          same_reply = reply_to.present? &&
            event["autopilot_reply_to_sid"].to_s == reply_to &&
            event["body"].to_s.squish == body
          same_question = question_id.present? &&
            event["autos_question_id"].to_s == question_id
          same_reply || same_question
        end
      end

      def duplicate_dojo_conversation_event(thread, payload)
        payload = payload.to_h
        return unless payload["recursive_dojo"] || payload["dojo_conversation"]

        role = payload["role"].to_s
        generation = payload["dojo_generation"].to_s
        conversation_id = payload["dojo_conversation_id"].to_s
        cycle = payload["dojo_cycle"].to_i
        turn_index = payload["dojo_turn_index"].to_i
        message_index = payload["dojo_turn_message_index"].to_i
        return if role.blank? || generation.blank? || conversation_id.blank? || cycle.zero?
        return if turn_index.zero? && role != "dojo_conversation_grade"

        Array(thread).reverse.find do |event|
          event = event.to_h
          next false if event["status"].to_s.in?(%w[failed canceled])
          next false unless event["role"].to_s == role
          next false unless event["dojo_generation"].to_s == generation
          next false unless event["dojo_conversation_id"].to_s == conversation_id
          next false unless event["dojo_cycle"].to_i == cycle

          if role == "dojo_conversation_grade"
            true
          elsif message_index.positive? || event["dojo_turn_message_index"].to_i.positive?
            event["dojo_turn_index"].to_i == turn_index &&
              event["dojo_turn_message_index"].to_i == message_index
          else
            event["dojo_turn_index"].to_i == turn_index
          end
        end
      end

      def stale_simulator_outbound_payload?(thread, payload)
        payload = payload.to_h
        return false unless payload["direction"].to_s == "outbound"
        return false unless ActiveModel::Type::Boolean.new.cast(payload["ask_autopilot_test"])

        reply_to = payload["autopilot_reply_to_sid"].to_s.presence
        return false if reply_to.blank?

        latest_inbound = Array(thread).map(&:to_h).reverse.find do |event|
          event["channel"].to_s == "sms" &&
            event["direction"].to_s == "inbound" &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
        return false if latest_inbound.blank?

        latest_sid = latest_inbound["provider_message_id"].presence || latest_inbound["id"].presence
        latest_sid.present? && reply_to != latest_sid.to_s
      end

      def record_sent_result!(stage, result)
        metadata = stage.metadata.to_h.deep_dup
        history = Array(metadata["sms_draft_history"]).last(24)
        history << draft_history_entry(result)
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "sms_draft_history" => history,
            "ask_autopilot_last_result" => simulator_result_payload(result),
            "ask_autopilot_last_autos_question_id" => result["autos_question_id"],
            "ask_autopilot_last_result_at" => Time.current.iso8601,
            "sms_autopilot_sent_count" => metadata["sms_autopilot_sent_count"].to_i + 1,
            "sms_autopilot_last_sent_at" => Time.current.iso8601,
            "sms_autopilot_last_error" => nil,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_question_id" => result["autos_question_id"],
            "comms_command_background_status" => result["autos_question_id"].present? ? "applied" : nil,
            "comms_command_background_at" => Time.current.iso8601,
            "sms_reply_job_status" => "simulated_sent",
            "sms_reply_job_completed_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
      end

      def record_reply_queued!(stage, inbound_event)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        generation = inbound_event.to_h["reply_generation"].presence || metadata["sms_reply_generation"].presence || SecureRandom.uuid
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_inbound_id" => inbound_event.to_h["id"],
            "comms_command_background_inbound_sid" => inbound_event.to_h["provider_message_id"],
            "comms_command_background_status" => "queued",
            "comms_command_background_at" => now,
            "sms_reply_generation" => generation,
            "sms_reply_generation_at" => metadata["sms_reply_generation_at"].presence || now,
            "sms_reply_generation_inbound_id" => inbound_event.to_h["id"],
            "sms_reply_generation_inbound_sid" => inbound_event.to_h["provider_message_id"],
            "sms_reply_job_generation" => generation,
            "sms_reply_job_status" => "queued",
            "sms_reply_job_queued_at" => now,
            "ask_autopilot_pending_started_at" => metadata["ask_autopilot_pending_started_at"].presence || now,
            "ask_autopilot_pending_phase" => "gathering_thoughts",
            "comms_command_last_channel" => "sms",
            "comms_command_last_status" => "drafting",
            "comms_command_last_at" => now,
            "sms_autopilot_last_error" => nil
          ).compact_blank
        )
      end

      def no_reply_needed_for_inbound?(stage, inbound_event)
        return false unless defined?(DealReports::CommsDraftWriter)

        body = inbound_event.to_h["body"].to_s
        return false if body.squish.blank?

        writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
        writer.send(:customer_acknowledgment_no_reply?, body)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] no-reply check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def record_no_reply_needed!(stage, inbound_event, generation: nil)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        generation = generation.to_s.presence || inbound_event.to_h["reply_generation"].presence || metadata["sms_reply_generation"].presence
        result = {
          "provider" => "local/no_reply_needed",
          "draft_source" => "no_reply_needed",
          "reason" => "Customer acknowledgement did not need an automated reply.",
          "sms_generation_pipeline" => "simulator_no_reply_fast_path",
          "pending" => false
        }
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "ask_autopilot_last_result" => simulator_result_payload(result),
            "ask_autopilot_last_result_at" => now,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_question_id" => nil,
            "comms_command_background_inbound_id" => inbound_event.to_h["id"],
            "comms_command_background_inbound_sid" => inbound_event.to_h["provider_message_id"],
            "comms_command_background_status" => "no_reply_needed",
            "comms_command_background_at" => now,
            "sms_reply_job_generation" => generation,
            "sms_reply_job_status" => "no_reply_needed",
            "sms_reply_job_completed_at" => now,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil,
            "comms_command_last_channel" => "sms",
            "comms_command_last_status" => "listening",
            "comms_command_last_at" => now,
            "sms_autopilot_last_error" => nil
          ).compact_blank
        )
        true
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed marking no-reply stage=#{stage&.id} inbound=#{inbound_event.to_h["id"]} #{error.class}: #{error.message}")
        false
      end

      def persist_writer_model!(stage, writer_model)
        normalized = WizwikiSettings.normalize_sms_writer_model(writer_model)
        metadata = stage.metadata.to_h.deep_dup
        return normalized if metadata["sms_writer_model"].to_s == normalized

        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "sms_writer_model" => normalized,
            "sms_writer_model_label" => WizwikiSettings.sms_writer_model_label(normalized),
            "sms_writer_model_explicit" => WizwikiSettings.sms_writer_model_explicit?(normalized),
            "sms_writer_model_saved_at" => Time.current.iso8601
          ).compact_blank
        )
        normalized
      end

      def mark_reply_running!(stage, inbound_event, generation: nil)
        metadata = stage.metadata.to_h.deep_dup
        now = Time.current.iso8601
        generation = generation.to_s.presence || inbound_event.to_h["reply_generation"].presence || metadata["sms_reply_generation"].presence
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "comms_command_background_inbound_id" => inbound_event.to_h["id"],
            "comms_command_background_inbound_sid" => inbound_event.to_h["provider_message_id"],
            "comms_command_background_status" => "running",
            "comms_command_background_at" => metadata["comms_command_background_at"].presence || now,
            "comms_command_background_running_at" => now,
            "sms_reply_job_generation" => generation,
            "sms_reply_job_status" => "running",
            "sms_reply_job_running_at" => now,
            "ask_autopilot_pending_started_at" => metadata["ask_autopilot_pending_started_at"].presence || metadata["comms_command_background_at"].presence || now,
            "ask_autopilot_pending_phase" => "drafting_message",
            "comms_command_last_status" => "drafting",
            "comms_command_last_at" => now
          ).compact_blank
        )
      end

      def mark_reply_failed!(stage, error)
        metadata = stage.metadata.to_h.deep_dup
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "comms_command_background_status" => "failed",
            "comms_command_background_error" => "#{error.class}: #{error.message}",
            "comms_command_background_at" => Time.current.iso8601,
            "comms_command_last_status" => "draft_failed",
            "comms_command_last_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil,
            "sms_autopilot_last_error" => "#{error.class}: #{error.message}"
          ).compact_blank
        )
      rescue StandardError => update_error
        Rails.logger.warn("[AskAutopilotTest] failed marking async reply failure stage=#{stage&.id} #{update_error.class}: #{update_error.message}")
      end

      def process_inbound_reply!(stage, user:, inbound_event:)
        return record_no_reply_needed!(stage.reload, inbound_event) if no_reply_needed_for_inbound?(stage.reload, inbound_event)

        result = draft_reply(stage.reload, user: user, inbound_event: inbound_event)
        result = apply_simulator_quality_gate(stage.reload, result, inbound_event)
        generation = inbound_event.to_h["reply_generation"].presence || result.to_h["sms_reply_generation"].presence
        return record_stale_reply!(stage.reload, inbound_event, generation: generation) if reply_generation_stale?(stage.reload, generation)
        return true if simulator_quality_gate_retryable?(result) && queue_simulator_quality_gate_retry!(stage.reload, result, inbound_event)

        reply_body = safe_customer_sms_body(result.to_h["body"])
        if reply_body.present?
          append_stage_event!(
            stage.reload,
            event_payload(
              direction: "outbound",
              status: "sent",
              body: reply_body,
              from: SIMULATED_WIZWIKI_NUMBER,
              to: simulated_customer_phone(user),
              user: user
            ).merge(
              "autopilot" => true,
              "ask_autopilot_test" => true,
              "autopilot_reply_to_sid" => inbound_event["provider_message_id"].presence || inbound_event["id"],
              "draft_provider" => result["provider"],
              "draft_model" => result["model"],
              "draft_source" => result["draft_source"],
              "writer_model" => result["writer_model"],
              "writer_model_label" => result["writer_model_label"],
              "sms_generation_pipeline" => result["sms_generation_pipeline"],
              "sms_quality_gate" => result["sms_quality_gate"],
              "autos_question_id" => result["autos_question_id"]
            ).compact_blank
          )
          record_sent_result!(stage.reload, result)
        else
          record_pending_result!(stage.reload, result)
          ensure_latest_inbound_has_reply_or_retry!(stage.reload)
        end

        true
      end

      def reply_generation_stale?(stage, generation)
        expected = generation.to_s.presence
        current = stage.reload.metadata.to_h["sms_reply_generation"].to_s
        return false if expected.blank? && current.blank?
        return true if expected.blank? && current.present?

        current.blank? || current != expected
      end

      def record_stale_reply!(stage, inbound_event, generation: nil)
        metadata = stage.metadata.to_h.deep_dup
        updates = {
          "sms_reply_last_stale_generation" => generation.to_s.presence,
          "sms_reply_last_stale_at" => Time.current.iso8601,
          "sms_autopilot_last_error" => "Skipped stale simulator draft because a newer customer message arrived."
        }.compact_blank
        if generation.to_s.blank? || metadata["sms_reply_job_generation"].to_s == generation.to_s
          updates.merge!(
            "comms_command_background_status" => "stale_inbound_rescan",
            "comms_command_background_at" => Time.current.iso8601,
            "sms_reply_job_status" => "stale",
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil,
            "comms_command_last_status" => metadata["comms_command_last_status"].presence || "received"
          )
        end
        stage.update!(generated_at: Time.current, metadata: metadata.merge(updates).compact_blank)
        Rails.logger.info("[AskAutopilotTest] skipped stale reply stage=#{stage.id} inbound=#{inbound_event.to_h["id"]} generation=#{generation}")
        false
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed marking stale reply stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def record_pending_result!(stage, result)
        metadata = stage.metadata.to_h.deep_dup
        pending = ActiveModel::Type::Boolean.new.cast(result.to_h["pending"])
        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "ask_autopilot_last_result" => simulator_result_payload(result),
            "ask_autopilot_last_autos_question_id" => result.to_h["autos_question_id"],
            "ask_autopilot_last_result_at" => Time.current.iso8601,
            "comms_command_sms_draft" => result,
            "comms_command_background_question_id" => result.to_h["autos_question_id"],
            "comms_command_background_status" => pending ? "queued" : "no_body",
            "comms_command_background_at" => metadata["comms_command_background_at"].presence || Time.current.iso8601,
            "sms_reply_job_status" => pending ? "draft_pending" : "no_body",
            "ask_autopilot_pending_started_at" => pending ? (metadata["ask_autopilot_pending_started_at"].presence || metadata["comms_command_background_at"].presence || Time.current.iso8601) : nil,
            "ask_autopilot_pending_phase" => pending ? "drafting_message" : nil,
            "comms_command_last_status" => pending ? "drafting" : "draft_failed",
            "sms_autopilot_last_error" => result.to_h["error"].presence
          ).compact_blank
        )
      end

      def payload_for(stage)
        metadata = stage.metadata.to_h
        pending = pending_background_draft?(metadata)
        {
          "active" => active_stage?(stage),
          "stage_id" => stage.id,
          "crm_record_id" => stage.crm_record_id,
          "started_at" => metadata["ask_autopilot_test_started_at"],
          "updated_at" => stage.updated_at.iso8601,
          "version" => payload_version(stage, metadata),
          "contact_name" => metadata["captured_contact_name"].presence || "Customer",
          "company_name" => metadata["company_name"].presence || "Customer",
          "sms_writer_model" => WizwikiSettings.sms_writer_model_from_metadata(metadata),
          "sms_writer_model_label" => WizwikiSettings.sms_writer_model_label(WizwikiSettings.sms_writer_model_from_metadata(metadata)),
          "engine_label" => engine_label(metadata),
          "backend_label" => backend_label(metadata),
          "last_result" => metadata["ask_autopilot_last_result"].presence,
          "pending" => pending,
          "pending_started_at" => (pending ? pending_started_at(stage, metadata) : nil),
          "pending_phase" => (pending ? pending_phase(metadata) : nil),
          "pending_label" => (pending ? pending_label(metadata) : nil),
          "pending_details" => (pending ? pending_details(metadata) : nil),
          "dojo_scoreboard" => dojo_scoreboard(metadata),
          "autopilot_alert" => no_answer_alert(stage, metadata),
          "messages" => Array(metadata["sms_thread"]).map { |event| message_from_event(event) }
        }.compact_blank
      end

      def payload_version(stage, metadata)
        events = Array(metadata["sms_thread"]).map(&:to_h).map do |event|
          [
            event["id"],
            event["provider_message_id"],
            event["direction"],
            event["status"],
            event["role"],
            event["dojo_cycle"],
            event["dojo_grade"],
            event["embedding_summary"],
            event["created_at"],
            Digest::SHA1.hexdigest(event["body"].to_s),
            Digest::SHA1.hexdigest(event["original_body"].to_s),
            Digest::SHA1.hexdigest(event["english_body"].to_s),
            event["language_code"],
            event["language_label"],
            event["language_translated"]
          ]
        end
        Digest::SHA1.hexdigest(
          [
            stage.updated_at.to_f,
            metadata["sms_writer_model"],
            metadata["sms_writer_model_label"],
            pending_background_draft?(metadata),
            metadata["comms_command_background_status"],
            metadata["recursive_dojo_status"],
            metadata["recursive_dojo_embedding_summary"],
            metadata["ask_autopilot_last_result_at"],
            metadata["ask_autopilot_pending_phase"],
            metadata["sms_reply_job_status"],
            metadata["ask_autopilot_sim_retry_count"],
            metadata["ask_autopilot_sim_retry_reason"],
            metadata["comms_command_background_error"],
            metadata.dig("ask_autopilot_last_result", "sms_quality_gate"),
            metadata.dig("ask_autopilot_last_result", "error"),
            metadata.dig("ask_autopilot_last_result", "reason"),
            events
          ].to_json
        )
      end

      def materialize_background_reply!(stage)
        metadata = stage.metadata.to_h.deep_dup
        body = metadata["comms_command_sms_draft_body"].to_s.squish
        return false if body.blank?

        events = Array(metadata["sms_thread"]).map(&:to_h)
        latest_inbound_index = events.rindex do |event|
          event["channel"].to_s == "sms" &&
            event["direction"].to_s == "inbound" &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
        return false if latest_inbound_index.blank?

        later_events = events[(latest_inbound_index + 1)..] || []
        return false if later_events.any? { |event| event["channel"].to_s == "sms" && event["direction"].to_s == "outbound" && !event["status"].to_s.in?(%w[failed canceled]) }

        draft = metadata["comms_command_sms_draft"].to_h
        question_id = draft["autos_question_id"].presence || metadata["comms_command_background_question_id"].presence
        return false if question_id.present? && events.any? { |event| event["direction"].to_s == "outbound" && event["autos_question_id"].to_s == question_id.to_s }
        question = nil
        if question_id.present?
          question = AutosQuestion.find_by(id: question_id)
          question_generation = question&.metadata.to_h["sms_reply_generation"].to_s.presence
          if reply_generation_stale?(stage.reload, question_generation)
            clear_rejected_background_reply!(stage.reload, draft.merge("error" => "stale_inbound_generation"), question_id)
            return false
          end
        end

        inbound = events[latest_inbound_index]
        unless background_question_matches_inbound?(stage.reload, question, inbound)
          clear_rejected_background_reply!(stage.reload, draft.merge("error" => "stale_simulator_inbound"), question_id)
          return false
        end

        draft = draft.merge("body" => body)
        draft = apply_simulator_quality_gate(stage.reload, draft, inbound)
        return true if simulator_quality_gate_retryable?(draft) && queue_simulator_quality_gate_retry!(stage.reload, draft, inbound)

        body = safe_customer_sms_body(draft["body"]).to_s.squish
        if body.blank?
          clear_rejected_background_reply!(stage.reload, draft, question_id)
          return false
        end

        appended = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "outbound",
            status: "sent",
            body: body,
            from: SIMULATED_WIZWIKI_NUMBER,
            to: inbound["from"].presence || stage.metadata.to_h.dig("phone_options", 0, "value").presence || simulated_customer_phone(stage.user),
            user: stage.user
          ).merge(
            "autopilot" => true,
            "ask_autopilot_test" => true,
            "autopilot_reply_to_sid" => inbound["provider_message_id"].presence || inbound["id"],
            "draft_provider" => draft["provider"],
            "draft_model" => draft["model"],
            "draft_source" => draft["draft_source"],
            "writer_model" => draft["writer_model"],
            "writer_model_label" => draft["writer_model_label"],
            "sms_generation_pipeline" => draft["sms_generation_pipeline"],
            "sms_quality_gate" => draft["sms_quality_gate"],
            "autos_question_id" => question_id,
            "late_worker_writeback" => true
          ).merge(dojo_materialized_event_metadata(inbound)).compact_blank
        )
        return false if appended.blank?

        latest = stage.reload.metadata.to_h.deep_dup
        stage.update!(
          generated_at: Time.current,
          metadata: latest.merge(
            "ask_autopilot_last_result" => simulator_result_payload(draft.merge("autos_question_id" => question_id)),
            "ask_autopilot_last_autos_question_id" => question_id,
            "ask_autopilot_last_result_at" => Time.current.iso8601,
            "sms_autopilot_sent_count" => latest["sms_autopilot_sent_count"].to_i + 1,
            "sms_autopilot_last_sent_at" => Time.current.iso8601,
            "sms_autopilot_last_error" => nil,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_status" => "simulated_sent",
            "comms_command_background_at" => Time.current.iso8601,
            "sms_reply_job_status" => "simulated_sent",
            "sms_reply_job_completed_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
        true
      end

      def dojo_materialized_event_metadata(inbound)
        payload = inbound.to_h
        return {} unless ActiveModel::Type::Boolean.new.cast(payload["recursive_dojo"]) || payload["role"].to_s == "dojo_customer"

        conversation = ActiveModel::Type::Boolean.new.cast(payload["dojo_conversation"]) ||
          payload["role"].to_s.start_with?("dojo_conversation")

        {
          "recursive_dojo" => true,
          "role" => conversation ? "dojo_conversation_answer" : "dojo_answer",
          "dojo_conversation" => conversation,
          "dojo_conversation_id" => payload["dojo_conversation_id"],
          "dojo_conversation_title" => payload["dojo_conversation_title"],
          "dojo_cycle" => payload["dojo_cycle"],
          "dojo_turn_index" => payload["dojo_turn_index"],
          "dojo_generation" => payload["dojo_generation"]
        }.compact_blank
      end

      def recover_answered_background_draft!(stage)
        metadata = stage.metadata.to_h
        return false if metadata["comms_command_sms_draft_body"].present?
        return false unless recoverable_background_draft?(metadata)

        question_id = metadata["comms_command_background_question_id"].presence ||
          metadata.dig("ask_autopilot_last_result", "autos_question_id").presence ||
          metadata["ask_autopilot_last_autos_question_id"].presence
        return false if question_id.blank?

        events = Array(metadata["sms_thread"]).map(&:to_h)
        return false if events.any? { |event| event["direction"].to_s == "outbound" && event["autos_question_id"].to_s == question_id.to_s }

        question = AutosQuestion.find_by(id: question_id)
        return false unless question.present?
        question_metadata = question.metadata.to_h
        return false unless question_metadata["surface"].to_s == "comms_sms_draft"
        return false unless question_metadata["comms_stage_id"].to_s == stage.id.to_s
        return false unless ActiveModel::Type::Boolean.new.cast(question_metadata["ask_autopilot_test"])
        worker = question_metadata["local_worker"].to_h
        worker_rejected = worker["reject_reason"].to_s.present? || worker["status"].to_s.in?(%w[rejected ignored])
        return false if question.status.to_s == "answered" && worker_rejected

        inbound = latest_inbound_event(stage.reload.metadata.to_h)
        return false unless background_question_matches_inbound?(stage.reload, question, inbound)
        return false unless defined?(DealReports::CommsDraftWriter)

        if question.status.to_s == "answered" && question.answer.to_s.squish.present?
          applied = DealReports::CommsDraftWriter.apply_worker_answer!(question)
          Rails.logger.info("[AskAutopilotTest] recovered answered draft stage=#{stage.id} question=#{question.id}") if applied
          return applied
        end

        if question.status.to_s == "failed"
          recovered = recover_failed_background_question!(stage.reload, question, inbound)
          Rails.logger.info("[AskAutopilotTest] recovered failed draft with fallback stage=#{stage.id} question=#{question.id}") if recovered
          return recovered
        end

        false
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] recover answered draft failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def recover_failed_background_question!(stage, question, inbound)
        return false unless background_question_matches_inbound?(stage.reload, question, inbound)
        return true if materialized_dojo_answer_event(stage.reload, inbound, nil).present?

        metadata = stage.metadata.to_h.deep_dup
        question_metadata = question.metadata.to_h
        worker = question_metadata["local_worker"].to_h
        base_draft = {
          "model" => worker["model"].presence || question_metadata["writer_model"],
          "writer_model" => question_metadata["writer_model"].presence || metadata["sms_writer_model"],
          "writer_model_label" => question_metadata["writer_model_label"].presence || metadata["sms_writer_model_label"],
          "error" => worker["reject_reason"].presence || question_metadata["error"].presence || "failed_background_draft",
          "sms_generation_pipeline" => "single_writer_guardrailed",
          "autos_question_id" => question.id
        }.compact_blank

        raw_body = question.answer.to_s.squish.presence
        raw_body = nil if worker["reject_reason"].to_s.present? || worker["status"].to_s.in?(%w[rejected ignored])
        gated = if raw_body.present?
          apply_simulator_quality_gate(
            stage.reload,
            base_draft.merge(
              "body" => raw_body,
              "provider" => worker["provider"].presence,
              "draft_source" => "thumper",
              "reason" => "Recovered a failed simulator draft through the SMS quality gate."
            ).compact_blank,
            inbound
          )
        else
          {}
        end

        body = safe_customer_sms_body(gated.to_h["body"]).to_s.squish
        return true if simulator_quality_gate_retryable?(gated) && queue_simulator_quality_gate_retry!(stage.reload, gated, inbound)

        if body.blank?
          fallback_body = simulator_priority_fallback(inbound, metadata: metadata, stage: stage, force: true).to_s.squish.presence
          if fallback_body.present?
            gated = apply_simulator_quality_gate(
              stage.reload,
              base_draft.merge(
                "body" => fallback_body,
                "provider" => "local/ask_sim_quality_gate",
                "draft_source" => "thumper_guardrail",
                "reason" => "Recovered a failed simulator draft with deterministic fallback."
              ).compact_blank,
              inbound
            )
            body = safe_customer_sms_body(gated.to_h["body"]).to_s.squish
            return true if simulator_quality_gate_retryable?(gated) && queue_simulator_quality_gate_retry!(stage.reload, gated, inbound)
          end
        end

        if body.blank?
          retry_draft = base_draft.merge(gated.to_h).merge("autos_question_id" => question.id).compact_blank
          return true if queue_simulator_guardrail_retry!(stage.reload, retry_draft)

          fallback_body = local_simulator_fallback(inbound, metadata: metadata, stage: stage).to_s.squish.presence
          if fallback_body.present?
            gated = apply_simulator_quality_gate(
              stage.reload,
              base_draft.merge(
                "body" => fallback_body,
                "provider" => "local/ask_sim_quality_gate",
                "draft_source" => "thumper_guardrail",
                "reason" => "Recovered a failed simulator draft with deterministic fallback."
              ).compact_blank,
              inbound
            )
            body = safe_customer_sms_body(gated.to_h["body"]).to_s.squish
            return true if simulator_quality_gate_retryable?(gated) && queue_simulator_quality_gate_retry!(stage.reload, gated, inbound)
          end
        end

        if body.blank?
          clear_rejected_background_reply!(stage.reload, gated, question.id)
          return false
        end

        appended = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "outbound",
            status: "sent",
            body: body,
            from: SIMULATED_WIZWIKI_NUMBER,
            to: inbound.to_h["from"].presence || stage.metadata.to_h.dig("phone_options", 0, "value").presence || simulated_customer_phone(stage.user),
            user: stage.user
          ).merge(
            "autopilot" => true,
            "ask_autopilot_test" => true,
            "autopilot_reply_to_sid" => inbound.to_h["provider_message_id"].presence || inbound.to_h["id"],
            "draft_provider" => gated["provider"],
            "draft_model" => gated["model"],
            "draft_source" => gated["draft_source"],
            "writer_model" => gated["writer_model"],
            "writer_model_label" => gated["writer_model_label"],
            "sms_generation_pipeline" => gated["sms_generation_pipeline"],
            "sms_quality_gate" => gated["sms_quality_gate"],
            "ask_quality_gate" => gated["ask_quality_gate"],
            "ask_quality_gate_replaced_body" => gated["ask_quality_gate_replaced_body"],
            "autos_question_id" => question.id,
            "failed_worker_recovery" => true
          ).merge(dojo_materialized_event_metadata(inbound)).compact_blank
        )
        return false if appended.blank?

        latest = stage.reload.metadata.to_h.deep_dup
        stage.update!(
          generated_at: Time.current,
          metadata: latest.merge(
            "ask_autopilot_last_result" => simulator_result_payload(gated.merge("body" => body, "autos_question_id" => question.id)),
            "ask_autopilot_last_autos_question_id" => question.id,
            "ask_autopilot_last_result_at" => Time.current.iso8601,
            "sms_autopilot_sent_count" => latest["sms_autopilot_sent_count"].to_i + 1,
            "sms_autopilot_last_sent_at" => Time.current.iso8601,
            "sms_autopilot_last_error" => nil,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_status" => "simulated_sent_after_rejection",
            "comms_command_background_at" => Time.current.iso8601,
            "sms_reply_job_status" => "simulated_sent_after_rejection",
            "sms_reply_job_completed_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
        true
      end

      def latest_inbound_event(metadata)
        Array(metadata.to_h["sms_thread"]).map(&:to_h).reverse.find do |event|
          event["channel"].to_s == "sms" &&
            event["direction"].to_s == "inbound" &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
      end

      def background_question_matches_inbound?(stage, question, inbound)
        return false if inbound.blank?
        return true if question.blank?

        metadata = stage.reload.metadata.to_h
        question_metadata = question.metadata.to_h
        started_at = metadata["ask_autopilot_test_started_at"].to_s.presence
        if started_at.present?
          reset_at = Time.zone.parse(started_at) rescue nil
          return false if reset_at.present? && question.created_at < reset_at
        end

        expected_generation = question_metadata["sms_reply_generation"].to_s.presence
        current_generation = metadata["sms_reply_generation"].to_s.presence
        return false if expected_generation.present? && current_generation.present? && expected_generation != current_generation

        expected_sid = question_metadata["sms_reply_generation_inbound_sid"].presence ||
          question_metadata["sms_reply_generation_inbound_id"].presence
        current_sid = inbound.to_h["provider_message_id"].presence ||
          inbound.to_h["id"].presence
        return false if expected_sid.present? && current_sid.present? && expected_sid != current_sid

        true
      end

      def apply_simulator_quality_gate(stage, result, inbound_event)
        draft = result.to_h.deep_dup
        raw_body = draft["body"].to_s.squish
        return draft if raw_body.blank?

        safe_body = simulator_safe_sms_body(stage, raw_body, inbound_event: inbound_event)
        if safe_body.present? && normalize_body(safe_body) == normalize_body(raw_body)
          return draft.merge(
            "body" => safe_body,
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "passed",
            "ask_quality_gate" => false
          ).compact_blank
        end

        if safe_body.present?
          draft.merge(
            "body" => safe_body,
            "provider" => "local/ask_sim_quality_gate",
            "model" => draft["model"].presence || "deterministic_route_guardrail",
            "draft_source" => "thumper_guardrail",
            "reason" => "Ask simulator replaced a non-customer-facing worker reply with the live SMS guardrail.",
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "rewritten",
            "ask_quality_gate" => true,
            "ask_quality_gate_replaced_body" => raw_body.present?,
            "ask_quality_gate_original_body" => raw_body.first(500)
          ).compact_blank
        else
          draft.except("body").merge(
            "reason" => "Ask simulator rejected a non-customer-facing worker reply.",
            "error" => [draft["error"], "ask_simulator_quality_gate_rejected"].compact_blank.join(" | "),
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "rejected",
            "ask_quality_gate" => true,
            "ask_quality_gate_original_body" => raw_body.first(500)
          ).compact_blank
        end
      end

      def simulator_safe_sms_body(stage, raw_body, inbound_event:)
        writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
        sanitized = writer.send(:sanitize_sms, raw_body)
        if sanitized.present?
          return sanitized if simulator_postcard_special_answer?(sanitized, inbound_event.to_h["body"], metadata: stage.metadata.to_h)

          if simulator_direct_pricing_reply_missing_price?(sanitized, inbound_event, metadata: stage.metadata.to_h)
            direct = local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
            return direct if direct.present?
          end

          if (direct = simulator_stack_completion_reply_if_needed(stage, sanitized, inbound_event, writer: writer))
            return direct
          end

          if simulator_known_lane_answer_mismatch?(stage, sanitized, inbound_event, writer: writer)
            direct = local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
            return direct if direct.present?

            return nil
          end

          return sanitized if simulator_customer_safe_direct_answer?(stage, sanitized, inbound_event, writer: writer)
          return sanitized if writer.send(:safe_sms_body_for_autopilot?, sanitized)
        end

        pipeline_safe = Comms::SmsBodySafety.sanitize_customer_body(raw_body) if defined?(Comms::SmsBodySafety)
        if pipeline_safe.present?
          return pipeline_safe if simulator_postcard_special_answer?(pipeline_safe, inbound_event.to_h["body"], metadata: stage.metadata.to_h)

          if simulator_direct_pricing_reply_missing_price?(pipeline_safe, inbound_event, metadata: stage.metadata.to_h)
            direct = local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
            return direct if direct.present?
          end

          if (direct = simulator_stack_completion_reply_if_needed(stage, pipeline_safe, inbound_event, writer: writer))
            return direct
          end

          if simulator_known_lane_answer_mismatch?(stage, pipeline_safe, inbound_event, writer: writer)
            direct = local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
            return direct if direct.present?

            return nil
          end

          return pipeline_safe if simulator_customer_safe_direct_answer?(stage, pipeline_safe, inbound_event, writer: writer)
          return pipeline_safe if writer.send(:safe_sms_body_for_autopilot?, pipeline_safe)
        end

        if (defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(raw_body)) || writer.send(:analysis_leak?, raw_body)
          return nil unless deterministic_simulator_fallbacks_enabled?

          direct = local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
          return direct if direct.present?
        end

        return nil unless deterministic_simulator_fallbacks_enabled?

        fallback = writer.send(:fallback_recovery_body, raw_body)
        fallback = writer.send(:sanitize_sms, fallback) if fallback.present?
        return fallback if fallback.present? && writer.send(:safe_sms_body_for_autopilot?, fallback)

        local_simulator_fallback(inbound_event, metadata: stage.metadata.to_h, stage: stage)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] quality gate failed stage=#{stage&.id} #{error.class}: #{error.message}")
        return nil unless deterministic_simulator_fallbacks_enabled?

        local_simulator_fallback(inbound_event, metadata: stage&.metadata.to_h, stage: stage)
      end

      def simulator_known_lane_answer_mismatch?(stage, body, inbound_event, writer:)
        text = body.to_s.squish
        inbound = inbound_event.to_h["body"].to_s.squish
        return false if text.blank? || inbound.blank?
        return true if simulator_turnaround_question?(stage, inbound) &&
          !writer.send(:turnaround_answer_for_inbound?, text, inbound)
        return true if simulator_messy_print_consultant_question?(inbound, metadata: stage&.metadata.to_h) &&
          !(writer.send(:print_products_answer_for_inbound?, text, inbound) && writer.send(:human_handoff_answer?, text))
        return true if simulator_standalone_print_product_quantity_followup?(inbound, stage&.metadata.to_h) &&
          !simulator_standalone_print_product_quantity_answer?(text, inbound, stage&.metadata.to_h)
        return true if simulator_print_products_question?(inbound) &&
          !writer.send(:print_products_answer_for_inbound?, text, inbound)
        return true if simulator_direct_mail_strategy_handoff_question?(inbound) &&
          !(writer.send(:human_handoff_answer?, text) && text.match?(/\b(?:strategy|routes?|lists?|targeting|neighborhoods?|details|go over|direct mail|postcard|eddm)\b/i))

        false
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] lane mismatch check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_stack_completion_reply_if_needed(stage, body, inbound_event, writer:)
        text = body.to_s.squish
        return if text.blank?
        missing_stack_answer = writer.send(:misses_open_customer_messages?, text) ||
          writer.send(:stacked_yard_sign_price_process_missing?, text)
        return unless missing_stack_answer

        simulator_priority_fallback(
          inbound_event,
          metadata: stage.reload.metadata.to_h,
          stage: stage.reload,
          force: true
        )
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] stack completion safety check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def simulator_customer_safe_direct_answer?(stage, body, inbound_event, writer:)
        text = body.to_s.squish
        inbound = inbound_event.to_h["body"].to_s.squish
        return false if text.blank? || inbound.blank?
        return false if text.length > DealReports::CommsDraftWriter::MAX_SMS_CHARS
        return false if writer.send(:analysis_leak?, text)
        return false if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)
        return true if writer.send(:turnaround_answer_for_inbound?, text, inbound)
        return false if simulator_turnaround_question?(stage, inbound)
        return false if simulator_known_lane_answer_mismatch?(stage, text, inbound_event, writer: writer)
        return true if simulator_postcard_special_answer?(text, inbound, metadata: stage.metadata.to_h)
        return false unless writer.send(:acceptable_sms_body?, text, include_drafts: false) || writer.send(:acceptable_sms_body?, text)

        return true if writer.send(:pricing_answer_for_inbound?, text, inbound)
        return true if writer.send(:yard_sign_pricing_request?, inbound) && writer.send(:yard_sign_pricing_answer_for_inbound?, text, inbound)
        return true if simulator_unit_pricing_question?(inbound) && simulator_unit_pricing_answer?(text)

        false
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] direct answer safety check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_postcard_special_answer?(body, inbound, metadata: {})
        text = body.to_s.downcase.squish
        question = inbound.to_s.downcase.squish
        return false if text.blank? || question.blank?
        price_sheet_followup = simulator_postcard_special_price_sheet_request?(question, metadata)
        quantity_followup = simulator_postcard_special_quantity_followup?(question, metadata)
        return false unless price_sheet_followup ||
          quantity_followup ||
          question.match?(/\b(?:specials?|promo|promos|discounts?|4th\s+of\s+july|july\s*4|block\s+sale)\b/)
        return false unless price_sheet_followup ||
          quantity_followup ||
          question.match?(/\b(?:post\s*cards?|postcards?|direct mail|mailers?|mailing)\b/) ||
          question.match?(/\b(?:4th\s+of\s+july|july\s*4|block\s+sale)\b/)
        return false unless text.match?(/\b(?:post\s*cards?|postcards?|postcard-only|block\s+sale|direct mail|mail)\b/)
        return false unless text.match?(/\b(?:4th\s+of\s+july|july\s*4|block\s+sale|special)\b/)

        if quantity_followup
          quantity = simulator_postcard_special_quantity_from_text(question)
          return false if quantity.blank?

          quantity_pattern = /\b#{Regexp.escape(quantity.to_fs(:delimited))}\b|\b#{quantity}\b/
          return text.match?(quantity_pattern) && text.match?(Regexp.new(Regexp.escape(simulator_postcard_special_price_for_quantity(quantity))))
        end

        if price_sheet_followup || question.match?(/\b(?:full|all|entire|sheet|tiers?|list)\b/)
          return [
            [/\b(?:1,?000|1000|1k)\b/, /\$\s?790\b/],
            [/\b(?:2,?500|2500|2\.5k)\b/, /\$\s?1,?725\b/],
            [/\b(?:5,?000|5000|5k)\b/, /\$\s?3,?250\b/],
            [/\b(?:10,?000|10000|10k)\b/, /\$\s?6,?300\b/],
            [/\b(?:25,?000|25000|25k)\b/, /\$\s?14,?750\b/]
          ].all? { |quantity_pattern, price_pattern| text.match?(quantity_pattern) && text.match?(price_pattern) }
        end

        text.match?(/\b(?:1,?000|1000|1k)\b/) && text.match?(/\$\s?790\b/)
      end

      def recursive_dojo_priority_fallback(stage, inbound_event)
        return unless recursive_dojo_priority_fallback_enabled?

        simulator_priority_fallback(
          inbound_event,
          metadata: stage.reload.metadata.to_h,
          stage: stage.reload,
          force: true
        )
      end

      def recursive_dojo_priority_fallback_enabled?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("ASK_RECURSIVE_DOJO_PRIORITY_FALLBACK_ENABLED", "1"))
      end

      def simulator_priority_fallback(inbound_event, metadata: {}, stage: nil, force: false)
        return unless force || deterministic_simulator_fallbacks_enabled?

        inbound = inbound_event.to_h["body"].to_s.squish
        return if inbound.blank?
        route = simulator_route_code(metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_direct_mail_strategy_handoff_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_postcard_special_checkout_request?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if yard_sign_checkout_link_request?(inbound, metadata: metadata, route: route)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_postcard_special_question?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_postcard_special_quantity_followup?(inbound, metadata)

        stack_reply = simulator_open_customer_stack_reply(stage, inbound, metadata: metadata)
        return stack_reply if stack_reply.present?
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_turnaround_question?(stage, inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_messy_print_consultant_question?(inbound, metadata: metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_print_handoff_choice_question?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_print_product_detail_question?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_multi_print_product_request?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_direct_mail_interest_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_standalone_print_product_quantity_followup?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if listed_yard_sign_quantity_request?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_print_products_question?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_postcard_minimum_path_question?(inbound, metadata: metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_postcard_special_checkout_request?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_price_before_handoff_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_yard_sign_included_items_question?(inbound, metadata: metadata, route: route)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if yard_sign_artwork_help_question?(inbound, metadata: metadata, route: route)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if yard_sign_artwork_context_statement?(inbound, metadata: metadata, route: route)
        if design_process_question?(inbound) && !ai_art_builder_question?(inbound)
          return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage)
        end
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_support_handoff_confirmation_request?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_yard_sign_cheapest_question?(inbound, metadata: metadata, route: route)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_unit_pricing_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if eddm_neighborhood_blitz_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_neighborhood_blitz_checkout_request?(inbound, metadata)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if starter_pro_compare_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if standard_lane_compare_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_yard_sign_route_context_message?(inbound, metadata: metadata, route: route)
        if route.to_s == "LAWN_SIGNS" && (simulator_standalone_quantity_answer?(inbound) || listed_yard_sign_quantity_request?(inbound, route: route))
          return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage)
        end
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if yard_sign_checkout_link_request?(inbound, metadata: metadata, route: route)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if mixed_postcards_signs_cards_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_contact_context_question?(stage, inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if simulator_current_specials_question?(stage, inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if full_options_pricing_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if generic_pricing_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if signs_only_bundle_compare_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if signs_only_pricing_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if neighborhood_blitz_contents_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if neighborhood_blitz_best_deal_request?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if signs_only_bundle_fit_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if checkout_confusion_question?(inbound)
        return local_simulator_fallback(inbound_event, metadata: metadata, stage: stage) if large_volume_request?(inbound)

        nil
      end

      def simulator_full_options_pricing_reply_incomplete?(body, inbound_event)
        inbound = inbound_event.to_h["body"].to_s.squish
        return false unless full_options_pricing_question?(inbound)

        !full_options_pricing_answer?(body)
      end

      def simulator_open_customer_stack_reply(stage, inbound, metadata: {})
        messages = simulator_open_customer_stack_messages(stage, metadata: metadata)
        return if messages.length < 2

        active_messages = simulator_active_open_customer_stack(messages)
        return if active_messages.length < 2

        latest = active_messages.last.to_s.downcase.squish
        stack_text = active_messages.join(" ").downcase.squish

        if simulator_stack_superseding_pivot?(latest) && simulator_message_lane(latest) == "postcards"
          return "Not a problem. We can switch to postcards. For 1,000 postcards, the 4th of July postcard Block Sale is $790. If you want that path, I can send the postcard special checkout link."
        end

        if stack_text.match?(/\b50\b/) && stack_text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
          return "For 18x24 yard signs, 50 signs are $249. Stakes, shipping, and design help are included. Other signs-only tiers include 10 for $99, 20 for $159, and 100 for $399. Want me to send the 50-sign checkout link?"
        end

        if stack_text.match?(/\b100\b/) && stack_text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) && stack_text.match?(/\b(?:proof|approve|approval|printing|print)\b/)
          return "100 yard signs are $399, with stakes, shipping, and design help included. Yes, you approve a proof before anything prints; after checkout, the intake form collects your logo/artwork and notes."
        end

        if stack_text.match?(/\b500\b/) && stack_text.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) && stack_text.match?(/\b(?:design|stakes?|shipping|included)\b/)
          return "500 yard signs are $1,699. Design help, stakes, and shipping are included in that listed price. If you want a person involved too, I can pass the 500-sign thread to a WIZWIKI teammate."
        end

        nil
      end

      def simulator_open_customer_stack_messages(stage, metadata: {})
        thread = Array(stage&.metadata.to_h["recursive_dojo_isolated_thread"].presence || metadata.to_h["sms_thread"]).map(&:to_h)
        last_outbound_index = thread.rindex do |event|
          event["direction"].to_s == "outbound" &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled blocked skipped])
        end
        candidates = last_outbound_index ? thread[(last_outbound_index + 1)..] : thread
        Array(candidates).filter_map do |event|
          next unless event["direction"].to_s == "inbound"
          next if event["status"].to_s.in?(%w[failed canceled blocked skipped])

          event["body"].to_s.squish.presence
        end
      end

      def simulator_active_open_customer_stack(messages)
        messages = Array(messages).map { |message| message.to_s.squish }.reject(&:blank?)
        return messages if messages.length < 2

        latest = messages.last.to_s.downcase.squish
        return messages unless simulator_stack_superseding_pivot?(latest)

        latest_lane = simulator_message_lane(latest)
        return messages if latest_lane.blank?

        messages.reject.with_index do |message, index|
          next false if index == messages.length - 1

          earlier_lane = simulator_message_lane(message)
          earlier_lane.present? && earlier_lane != latest_lane
        end
      end

      def simulator_stack_superseding_pivot?(text)
        text.to_s.match?(/\b(?:actually|nevermind|never mind|scratch that|ignore that|forget that|instead|rather|rather than|prefer|change|switch|not that|not those|don'?t want|do not want)\b/i)
      end

      def simulator_message_lane(text)
        body = text.to_s.downcase.squish
        return "postcards" if body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail|mailboxes?|homes?|houses?|routes?|lists?)\b/)
        return "yard_signs" if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|signs?)\b/)
        return "print" if body.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|print products?)\b/)
        return "bundle" if body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/)

        nil
      end

      def simulator_yard_sign_quantity_reply_missing_price?(stage, body, inbound_event)
        metadata = stage.metadata.to_h
        route = simulator_route_code(metadata)
        inbound = inbound_event.to_h["body"].to_s.squish
        text = body.to_s.squish
        return false unless route.to_s == "LAWN_SIGNS"
        return false unless inbound.match?(/\A\d{1,6}\z/)
        return false if text.match?(/\$\s?\d|closest|listed quantities|checkout tier|tier/i)

        text.match?(/\b(?:signs?|yard signs?|lawn signs?|covered|proceed|company)\b/i)
      end

      def simulator_direct_pricing_reply_missing_price?(body, inbound_event, metadata: {})
        inbound = inbound_event.to_h["body"].to_s.squish
        text = body.to_s.squish
        return false if inbound.blank? || text.blank?
        return false unless inbound.match?(/\b(?:how\s+(?:much|mush|mauch|mutch|muxh)|howmuch|cost|costs|price|pricing|total|rate|rates|charge|charges|quote|quotes)\b/i)
        return !simulator_unit_pricing_answer?(text) if simulator_unit_pricing_question?(inbound)
        return false if text.match?(/\$\s?\d|dollars?|pricing|price|cost/i)

        route = simulator_route_code(metadata)
        route.to_s == "LAWN_SIGNS" ||
          listed_yard_sign_quantity_request?(inbound, route: route) ||
          bundle_price_question?(inbound) ||
          yard_sign_budget_question?(inbound, metadata: metadata, route: route)
      end

      def simulator_unit_pricing_question?(text)
        text.to_s.match?(/\b(?:each|apiece|a piece|per\s+(?:unit|piece|sign|card|hanger|home|house|door|postcard)|price\s+per|unit\s+price|how\s+much\s+(?:is|are)\s+(?:one|each)|costs?\s+each|cost\s+per)\b/i) ||
          text.to_s.match?(/\b(?:what(?:'s| is| would)?|how\s+much)\b.{0,40}\b(?:one|1|single)\b.{0,20}\b(?:yard\s+|lawn\s+)?(?:sign|postcard|card|hanger)\b.{0,40}\b(?:cost|run|work\s+out|each|apiece|per)\b/i) ||
          text.to_s.match?(/\b(?:one|1|single)\b.{0,20}\b(?:yard\s+|lawn\s+)?(?:sign|postcard|card|hanger)\b.{0,40}\b(?:cost|run|work\s+out|each|apiece|per)\b/i)
      end

      def simulator_unit_pricing_answer?(text)
        body = text.to_s.squish
        return false if body.blank?
        return false unless body.match?(/\$\s?\d/)

        body.match?(/\b(?:each|apiece|a piece|per\s+(?:unit|piece|sign|card|hanger|home|house|door|postcard)|unit\s+price)\b/i)
      end

      def simulator_conversational_quantity_reply?(stage, body, inbound_event, writer:)
        metadata = stage.metadata.to_h
        route = simulator_route_code(metadata)
        inbound = inbound_event.to_h["body"].to_s.squish
        text = body.to_s.squish
        return false unless route.to_s == "LAWN_SIGNS"
        return false if text.blank? || text.length > DealReports::CommsDraftWriter::MAX_SMS_CHARS
        return false if writer.send(:analysis_leak?, text) || text.match?(/\b(?:checkout|link|tier|price|cost|\$\s?\d|listed quantities)\b/i)

        unless inbound.match?(/\A\d{1,6}\z/)
          return simulator_company_after_quantity_follow_up?(metadata, text, inbound)
        end

        return false unless text.match?(/\b(?:#{Regexp.escape(inbound)}|signs?|yard signs?|lawn signs?)\b/i)

        text.match?(/\b(?:first name|your name|company|business|campaign|what kind|save this conversation)\b/i)
      end

      def simulator_company_after_quantity_follow_up?(metadata, text, inbound)
        return false unless company_identity_after_yard_sign_quantity?(inbound, metadata: metadata)

        quantity = recent_yard_sign_quantity(metadata)
        return false unless quantity.positive?
        return false unless text.match?(/\b(?:#{Regexp.escape(quantity.to_s)}|signs?|yard signs?|lawn signs?)\b/i)

        text.match?(/\b(?:first name|your name|what'?s your name|what is your name)\b/i)
      end

      def simulator_print_products_question?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if simulator_standalone_print_product_quantity_followup?(body, metadata)
        return true if body.match?(/\b(?:business|biz)\s+cards?\b|\bdoor\s*hangers?\b|\bdoorhanger\b|\bhangers?\b/) && !body.match?(/\bpost\s*cards?|postcards?|eddm|direct mail\b/)
        return true if body.match?(/\bcards?\b/) && simulator_recent_standalone_print_route(metadata).to_s == "BUSINESS_CARDS"
        return true if body.match?(/\b(?:what other|what else|other print|print products?|printed?\s+materials?|marketing\s+materials?|print(?:ed)?\s+pieces?|print(?:ed)?\s+collateral|custom\s+print|what can you help with|what do you offer)\b/)
        return true if body.match?(/\b(?:flyers?|rack cards?|magnets?|brochures?|menus?)\b/)
        return true if body.match?(/\bbusiness cards?\b/) && body.match?(/\bdoor hangers?\b/) && body.match?(/\b(?:include|offer|help|those|products?)\b/)
        return true if body.match?(/\b(?:all that|those|these)\b/) && body.match?(/\b(?:help me choose|real person|person|consultant|talk to someone)\b/)

        false
      end

      def simulator_print_product_detail_question?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless recent_print_context?(metadata) ||
          body.match?(/\b(?:business|biz)\s+cards?\b|\bdoor\s+hangers?\b|\bdoorhanger\b|\bflyers?\b/)

        body.match?(/\b(?:details?|sizes?|quantit(?:y|ies)|prices?|pricing|costs?|tell me more|what are the options|how much)\b/) ||
          body.match?(/\b(?:those|these|that|all three|all that)\b.{0,80}\b(?:details?|prices?|pricing|costs?|options?)\b/)
      end

      def simulator_multi_print_product_request?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?

        products = 0
        products += 1 if body.match?(/\b(?:business|biz)\s+cards?\b/)
        products += 1 if body.match?(/\bdoor\s+hangers?\b|\bdoorhanger\b|\bhangers?\b/)
        products += 1 if body.match?(/\bflyers?\b/)
        products >= 2 || (recent_print_context?(metadata) && body.match?(/\b(?:flyers?|business cards?|door hangers?|what can you help|what else|also)\b/))
      end

      def simulator_print_product_detail_reply
        "Business cards are 16pt premium matte: 250 for $70, 500 for $75, and 1,000 for $80. Door hangers are 4.25x11: 500 from $270 and 1,000 from $335. Flyers have standalone size options; 8.5x11 starts at 250 for $210 and 500 for $280. Which link should I send first?"
      end

      def simulator_messy_print_consultant_reply
        "For that custom print mix, WIZWIKI can help with flyers, business cards, door hangers, and related print, but a marketing consultant should map out sizes, quantities, and the cleanest path. What is the best way for them to reach you?"
      end

      def simulator_print_handoff_choice_reply
        "Yes, a real person is the right move for choosing that custom print setup. WIZWIKI can produce flyers, business cards, and door hangers, but a marketing consultant should help pick sizes, quantities, and the cleanest path. What is the best way for them to reach you?"
      end

      def simulator_standalone_print_product_quantity_followup?(text, metadata = {})
        simulator_standalone_print_product_quantity_route(text, metadata).present? &&
          simulator_standalone_print_product_quantity_value(text).present?
      end

      def simulator_standalone_print_product_quantity_route(text, metadata = {})
        body = text.to_s.downcase.squish
        return if body.blank?
        return "DOOR_HANGERS" if body.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/)
        return "FLYERS" if body.match?(/\bflyers?\b/)
        return "BUSINESS_CARDS" if body.match?(/\b(?:business|biz)\s+cards?\b/)
        return "BUSINESS_CARDS" if body.match?(/\bcards?\b/) && simulator_recent_standalone_print_route(metadata).to_s == "BUSINESS_CARDS"

        if body.match?(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+|just\s+)?[\d,]{1,6}\s*[.!?]?\z/i)
          route = simulator_route_code(metadata).to_s.presence || simulator_recent_standalone_print_route(metadata).to_s.presence
          return route if %w[BUSINESS_CARDS DOOR_HANGERS FLYERS].include?(route)
        end

        nil
      end

      def simulator_standalone_print_product_quantity_value(text)
        body = text.to_s.downcase.squish
        return if body.blank?
        return if body.match?(/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/)

        values = body.scan(/\b[\d,]{1,6}\b/).map { |value| value.delete(",").to_i }.select(&:positive?).uniq
        return unless values.one?

        values.first
      end

      def simulator_standalone_print_product_quantity_reply(text, metadata = {})
        body = text.to_s.downcase.squish
        route = simulator_standalone_print_product_quantity_route(body, metadata)
        quantity = simulator_standalone_print_product_quantity_value(body)
        return if route.blank? || quantity.blank?

        case route
        when "BUSINESS_CARDS"
          prices = { 250 => "$70", 500 => "$75", 1_000 => "$80", 2_500 => "$150", 5_000 => "$195", 10_000 => "$300" }
          if quantity < 250
            return "Standalone business cards start at 250. The 250-count option is $70. Would 250 work?"
          end
          price = prices[quantity]
          return "For #{quantity.to_fs(:delimited)} business cards, the standalone 16pt premium matte option is #{price}. Want me to send the Business Cards checkout link?" if price.present?

          "Business cards have listed standalone tiers at 250, 500, 1,000, 2,500, 5,000, and 10,000. #{quantity.to_fs(:delimited)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
        when "DOOR_HANGERS"
          prices = { 500 => "$270", 1_000 => "$335", 2_500 => "$600", 5_000 => "$1,035", 10_000 => "$1,985" }
          if quantity < 500
            return "Standalone door hangers start at 500, so #{quantity.to_fs(:delimited)} is below the listed checkout minimum. The 500-count option starts at $270. Would 500 work?"
          end
          price = prices[quantity]
          return "For #{quantity.to_fs(:delimited)} door hangers, the standalone 4.25x11 option starts at #{price}, depending on finish. Want me to send the door-hanger checkout link?" if price.present?

          "Door hangers have listed standalone tiers at 500, 1,000, 2,500, 5,000, and 10,000. #{quantity.to_fs(:delimited)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
        when "FLYERS"
          prices = { 250 => "$210", 500 => "$280", 1_000 => "$345", 2_500 => "$570", 5_000 => "$820", 10_000 => "$1,550" }
          if quantity < 250
            return "For 8.5x11 flyers, the listed standalone tiers start at 250. The 250-count option is $210. Would 250 work?"
          end
          price = prices[quantity]
          return "For #{quantity.to_fs(:delimited)} 8.5x11 flyers, the standalone option is #{price}; smaller flyer sizes can be lower. Want me to send the Flyers checkout link?" if price.present?

          "Flyers have listed 8.5x11 tiers at 250, 500, 1,000, 2,500, 5,000, and 10,000. #{quantity.to_fs(:delimited)} is outside those exact tiers, so a marketing consultant should check the cleanest setup."
        end
      end

      def simulator_standalone_print_product_quantity_answer?(body, inbound, metadata = {})
        text = body.to_s.downcase.squish
        route = simulator_standalone_print_product_quantity_route(inbound, metadata)
        quantity = simulator_standalone_print_product_quantity_value(inbound)
        return false if text.blank? || route.blank? || quantity.blank?

        case route
        when "BUSINESS_CARDS"
          return text.match?(/\bbusiness\s+cards?\b/) && text.match?(/\b250\b/) && text.match?(/\$70\b/) if quantity < 250
          expected = { 250 => "$70", 500 => "$75", 1_000 => "$80", 2_500 => "$150", 5_000 => "$195", 10_000 => "$300" }[quantity]
          expected.present? ? text.match?(/\bbusiness\s+cards?\b/) && text.include?(expected.downcase) : text.match?(/\bbusiness\s+cards?\b/) && text.match?(/\boutside\b|\bmarketing consultant\b/)
        when "DOOR_HANGERS"
          return text.match?(/\bdoor\s+hangers?\b/) && text.match?(/\bstart(?:s)?\s+at\s+500\b|\b500-count\b|\bbelow\b/) && !text.match?(/\byes\b.{0,20}\b(?:you can|get just)\b/) if quantity < 500
          expected = { 500 => "$270", 1_000 => "$335", 2_500 => "$600", 5_000 => "$1,035", 10_000 => "$1,985" }[quantity]
          expected.present? ? text.match?(/\bdoor\s+hangers?\b/) && text.include?(expected.downcase) : text.match?(/\bdoor\s+hangers?\b/) && text.match?(/\boutside\b|\bmarketing consultant\b/)
        when "FLYERS"
          return text.match?(/\bflyers?\b/) && text.match?(/\b250\b/) && text.match?(/\$210\b/) if quantity < 250
          expected = { 250 => "$210", 500 => "$280", 1_000 => "$345", 2_500 => "$570", 5_000 => "$820", 10_000 => "$1,550" }[quantity]
          expected.present? ? text.match?(/\bflyers?\b/) && text.include?(expected.downcase) : text.match?(/\bflyers?\b/) && text.match?(/\boutside\b|\bmarketing consultant\b/)
        else
          false
        end
      end

      def simulator_recent_standalone_print_route(metadata = {})
        Array(metadata.to_h["sms_thread"]).map(&:to_h).last(8).reverse_each do |event|
          body = event["body"].to_s.downcase.squish
          next if body.blank?

          return "BUSINESS_CARDS" if body.match?(/\b(?:business|biz)\s+cards?\b/)
          return "DOOR_HANGERS" if body.match?(/\b(?:door\s*hangers?|doorhanger|hangers?)\b/)
          return "FLYERS" if body.match?(/\bflyers?\b/)
        end

        nil
      end

      def simulator_print_product_confirmation_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:could|can|would|do|does|will)\b.{0,70}\b(?:include|include those|have|offer|help with)\b/) ||
          body.match?(/\b(?:those|these|that|all that)\b.{0,70}\b(?:include|included|available|possible|work|help)\b/) ||
          body.match?(/\b(?:yes|yep|yeah|ok|okay)\b.{0,40}\b(?:business cards?|door hangers?|flyers?|rack cards?|magnets?|brochures?)\b/)
      end

      def simulator_print_handoff_choice_question?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if body.match?(/\bthumper\b.{0,80}\b(?:figure all that out|help me choose)\b/) &&
          body.match?(/\b(?:real person|person|consultant|someone|help me choose)\b/)

        context = [
          body,
          Array(metadata.to_h["sms_thread"]).map(&:to_h).last(8).map { |event| event["body"].to_s }.join(" ")
        ].join(" ").downcase.squish
        return false unless context.match?(/\b(?:print|flyers?|business cards?|door hangers?|rack cards?|brochures?|cards?)\b/)

        body.match?(/\b(?:should|can|could|would)\b.{0,90}\b(?:real person|person|consultant|someone|teammate)\b/) ||
          body.match?(/\b(?:real person|person|consultant|someone|teammate)\b.{0,90}\b(?:help me choose|figure|map|handle|take over)\b/) ||
          body.match?(/\bthumper\b.{0,80}\b(?:figure all that out|help me choose)\b/)
      end

      def simulator_messy_print_consultant_question?(text, metadata: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if body.match?(/\b(?:all that|figure all that out|help me choose)\b/) &&
          body.match?(/\b(?:thumper|real person|person|consultant|someone)\b/)
        print_context = body.match?(/\b(?:print(?:ed)?\s+materials?|marketing\s+materials?|print(?:ed)?\s+pieces?|print(?:ed)?\s+collateral|custom\s+print|print|flyers?|business cards?|door hangers?|rack cards?|brochures?|menus?|cards?)\b/) ||
          recent_print_context?(metadata)
        return false unless print_context

        body.match?(/\b(?:messy|custom|not sure|don'?t know|do not know|sizes?|quantit(?:y|ies)|figure all that out|all that out|real person|person help|help me choose|talk to a person|consultant)\b/)
      end

      def recent_print_context?(metadata)
        thread = Array(metadata.to_h["recursive_dojo_isolated_thread"].presence || metadata.to_h["sms_thread"]).map(&:to_h).last(12)
        context = thread.map do |event|
          [
            event["body"],
            event["english_body"],
            event["original_body"]
          ].compact.join(" ")
        end.join(" ").downcase.squish

        context.match?(/\b(?:print(?:ed)?\s+materials?|marketing\s+materials?|print(?:ed)?\s+pieces?|print(?:ed)?\s+collateral|custom\s+print|flyers?|business cards?|door hangers?|rack cards?|brochures?|menus?)\b/)
      end

      def simulator_direct_mail_strategy_handoff_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:direct mail|eddm|postcards?|mailers?|mailboxes?|routes?|lists?|targeting|neighborhoods?)\b/)

        body.match?(/\b(?:strategy|targeting|routes?|lists?|software|account setup|best neighborhoods?|what would work|pick the best|plan|manage)\b/)
      end

      def simulator_direct_mail_strategy_handoff_reply
        "Thumper can cover simple EDDM and postcard basics, but picking neighborhoods, routes, lists, strategy, or software setup should go through a marketing consultant so the plan is accurate. What is the best way for them to reach you?"
      end

      def simulator_direct_mail_interest_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if simulator_direct_mail_strategy_handoff_question?(body)

        body.match?(/\b(?:direct mail|eddm|post\s*cards?|postcards?|mailers?|mailboxes?|mailing)\b/)
      end

      def simulator_writer_reply(stage, method_name, *args)
        return if stage.blank? || !defined?(DealReports::CommsDraftWriter)

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(method_name, *args)
          .to_s
          .squish
          .presence
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] writer reply #{method_name} failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def simulator_yard_sign_cheapest_question?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/) && !body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
        return false unless body.match?(/\b(?:cheap(?:er|est)?|least expensive|lowest(?:\s+(?:cost|price|total))?|entry(?:\s*point)?|smallest|budget)\b/)
        sign_context = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) ||
          route.to_s == "LAWN_SIGNS" ||
          recent_thread_mentions_yard_signs?(metadata)
        return false unless sign_context

        body.match?(/\b(?:package|pack|option|deal|path|price|pricing|cost|total)\b/)
      end

      def simulator_yard_sign_included_items_question?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:include|included|comes with|come with|part of|free)\b/)
        return false unless body.match?(/\b(?:design|stakes?|shipping|ship)\b/)

        body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) ||
          route.to_s == "LAWN_SIGNS" ||
          recent_thread_mentions_yard_signs?(metadata)
      end

      def simulator_price_before_handoff_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:person|someone|consultant|team|teammate|human|rep|representative|call|follow\s*up|reach out|connect)\b/)

        direct_price_question?(body) ||
          body.match?(/\b(?:what\s+do|what\s+would|how\s+much)\b.{0,80}\b(?:\d|yard\s+signs?|lawn\s+signs?|signs?)\b/)
      end

      def simulator_price_before_handoff_reply(stage, inbound)
        reply = simulator_writer_reply(stage, :price_then_handoff_reply, inbound)
        return reply if reply.present? && reply.match?(/\$\s?\d/)

        body = inbound.to_s.downcase.squish
        if body.match?(/\b500\b/) && body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
          return "500 Yard Signs are $1,699 double-sided, with design help, stakes, and shipping included. I will also pass this to a WIZWIKI teammate so a person can follow up on the 500 signs."
        end

        "I can answer the price first, then pass this to a WIZWIKI teammate for follow-up. Which product and quantity should I price?"
      end

      def simulator_postcard_minimum_path_question?(text, metadata: {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:checkout|link|order|buy|purchase)\b/)
        return false if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) && !body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|mail)\b/)
        return false unless body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|mail)\b/) || simulator_recent_postcard_context?(metadata)

        body.match?(/\b(?:smallest|minimum|lowest|starter|starting|entry|real)\b.{0,50}\b(?:path|order|option|route|postcards?|mail)\b/) ||
          body.match?(/\b(?:what|which)\b.{0,40}\b(?:smallest|minimum|lowest|starter|starting|entry)\b.{0,40}\b(?:postcards?|mail|order|path|route)\b/)
      end

      def simulator_support_handoff_confirmation_request?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if simulator_turnaround_text?(body)
        return false if simulator_price_before_handoff_question?(body)
        return false if body.match?(/\b(?:artwork|art work|design|logo|creative|file|files|image|images|proof|screenshot)\b/)
        human = body.match?(/\b(?:person|someone|consultant|team|teammate|human|rep|representative|call|follow\s*up|reach out|connect)\b/)
        return false unless human

        body.match?(/\b(?:yes|yep|yeah|sure|ok|okay|please|too|also)\b/) ||
          body.match?(/\b(?:have|get|connect|pass|send)\b.{0,80}\b(?:person|someone|consultant|team|teammate|human|rep|representative)\b/) ||
          body.match?(/\b(?:person|someone|consultant|team|teammate|human|rep|representative)\b.{0,80}\b(?:follow\s*up|reach out|connect|pick this up)\b/)
      end

      def simulator_support_handoff_reply(inbound, metadata: {})
        body = inbound.to_s.downcase.squish
        recent = Array(metadata.to_h["sms_thread"]).map(&:to_h).last(8).map { |event| event["body"].to_s }.join(" ").downcase
        context = [body, recent].join(" ")

        if context.match?(/\b500\b.{0,30}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b|\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,30}\b500\b/)
          return "For 500 yard signs, the listed price is $1,699, and design help, stakes, and shipping are included. I want to help you get the best support possible. Can I have one of our amazing marketing consultants reach out to you? What is the best way to reach you?"
        end

        if context.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
          return "I want to help you get the best support possible. Can I have one of our amazing marketing consultants reach out to you about the yard-sign order? What is the best way to reach you?"
        end

        if context.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/)
          return "I want to help you get the best support possible. Can I have one of our amazing marketing consultants reach out to you about the postcard order? What is the best way to reach you?"
        end

        "I want to help you get the best support possible. Can I have one of our amazing marketing consultants reach out to you? What is the best way to reach you?"
      end

      def simulator_neighborhood_blitz_checkout_request?(text, metadata = {})
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if simulator_turnaround_text?(body)
        return false if full_options_pricing_question?(body) || generic_pricing_question?(body)
        return false unless body.match?(/\b(?:blitz|neighbou?rhood)\b/) || simulator_recent_neighborhood_blitz_context?(metadata)
        accepted = body.match?(/\b(?:sounds right|sounds good|that works|go ahead|yes|yep|yeah|ok|okay)\b/)
        explicit_link = body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:checkout|link|order|buy|purchase)\b/) ||
          body.match?(/\b(?:checkout|order|buy|purchase)\s+links?\b/)
        return false unless accepted || explicit_link

        !body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
      end

      def simulator_recent_neighborhood_blitz_context?(metadata)
        Array(metadata.to_h["sms_thread"]).map(&:to_h).last(8).any? do |event|
          event["body"].to_s.match?(/\b(?:neighbou?rhood\s+blitz|blitz)\b/i)
        end
      end

      def starter_pro_compare_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\bstarter\s*pack\b/) && body.match?(/\bpro\s*pack\b/)

        body.match?(/\b(?:compare|comparison|versus|vs\.?|difference|what.*come|what.*include|cards?|business\s+cards?|door\s+hangers?)\b/)
      end

      def local_simulator_fallback(inbound_event, metadata: {}, stage: nil)
        inbound = inbound_event.to_h["body"].to_s.squish
        route = simulator_route_code(metadata)

        if simulator_direct_mail_strategy_handoff_question?(inbound)
          return simulator_direct_mail_strategy_handoff_reply
        end

        if simulator_postcard_special_checkout_request?(inbound, metadata)
          return simulator_postcard_special_checkout_reply(stage, inbound)
        end

        if yard_sign_checkout_link_request?(inbound, metadata: metadata, route: route)
          return yard_sign_checkout_link_reply(metadata)
        end

        if simulator_postcard_special_question?(inbound, metadata)
          reply = simulator_postcard_special_question_reply(inbound, metadata: metadata)
          return reply if reply.present?
        end

        if simulator_postcard_special_quantity_followup?(inbound, metadata)
          reply = simulator_postcard_special_quantity_reply(stage, inbound)
          return reply if reply.present?
        end

        stack_reply = simulator_open_customer_stack_reply(stage, inbound, metadata: metadata)
        return stack_reply if stack_reply.present?

        if simulator_turnaround_question?(stage, inbound)
          reply = simulator_turnaround_reply(stage, inbound)
          return reply if reply.present?
        end

        if simulator_print_handoff_choice_question?(inbound, metadata)
          return simulator_print_handoff_choice_reply
        end

        if simulator_messy_print_consultant_question?(inbound)
          return simulator_messy_print_consultant_reply
        end

        if simulator_direct_mail_strategy_handoff_question?(inbound)
          return simulator_direct_mail_strategy_handoff_reply
        end

        if simulator_print_product_detail_question?(inbound, metadata) || simulator_multi_print_product_request?(inbound, metadata)
          return simulator_print_product_detail_reply
        end

        if simulator_standalone_print_product_quantity_followup?(inbound, metadata)
          reply = simulator_writer_reply(stage, :standalone_print_product_quantity_reply, inbound)
          return reply if reply.present?
          return simulator_standalone_print_product_quantity_reply(inbound, metadata)
        end

        if simulator_print_products_question?(inbound, metadata)
          reply = simulator_writer_reply(stage, :print_products_reply)
          return reply if reply.present?
          if simulator_print_product_confirmation_question?(inbound)
            return "WIZWIKI can help with business cards, door hangers, and flyers. If you have rough quantities, I can point you to the right path; if it gets custom, a marketing consultant can map it out."
          end
          return "WIZWIKI can help with practical print pieces like business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials. If it is custom, a marketing consultant can help map it out."
        end

        if simulator_postcard_minimum_path_question?(inbound, metadata: metadata)
          reply = simulator_writer_reply(stage, :postcard_minimum_path_reply)
          return reply if reply.present?
          return "The smallest real postcard path is standard EDDM at $399 for one mail-only route, usually about 500-700 homes. If you want 1,000+ postcards, the 4th of July Block Sale starts at 1,000 for $790. Are you staying around one EDDM route or looking at 1,000+?"
        end

        if simulator_postcard_special_checkout_request?(inbound, metadata)
          return simulator_postcard_special_checkout_reply(stage, inbound)
        end

        if simulator_price_before_handoff_question?(inbound)
          return simulator_price_before_handoff_reply(stage, inbound)
        end

        if simulator_yard_sign_included_items_question?(inbound, metadata: metadata, route: route)
          reply = simulator_writer_reply(stage, :yard_sign_included_items_reply, inbound)
          return reply if reply.present?
          return "Yes. For Yard Signs, design help, stakes, and shipping are included in the listed price. Different front/back designs add $125."
        end

        if yard_sign_artwork_help_question?(inbound, metadata: metadata, route: route)
          return yard_sign_artwork_help_reply(inbound)
        end
        if yard_sign_artwork_context_statement?(inbound, metadata: metadata, route: route)
          return yard_sign_artwork_help_reply(inbound)
        end

        if design_process_question?(inbound)
          if inbound.match?(/\b(?:proof|approve|approval|printing|print)\b/i) &&
              inbound.match?(/\b(?:logo|rough|screenshot|clean\s*up|cleaned\s*up|artwork)\b/i)
            return "Yes. You approve a proof before anything prints, and the team can use or clean up your rough logo through the intake form after checkout."
          end

          follow_up = design_process_follow_up_question(inbound, metadata: metadata, route: route)
          return [
            "You do not need finished artwork before ordering.",
            "Complete checkout first; after checkout, the design team sends an intake form to the checkout email for your logo, images, wording, colors, and notes.",
            "WIZWIKI can use or clean up what you have, or help create it with the AI postcard/art builder and in-house designers.",
            "Nothing prints until you approve the proof.",
            follow_up
          ].compact.join(" ")
        end

        if simulator_support_handoff_confirmation_request?(inbound, metadata)
          return simulator_support_handoff_reply(inbound, metadata: metadata)
        end

        if simulator_yard_sign_cheapest_question?(inbound, metadata: metadata, route: route)
          return "The cheapest total Yard Signs option is 10 signs for $99. The best per-sign price improves with volume, but that 10-sign package is the real entry point. Stakes, shipping, and design are included. Want me to send the 10-sign checkout link?"
        end

        if simulator_unit_pricing_question?(inbound)
          reply = simulator_writer_reply(stage, :unit_pricing_reply, inbound)
          return reply if reply.present?
          return "The listed Yard Signs minimum is 10 signs for $99, which works out to $9.90 per sign. There is not a one-sign checkout; 10 signs is the real entry point."
        end

        if eddm_neighborhood_blitz_question?(inbound)
          return "EDDM is the mail-only postcard route: $399 for one route, usually about 500-700 homes. Neighborhood Blitz is the fuller local visibility push with postcards plus extra field pieces; the listed package is $699. If you want mailboxes only, EDDM is cleaner. If you want mail plus visibility, Neighborhood Blitz is stronger."
        end

        if simulator_neighborhood_blitz_checkout_request?(inbound, metadata)
          reply = simulator_writer_reply(stage, :direct_checkout_link_reply, inbound)
          return reply if reply.present? && reply.match?(/\bNeighborhood Blitz\b/i)
          return "Here is the Neighborhood Blitz checkout link: https://shop.example.invalid/products/main-course-bundle-eddm-postcards-1-deluxe-a-frames-500-rack-cards-sample_owner After checkout, the intake/proof form goes to the checkout email and nothing prints until approval."
        end

        if starter_pro_compare_question?(inbound)
          return bundle_price_fallback_reply(inbound, metadata: metadata)
        end

        if standard_lane_compare_question?(inbound)
          return standard_lane_compare_reply
        end

        if simulator_postcard_special_quantity_followup?(inbound, metadata)
          reply = simulator_postcard_special_quantity_reply(stage, inbound)
          return reply if reply.present?
        end

        if simulator_postcard_below_minimum_quantity_followup?(inbound, metadata)
          reply = simulator_postcard_below_minimum_quantity_reply(inbound)
          return reply if reply.present?
        end

        if mixed_postcards_signs_cards_question?(inbound)
          return mixed_postcards_signs_cards_reply
        end

        if simulator_contact_context_question?(stage, inbound)
          reply = simulator_contact_context_reply(stage, inbound)
          return reply if reply.present?
        end

        if simulator_current_specials_question?(stage, inbound)
          reply = simulator_current_specials_reply(stage, inbound)
          return reply if reply.present?
        end

        if checkout_confusion_question?(inbound)
          return checkout_confusion_reply(route)
        end

        if full_options_pricing_question?(inbound)
          reply = standard_options_pricing_fallback(stage: stage)
          return reply if reply.present?
        end

        if direct_price_question?(inbound)
          reply = writer_pricing_fallback(stage, inbound)
          reply = standard_options_pricing_fallback(stage: stage) if reply.blank? && route.present?
          return reply if reply.present?
        end

        if generic_pricing_question?(inbound)
          reply = writer_pricing_fallback(stage, inbound)
          reply = standard_options_pricing_fallback(stage: stage) if reply.blank?
          return reply if reply.present?
        end

        if signs_only_bundle_compare_question?(inbound) || signs_only_pricing_question?(inbound)
          reply = writer_pricing_fallback(stage, inbound)
          return reply if reply.present?
          return signs_only_bundle_compare_fallback if signs_only_bundle_compare_question?(inbound)
          return yard_sign_price_options_fallback
        end

        if company_identity_after_yard_sign_quantity?(inbound, metadata: metadata)
          quantity = recent_yard_sign_quantity(metadata)
          return yard_sign_company_ack_reply(inbound, quantity) if quantity.positive?
        end

        if yard_sign_budget_question?(inbound, metadata: metadata, route: route)
          budget = explicit_budget_value(inbound) || 100
          label = budget == budget.to_i ? "$#{budget.to_i}" : "$#{format('%.2f', budget)}"
          return "#{label} gets you about 10 yard signs. The Yard Signs package is the best fit at that entry point, and the sign deal includes stakes, shipping, and design. Do you want to keep this signs-only?"
        end

        if listed_yard_sign_quantity_request?(inbound, route: route)
          return yard_sign_quantity_fallback_reply(inbound)
        end

        if neighborhood_blitz_best_deal_request?(inbound)
          return "For postcards plus yard signs, the Neighborhood Blitz package is the best-fit combined path at $699. It is built for a local push with postcards plus field visibility pieces like signs, door hangers, rack cards, or job-area materials. Do you want the combined blitz, or signs-only?"
        end

        if eddm_neighborhood_blitz_question?(inbound)
          return "EDDM is the mail-only piece: postcards go to selected homes by USPS route. Neighborhood Blitz is the fuller local push with postcards plus field visibility pieces like signs, door hangers, rack cards, or job-area materials; the listed package is $699. If you want mailboxes only, EDDM is cleaner. If you want mail plus visibility, Neighborhood Blitz is stronger."
        end

        if signs_only_bundle_fit_question?(inbound)
          return signs_only_bundle_fit_reply(inbound)
        end

        if large_volume_request?(inbound)
          return "That count is outside the package options priced cleanly by text. The standard safe paths are Starter Pack, Pro Pack, and listed Yard Signs package options. Larger-volume specials need a custom check so pricing stays accurate. Do you want the closest listed path or custom pricing help?"
        end

        if neighborhood_blitz_contents_question?(inbound)
          return "Yes. Neighborhood Blitz is the broader combined push, not the signs-only path. It can include postcards plus field visibility pieces like the Yard Signs package, door hangers, rack cards, or job-area materials. If you only want signs, Yard Signs is the signs-only path; if you want the broader push, Neighborhood Blitz fits better."
        end

        if bundle_price_question?(inbound)
          return bundle_price_fallback_reply(inbound, metadata: metadata)
        end

        if inbound.match?(/\b(?:postcards?|eddm|direct mail|mailers?)\b/i)
          return "EDDM postcards can work well for route-based neighborhood reach. About how many homes do you want to reach?"
        end

        if simulator_yard_sign_route_context_message?(inbound, metadata: metadata, route: route)
          return yard_sign_route_context_reply(inbound)
        end

        if route.to_s == "LAWN_SIGNS" && simulator_standalone_quantity_answer?(inbound)
          return yard_sign_quantity_fallback_reply(inbound)
        end

        if inbound.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i) || route.to_s == "LAWN_SIGNS"
          return "Yard signs make sense. About how many signs do you want to start with?"
        end

        "Postcards, yard signs, bundles, and artwork are all fair game. Which one are you leaning toward first?"
      end

      def default_simulator_customer_recovery(inbound_event, metadata: {})
        inbound = inbound_event.to_h["body"].to_s.squish
        route = simulator_route_code(metadata)

        return yard_sign_artwork_help_reply(inbound) if yard_sign_artwork_help_question?(inbound, metadata: metadata, route: route)

        if inbound.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?|mailboxes?)\b/i) || simulator_recent_postcard_context?(metadata)
          return "I can help with postcards. Standard EDDM starts at $399, and the 4th of July postcard block sale starts at 1,000 for $790. About how many homes do you want to reach?"
        end

        if route.to_s == "LAWN_SIGNS" || recent_thread_mentions_yard_signs?(metadata)
          return "I can help with yard signs. Signs-only options are 10 for $99, 20 for $159, 50 for $249, and 100 for $399. Stakes, shipping, and design are included. Were you thinking closer to 20, 50, or 100?"
        end

        "I can help with that. We can price postcards, yard signs, EDDM, or a bundle, and I will keep the answer tied to the option you are asking about. Which one should I narrow down first?"
      end

      def yard_sign_artwork_help_question?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?

        sign_context = route.to_s == "LAWN_SIGNS" ||
          recent_thread_mentions_yard_signs?(metadata) ||
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
        art_context = body.match?(/\b(?:artwork|art work|finished art|design|logo|creative|file|files|image|images|proof)\b/)
        help_context = body.match?(/\b(?:do not have|don't have|dont have|no|need|needs|help|without|unfinished|not finished|make|create|build|send|upload)\b/)

        sign_context && art_context && help_context
      end

      def yard_sign_artwork_context_statement?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?

        sign_context = route.to_s == "LAWN_SIGNS" ||
          recent_thread_mentions_yard_signs?(metadata) ||
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
        art_context = body.match?(/\b(?:rough|screenshot|artwork|art work|logo|image|images|file|files|design)\b/)
        possession_context = body.match?(/\b(?:i\s+have|i've got|ive got|we\s+have|we've got|weve got|my|our|rough|screenshot|not ready|unfinished|messy)\b/)

        sign_context && art_context && possession_context
      end

      def yard_sign_artwork_help_reply(inbound = nil)
        body = inbound.to_s.downcase.squish

        if body.match?(/\b(?:proof|approve|approval|print|prints|printing|nothing)\b/)
          return "Yes. You review and approve the proof before anything prints. After checkout, the intake form collects your logo, wording, colors, and notes; then the team builds the proof and you can request changes if needed."
        end

        if body.match?(/\b(?:buy|pay|checkout|order)\b/) && body.match?(/\b(?:before|first|after|upload|notes?|artwork|logo|design)\b/)
          return "You do not need finished artwork before you buy. Checkout starts the order/design queue; after that, the intake form goes to the checkout email so you can upload the logo, wording, colors, and notes before the proof is made."
        end

        "A messy logo is workable. Design help is included with the Yard Signs package, so after checkout the intake form collects your logo, colors, wording, and notes, then nothing prints until you approve the proof."
      end

      def simulator_yard_sign_route_context_message?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless route.to_s == "LAWN_SIGNS" || metadata.to_h["route_code"].to_s == "LAWN_SIGNS"
        return false if body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mailboxes?|homes?)\b/)
        return false if full_options_pricing_question?(body) || standard_lane_compare_question?(body)
        return false if direct_price_question?(body) || simulator_unit_pricing_question?(body)
        return false if yard_sign_checkout_link_request?(body, metadata: metadata, route: route)

        body.match?(/\b(?:business|company|crew|shop|job|jobs|missed|busy|sorry|plumbing|roofing|hvac|landscap|tree|pest|service)\b/)
      end

      def yard_sign_route_context_reply(inbound = nil)
        business = inbound.to_s.match(/\b(plumbing|roofing|hvac|landscap(?:ing)?|tree service|pest control)\b/i)&.[](1).to_s.downcase
        opener = business.present? ? "For a #{business} business, yard signs around active jobs are a clean starting point." : "Yard signs are a clean starting point for local visibility."
        "No worries. #{opener} If you want the lowest entry point, Yard Signs start at 10 for $99. What quantity feels closest?"
      end

      def simulator_standalone_quantity_answer?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+|approximately\s+)?\$?\s*[\d,]{1,6}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)?\z/i)
      end

      def simulator_route_code(metadata)
        data = metadata.to_h
        data["route_code"].presence ||
          data["product_interest_code"].presence ||
          data.dig("conversation_state", "route_code").presence ||
          data.dig("campaign_fit", "route_code").presence
      end

      def simulator_contact_context_question?(stage, inbound)
        return false if stage.blank?

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(:contact_context_question?, inbound)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] contact context check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_contact_context_reply(stage, inbound)
        return if stage.blank?

        writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
        return unless writer.send(:contact_context_question?, inbound)

        writer.send(:contact_context_reply).to_s.squish.presence
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] contact context fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def simulator_current_specials_question?(stage, inbound)
        return false if stage.blank?

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(:current_specials_question?, inbound)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] specials question check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_current_specials_reply(stage, inbound)
        return if stage.blank?

        if simulator_postcard_special_question?(inbound, stage.reload.metadata.to_h)
          reply = simulator_postcard_special_question_reply(inbound, metadata: stage.reload.metadata.to_h)
          return reply if reply.present?
        end

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(:current_specials_reply, inbound)
          .to_s
          .squish
          .presence
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] specials fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def simulator_postcard_special_question?(inbound, metadata = {})
        body = inbound.to_s.downcase.squish
        return false if body.blank?
        return true if simulator_postcard_special_price_sheet_request?(body, metadata)
        return false unless body.match?(/\b(?:specials?|promo|promos|discounts?|coupon|coupons|deal|deals|4th\s+of\s+july|july\s*4|block\s+sale)\b/)
        return true if body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mailing|mailboxes?|homes?)\b/)
        return true if body.match?(/\b(?:4th\s+of\s+july|july\s*4|block\s+sale)\b/)

        simulator_recent_postcard_context?(metadata)
      end

      def simulator_postcard_special_price_sheet_request?(inbound, metadata = {})
        body = inbound.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:full|complete|entire|all|every|list|show|send|give|price\s*sheet|pricing\s*sheet|price\s*table|price\s*list|tiers?)\b/)
        return false unless body.match?(/\b(?:price|pricing|sheet|table|list|tiers?|options?)\b/)

        simulator_recent_postcard_special_context?(metadata) || simulator_recent_postcard_context?(metadata)
      end

      def simulator_postcard_special_question_reply(inbound, metadata: {})
        body = inbound.to_s.downcase.squish
        return if body.blank?

        signs_only = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) &&
          !body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mailing|mailboxes?|homes?)\b/) &&
          !simulator_recent_postcard_context?(metadata)
        if signs_only
          return "The 4th of July special is postcard-only, not yard signs. Yard signs use the listed yard-sign pricing; if you want postcards too, the special starts at 1,000 postcards for $790."
        end

        price_sheet = simulator_postcard_special_price_sheet_request?(body, metadata)
        quantity = simulator_postcard_special_quantity_from_text(body)
        if quantity.present? && !price_sheet && !body.match?(/\b(?:all|every|full|complete|entire|sheet|table|list|tiers?)\b/)
          label = quantity.to_i.to_fs(:delimited)
          return "Yes. For #{label} postcards, the 4th of July postcard Block Sale is #{simulator_postcard_special_price_for_quantity(quantity)}. Want me to send that checkout link?"
        end

        "Yes. The 4th of July postcard special is postcard-only: 1,000 for $790, 2,500 for $1,725, 5,000 for $3,250, 10,000 for $6,300, and 25,000 for $14,750. Are you looking at 1,000+ postcards?"
      end

      def simulator_turnaround_question?(stage, inbound)
        return true if simulator_turnaround_text?(inbound)
        return false if stage.blank?

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(:turnaround_question?, inbound)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] turnaround question check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_turnaround_text?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:turnaround|turn around|timeline|how long|how soon|when would|when will|need them by|need it by|asap|rush|rushed|expedite|faster|fast|in a hurry|hurry|hurray|next\s+friday|deadline|normal shopify checkout|normal checkout|standard checkout|regular checkout|production time|shipping time|delivery time)\b/)
      end

      def simulator_turnaround_reply(stage, inbound)
        if stage.blank?
          body = inbound.to_s.downcase.squish
          if body.match?(/\b(?:normal|standard|regular)\b.{0,40}\b(?:checkout|shopify)\b|\bcheckout\b.{0,80}\brush|\brush\b.{0,80}\bcheckout\b/)
            return "For a rush yard-sign order, the normal Shopify checkout is not the right path. Rush needs a marketing consultant to confirm availability and pricing first; rush starts after proof approval, moves production ahead in the queue, and shipping is still usually 2-5 business days."
          end
          if body.match?(/\b(?:yes|yep|yeah|ok|okay|please|connect|marketing consultant|someone)\b/)
            return "Got it. I will get this in front of a marketing consultant for rush availability and pricing. Rush starts after proof approval, mainly moves print production ahead in the queue, and shipping is still usually 2-5 business days."
          end
          return "For yard signs, rush needs to be handled outside the standard checkout so a marketing consultant can confirm availability and pricing for the quantity and timeline. Rush starts after proof approval, mainly moves print production ahead in the queue, and shipping is still usually 2-5 business days. Want me to get someone connected with you?"
        end

        DealReports::CommsDraftWriter
          .new(stage: stage.reload, user: stage.user)
          .send(:turnaround_reply, inbound)
          .to_s
          .squish
          .presence
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] turnaround fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def simulator_postcard_special_checkout_request?(inbound, metadata)
        body = inbound.to_s.downcase.squish
        return false if body.blank?
        return false if simulator_postcard_minimum_path_question?(body, metadata: metadata)
        return false unless body.match?(/\b(?:send|text|share|give me|need|want|checkout|link|order|buy|purchase|yes)\b/)
        return false unless body.match?(/\b(?:post\s*cards?|postcards?|postcard\s+block\s+sale|block\s+sale|postcard\s+special|4th\s+of\s+july|july\s*4)\b/) ||
          (body.match?(/\b(?:1,?000|1000|1k|2,?500|2500|2\.5k|5,?000|5000|5k|10,?000|10000|10k|25,?000|25000|25k)\b/) && simulator_recent_postcard_context?(metadata))

        body.match?(/\b(?:checkout|link|order|buy|purchase|send|text|share|give me)\b/)
      end

      def simulator_postcard_special_checkout_reply(stage, inbound)
        quantity = simulator_postcard_special_quantity_from_text(inbound) || 1_000
        price = simulator_postcard_special_price_for_quantity(quantity)
        label = quantity.to_i.to_fs(:delimited)
        "Yes. For #{label} postcards, the 4th of July postcard Block Sale is #{price}. Use this checkout link when you are ready: https://shop.example.invalid/products/postcard-block-sale-0704"
      end

      def simulator_postcard_special_quantity_from_text(text)
        body = text.to_s.downcase
        [[25_000, /\b(?:25,?000|25000|25k)\b/], [10_000, /\b(?:10,?000|10000|10k)\b/], [5_000, /\b(?:5,?000|5000|5k)\b/], [2_500, /\b(?:2,?500|2500|2\.5k)\b/], [1_000, /\b(?:1,?000|1000|1k)\b/]]
          .find { |_quantity, pattern| body.match?(pattern) }&.first
      end

      def simulator_postcard_special_price_for_quantity(quantity)
        case quantity.to_i
        when 25_000 then "$14,750"
        when 10_000 then "$6,300"
        when 5_000 then "$3,250"
        when 2_500 then "$1,725"
        else "$790"
        end
      end

      def simulator_postcard_special_quantity_followup?(inbound, metadata)
        body = inbound.to_s.downcase.squish
        return false if body.blank?
        return false if simulator_postcard_special_checkout_request?(inbound, metadata)
        return false if body.match?(/\$\s*1,?000\b/)
        return false if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/) && !body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?)\b/)
        return false unless body.match?(/\b(?:1,?000|1000|1k|2,?500|2500|2\.5k|5,?000|5000|5k|10,?000|10000|10k|25,?000|25000|25k)\b/)
        return false unless body.match?(/\b(?:or more|\+|more|what about|how about|price|pricing|cost|total|expect|link|checkout|order|send|mail|mailing|homes?|households?|mailboxes?|nearby|reach|post\s*cards?|postcards?)\b/)

        body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?)\b/) || simulator_recent_postcard_context?(metadata)
      end

      def simulator_recent_postcard_context?(metadata)
        latest_postcard = nil
        latest_sign = nil
        Array(metadata.to_h["sms_thread"]).map(&:to_h).each_with_index do |event, index|
          body = [event["body"], event["english_body"], event["original_body"]].compact.join(" ").downcase.squish
          next if body.blank?

          postcard = body.match?(/\b(?:post\s*cards?|postcards?|eddm|mailers?|direct mail|mail-only|mailing route)\b/)
          signs = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?)\b/)
          latest_postcard = index if postcard && (!signs || body.match?(/\beddm\b/))
          latest_sign = index if signs && !postcard
        end

        latest_postcard.present? && (latest_sign.blank? || latest_postcard > latest_sign)
      end

      def simulator_postcard_special_quantity_reply(stage, inbound)
        quantity = simulator_postcard_special_quantity_from_text(inbound)
        if quantity.present?
          label = quantity.to_i.to_fs(:delimited)
          return "Yes. For #{label} postcards, the 4th of July postcard Block Sale is #{simulator_postcard_special_price_for_quantity(quantity)}. Want me to send that checkout link?"
        end

        if stage.present? && defined?(DealReports::CommsDraftWriter)
          writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
          reply = writer.send(:postcard_special_quantity_followup_reply, inbound).to_s.squish.presence
          return reply if reply.present?
          reply = writer.send(:current_specials_reply, inbound).to_s.squish.presence
          return reply if reply.present? && !reply.match?(/\bmissing pricing|custom check|account manager\b/i)
        end

        "For mailing around 1,000 homes, the 4th of July postcard Block Sale is 1,000 postcards for $790. That is the closest postcard special tier; want me to send that checkout link?"
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] postcard special quantity fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        "For mailing around 1,000 homes, the 4th of July postcard Block Sale is 1,000 postcards for $790. That is the closest postcard special tier; want me to send that checkout link?"
      end

      def simulator_postcard_below_minimum_quantity_followup?(inbound, metadata)
        quantity = simulator_bare_postcard_quantity(inbound)
        return false unless quantity.present? && quantity < 1_000
        return false unless simulator_recent_postcard_context?(metadata)

        simulator_recent_postcard_special_context?(metadata)
      end

      def simulator_bare_postcard_quantity(text)
        body = text.to_s.downcase.squish
        return if body.blank?

        match = body.match(/\A(?:maybe\s+|about\s+|around\s+|roughly\s+)?([\d,]{1,6})\s*(?:homes?|households?|mailboxes?|doors?|post\s*cards?|postcards?)?\z/i)
        return if match.blank?

        match[1].to_s.delete(",").to_i
      end

      def simulator_recent_postcard_special_context?(metadata)
        Array(metadata.to_h["sms_thread"]).map(&:to_h).last(8).any? do |event|
          [event["body"], event["english_body"], event["original_body"]].compact.join(" ").match?(/\b(?:4th\s+of\s+july|july\s*4|july\s+special|postcard\s+special|postcard\s+block\s+sale|1,?000\s+postcards?\s+for\s+\$?790|1,?000\s+postcards?\b.{0,80}\$\s?790|\$\s?790\b.{0,80}\b1,?000\s+postcards?|1k\s+postcards?)\b/i)
        end
      end

      def simulator_postcard_below_minimum_quantity_reply(inbound)
        quantity = simulator_bare_postcard_quantity(inbound)
        count = quantity.present? ? "#{quantity.to_fs(:delimited)} homes" : "that count"

        "For #{count}, I would not use the 4th of July block sale. The standard postcard path starts at $399; EDDM route mail usually reaches about 500-700 homes. Want the $399 postcard link?"
      end

      def mixed_postcards_signs_cards_question?(inbound)
        body = inbound.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:post\s*cards?|postcards?|mailers?|eddm|direct mail)\b/)
        return false unless body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
        return false unless body.match?(/\b(?:business\s+cards?|cards?)\b/)

        body.match?(/\b(?:mixture|mix|combo|combined?|combination|both|also|and|with|do you do|have)\b/)
      end

      def mixed_postcards_signs_cards_reply
        "Yes. For postcards plus signs, Neighborhood Blitz is the combined local-visibility path. Business cards are in the fixed packs: Starter Pack is $299 with 20 yard signs, 500 business cards, and 500 door hangers; Pro Pack is $599 with 100 signs, 1,000 cards, and 1,000 door hangers. Are you wanting mail plus signs, or the cards bundle?"
      end

      def standard_lane_compare_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:compare|comparing|deciding|looking at|looking between|not sure)\b/)

        lanes = [
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/),
          body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?)\b/),
          body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle|business\s+cards?|door\s+hangers?)\b/)
        ]
        lanes.count(true) >= 2
      end

      def standard_lane_compare_reply
        "Those are different lanes. Yard Signs is the lowest entry point at 10 for $99, EDDM postcards start at $399 for one mail-only route, and Starter Pack is $299 with 20 signs, 500 business cards, and 500 door hangers. If you want everything side by side, I can list the full menu."
      end

      def standard_options_pricing_fallback(stage: nil)
        if stage.present?
          reply = DealReports::CommsDraftWriter
            .new(stage: stage.reload, user: stage.user)
            .send(:standard_options_pricing_reply)
            .to_s
            .squish
          return reply if full_options_pricing_answer?(reply)
        end

        "Here are the standard options I can price: Starter Pack: $299 for 20 yard signs, 500 business cards, and 500 door hangers. Pro Pack: $599 for 100 signs, 1,000 cards, and 1,000 door hangers. Yard Signs package: 10 for $99, 20 for $159, 50 for $249, 100 for $399, 250 for $899, 500 for $1,699, and 1,000 for $3,349. Neighborhood Blitz: $699. EDDM: $399. Lowest total is Yard Signs at 10 for $99."
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] standard pricing fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        "Here are the standard options I can price: Starter Pack $299, Pro Pack $599, Yard Signs 10 for $99, 20 for $159, 50 for $249, 100 for $399, 250 for $899, 500 for $1,699, 1,000 for $3,349, Neighborhood Blitz $699, and EDDM $399. Lowest total is Yard Signs at 10 for $99."
      end

      def writer_pricing_fallback(stage, inbound)
        return if stage.blank?

        writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
        priority = writer.send(:must_answer_reply_for, inbound).to_s.squish.presence
        return priority if priority.present?

        writer.send(:pricing_reply, inbound).to_s.squish.presence
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] writer pricing fallback failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def signs_only_bundle_compare_fallback
        "#{yard_sign_price_options_fallback} Bundle options add cards and door hangers: Starter Pack is $299 for 20 yard signs, 500 business cards, and 500 door hangers. Pro Pack is $599 for 100 signs, 1,000 business cards, and 1,000 door hangers. Which option feels closer?"
      end

      def yard_sign_price_options_fallback
        "Signs-only Yard Signs are 10 for $99, 20 for $159, 50 for $249, 100 for $399, 250 for $899, 500 for $1,699, and 1,000 for $3,349. Stakes, shipping, and design are included."
      end

      def design_process_follow_up_question(inbound, metadata: {}, route: nil)
        return nil if process_answer_should_stand_alone?(inbound)

        body = [
          inbound.to_s,
          Array(metadata.to_h["sms_thread"]).last(6).map { |event| event.to_h["body"].to_s }
        ].flatten.join(" ").downcase

        return "What quantity should I price for the signs?" if route.to_s == "LAWN_SIGNS" || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
        return "About how many homes do you want to reach?" if body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?|neighborhood)\b/)
        return "Are you trying to drive calls, visits, event traffic, or general local awareness?" if body.match?(/\b(?:both|combo|combined|bundle|blitz|postcards?.*signs?|signs?.*postcards?)\b/)

        "What are you trying to promote first?"
      end

      def process_answer_should_stand_alone?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:where|how|when|why|what)\b.{0,80}\b(?:upload|send|receive|get|proof|logo|artwork|image|images|file|files|checkout|pay|payment|email)\b/) ||
          body.match?(/\b(?:upload|proof|checkout email|after checkout|pay before|payment before|pay first|order first|before print|before printing|nothing prints)\b/) ||
          body.match?(/\b(?:do|does|will|can|could)\b.{0,80}\b(?:send|email|upload|approve|proof|logo|artwork|file|files)\b/)
      end

      def simulator_resets_known_lane?(stage, body, inbound_event)
        text = body.to_s.downcase.squish
        return false if text.blank?

        generic_product_reset = text.match?(/\b(?:postcards?, yard signs?, bundles?, or artwork|postcards?, yard signs?, or both|which one are you leaning toward|which product|what are you looking for|looking at postcards?)\b/)
        return false unless generic_product_reset

        metadata = stage.metadata.to_h
        company_identity_after_yard_sign_quantity?(inbound_event.to_h["body"], metadata: metadata) ||
          recent_thread_mentions_yard_signs?(metadata)
      end

      def company_identity_after_yard_sign_quantity?(text, metadata:)
        inbound = text.to_s.squish
        return false if inbound.blank? || inbound.length > 90
        return false if inbound.match?(/[?]/)
        return false if inbound.match?(/\b(?:yard\s+signs?|lawn\s+signs?|post\s*cards?|postcards?|bundle|price|cost|how much|checkout|link|proof|design|artwork|yes|no|maybe|both)\b/i)
        return false unless recent_yard_sign_quantity(metadata).positive?

        previous_outbound_asked_company?(metadata)
      end

      def previous_outbound_asked_company?(metadata)
        Array(metadata.to_h["sms_thread"]).reverse_each.first(6).any? do |event|
          body = event.to_h["body"].to_s.downcase.squish
          event.to_h["direction"].to_s == "outbound" &&
            body.match?(/\b(?:what company|company should i connect|company name|business name|save this conversation|connect this to)\b/)
        end
      end

      def recent_thread_mentions_yard_signs?(metadata)
        Array(metadata.to_h["sms_thread"]).last(8).any? do |event|
          event.to_h["body"].to_s.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/i)
        end
      end

      def recent_yard_sign_quantity(metadata)
        return 0 unless recent_thread_mentions_yard_signs?(metadata)

        Array(metadata.to_h["sms_thread"]).reverse_each.first(8).filter_map do |event|
          next unless event.to_h["direction"].to_s == "inbound"

          body = event.to_h["body"].to_s
          next if body.match?(/[?@]/)

          body.scan(/\b\d{1,6}\b/).map { |value| value.delete(",").to_i }.max
        end.compact.max.to_i
      end

      def yard_sign_company_ack_reply(company_name, quantity)
        table = {
          10 => "$99",
          20 => "$159",
          50 => "$249",
          100 => "$399",
          250 => "$899",
          500 => "$1,699",
          1000 => "$3,349"
        }
        company = company_name.to_s.squish
        prefix = company.present? ? "Got #{company}." : "Got it."

        if table[quantity].present?
          return "#{prefix} The #{quantity}-sign Yard Signs package is #{table[quantity]} double-sided, with stakes, shipping, and design included. What first name should I put on this thread?"
        end

        lower = table.keys.select { |candidate| candidate < quantity }.max
        higher = table.keys.select { |candidate| candidate > quantity }.min
        closest = [lower, higher].compact.map { |candidate| "#{format_quantity(candidate)} at #{table[candidate]}" }.to_sentence
        "#{prefix} I do not see an exact #{quantity}-sign package option listed. Closest Yard Signs package options are #{closest}. What first name should I put on this thread?"
      end

      def format_quantity(value)
        value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      end

      def yard_sign_quantity_fallback_reply(inbound)
        quantity = inbound.to_s.gsub(/[^\d]/, "").to_i
        return "Yard signs make sense. About how many signs do you want to start with?" if quantity <= 0

        table = {
          10 => "$99",
          20 => "$159",
          50 => "$249",
          100 => "$399",
          250 => "$899",
          500 => "$1,699",
          1000 => "$3,349"
        }

        if table[quantity].present?
          "#{quantity} Yard Signs are #{table[quantity]} double-sided. Stakes, shipping, and design are included. Want me to send the Yard Signs checkout link?"
        else
          lower = table.keys.select { |candidate| candidate < quantity }.max
          higher = table.keys.select { |candidate| candidate > quantity }.min
          closest = [lower, higher].compact.map { |candidate| "#{candidate} at #{table[candidate]}" }.to_sentence
          "I do not see an exact #{quantity}-sign package option listed. Closest Yard Signs package options are #{closest}. Stakes, shipping, and design are included. Want the closest checkout link?"
        end
      end

      def bundle_price_fallback_reply(inbound, metadata: {})
        question = bundle_price_followup_variant(inbound, metadata: metadata)
        [
          bundle_price_starter_sentence(inbound, metadata: metadata),
          bundle_price_pro_sentence(inbound, metadata: metadata),
          "Both include design, double-sided UV printing/coating, stakes, and shipping.",
          question
        ].compact_blank.join(" ")
      end

      def bundle_price_starter_sentence(inbound, metadata: {})
        bundle_sentence_variant(
          inbound,
          metadata: metadata,
          label: "Starter Pack",
          price: "$299",
          included: "20 yard signs, 500 business cards, and 500 door hangers",
          offset: 0
        )
      end

      def bundle_price_pro_sentence(inbound, metadata: {})
        bundle_sentence_variant(
          inbound,
          metadata: metadata,
          label: "Pro Pack",
          price: "$599",
          included: "100 signs, 1,000 business cards, and 1,000 door hangers",
          offset: 3
        )
      end

      def bundle_sentence_variant(inbound, metadata:, label:, price:, included:, offset:)
        variants = [
          "#{label} is #{price} for #{included}.",
          "#{label} runs #{price} and includes #{included}.",
          "#{price} gets you #{included} in #{label}.",
          "With #{label}, #{price} covers #{included}."
        ]
        seed = Digest::SHA1.hexdigest([inbound, metadata.to_h["sms_autopilot_sent_count"], offset, Time.current.to_i / 90].join(":")).to_i(16)
        variants[seed % variants.length]
      end

      def bundle_price_followup_variant(inbound, metadata: {})
        variants = [
          "Are you leaning toward the smaller starter run or the bigger pro run?",
          "Would the 20-sign starter run cover it, or do you need the 100-sign pro push?",
          "Which bundle feels closer to what you want to launch with?",
          "Do you want to keep it lean with Starter, or go heavier with Pro?"
        ]
        seed = Digest::SHA1.hexdigest([inbound, metadata.to_h["sms_autopilot_sent_count"], Time.current.to_i / 90].join(":")).to_i(16)
        variants[seed % variants.length]
      end

      def large_volume_request?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        quantity = numeric_quantity_candidates(body, pattern: /\b\d{3,6}\b/).max.to_i
        return false if listed_yard_sign_quantity_request?(body)

        quantity >= 300 && body.match?(/\b(?:signs?|cards?|door\s*hangers?|pieces?|prints?)\b/)
      end

      def listed_yard_sign_quantity_request?(text, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless route.to_s == "LAWN_SIGNS" || body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)

        quantity = numeric_quantity_candidates(body, pattern: /\b\d{1,6}\b/).max.to_i
        [10, 20, 50, 100, 250, 500, 1000].include?(quantity)
      end

      def numeric_quantity_candidates(body, pattern:)
        body.to_s.scan(pattern).map { |value| value.to_s.delete(",").to_i }
          .select(&:positive?)
          .reject { |quantity| zip_code_quantity_token?(body, quantity) }
      end

      def zip_code_quantity_token?(body, quantity)
        token = quantity.to_i.to_s
        return false unless token.match?(/\A\d{5}\z/)

        escaped = Regexp.escape(token)
        return true if body.match?(/\b(?:zip|zipcode|zip\s+code|postal|area|market|location)\b.{0,24}\b#{escaped}\b/)
        return true if body.match?(/\b(?:in|near|around|serving|located\s+in|service\s+area)\s+#{escaped}\b/)

        explicit_budget_value(body).present? && !body.match?(/\b#{escaped}\s*(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?|post\s*cards?|postcards?|mailers?|cards?|business\s+cards?|door\s+hangers?|pieces?|prints?)\b/)
      end

      def checkout_confusion_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if body.match?(/\bwhat\s+exactly\s+am\s+i\s+buying\b/)
        return false unless body.match?(/\b(?:checkout|links?|order|buying|purchase|cart|product\s+page)\b/)

        body.match?(/\b(?:confused|confusing|understand|not\s+sure|what\s+exactly|what\s+am\s+i\s+buying|what\s+is\s+this|what\s+does\s+this\s+include|why\s+this\s+link)\b/)
      end

      def eddm_neighborhood_blitz_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:same|different|difference|versus|vs\.?|compare|like|better|best|recommend|which|should i|right fit)\b/)
        return false unless body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b/)

        body.match?(/\b(?:eddm|post\s*cards?|postcards?|mail|mailer|mailing|route|carrier route)\b/)
      end

      def eddm_neighborhood_blitz_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\beddm\b/) &&
          body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b/) &&
          body.match?(/\b(?:mail-only|mail only|postcards?|mailboxes?|usps|route)\b/) &&
          body.match?(/\b(?:fuller|broader|local push|visibility|signs?|door hangers?|rack cards?)\b/)
      end

      def signs_only_bundle_fit_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:only|just)\s+(?:need|want)\s+(?:yard\s+)?signs?\b/) ||
          body.match?(/\bonly\b.{0,40}\b(?:care|need|want|looking)\b.{0,25}\b(?:yard\s+|lawn\s+)?signs?\b/) ||
          body.match?(/\b(?:yard\s+)?signs?\s+only\b|\bsigns[-\s]?only\b/)
      end

      def signs_only_bundle_fit_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\byard\s+signs?\s+package\b|\bsigns[-\s]?only\b|\bsigns only\b/) &&
          body.match?(/\b(?:starter\s*pack|pro\s*pack|bundle)\b/) &&
          body.match?(/\bbusiness\s+cards?\b/) &&
          body.match?(/\bdoor\s+hangers?\b/)
      end

      def signs_only_bundle_fit_reply(inbound)
        body = inbound.to_s.downcase
        if body.match?(/\bpro\s*pack\b/)
          "If you only need yard signs, the Yard Signs package is the cleaner signs-only path. Pro Pack is $599 for 100 signs plus 1,000 business cards and 1,000 door hangers, so it is better only if you want those extra pieces too. Do you want signs-only or the full bundle?"
        elsif body.match?(/\bstarter\s*pack\b/)
          "If you only need yard signs, the Yard Signs package is the cleaner signs-only path. Starter Pack is $299 for 20 signs plus 500 business cards and 500 door hangers, so it makes sense only if you want those pieces too. Do you want signs-only or the bundle?"
        else
          "If you only need yard signs, use the Yard Signs package. Starter Pack and Pro Pack are bundles that add business cards and door hangers, so they fit better when you want those extra pieces too. Do you want signs-only or the bundle?"
        end
      end

      def accepted_recommendation_link_request?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if rush_checkout_boundary_text?(body)
        return false if simulator_yard_sign_cheapest_question?(body)
        return false if simulator_unit_pricing_question?(body)
        pivot_tail = latest_pivot_tail(body)
        if pivot_tail.present?
          if pivot_tail.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?)\b/) &&
              pivot_tail.match?(/\b(?:what(?:'s| is)|how much|price|pricing|special|deal|cost)\b/) &&
              !pivot_tail.match?(/\b(?:send|text|share|give me|yes)\b.{0,80}\b(?:postcard|postcards|block sale|special|eddm)\b.{0,80}\b(?:link|checkout|order)\b/)
            return false
          end

          if pivot_tail.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?)\b/) &&
              body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,80}\b(?:checkout|link|order)|\b(?:checkout|link|order)\b.{0,80}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
            return false unless pivot_tail.match?(/\b(?:send|text|share|give me|yes)\b.{0,80}\b(?:postcard|postcards|block sale|special|eddm)\b.{0,80}\b(?:link|checkout|order)\b/)
          end
        end
        if body.match?(/\b(?:actually|nevermind|never mind|scratch that|ignore that|forget that|instead|rather|prefer|switch|change)\b/) &&
            body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?)\b/) &&
            body.match?(/\b(?:what(?:'s| is)|how much|price|pricing|special|deal|cost)\b/) &&
            !body.match?(/\b(?:send|text|share|give me)\b.{0,80}\b(?:postcard|postcards|block sale|special|eddm)\b.{0,80}\b(?:link|checkout|order)\b/)
          return false
        end
        if body.match?(/\b(?:actually|nevermind|never mind|scratch that|ignore that|forget that|instead|rather|prefer|switch|change)\b/) &&
            body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|homes?)\b/) &&
            body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,80}\b(?:checkout|link|order)|\b(?:checkout|link|order)\b.{0,80}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
          return false unless body.match?(/\b(?:send|text|share|give me)\b.{0,80}\b(?:postcard|postcards|block sale|special|eddm)\b.{0,80}\b(?:link|checkout|order)\b/)
        end

        accepted = body.match?(/\b(?:sounds good|that works|that should work|looks good|perfect|great|ok|okay|cool|i'?ll do that|i will do that|go ahead|proceed)\b/)
        link_request = body.match?(/\b(?:send|text|share|give me|where is)\b.{0,60}\b(?:links?|checkout|order|buy|purchase)\b/) ||
          body.match?(/\b(?:checkout|order|buy|purchase)\s+links?\b/) ||
          body.match?(/\blinks?\s+(?:for me|to order|to buy|to checkout|to check out)\b/)
        package_context = body.match?(/\b(?:neighborhood blitz|starter pack|pro pack|yard signs?|lawn signs?|eddm|bundle|package|deal|checkout)\b/)

        (accepted && (link_request || package_context)) || link_request
      end

      def latest_pivot_tail(text)
        body = text.to_s.downcase.squish
        return if body.blank?

        matches = body.to_enum(:scan, /\b(?:actually|nevermind|never mind|scratch that|ignore that|forget that|instead|rather|prefer|switch|change)\b/).map { Regexp.last_match }
        match = matches.last
        return if match.blank?

        body[match.begin(0)..].to_s.squish.presence
      end

      def yard_sign_checkout_link_request?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if rush_checkout_boundary_text?(body)
        return false if simulator_yard_sign_cheapest_question?(body, metadata: metadata, route: route)
        return false if simulator_unit_pricing_question?(body)
        return false if body.match?(/\b(?:blitz|neighbou?rhood|eddm|post\s*cards?|postcards?|direct mail|mailers?)\b/) && !body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/)
        selected_option_request = body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:10|20|50|100|250|500|1,?000)\b.{0,35}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,35}\b(?:option|package|checkout)\b/) ||
          body.match?(/\b(?:send|text|share|give me)\b.{0,60}\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b.{0,35}\b(?:10|20|50|100|250|500|1,?000)\b.{0,35}\b(?:option|package|checkout)\b/)
        return false unless selected_option_request || accepted_recommendation_link_request?(body) || body.match?(/\b(?:send|text|share|give me|checkout|order|buy)\b.{0,40}\blink\b|\blink\b.{0,40}\b(?:send|text|share|checkout|order|buy)\b/i)

        route.to_s == "LAWN_SIGNS" ||
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs?)\b/i) ||
          recent_thread_mentions_yard_signs?(metadata)
      end

      def yard_sign_checkout_link_reply(metadata = {})
        link = yard_sign_checkout_url(metadata)
        "Absolutely. Choose the quantity on the Yard Signs page; after checkout we collect the artwork details and send a proof before printing: #{link}"
      end

      def rush_checkout_boundary_text?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        checkout_context = body.match?(/\bcheckout\b|\bcheck\s+out\b/)
        rush_context = body.match?(/\b(?:rush|rushed|asap|expedite|faster|fast|in a hurry|hurry|hurray|next\s+friday|need (?:them|it) by|deadline)\b/)
        boundary_context = body.match?(/\b(?:normal|standard|regular)\b.{0,30}\b(?:checkout|check\s+out)\b/) ||
          body.match?(/\b(?:checkout|check\s+out)\b.{0,80}\b(?:rush|rushed|asap|expedite|normal|standard|regular)\b/) ||
          body.match?(/\b(?:rush|rushed|asap|expedite)\b.{0,80}\b(?:checkout|check\s+out)\b/) ||
          body.match?(/\b(?:shouldn'?t|should\s+not|don'?t|do\s+not|avoid|instead)\b.{0,80}\b(?:checkout|check\s+out)\b/)

        checkout_context && rush_context && boundary_context
      end

      def yard_sign_checkout_url(metadata = {})
        configured = metadata.to_h["shopify_link"].to_s.squish
        return configured if configured.present? && configured.match?(/\byard|sign|sample_owner/i)

        "https://shop.example.invalid/products/24x18-yard-signs-sample_owner"
      end

      def checkout_confusion_reply(route = nil)
        route_label = route.to_s.presence&.tr("_", " ")&.titleize
        package_sentence = route_label.present? ? "It is for the #{route_label} checkout path we have been discussing." : "It is for the WIZWIKI checkout option we have been discussing."
        [
          "That checkout link is not meant to be mysterious.",
          package_sentence,
          "It should show the package, quantity, and price before you pay.",
          "After checkout, WIZWIKI sends the artwork/proof intake to the checkout email, and nothing prints until you approve the proof.",
          "If the link does not match what you want, send me the package name you see."
        ].join(" ")
      end

      def checkout_confusion_answer?(answer)
        body = answer.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:checkout|link|order)\b/) &&
          body.match?(/\b(?:package|option|deal|quantity|price|what you are buying|shows?)\b/) &&
          body.match?(/\b(?:proof|intake|approve|approval|nothing prints|does not match|doesn't match|package name)\b/)
      end

      def design_process_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:proof|artwork|logo|design|creative|file|upload|pay before|payment before|checkout before|ai art|ai builder|art builder|postcard generator)\b/) &&
          body.match?(/\b(?:how|why|where|when|can|could|do|does|will|would|need|help|make|create|send)\b/)
      end

      def ai_art_builder_question?(text)
        body = text.to_s.downcase.squish
        body.match?(/\b(?:ai\s+art|ai\s+builder|art\s+builder|postcard\s+generator|ai\s+postcard)\b/)
      end

      def neighborhood_blitz_contents_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false unless body.match?(/\b(?:neighborhood|neighbourhood)\s+blitz\b|\bblitz\b|\bmain course\b/)

        body.match?(/\b(?:get|include|come with|comes with|have|with)\b.*\b(?:yard signs?|lawn signs?|signs?|other products?|door hangers?|cards?|postcards?)\b/) ||
          body.match?(/\b(?:yard signs?|lawn signs?|signs?|other products?|door hangers?|cards?|postcards?)\b.*\b(?:included|come with|comes with|part of|with it|in it)\b/)
      end

      def neighborhood_blitz_best_deal_request?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if standard_lane_compare_question?(body)

        postcards = body.match?(/\b(?:post\s*cards?|postcards?|eddm|direct mail|mailers?|mailing|homes?)\b/)
        signs = body.match?(/\b(?:yard\s+signs?|yard\s+sign|lawn\s+signs?|lawn\s+sign|jobsite\s+signs?|jobsite\s+sign|directional\s+signs?|directional\s+sign|signs?)\b/)
        combined = body.match?(/\b(?:both|combo|combined|together|plus|and)\b/)
        return false unless postcards && signs && combined

        body.match?(/\b(?:best|right|good|better|recommend|deal|package|bundle|option|fit|targeting|reach|mail|homes?|doors?|neighborhoods?)\b/)
      end

      def bundle_price_question?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if signs_only_pricing_question?(body)
        return false unless bundle_family_interest?(body)

        body.match?(/\b(how\s+(?:much|mush)|cost|costs|price|pricing|total|rate|rates|charge|charges|quote|quotes)\b/)
      end

      def signs_only_intent?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?

        body.match?(/\b(?:signs?\s*[- ]?only|only\s+(?:yard\s+|lawn\s+)?signs?|yard\s+signs?\s*[- ]?only|lawn\s+signs?\s*[- ]?only)\b/) ||
          body.match?(/\bonly\b.{0,40}\b(?:care|need|want|looking)\b.{0,25}\b(?:yard\s+|lawn\s+)?signs?\b/) ||
          body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/) && body.match?(/\bonly\b/)
      end

      def signs_only_pricing_question?(text)
        body = text.to_s.downcase.squish
        return false unless signs_only_intent?(body)
        return false if signs_only_bundle_compare_question?(body)

        body.match?(/\b(?:how\s+(?:much|mush)|cost|costs|price|prices|pricing|total|rate|rates|quote|quotes|options?|tiers?|packages?)\b/)
      end

      def signs_only_bundle_compare_question?(text)
        body = text.to_s.downcase.squish
        return false unless signs_only_intent?(body)

        body.match?(/\b(?:combo|bundle|bundles|pack|packs|starter\s*pack|pro\s*pack|both|compare|comparison|vs\.?|versus|or)\b/)
      end

      def yard_sign_budget_question?(text, metadata: {}, route: nil)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return false if explicit_budget_value(body).blank?
        return true if body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signs?)\b/)
        return true if route.to_s == "LAWN_SIGNS"

        recent = Array(metadata.to_h["sms_thread"]).last(8).filter_map { |event| event.to_h["body"].to_s.squish.presence }.join(" ").downcase
        recent.match?(/\b(?:yard\s+signs?|lawn\s+signs?|signs in the ground|yard signs package)\b/)
      end

      def explicit_budget_value(text)
        body = text.to_s.downcase.squish
        return nil if body.blank?
        return 100 if body.match?(/\b(?:a\s+|one\s+)?hundred\s+(?:dollars?|dolla(?:rs?)?|bucks?)\b/)

        if (match = body.match(/\$\s*([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?/i))
          return explicit_budget_match_value(match)
        end
        if (match = body.match(/\b([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?\s*(?:dollars?|dolla(?:rs?)?|bucks?)\b/i))
          return explicit_budget_match_value(match)
        end
        if (match = body.match(/\b(?:budget|spend|around|under|up to|about|for|with)\s+\$?\s*([\d,]+(?:\.\d+)?)(?:\s*([km])\b)?/i))
          return explicit_budget_match_value(match) unless body[match.end(0), 48].to_s.match?(/\A\s*(?:yard\s+signs?|lawn\s+signs?|signs?|post\s*cards?|postcards?|cards?|door\s+hangers?|hangers?|homes?|houses?|households?|doors?|addresses?|mailboxes?|pieces?|units?)\b/i)
        end
        nil
      end

      def explicit_budget_match_value(match)
        base = match[1].to_s.delete(",").to_f
        return nil unless base.positive?

        suffix = match[2].to_s.downcase
        base *= 1_000 if suffix == "k"
        base *= 1_000_000 if suffix == "m"
        base == base.round ? base.round : base
      end

      def bundle_family_interest?(text)
        body = text.to_s.downcase.squish
        return false if body.blank?
        return true if body.match?(/\b(starter\s*pack|pro\s*pack|starter[-\s]?pack|pro[-\s]?pack|bundle|bundles)\b/)

        wants_signs = body.match?(/\b(?:yard\s+signs?|lawn\s+signs?|jobsite\s+signs?|directional\s+signs?|signage|stakes?|signs?)\b/)
        wants_cards = body.match?(/\b(?:business\s+cards?|cards?)\b/)
        wants_hangers = body.match?(/\b(?:door\s+hangers?|hangers?)\b/)
        wants_signs && (wants_cards || wants_hangers) || (wants_cards && wants_hangers)
      end

      def clear_rejected_background_reply!(stage, draft, question_id)
        metadata = stage.metadata.to_h.deep_dup
        rejected = draft.merge("autos_question_id" => question_id)
        return if queue_simulator_guardrail_retry!(stage.reload, rejected)
        return if materialize_simulator_no_ghost_fallback!(stage.reload, rejected)

        stage.update!(
          generated_at: Time.current,
          metadata: metadata.merge(
            "ask_autopilot_last_result" => simulator_result_payload(rejected),
            "ask_autopilot_last_autos_question_id" => question_id,
            "ask_autopilot_last_result_at" => Time.current.iso8601,
            "sms_autopilot_last_error" => rejected["error"].presence || "ask_simulator_quality_gate_rejected",
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_status" => "rejected_quality_gate",
            "comms_command_background_at" => Time.current.iso8601,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
      end

      def ensure_latest_inbound_has_reply_or_retry!(stage)
        metadata = stage.metadata.to_h.deep_dup
        return false if pending_background_draft?(metadata)
        return false unless latest_inbound_waiting_for_materialized_reply?(metadata)
        return false unless simulator_no_reply_failure?(metadata)

        rejected = metadata["ask_autopilot_last_result"].to_h
        rejected["autos_question_id"] ||= metadata["comms_command_background_question_id"].presence ||
          metadata["ask_autopilot_last_autos_question_id"].presence

        queue_simulator_guardrail_retry!(stage.reload, rejected) ||
          materialize_simulator_no_ghost_fallback!(stage.reload, rejected)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] no-ghost recovery failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_no_reply_failure?(metadata)
        return true if terminal_background_question_for_metadata?(metadata)

        status = metadata.to_h["comms_command_background_status"].to_s
        return true if status.in?(%w[rejected_quality_gate rejected_sms_quality_gate no_body failed stale_inbound_rescan])

        result = metadata.to_h["ask_autopilot_last_result"].to_h
        result["body"].to_s.squish.blank? &&
          (
            result["error"].present? ||
            result["reason"].to_s.match?(/\brejected|failed|no body|empty|stale\b/i) ||
            result["sms_quality_gate"].to_s == "rejected" ||
            ActiveModel::Type::Boolean.new.cast(result["ask_quality_gate"])
          )
      end

      def queue_simulator_guardrail_retry!(stage, rejected)
        return false unless defined?(DealReports::CommsDraftWriter)

        metadata = stage.metadata.to_h.deep_dup
        inbound = latest_inbound_event(metadata)
        return false if inbound.blank?
        return false unless latest_inbound_waiting_for_materialized_reply?(metadata)
        pending_same_rejected_question = rejected.to_h["autos_question_id"].present? &&
          metadata["comms_command_background_question_id"].to_s == rejected.to_h["autos_question_id"].to_s
        return false if pending_background_draft?(metadata) && !pending_same_rejected_question

        retry_key = simulator_guardrail_retry_key(stage, inbound)
        effective_retry_count = simulator_effective_guardrail_retry_count(stage, inbound, rejected, retry_key: retry_key)
        return false if immediate_simulator_no_ghost_fallback?(stage, inbound, effective_retry_count)
        return false if effective_retry_count >= simulator_guardrail_retry_limit

        next_count = effective_retry_count + 1
        instruction = simulator_guardrail_retry_instruction(inbound, rejected, next_count)
        writer = DealReports::CommsDraftWriter.new(
          stage: stage.reload,
          user: stage.user,
          operator_prompt: Comms::SmsOperatorPrompt.inbound_reply(body: inbound.to_h["body"]),
          writer_model: metadata["sms_writer_model"],
          guardrail_retry_instruction: instruction
        )
        question = writer.send(
          :enqueue_background_draft_question,
          extra_metadata: {
            "guardrail_retry" => true,
            "guardrail_retry_count" => next_count,
            "guardrail_retry_reason" => simulator_guardrail_retry_reason(rejected),
            "guardrail_retry_instruction" => instruction,
            "simulator_no_ghost_retry" => true,
            "rejected_autos_question_id" => rejected.to_h["autos_question_id"]
          }.compact_blank
        )
        question.reload
        return false if terminal_background_question?(question)

        pending = writer.send(:pending_draft_for, question)
        now = Time.current.iso8601
        latest = stage.reload.metadata.to_h.deep_dup
        stage.update!(
          generated_at: Time.current,
          metadata: latest.merge(
            "ask_autopilot_last_result" => simulator_result_payload(
              pending.merge(
                "reason" => "#{pending['reason']} Retrying after simulator guardrail rejection.",
                "error" => simulator_guardrail_retry_reason(rejected)
              )
            ),
            "ask_autopilot_last_autos_question_id" => question.id,
            "ask_autopilot_last_result_at" => now,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => pending.merge(
              "created_at" => now,
              "simulator_no_ghost_retry" => true,
              "guardrail_retry_count" => next_count,
              "guardrail_retry_reason" => simulator_guardrail_retry_reason(rejected),
              "rejected_autos_question_id" => rejected.to_h["autos_question_id"]
            ).compact_blank,
            "comms_command_background_question_id" => question.id,
            "comms_command_background_status" => "queued",
            "comms_command_background_error" => "Retrying after simulator rejection: #{simulator_guardrail_retry_reason(rejected)}",
            "comms_command_background_at" => now,
            "comms_command_background_running_at" => nil,
            "comms_command_last_status" => "drafting",
            "comms_command_last_at" => now,
            "sms_reply_job_status" => "draft_pending",
            "sms_reply_job_queued_at" => now,
            "ask_autopilot_pending_started_at" => now,
            "ask_autopilot_pending_phase" => "drafting_message",
            "sms_autopilot_last_error" => "Retrying after simulator rejection: #{simulator_guardrail_retry_reason(rejected)}",
            "sms_guardrail_retry_instruction" => instruction,
            "ask_autopilot_sim_retry_key" => retry_key,
            "ask_autopilot_sim_retry_count" => next_count,
            "ask_autopilot_sim_retry_reason" => simulator_guardrail_retry_reason(rejected),
            "ask_autopilot_sim_retry_previous_question_id" => rejected.to_h["autos_question_id"],
            "ask_autopilot_sim_retry_at" => now
          ).compact_blank
        )
        Rails.logger.info("[AskAutopilotTest] queued no-ghost retry stage=#{stage.id} question=#{question.id} count=#{next_count}")
        true
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed queueing no-ghost retry stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_rejected_question_retry_count(rejected)
        question_id = rejected.to_h["autos_question_id"].presence || rejected.to_h["rejected_autos_question_id"].presence
        return 0 if question_id.blank?

        AutosQuestion.find_by(id: question_id)&.metadata.to_h["guardrail_retry_count"].to_i
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] rejected retry count lookup failed question=#{question_id} #{error.class}: #{error.message}")
        0
      end

      def immediate_simulator_no_ghost_fallback?(stage, inbound, retry_count)
        return false if retry_count < 3

        body = inbound.to_h["body"].to_s.squish
        return false if body.blank?

        simulator_turnaround_question?(stage, body) ||
        simulator_messy_print_consultant_question?(body) ||
          simulator_direct_mail_strategy_handoff_question?(body) ||
          simulator_direct_mail_interest_question?(body) ||
          simulator_print_products_question?(body) ||
          (design_process_question?(body) && !ai_art_builder_question?(body))
      end

      def materialize_simulator_no_ghost_fallback!(stage, rejected)
        metadata = stage.metadata.to_h.deep_dup
        inbound = latest_inbound_event(metadata)
        return false if inbound.blank?
        return false unless latest_inbound_waiting_for_materialized_reply?(metadata)

        fallback_body = local_simulator_fallback(inbound, metadata: metadata, stage: stage).to_s.squish.presence
        if fallback_body.blank? && defined?(DealReports::CommsDraftWriter)
          writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
          fallback_body = writer.send(:fallback_reply_to_inbound, inbound.to_h["body"]).to_s.squish.presence
        end
        return false if fallback_body.blank?

        draft = apply_simulator_quality_gate(
          stage.reload,
          rejected.to_h.merge(
            "body" => fallback_body,
            "provider" => "local/ask_sim_no_ghost",
            "model" => rejected.to_h["model"].presence || "deterministic_no_ghost_recovery",
            "writer_model" => rejected.to_h["writer_model"].presence || metadata["sms_writer_model"],
            "writer_model_label" => rejected.to_h["writer_model_label"].presence || metadata["sms_writer_model_label"],
            "draft_source" => "thumper_guardrail",
            "reason" => "Simulator no-ghost fallback materialized after retry budget or queue failure.",
            "sms_generation_pipeline" => "single_writer_guardrailed"
          ).compact_blank,
          inbound
        )
        body = safe_customer_sms_body(draft.to_h["body"]).to_s.squish
        if body.blank?
          body = safe_customer_sms_body(fallback_body).to_s.squish
          return false unless simulator_last_chance_customer_sms_body?(stage.reload, body, inbound)

          draft = rejected.to_h.merge(
            "body" => body,
            "provider" => "local/ask_sim_no_ghost",
            "model" => rejected.to_h["model"].presence || "deterministic_no_ghost_recovery",
            "writer_model" => rejected.to_h["writer_model"].presence || metadata["sms_writer_model"],
            "writer_model_label" => rejected.to_h["writer_model_label"].presence || metadata["sms_writer_model_label"],
            "draft_source" => "thumper_guardrail",
            "reason" => "Simulator no-ghost fallback used a verified customer-facing SMS after the retry limit.",
            "sms_generation_pipeline" => "single_writer_guardrailed",
            "sms_quality_gate" => "last_chance",
            "ask_quality_gate" => true,
            "ask_quality_gate_replaced_body" => true
          ).compact_blank
        end
        return false if body.blank?

        question_id = rejected.to_h["autos_question_id"]
        appended = append_stage_event!(
          stage.reload,
          event_payload(
            direction: "outbound",
            status: "sent",
            body: body,
            from: SIMULATED_WIZWIKI_NUMBER,
            to: inbound.to_h["from"].presence || stage.metadata.to_h.dig("phone_options", 0, "value").presence || simulated_customer_phone(stage.user),
            user: stage.user
          ).merge(
            "autopilot" => true,
            "ask_autopilot_test" => true,
            "autopilot_reply_to_sid" => inbound.to_h["provider_message_id"].presence || inbound.to_h["id"],
            "draft_provider" => draft["provider"],
            "draft_model" => draft["model"],
            "draft_source" => draft["draft_source"],
            "writer_model" => draft["writer_model"],
            "writer_model_label" => draft["writer_model_label"],
            "sms_generation_pipeline" => draft["sms_generation_pipeline"],
            "sms_quality_gate" => draft["sms_quality_gate"],
            "ask_quality_gate" => draft["ask_quality_gate"],
            "ask_quality_gate_replaced_body" => draft["ask_quality_gate_replaced_body"],
            "autos_question_id" => question_id,
            "simulator_no_ghost_fallback" => true
          ).merge(dojo_materialized_event_metadata(inbound)).compact_blank
        )
        return false if appended.blank?

        latest = stage.reload.metadata.to_h.deep_dup
        now = Time.current.iso8601
        stage.update!(
          generated_at: Time.current,
          metadata: latest.merge(
            "ask_autopilot_last_result" => simulator_result_payload(draft.merge("body" => body, "autos_question_id" => question_id)),
            "ask_autopilot_last_autos_question_id" => question_id,
            "ask_autopilot_last_result_at" => now,
            "sms_autopilot_sent_count" => latest["sms_autopilot_sent_count"].to_i + 1,
            "sms_autopilot_last_sent_at" => now,
            "sms_autopilot_last_error" => nil,
            "comms_command_sms_draft_body" => nil,
            "comms_command_sms_draft" => nil,
            "comms_command_background_status" => "simulated_sent_no_ghost_fallback",
            "comms_command_background_at" => now,
            "sms_reply_job_status" => "simulated_sent_no_ghost_fallback",
            "sms_reply_job_completed_at" => now,
            "ask_autopilot_pending_started_at" => nil,
            "ask_autopilot_pending_phase" => nil
          ).compact_blank
        )
        Rails.logger.info("[AskAutopilotTest] materialized no-ghost fallback stage=#{stage.id} question=#{question_id}")
        true
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] failed materializing no-ghost fallback stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_last_chance_customer_sms_body?(stage, body, inbound)
        return false unless defined?(DealReports::CommsDraftWriter)

        text = body.to_s.squish
        return false if text.blank? || text.length > DealReports::CommsDraftWriter::MAX_SMS_CHARS

        writer = DealReports::CommsDraftWriter.new(stage: stage.reload, user: stage.user)
        return false if writer.send(:analysis_leak?, text)
        return false if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)
        return true if simulator_customer_safe_direct_answer?(stage, text, inbound, writer: writer)

        writer.send(:acceptable_sms_body?, text, include_drafts: false)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] last-chance SMS safety check failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def simulator_guardrail_retry_limit
        ENV.fetch("ASK_AUTOPILOT_SIM_RETRY_LIMIT", SIMULATOR_REPLY_RETRY_LIMIT.to_s).to_i.clamp(0, 15)
      end

      def simulator_guardrail_retry_budget_spent?(stage, inbound)
        metadata = stage.metadata.to_h
        retry_key = simulator_guardrail_retry_key(stage, inbound)

        simulator_guardrail_retry_count(metadata, retry_key) >= simulator_guardrail_retry_limit
      end

      def simulator_guardrail_retry_key(stage, inbound)
        Digest::SHA1.hexdigest(
          [
            stage.id,
            inbound.to_h["provider_message_id"].presence || inbound.to_h["id"].presence,
            inbound.to_h["from"].to_s.squish,
            inbound.to_h["body"].to_s.squish,
            stage.metadata.to_h["sms_writer_model"].to_s
          ].join(":")
        )
      end

      def simulator_guardrail_retry_count(metadata, retry_key)
        return 0 unless metadata.to_h["ask_autopilot_sim_retry_key"].to_s == retry_key.to_s

        metadata.to_h["ask_autopilot_sim_retry_count"].to_i
      end

      def simulator_effective_guardrail_retry_count(stage, inbound, rejected, retry_key: nil)
        metadata = stage.metadata.to_h
        key = retry_key.presence || simulator_guardrail_retry_key(stage, inbound)

        [
          simulator_guardrail_retry_count(metadata, key),
          metadata["ask_autopilot_sim_retry_count"].to_i,
          rejected.to_h["guardrail_retry_count"].to_i,
          simulator_rejected_question_retry_count(rejected)
        ].max
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] effective retry count failed stage=#{stage&.id} #{error.class}: #{error.message}")
        0
      end

      def simulator_guardrail_retry_reason(rejected)
        [
          rejected.to_h["error"],
          rejected.to_h["reason"],
          rejected.to_h["sms_quality_gate"].presence && "sms_quality_gate=#{rejected.to_h['sms_quality_gate']}"
        ].compact_blank.join(" | ").presence || "simulator_no_visible_reply"
      end

      def simulator_guardrail_retry_instruction(inbound, rejected, retry_count)
        inbound_text = inbound.to_h["body"].to_s.squish
        rejected_text = rejected.to_h["ask_quality_gate_original_body"].presence || rejected.to_h["body"]
        rejected_text = rejected_text.to_s.squish.first(220)
        foreign_language_rejected_text = simulator_foreign_language_text?(rejected_text)
        rejected_text = nil if foreign_language_rejected_text
        issue = simulator_guardrail_retry_reason(rejected)
        unit_pricing = simulator_unit_pricing_question?(inbound_text) ?
          "The latest customer asks for per-unit pricing; include actual each/per-unit math plus the relevant total, not only a package total." :
          nil
        known_quantity = inbound_text.match?(/\A(?:maybe\s+|about\s+|around\s+)?[\d,]{1,6}\s*(?:homes?|households?|mailboxes?|doors?|postcards?|signs?)?\z/i) ?
          "If the latest customer message is a quantity or count, treat that quantity as already answered; do not ask for it again." :
          nil
        pricing_answer = inbound_text.match?(/\b(?:how\s+(?:much|many)|cost|costs|price|pricing|total|rate|quote|cheapest|specials?)\b/i) ?
          "If the customer asked price, specials, cheapest option, or a numeric fit question, include the relevant price from retrieved context before asking a follow-up." :
          nil

        [
          "This is ask-simulator no-ghost retry #{retry_count}; the prior draft did not create a visible customer reply because: #{issue}.",
          "Regenerate from scratch through the RAG/pricing context as exactly one customer-facing SMS body.",
          "Answer the latest customer message directly before discovery, links, or next-step language.",
          foreign_language_rejected_text ? "The prior rejected draft was already localized into the customer's preferred language. Do not repeat or imitate that language in this retry; write the internal draft in English and let the SMS language layer translate after the quality gate." : nil,
          known_quantity,
          pricing_answer,
          unit_pricing,
          "Do not include labels, JSON, analysis, internal notes, or wrapper phrases.",
          rejected_text.present? ? "Avoid repeating this rejected text: #{rejected_text}" : nil
        ].compact.join(" ")
      end

      def simulator_foreign_language_text?(text)
        body = text.to_s.squish
        return false if body.blank?
        return true if body.match?(/[\p{Han}\p{Arabic}\p{Cyrillic}\p{Hangul}]/)
        return false unless defined?(Comms::SmsLanguageSupport)

        Comms::SmsLanguageSupport::CUSTOMER_LANGUAGE_CODES.keys.any? do |code|
          code != "en" && Comms::SmsLanguageSupport.target_language_signal?(body, code)
        end
      rescue StandardError
        false
      end

      def simulator_quality_gate_retryable?(draft)
        data = draft.to_h
        return false unless ActiveModel::Type::Boolean.new.cast(data["ask_quality_gate"])

        return true if data["sms_quality_gate"].to_s == "rejected"

        data["body"].to_s.squish.blank?
      end

      def queue_simulator_quality_gate_retry!(stage, draft, inbound_event)
        rejected = draft.to_h.deep_dup
        original = rejected["ask_quality_gate_original_body"].to_s.squish.presence
        rejected["body"] = original if original.present?
        rejected["error"] = [
          rejected["error"],
          "ask_simulator_quality_gate_#{rejected['sms_quality_gate'].presence || 'rewritten'}"
        ].compact_blank.join(" | ")
        rejected["reason"] = [
          rejected["reason"],
          "The simulator quality gate changed or rejected the Qwen draft; retrying with RAG feedback before deterministic fallback."
        ].compact_blank.join(" ")
        rejected["autos_question_id"] ||= draft.to_h["autos_question_id"]

        reloaded_stage = stage.reload
        effective_retry_count = simulator_effective_guardrail_retry_count(reloaded_stage, inbound_event, rejected)
        if immediate_simulator_no_ghost_fallback?(reloaded_stage, inbound_event, effective_retry_count) ||
            effective_retry_count >= simulator_guardrail_retry_limit
          return true if materialize_simulator_no_ghost_fallback!(reloaded_stage, rejected)
        end

        return true if queue_simulator_guardrail_retry!(stage.reload, rejected)

        reloaded_stage = stage.reload
        effective_retry_count = simulator_effective_guardrail_retry_count(reloaded_stage, inbound_event, rejected)
        return materialize_simulator_no_ghost_fallback!(reloaded_stage, rejected) if immediate_simulator_no_ghost_fallback?(reloaded_stage, inbound_event, effective_retry_count)
        return materialize_simulator_no_ghost_fallback!(reloaded_stage, rejected) if effective_retry_count >= simulator_guardrail_retry_limit

        false
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] quality-gate retry queue failed stage=#{stage&.id} #{error.class}: #{error.message}")
        false
      end

      def normalize_body(value)
        value.to_s.downcase.gsub(/\s+/, " ").gsub(/[[:punct:]]+\z/, "").strip
      end

      def pending_background_draft?(metadata)
        if metadata["comms_command_sms_draft_body"].present?
          return latest_inbound_waiting_for_materialized_reply?(metadata)
        end

        return false if terminal_background_question_for_metadata?(metadata)
        return true if active_recursive_dojo_pending?(metadata)

        metadata["comms_command_background_status"].to_s.in?(%w[queued running pending claimed])
      end

      def active_recursive_dojo_pending?(metadata)
        return false unless metadata.to_h["recursive_dojo_status"].to_s.in?(%w[queued running])

        last_activity = recursive_dojo_last_activity_at(metadata)
        last_activity.blank? || last_activity > recursive_dojo_stale_after
      end

      def recoverable_background_draft?(metadata)
        last_result = metadata["ask_autopilot_last_result"].to_h
        pending_result = ActiveModel::Type::Boolean.new.cast(last_result["pending"]) ||
          last_result["draft_source"].to_s == "pending" ||
          ActiveModel::Type::Boolean.new.cast(last_result["background_queued"])
        return true if terminal_background_question_for_metadata?(metadata)

        pending_background_draft?(metadata) ||
          pending_result ||
          metadata["comms_command_background_status"].to_s.in?(%w[queued running pending claimed applied])
      end

      def terminal_background_question_for_metadata?(metadata)
        question_id = metadata.to_h["comms_command_background_question_id"].presence ||
          metadata.to_h.dig("ask_autopilot_last_result", "autos_question_id").presence
        return false if question_id.blank?

        terminal_background_question?(AutosQuestion.find_by(id: question_id))
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] terminal background question check failed question=#{question_id} #{error.class}: #{error.message}")
        false
      end

      def terminal_background_question?(question)
        return false if question.blank?
        return false if question.answer.to_s.squish.present?

        question.status.to_s.in?(%w[canceled cancelled failed ignored])
      end

      def latest_inbound_waiting_for_materialized_reply?(metadata)
        events = Array(metadata["sms_thread"]).map(&:to_h)
        latest_inbound_index = events.rindex do |event|
          event["channel"].to_s == "sms" &&
            event["direction"].to_s == "inbound" &&
            event["body"].to_s.squish.present? &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
        return false if latest_inbound_index.blank?

        later_events = events[(latest_inbound_index + 1)..] || []
        later_events.none? do |event|
          event["channel"].to_s == "sms" &&
            event["direction"].to_s == "outbound" &&
            !event["status"].to_s.in?(%w[failed canceled])
        end
      end

      def pending_started_at(stage, metadata)
        metadata["ask_autopilot_pending_started_at"].presence ||
          metadata["comms_command_background_at"].presence ||
          metadata["ask_autopilot_last_result_at"].presence ||
          latest_simulated_inbound_at(metadata) ||
          stage.updated_at&.iso8601
      end

      def pending_phase(metadata)
        phase = metadata["ask_autopilot_pending_phase"].to_s
        return phase if phase.present?
        if metadata["recursive_dojo_status"].to_s.in?(%w[queued running])
          return metadata["recursive_dojo_current_kind"].to_s == "conversation" ? "recursive_dojo_conversation_drafting" : "recursive_dojo_drafting"
        end

        case metadata["comms_command_background_status"].to_s
        when "running", "claimed"
          "drafting_message"
        when "queued", "pending"
          "gathering_thoughts"
        else
          "thinking"
        end
      end

      def pending_label(metadata)
        case pending_phase(metadata)
        when "recursive_dojo_resume"
          "Resuming dojo"
        when "recursive_dojo"
          "Building dojo prompts"
        when "recursive_dojo_drafting"
          "Drafting and grading"
        when "recursive_dojo_conversation"
          "Dojo conversation"
        when "recursive_dojo_conversation_drafting"
          "Dojo turn drafting"
        when "recursive_dojo_embedding"
          "Embedding dojo lessons"
        when "gathering_thoughts"
          "Gathering thoughts"
        when "drafting_message"
          "Drafting message"
        else
          "Thumper thinking"
        end
      end

      def pending_details(metadata)
        draft = metadata.to_h["comms_command_sms_draft"].to_h
        last_result = metadata.to_h["ask_autopilot_last_result"].to_h
        question = pending_autos_question(metadata, draft, last_result)
        retry_count = pending_retry_count(metadata, draft)
        retry_limit = simulator_guardrail_retry_limit
        attempt = retry_count + 1
        status = metadata.to_h["sms_reply_job_status"].presence ||
          metadata.to_h["comms_command_background_status"].presence ||
          "pending"
        background_status = metadata.to_h["comms_command_background_status"].presence
        gate = [
          last_result["sms_quality_gate"].presence || draft["sms_quality_gate"].presence,
          ActiveModel::Type::Boolean.new.cast(last_result["ask_quality_gate"]) || ActiveModel::Type::Boolean.new.cast(draft["ask_quality_gate"]) ? "ask gate" : nil
        ].compact.join(" / ").presence
        source = [
          last_result["provider"].presence || draft["provider"].presence,
          last_result["model"].presence || draft["model"].presence || metadata.to_h["sms_writer_model"].presence
        ].compact_blank.join(" // ").presence

        timeline = pending_timeline(metadata)
        notes = pending_notes(metadata, draft, last_result, question)
        rag_trace = pending_rag_trace(question)
        dojo_progress = pending_dojo_progress(metadata)
        score = dojo_scoreboard(metadata)
        summary = if dojo_progress.present?
          pending_dojo_summary(dojo_progress)
        elsif retry_count.positive?
          "Guardrail retry: fresh guidance is drafting now."
        elsif question&.status.to_s.in?(%w[answered completed])
          "Worker answered; SMS safety gate is checking the body."
        elsif status.to_s.in?(%w[queued draft_pending pending])
          "Draft job is queued for the local SMS writer."
        elsif status.to_s.in?(%w[running claimed])
          "Local writer is building the next customer-facing text."
        else
          "Simulator is waiting for a sendable SMS body."
        end

        {
          "summary" => summary,
          "cycle" => {
            "attempt" => attempt,
            "retry_count" => retry_count,
            "retry_limit" => retry_limit,
            "max_attempts" => retry_limit + 1
          },
          "dojo_scoreboard" => score,
          "dojo" => dojo_progress,
          "timeline" => timeline,
          "notes" => notes,
          "rag_trace" => rag_trace,
          "question" => question.present? ? {
            "id" => question.id,
            "status" => human_pending_value(question.status)
          } : nil,
          "signals" => pending_signal_rows(
            metadata,
            attempt: attempt,
            retry_count: retry_count,
            retry_limit: retry_limit,
            status: status,
            background_status: background_status,
            question: question,
            gate: gate,
            source: source,
            timeline: timeline,
            notes: notes,
            rag_trace: rag_trace,
            dojo_progress: dojo_progress,
            dojo_scoreboard: score
          )
        }.compact_blank
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] pending details failed #{error.class}: #{error.message}")
        {}
      end

      def dojo_scoreboard(metadata)
        data = metadata.to_h
        current_generation = data["recursive_dojo_generation"].to_s.presence
        events = dojo_grade_events(data)
        current = dojo_score_snapshot(events.select { |event| event["generation"].to_s == current_generation.to_s }, generation: current_generation)
        stored_previous = data["recursive_dojo_last_scoreboard"].to_h
        stored_previous = {} if current_generation.present? &&
          stored_previous["generation"].to_s == current_generation.first(8).to_s &&
          data["recursive_dojo_status"].to_s != "complete"

        previous_generation = events.reverse_each.find do |event|
          event["generation"].present? && event["generation"].to_s != current_generation.to_s
        end&.dig("generation")
        previous = stored_previous.presence ||
          dojo_score_snapshot(events.select { |event| event["generation"].to_s == previous_generation.to_s }, generation: previous_generation)

        display = if current.to_h["grade_count"].to_i.positive? && data["recursive_dojo_status"].to_s == "complete"
          current
        else
          previous.presence || current
        end

        {
          "current" => current,
          "last_completed" => previous,
          "display" => display,
          "status" => data["recursive_dojo_status"].presence,
          "current_generation" => current_generation&.first(8),
          "target" => ENV.fetch("ASK_RECURSIVE_DOJO_TARGET_AVERAGE", "96").to_f
        }.compact_blank
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] dojo scoreboard failed #{error.class}: #{error.message}")
        {}
      end

      def completed_dojo_scoreboard_snapshot(metadata, generation: nil, completed_at: nil)
        data = metadata.to_h
        completed_generation = generation.presence || data["recursive_dojo_generation"].to_s.presence
        events = dojo_grade_events(data)
        snapshot = dojo_score_snapshot(
          events.select { |event| completed_generation.blank? || event["generation"].to_s == completed_generation.to_s },
          generation: completed_generation
        )
        return {} if snapshot.blank?

        snapshot.merge(
          "completed_at" => completed_at.presence || data["recursive_dojo_completed_at"].presence,
          "source" => "recursive_dojo"
        ).compact_blank
      end

      def dojo_grade_events(metadata)
        ledger = dojo_scorecard_ledger_events(metadata)
        return ledger if ledger.present?

        summary = dojo_summary_scorecard_events(metadata)
        return summary if summary.present?

        Array(metadata.to_h["sms_thread"]).filter_map.with_index do |event, index|
          event = event.to_h
          next unless event["role"].to_s.in?(%w[dojo_grade dojo_conversation_grade])

          dojo_scorecard_from_event(event, index: index)
        end
      end

      def dojo_scorecard_ledger_events(metadata)
        Array(metadata.to_h["recursive_dojo_scorecards"]).filter_map.with_index do |scorecard, index|
          event = scorecard.to_h
          next if event["score"].blank?

          event.merge("index" => event["index"].presence || index)
        end
      end

      def dojo_summary_scorecard_events(metadata)
        Array(metadata.to_h["sms_thread"]).flat_map.with_index do |event, event_index|
          event = event.to_h
          next [] unless event["role"].to_s == "dojo_summary"

          Array(event["dojo_cycles"]).filter_map.with_index do |cycle, cycle_index|
            cycle = cycle.to_h
            score = cycle["score"]
            next if score.blank?

            trajectory = cycle["trajectory"].to_h
            {
              "index" => "#{event_index}.#{cycle_index}",
              "generation" => event["dojo_generation"].to_s.presence || trajectory["generation"].to_s.presence,
              "conversation_id" => cycle["conversation_id"].to_s.presence || trajectory["conversation_id"].to_s.presence,
              "cycle" => cycle["cycle"].presence,
              "score" => score.to_f,
              "verdict" => cycle["verdict"].to_s.presence,
              "title" => cycle["title"].to_s.presence || trajectory["title"].to_s.presence,
              "created_at" => trajectory["created_at"].presence || event["created_at"].presence
            }.compact_blank
          end
        end
      end

      def upsert_dojo_scorecard_ledger(metadata, payload)
        scorecard = dojo_scorecard_from_event(payload)
        return Array(metadata.to_h["recursive_dojo_scorecards"]).map(&:to_h).last(120) if scorecard.blank?

        scorecards = remove_dojo_scorecard_ledger_entry(
          metadata,
          generation: scorecard["generation"],
          conversation_id: scorecard["conversation_id"],
          cycle: scorecard["cycle"]
        )
        (scorecards + [scorecard]).last(120)
      end

      def remove_dojo_scorecard_ledger_entry(metadata, generation:, conversation_id:, cycle:)
        Array(metadata.to_h["recursive_dojo_scorecards"]).map(&:to_h).reject do |scorecard|
          scorecard["generation"].to_s == generation.to_s &&
            scorecard["conversation_id"].to_s == conversation_id.to_s &&
            scorecard["cycle"].to_i == cycle.to_i
        end.last(120)
      end

      def dojo_scorecard_from_event(event, index: nil)
        event = event.to_h
        grade = event["dojo_grade"].to_h
        score = grade["score"]
        return nil if score.blank?

        {
          "index" => index,
          "generation" => event["dojo_generation"].to_s.presence,
          "conversation_id" => event["dojo_conversation_id"].to_s.presence,
          "cycle" => event["dojo_cycle"].presence,
          "score" => score.to_f,
          "verdict" => grade["verdict"].to_s.presence,
          "title" => event["dojo_conversation_title"].presence || event["dojo_title"].presence,
          "created_at" => event["created_at"].presence || Time.current.iso8601
        }.compact_blank
      end

      def dojo_score_snapshot(events, generation:)
        items = Array(events)
        scores = items.filter_map { |event| event.to_h["score"]&.to_f }
        return {} if scores.blank?

        verdicts = items.map { |event| event.to_h["verdict"].to_s.upcase }
        {
          "generation" => generation.to_s.first(8).presence,
          "average" => (scores.sum / scores.length.to_f).round(1),
          "grade_count" => scores.length,
          "pass_count" => verdicts.count("PASS"),
          "review_count" => verdicts.count("REVIEW"),
          "latest_title" => items.last.to_h["title"].presence,
          "latest_score" => scores.last&.round(1)
        }.compact_blank
      end

      def pending_dojo_progress(metadata)
        status = metadata.to_h["recursive_dojo_status"].to_s
        phase = metadata.to_h["ask_autopilot_pending_phase"].to_s
        return unless status.in?(%w[queued running]) || phase.start_with?("recursive_dojo")

        cycle = metadata.to_h["recursive_dojo_current_cycle"].to_i
        total = metadata.to_h["recursive_dojo_total_cycles"].to_i
        turn = metadata.to_h["recursive_dojo_current_turn"].to_i
        total_turns = metadata.to_h["recursive_dojo_total_turns"].to_i
        {
          "status" => status.presence || "running",
          "phase" => phase.presence || "recursive_dojo",
          "cycle" => cycle.positive? ? cycle : nil,
          "total_cycles" => total.positive? ? total : nil,
          "kind" => metadata.to_h["recursive_dojo_current_kind"].presence,
          "title" => metadata.to_h["recursive_dojo_current_title"].presence,
          "turn" => turn.positive? ? turn : nil,
          "total_turns" => total_turns.positive? ? total_turns : nil,
          "generation" => metadata.to_h["recursive_dojo_generation"].to_s.first(8).presence
        }.compact_blank
      end

      def pending_dojo_summary(dojo_progress)
        cycle = dojo_progress.to_h["cycle"]
        total = dojo_progress.to_h["total_cycles"]
        title = dojo_progress.to_h["title"].presence
        if cycle.present? && total.present?
          ["Recursive Dojo scenario #{cycle}/#{total}", title].compact.join(": ")
        else
          ["Recursive Dojo", human_pending_value(dojo_progress.to_h["phase"])].compact.join(" // ")
        end
      end

      def no_answer_alert(stage, metadata)
        data = metadata.to_h
        return if pending_background_draft?(data)
        return unless latest_inbound_waiting_for_materialized_reply?(data)
        return unless simulator_no_reply_failure?(data)

        draft = data["comms_command_sms_draft"].to_h
        last_result = data["ask_autopilot_last_result"].to_h
        question = pending_autos_question(data, draft, last_result)
        retry_count = pending_retry_count(data, draft)
        latest_customer = latest_inbound_event(data).to_h["body"].to_s.squish
        status = data["comms_command_background_status"].presence ||
          data["sms_reply_job_status"].presence ||
          "no_answer"
        reason = [
          data["sms_autopilot_last_error"],
          last_result["error"],
          last_result["reason"],
          draft["error"],
          draft["reason"]
        ].compact_blank.join(" | ")
        original_body = last_result["ask_quality_gate_original_body"].presence ||
          draft["ask_quality_gate_original_body"].presence ||
          question&.answer.to_s.squish.presence

        {
          "severity" => "danger",
          "title" => "No visible SMS sent",
          "summary" => "Autopilot reached a no-answer state. The latest customer text still needs a visible customer-facing reply.",
          "chips" => [
            { "label" => "stage", "value" => "##{stage.id}" },
            (question.present? ? { "label" => "question", "value" => "##{question.id} #{human_pending_value(question.status)}" } : nil),
            { "label" => "status", "value" => human_pending_value(status) },
            { "label" => "retry", "value" => "#{retry_count} of #{simulator_guardrail_retry_limit}" }
          ].compact,
          "details" => [
            alert_pair("customer", latest_customer),
            alert_pair("gate", human_pending_note(reason)),
            alert_pair("blocked draft", original_body),
            alert_pair("next action", "Use the latest customer text and RAG trace to repair the thread or let the no-ghost fallback create a visible answer.")
          ].compact,
          "rag_trace" => pending_rag_trace(question, metadata: data)
        }.compact_blank
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] no-answer alert failed stage=#{stage&.id} #{error.class}: #{error.message}")
        nil
      end

      def pending_autos_question(metadata, draft, last_result)
        question_id = metadata.to_h["comms_command_background_question_id"].presence ||
          metadata.to_h["ask_autopilot_last_autos_question_id"].presence ||
          last_result.to_h["autos_question_id"].presence ||
          draft.to_h["autos_question_id"].presence
        return if question_id.blank?

        AutosQuestion.find_by(id: question_id)
      end

      def pending_retry_count(metadata, draft)
        [
          metadata.to_h["ask_autopilot_sim_retry_count"],
          metadata.to_h["sms_guardrail_retry_count"],
          draft.to_h["guardrail_retry_count"]
        ].map(&:to_i).max.to_i
      end

      def pending_notes(metadata, draft, last_result, question)
        raw_notes = [
          note_pair("retry", metadata.to_h["ask_autopilot_sim_retry_reason"].presence || draft.to_h["guardrail_retry_reason"].presence),
          note_pair("gate", last_result.to_h["error"].presence || draft.to_h["error"].presence),
          note_pair("reason", last_result.to_h["reason"].presence || draft.to_h["reason"].presence),
          note_pair("queue", metadata.to_h["comms_command_background_error"].presence || metadata.to_h["sms_autopilot_last_error"].presence),
          note_pair("worker", question&.metadata.to_h.dig("local_worker", "reject_reason").presence || question&.metadata.to_h.dig("local_worker", "status").presence),
          note_pair("guidance", metadata.to_h["sms_guardrail_retry_instruction"].presence || draft.to_h["guardrail_retry_instruction"].presence)
        ].compact

        raw_notes.uniq { |note| note.to_h["text"].to_s.downcase }.first(3)
      end

      def pending_signal_rows(metadata, attempt:, retry_count:, retry_limit:, status:, background_status:, question:, gate:, source:, timeline:, notes:, rag_trace:, dojo_progress: nil, dojo_scoreboard: nil)
        total_time = (timeline.find { |item| item.to_h["label"].to_s == "total" } || {}).to_h["value"]
        current_time = (timeline.find { |item| item.to_h["label"].to_s == "current" } || {}).to_h["value"]
        queued_time = (timeline.find { |item| item.to_h["label"].to_s == "queued" } || {}).to_h["value"]
        note_text = Array(notes).first.to_h["text"].presence
        rag_text = [
          rag_trace.to_h["route"].presence,
          rag_trace.to_h["fine_training"].presence,
          rag_trace.to_h["current_next_text_skipped"].present? ? "stale draft skipped" : nil
        ].compact_blank.join(" // ")
        job_text = [
          human_pending_value(status),
          background_status.present? && background_status != status ? "queue #{human_pending_value(background_status)}" : nil,
          question.present? ? "q##{question.id} #{human_pending_value(question.status)}" : nil
        ].compact_blank.join(" // ")
        gate_text = gate.present? ? human_pending_value(gate) : (note_text.presence || "waiting on customer-facing body")
        dojo_text = if dojo_progress.present?
          [
            dojo_progress.to_h["cycle"].present? && dojo_progress.to_h["total_cycles"].present? ? "scenario #{dojo_progress.to_h['cycle']}/#{dojo_progress.to_h['total_cycles']}" : nil,
            dojo_progress.to_h["turn"].present? && dojo_progress.to_h["total_turns"].present? ? "turn #{dojo_progress.to_h['turn']}/#{dojo_progress.to_h['total_turns']}" : nil,
            human_pending_value(dojo_progress.to_h["phase"]),
            dojo_progress.to_h["title"]
          ].compact_blank.join(" // ")
        end
        score_display = dojo_scoreboard.to_h["display"].to_h
        score_text = if score_display["average"].present?
          [
            "#{score_display['average']}/100",
            score_display["grade_count"].present? ? "#{score_display['grade_count']} graded" : nil,
            score_display["pass_count"].present? || score_display["review_count"].present? ? "#{score_display['pass_count'].to_i} pass / #{score_display['review_count'].to_i} review" : nil
          ].compact_blank.join(" // ")
        end

        [
          (dojo_text.present? ? { "label" => "dojo", "value" => dojo_text } : nil),
          (score_text.present? ? { "label" => "last avg", "value" => score_text } : nil),
          { "label" => "attempt", "value" => "#{attempt}/#{retry_limit + 1}" },
          { "label" => "time", "value" => ["total #{total_time}", "current #{current_time}", queued_time.present? ? "queued #{queued_time}" : nil].compact_blank.join(" // ") },
          { "label" => "job", "value" => job_text.presence || "draft pending" },
          (source.present? ? { "label" => "model", "value" => human_pending_value(source) } : nil),
          { "label" => "rag", "value" => rag_text.presence || "training context loading" },
          { "label" => "gate", "value" => gate_text }
        ].compact_blank.first(8)
      end

      def pending_rag_trace(question, metadata: nil)
        qmd = question.present? ? question.metadata.to_h : {}
        trace = qmd["rag_trace"].to_h
        return trace if trace.present?

        retrieval = qmd["retrieval"].to_h
        query = retrieval["query"].to_s.squish
        route = query[/\bRoute:\s*([A-Z_]+)/, 1].presence ||
          metadata.to_h["product_interest_code"].presence ||
          qmd["model_lane"].presence
        docs = qmd["fine_training_documents"].to_i
        chunks = qmd["fine_training_chunks"].to_i
        return if query.blank? && docs.zero? && chunks.zero? && route.blank?

        {
          "route" => route,
          "retrieval" => [retrieval["mode"].presence, retrieval["provider"].presence].compact.join(" // ").presence,
          "fine_training" => "#{docs} docs / #{chunks} chunks",
          "query" => query.truncate(320, separator: " ")
        }.compact_blank
      end

      def note_pair(label, value)
        text = human_pending_note(value)
        return if text.blank?

        { "label" => label, "text" => text.truncate(180, separator: " ") }
      end

      def alert_pair(label, value)
        text = value.to_s.squish
        return if text.blank?

        { "label" => label, "text" => text.truncate(260, separator: " ") }
      end

      def pending_timeline(metadata)
        [
          pending_time_item("total", latest_simulated_inbound_at(metadata), "since latest customer text"),
          pending_time_item("current", pending_current_started_at(metadata), "this draft window"),
          pending_time_item("queued", metadata.to_h["sms_reply_job_queued_at"].presence || metadata.to_h["comms_command_background_at"].presence, "queue age")
        ].compact
      end

      def pending_current_started_at(metadata)
        metadata.to_h["ask_autopilot_pending_started_at"].presence ||
          metadata.to_h["comms_command_background_at"].presence ||
          metadata.to_h["ask_autopilot_last_result_at"].presence ||
          latest_simulated_inbound_at(metadata) ||
          Time.current.iso8601
      end

      def pending_time_item(label, started_at, hint)
        parsed = parse_pending_time(started_at)
        return if parsed.blank?

        seconds = [(Time.current - parsed).to_i, 0].max
        {
          "label" => label,
          "value" => format_pending_duration(seconds),
          "hint" => hint,
          "started_at" => parsed.iso8601
        }
      end

      def parse_pending_time(value)
        return if value.blank?

        value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def format_pending_duration(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60

        minutes, remaining_seconds = seconds.divmod(60)
        return "#{minutes}m #{remaining_seconds.to_s.rjust(2, '0')}s" if minutes < 60

        hours, remaining_minutes = minutes.divmod(60)
        "#{hours}h #{remaining_minutes.to_s.rjust(2, '0')}m"
      end

      def human_pending_value(value)
        value.to_s.tr("_", " ").squish
      end

      def human_pending_note(value)
        text = value.to_s.squish
        return if text.blank?

        parts = text.split(/\s*\|\s*/).map(&:squish).reject(&:blank?).uniq
        return "Simulator rejected a non-customer-facing worker reply; retrying with stricter SMS guidance." if parts.any? { |part| part.match?(/non-customer-facing worker reply/i) }
        return "Local worker is drafting again after the simulator guardrail blocked the prior output." if text.match?(/Retrying after simulator guardrail rejection/i)

        text.gsub("ask_simulator_quality_gate_rejected", "simulator quality gate rejected")
      end

      def latest_simulated_inbound_at(metadata)
        Array(metadata["sms_thread"]).reverse_each do |event|
          event = event.to_h
          next unless event["direction"].to_s == "inbound"

          timestamp = event["created_at"].presence || event["at"].presence || event["timestamp"].presence
          return timestamp if timestamp.present?
        end
        nil
      end

      def message_from_event(event)
        event = event.to_h
        direction = event["direction"].to_s == "inbound" ? "inbound" : "outbound"
        {
          "id" => event["id"],
          "direction" => direction,
          "role" => event["role"],
          "sender" => direction == "inbound" ? "Customer" : "Thumper",
          "body" => event["body"],
          "original_body" => event["original_body"],
          "english_body" => event["english_body"],
          "language_code" => event["language_code"],
          "language_label" => event["language_label"],
          "language_translated" => event["language_translated"],
          "translation_provider" => event["translation_provider"],
          "translation_model" => event["translation_model"],
          "translation_error" => event["translation_error"] || event["language_translation_error"],
          "created_at" => event["created_at"],
          "provider" => event["provider"],
          "draft_source" => event["draft_source"],
          "draft_model" => event["draft_model"],
          "sms_quality_gate" => event["sms_quality_gate"],
          "ask_quality_gate" => event["ask_quality_gate"],
          "reason" => event["reason"],
          "error" => event["error"],
          "autos_question_id" => event["autos_question_id"],
          "recursive_dojo" => event["recursive_dojo"],
          "dojo_cycle" => event["dojo_cycle"],
          "dojo_grade" => event["dojo_grade"],
          "dojo_trajectory" => event["dojo_trajectory"],
          "dojo_scroll_links" => event["dojo_scroll_links"],
          "embedding_summary" => event["embedding_summary"],
          "embedding_lesson" => event["embedding_lesson"]
        }.compact_blank
      end

      def event_payload(direction:, status:, body:, from:, to:, user:)
        {
          "id" => SecureRandom.uuid,
          "channel" => "sms",
          "direction" => direction,
          "status" => status,
          "to" => to.to_s,
          "from" => from.to_s,
          "body" => body.to_s,
          "provider" => "ask/simulator",
          "provider_message_id" => "ask-sim-#{SecureRandom.uuid}",
          "provider_status" => status,
          "user_id" => user&.id,
          "user_name" => display_name(user),
          "created_at" => Time.current.iso8601
        }.compact_blank
      end

      def processing_payload(stage, metadata:, latest_body:)
        DealReports::CommsProcessingCode.call(stage: stage, metadata: metadata, latest_body: latest_body)
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] processing failed stage=#{stage&.id} #{error.class}: #{error.message}")
        {}
      end

      def location_capture_payload(metadata, payload)
        return {} unless payload.to_h["direction"].to_s == "inbound"

        text = payload.to_h["body"].to_s.squish
        zip = extract_zip(text)
        permission_accepted = location_permission_recently_requested?(metadata) && location_permission_accepted?(text)
        return {} if zip.blank? && !permission_accepted

        event = {
          "id" => SecureRandom.uuid,
          "channel" => "sms",
          "direction" => "inbound",
          "status" => zip.present? ? "captured" : "permission_accepted",
          "zip" => zip,
          "postal_code" => zip,
          "provider" => "ask/simulator",
          "source" => zip.present? ? "ask_sms_body_zip" : "ask_sms_permission_reply",
          "created_at" => Time.current.iso8601
        }.compact_blank
        thread = Array(metadata.to_h["location_thread"]).last(20)
        thread << event

        {
          "location_thread" => thread,
          "location_capture_last" => event,
          "location_capture_status" => zip.present? ? "consented" : "permission_accepted_zip_needed",
          "location_capture_at" => Time.current.iso8601
        }
      end

      def extract_zip(value)
        value.to_s[/\b\d{5}(?:-\d{4})?\b/]
      end

      def location_permission_recently_requested?(metadata)
        Array(metadata.to_h["sms_thread"]).reverse_each.first(8).any? do |event|
          event = event.to_h
          event["direction"].to_s == "outbound" &&
            event["body"].to_s.match?(/\b(check where|check your zip|zip codes? for shipping|share your zip|location|service area|specific area|neighborhood)\b/i)
        end
      end

      def location_permission_accepted?(text)
        text.to_s.match?(/\b(yes|yeah|sure|ok|okay|go ahead|please do|send it)\b/i)
      end

      def checkout_link_sent_payload(metadata, payload)
        return {} unless payload["channel"].to_s == "sms"
        return {} unless payload["direction"].to_s == "outbound"
        return {} unless payload["status"].to_s == "sent"

        body = payload["body"].to_s
        configured_link = metadata["shopify_link"].to_s.squish
        link_sent = configured_link.present? ? body.include?(configured_link) : body.match?(%r{https?://\S*(?:shopify|shop\.wizwikimarketing|wizwikimarketing\.com/products)\S*}i)
        return {} unless link_sent

        {
          "shopify_link_sent_at" => metadata["shopify_link_sent_at"].presence || Time.current.iso8601,
          "comms_link_reached_at" => metadata["comms_link_reached_at"].presence || Time.current.iso8601
        }
      end

      def simulator_result_payload(result)
        result.to_h.slice(
          "provider",
          "model",
          "writer_model",
          "writer_model_label",
          "sms_generation_pipeline",
          "sms_quality_gate",
          "draft_source",
          "reason",
          "error",
          "autos_question_id",
          "background_queued",
          "pending",
          "ask_quality_gate",
          "requires_am_support",
          "am_support_reason"
        ).compact_blank
      end

      def broadcast_stage!(stage, user:)
        return if stage.blank? || user.blank? || !defined?(Turbo::StreamsChannel)

        Turbo::StreamsChannel.broadcast_replace_to(
          "autos_questions_user_#{user.id}",
          target: "ask-autopilot-test",
          partial: "asks/autopilot_test",
          locals: { ask_autopilot_test: payload_for(stage.reload) }
        )
      rescue StandardError => error
        Rails.logger.warn("[AskAutopilotTest] broadcast failed stage=#{stage&.id} user=#{user&.id} #{error.class}: #{error.message}")
      end

      def draft_history_entry(result)
        body = safe_customer_sms_body(result.to_h["body"])
        simulator_result_payload(result).merge(
          "id" => SecureRandom.uuid,
          "body" => body,
          "created_at" => Time.current.iso8601,
          "ask_autopilot_test" => true
        ).compact_blank
      end

      def safe_customer_sms_body(value)
        return if value.blank?
        return Comms::SmsBodySafety.sanitize_customer_body(value) if defined?(Comms::SmsBodySafety)

        value.to_s.squish.presence
      end

      def stage_from(payload, organization:)
        stage_id = payload.to_h["stage_id"].presence
        return if stage_id.blank? || organization.blank?

        organization.crm_record_artifacts
          .where(artifact_type: "comm_staging")
          .where("metadata ->> 'stage_type' = ?", STAGE_TYPE)
          .find_by(id: stage_id)
      end

      def active_stage?(stage)
        metadata = stage.metadata.to_h
        metadata["stage_type"].to_s == STAGE_TYPE &&
          ActiveModel::Type::Boolean.new.cast(metadata["ask_autopilot_test_active"])
      end

      def engine_label(metadata)
        writer = metadata["sms_writer_model_label"].presence || metadata["sms_writer_model"].presence || "SMS writer"
        "CommsDraftWriter // #{writer} // Twilio skipped"
      end

      def backend_label(metadata)
        if metadata["recursive_dojo_status"].to_s.in?(%w[queued running])
          return "Recursive Dojo // #{metadata['recursive_dojo_status']}"
        end

        question_id = metadata["ask_autopilot_last_autos_question_id"].presence ||
          metadata["comms_command_background_question_id"].presence
        return "stage ##{metadata['source_crm_record_id']}" if question_id.blank?

        "AutosQuestion ##{question_id}"
      end

      def default_objective
        "Thumper should run the normal WIZWIKI COMMS SMS autopilot conversation in simulator mode: answer the latest customer SMS, ask one useful question at a time, use product routing and Shopify links when ready, explain design/onboarding with the order-first intake/proof flow and AI postcard/art builder when relevant, answer large-quantity questions with standard options first, offer custom pricing help only as an option, and never send through Twilio."
      end

      def display_name(user)
        [user&.try(:first_name), user&.try(:last_name)].compact_blank.join(" ").presence ||
          user&.try(:display_name).presence ||
          user_email(user).to_s.split("@").first.presence ||
          "Operator"
      end

      def user_email(user)
        user&.try(:email_address).presence || user&.try(:email).presence
      end

      def simulated_customer_phone(user)
        digits = user&.id.to_i.to_s.rjust(7, "0")[-7, 7]
        "+1555#{digits}"
      end
    end
  end
end
