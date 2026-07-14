module Autos
  class WorkerQueue
    DEFAULT_CLAIM_TIMEOUT_SECONDS = 10.minutes.to_i
    CLAIM_TIMEOUT = ENV.fetch("AUTOS_WORKER_CLAIM_TIMEOUT_SECONDS", DEFAULT_CLAIM_TIMEOUT_SECONDS.to_s).to_i.clamp(120, 1_800).seconds
    SMS_CLAIM_TIMEOUT = ENV.fetch("AUTOS_WORKER_SMS_CLAIM_TIMEOUT_SECONDS", "90").to_i.clamp(45, 300).seconds
    MAX_ATTEMPTS = 3
    WORKER_QUEUES = %w[all telegram web sms comms embeddings weather].freeze
    PRIORITY_SURFACES = %w[comms_sms_draft dojo_judge ask].freeze
    LOCAL_WORKER_ONLY_SQL = "COALESCE(metadata ->> 'cloud_sms_writer', 'false') NOT IN ('true', '1', 'yes', 'on')".freeze
    ANALYSIS_LINK_RECORDS = {
      "companies" => ["company", "hubspot_company"],
      "contacts" => ["contact", "hubspot_contact"],
      "deals" => ["deal", "hubspot"],
      "tickets" => ["ticket", "hubspot_ticket"]
    }.freeze

    def self.enabled?
      WizwikiSettings.autos_local_worker_enabled?
    end

    def self.enabled_for?(question)
      enabled? && eligible?(question)
    end

    def self.status_for(worker_id:, worker_queue: nil)
      claimed = claimed_scope.count
      normalized_queue = normalize_worker_queue(worker_queue)
      {
        ok: true,
        app: "WIZWIKI",
        node: "Alice",
        worker_id: worker_id.presence || "alice-wizwiki-01",
        worker_queue: normalized_queue,
        role: "Thumper von AUTOS runtime for WIZWIKI",
        enabled: enabled?,
        queued: queued_scope_for(normalized_queue).count,
        queued_all: queued_scope.count,
        queued_telegram: queued_scope_for("telegram").count,
        queued_web: queued_scope_for("web").count,
        queued_comms: queued_scope_for("comms").count,
        queued_sms: queued_scope_for("sms").count,
        priority_work: priority_work_status,
        claimed: claimed,
        active: claimed,
        provider: WizwikiSettings.active_ai_provider,
        local_model: local_model,
        local_frontier_model: local_frontier_model,
        weather_calibration_model: weather_calibration_model,
        embedder_model: embedder_model,
        openai_runtime_enabled: WizwikiSettings.openai_runtime_enabled?,
        qwen_only: WizwikiSettings.qwen_only?,
        context: {
          focus: "design workflow, team building, Clifton Strengths, CRM opportunities, training documents",
          organizations: Organization.count,
          employee_profiles: EmployeeProfile.count,
          queued_design_orders: DesignOrder.queued.count
        },
        generated_at: Time.zone.now.iso8601
      }
    end

    def self.eligible?(question)
      question.present? && question.status == "queued" && question.answer.blank? && !cloud_sms_writer_question?(question)
    end

    def self.cancelable?(question)
      eligible?(question)
    end

    def self.queue!(question)
      raise "Cloud SMS writer jobs are handled by Comms::SmsCloudDraftJob" if cloud_sms_writer_question?(question)

      metadata = question.metadata.to_h.deep_dup
      cancel_superseded_comms_drafts!(question, metadata)
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "queued",
        "queued_at" => Time.zone.now.iso8601,
        "lane" => "cc_context_cache",
        "provider" => "alice"
      )
      metadata["local_worker"] = worker
      metadata["model_lane"] = "cc_context_cache"
      question.update!(status: "queued", metadata: metadata)
      broadcast(question) unless skip_ui_broadcast?(question)
    end

    def self.cancel_superseded_comms_drafts!(question, metadata)
      surface = metadata["surface"].to_s
      return unless comms_draft_surface?(surface)

      stage_id = metadata["comms_stage_id"].to_s
      return if stage_id.blank?

      AutosQuestion
        .where.not(id: question.id)
        .where(status: "queued")
        .where("metadata ->> 'surface' = ?", surface)
        .where("metadata ->> 'comms_stage_id' = ?", stage_id)
        .then { |scope|
          if surface == "comms_email_draft"
            draft_scope = metadata["email_draft_scope"].presence || metadata["draft_scope"].presence || "manual"
            scope.where("COALESCE(metadata ->> 'email_draft_scope', metadata ->> 'draft_scope', 'manual') = ?", draft_scope)
          else
            scope
          end
        }
        .find_each do |older|
          older_metadata = older.metadata.to_h.deep_dup
          older_worker = older_metadata["local_worker"].to_h
          older_worker.merge!(
            "status" => "canceled",
            "canceled_at" => Time.zone.now.iso8601,
            "cancel_reason" => "superseded_by_#{surface}_#{question.id}"
          )
          older_metadata["local_worker"] = older_worker
          older.update_columns(status: "canceled", metadata: older_metadata, updated_at: Time.current)
        end
    end

    def self.claim_next!(worker_id:, worker_queue: nil)
      normalized_queue = normalize_worker_queue(worker_queue)
      return nil if normalized_queue == "embeddings"

      question = nil
      AutosQuestion.transaction do
        question = queued_scope_for(normalized_queue).lock("FOR UPDATE SKIP LOCKED").first
        next unless question.present?

        metadata = question.metadata.to_h.deep_dup
        worker = metadata["local_worker"].to_h
        worker["status"] = "claimed"
        worker["claimed_at"] = Time.zone.now.iso8601
        worker["worker_id"] = worker_id.to_s
        worker["worker_queue"] = normalized_queue
        worker["attempts"] = worker["attempts"].to_i
        metadata["local_worker"] = worker
        question.update!(metadata: metadata)
      end
      question
    end

    def self.payload_for(question)
      metadata = question.metadata.to_h.deep_dup
      surface = metadata["surface"].presence || "ask"
      context = context_for(question, surface: surface)
      answer_contract = answer_contract_for(question)
      retrieval_contract = retrieval_contract_for(question, surface, metadata)
      direct_analysis_surface = comms_draft_surface?(surface) || surface.to_s == "weather_outcome_analysis"
      analysis_links = direct_analysis_surface ? [] : analysis_links_for(question)
      analysis_items = direct_analysis_surface ? [] : analysis_items_for(question)
      selected_local_model = local_model_for_surface(surface, metadata)
      selected_frontier_model = local_frontier_model_for_surface(surface)
      worker_prompt = if surface.to_s == "weather_outcome_analysis"
        [question.question, "OFFICIAL-STATION EVIDENCE JSON:", context.fetch(:text)].join("\n\n")
      else
        question.question
      end
      metadata["local_worker"] = metadata["local_worker"].to_h.merge("context_built_at" => Time.zone.now.iso8601)
      metadata["context_counts"] = context.fetch(:counts)
      metadata["answer_contract"] = answer_contract
      metadata["retrieval"] = retrieval_contract
      if analysis_items.present?
        metadata["analysis_items"] = analysis_items
      else
        metadata.delete("analysis_items")
      end
      if analysis_links.present?
        metadata["analysis_links"] = analysis_links
      else
        metadata.delete("analysis_links")
      end
      question.update!(metadata: metadata)

      {
        id: question.id,
        source: "wizwiki",
        surface: surface,
        lane: "cc_context_cache",
        organization_id: question.organization_id,
        preferred_provider: WizwikiSettings.active_ai_provider,
        qwen_only: WizwikiSettings.qwen_only?,
        prompt: worker_prompt,
        raw_prompt: question.question,
        semantic_query: retrieval_contract["query"],
        retrieval: retrieval_contract,
        context: context.fetch(:text),
        answer_contract: answer_contract,
        analysis_items: analysis_items,
        related_links: analysis_links,
        memory: {
          brain_type: memory_brain_type_for(surface),
          shared_brain_types: shared_brain_types_for(surface),
          organization_id: question.organization_id,
          user_id: question.user_id,
          surface: surface
        },
        local_model: selected_local_model,
        challenger_model: metadata["challenger_model"].presence,
        challenger_model_label: metadata["challenger_model_label"].presence,
        local_frontier: {
          provider: "qwen/local",
          model: selected_frontier_model,
          embedder_model: embedder_model
        },
        openai: {
          enabled: surface.to_s.in?(%w[dojo_judge weather_outcome_analysis]) ? false : WizwikiSettings.openai_runtime_enabled?,
          fallback_allowed: false,
          model: WizwikiSettings.openai_model,
          reasoning_effort: WizwikiSettings.openai_reasoning_effort
        },
        system_prompt: system_prompt_for(question, surface),
        complete_path: "/autos_worker/messages/#{question.id}/complete",
        fail_path: "/autos_worker/messages/#{question.id}/fail"
      }
    end

    def self.complete!(question, worker_payload:)
      question.reload
      return question if question.status == "answered" && question.answer.present?

      surface = question.metadata.to_h["surface"].presence || "ask"
      answer_contract = question.metadata.to_h["answer_contract"].presence || answer_contract_for(question)
      max_chars = answer_contract.to_h.fetch("max_chars", Autos::Settings.max_answer_chars).to_i
      max_lines = answer_contract.to_h.fetch("max_lines", Autos::Settings.max_answer_lines).to_i
      raw_answer = worker_payload["answer"].to_s
      constrained_raw_answer = Autos::Voice.constrain_answer_length(raw_answer, max_chars: max_chars, max_lines: max_lines).strip
      constrained_raw_answer = salvage_comms_sms_answer(constrained_raw_answer) if surface == "comms_sms_draft"
      raw_reject_reason = if surface == "comms_sms_draft" && wrapped_comms_sms_answer?(constrained_raw_answer)
        "rejected_wrapped_sms_answer"
      elsif surface == "comms_sms_draft" && defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(constrained_raw_answer)
        Comms::SmsBodySafety.leak_reason(constrained_raw_answer).presence || "analysis_or_internal_notes_in_sms_answer"
      end
      answer = if surface == "comms_sms_draft" && defined?(Comms::SmsBodySafety)
        Comms::SmsBodySafety.sanitize_customer_body(constrained_raw_answer).presence || constrained_raw_answer
      elsif surface.in?(%w[dojo_judge weather_outcome_analysis])
        constrained_raw_answer
      elsif surface.in?(%w[comms_sms_draft comms_email_draft])
        constrained_raw_answer
      else
        Autos::Voice.customer_visible_answer(raw_answer, question: question, max_chars: max_chars, max_lines: max_lines).strip
      end
      answer = comms_sms_rush_checkout_boundary_rewrite(answer, question.metadata.to_h) if surface == "comms_sms_draft"
      raise ArgumentError, "answer required" if answer.blank?

      metadata = question.metadata.to_h.deep_dup
      analysis_links = if surface == "weather_outcome_analysis"
        []
      else
        metadata["analysis_links"].presence || analysis_links_for(question)
      end
      worker = metadata["local_worker"].to_h
      worker.merge!(
        "status" => "answered",
        "completed_at" => Time.zone.now.iso8601,
        "provider" => worker_payload["provider"].presence || "local_cc",
        "model" => worker_payload["model"].presence || worker_payload["local_model"].presence || local_model,
        "usage" => worker_payload["usage"].presence
      )
      worker.compact!
      metadata["local_worker"] = worker
      metadata["answer_contract"] = answer_contract
      metadata["analysis_links"] = analysis_links if analysis_links.present?
      metadata["autos_voice_status"] = "queued"
      if surface.in?(%w[ask comms_sms_draft]) && answer != constrained_raw_answer
        metadata["visible_answer_safety"] = {
          "status" => "sanitized",
          "reason" => "internal_draft_leak_blocked",
          "sanitized_at" => Time.zone.now.iso8601
        }
      end

      if surface == "weather_outcome_analysis"
        validation = Kalshi::WeatherAnalysisContract.validate(
          answer,
          expected_digest: metadata["weather_batch_digest"],
          expected_sample_size: metadata["weather_sample_size"]
        )
        metadata["weather_analysis_validation"] = validation.except(:payload)
        unless validation.fetch(:valid)
          worker["status"] = "rejected"
          worker["reject_reason"] = "invalid_weather_analysis_contract"
          worker["rejected_at"] = Time.zone.now.iso8601
          metadata["local_worker"] = worker
          question.update!(
            answer: answer.truncate(max_chars.clamp(180, 4_000)),
            status: "failed",
            metadata: metadata
          )
          return question
        end

        answer = JSON.generate(validation.fetch(:payload))
      end

      if surface == "comms_sms_draft" && (raw_reject_reason.present? || invalid_comms_sms_answer?(answer))
        worker["status"] = "rejected"
        worker["reject_reason"] = raw_reject_reason.presence || "analysis_or_internal_notes_in_sms_answer"
        worker["rejected_at"] = Time.zone.now.iso8601
        metadata["local_worker"] = worker
        question.update!(
          answer: (raw_reject_reason.present? ? constrained_raw_answer : answer).truncate(max_chars.clamp(180, 4_000)),
          status: "failed",
          metadata: metadata
        )
        enqueue_comms_sms_writeback!(question.reload, reason: worker["reject_reason"])
        return question
      end

      question.update!(
        answer: answer.truncate(max_chars.clamp(180, 4_000)),
        status: "answered",
        metadata: metadata
      )
      if surface == "comms_sms_draft"
        enqueue_comms_sms_writeback!(question.reload)
      elsif surface == "comms_email_draft" && defined?(DealReports::CommsEmailDraftWriter)
        DealReports::CommsEmailDraftWriter.apply_worker_answer!(question.reload)
      end
      Autos::ChatMemoryRecorder.record!(question.reload) unless ActiveModel::Type::Boolean.new.cast(metadata["skip_chat_memory"])
      broadcast(question) unless skip_ui_broadcast?(question)
      question
    end

    def self.fail!(question, error:)
      question.reload
      metadata = question.metadata.to_h.deep_dup
      worker = metadata["local_worker"].to_h
      if question.status == "answered" && question.answer.present?
        worker["late_error_after_answer"] = error.to_s.truncate(500)
        worker["late_error_ignored_at"] = Time.zone.now.iso8601
        metadata["local_worker"] = worker
        question.update!(metadata: metadata)
        return question
      end
      attempts = worker["attempts"].to_i + 1
      worker["attempts"] = attempts
      worker["last_error"] = error.to_s.truncate(500)
      worker["failed_at"] = Time.zone.now.iso8601

      if attempts >= MAX_ATTEMPTS
        worker["status"] = "failed"
        metadata["local_worker"] = worker
        question.update!(status: "failed", answer: "THUMPER local Context Cache failed. Operator log saved.", metadata: metadata)
        enqueue_comms_sms_writeback!(question.reload, reason: worker["last_error"]) if question.metadata.to_h["surface"].to_s == "comms_sms_draft"
        DealReports::CommsEmailDraftWriter.apply_worker_failure!(question.reload, reason: worker["last_error"]) if question.metadata.to_h["surface"].to_s == "comms_email_draft" && defined?(DealReports::CommsEmailDraftWriter)
      else
        worker["status"] = "retry"
        metadata["local_worker"] = worker
        question.update!(metadata: metadata)
      end
      broadcast(question) unless skip_ui_broadcast?(question)
    end

    def self.queued_scope
      AutosQuestion
        .where(status: "queued", answer: [nil, ""])
        .where(LOCAL_WORKER_ONLY_SQL)
        .where(<<~SQL.squish, cutoff: CLAIM_TIMEOUT.ago, sms_cutoff: SMS_CLAIM_TIMEOUT.ago)
          ((metadata -> 'local_worker' ->> 'status') IN ('queued', 'retry'))
          OR ((metadata -> 'local_worker' ->> 'status') = 'claimed' AND metadata ->> 'surface' = 'comms_sms_draft' AND updated_at < :sms_cutoff)
          OR ((metadata -> 'local_worker' ->> 'status') = 'claimed' AND updated_at < :cutoff)
        SQL
        .order(Arel.sql(queue_priority_order_sql), :created_at, :id)
    end

    def self.priority_work_active?
      priority_work_scope.exists?
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerQueue] priority work check failed #{error.class}: #{error.message}")
      false
    end

    def self.priority_work_status
      scope = priority_work_scope
      {
        active: scope.exists?,
        queued: scope.where("COALESCE(metadata -> 'local_worker' ->> 'status', '') IN ('queued', 'retry')").count,
        claimed: scope.where("metadata -> 'local_worker' ->> 'status' = 'claimed'").count,
        surfaces: PRIORITY_SURFACES
      }
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerQueue] priority work status failed #{error.class}: #{error.message}")
      {
        active: false,
        queued: 0,
        claimed: 0,
        surfaces: PRIORITY_SURFACES,
        error: error.message
      }
    end

    def self.queued_scope_for(worker_queue)
      queue = normalize_worker_queue(worker_queue)
      scope = queued_scope
      case queue
      when "telegram"
        scope.where(<<~SQL.squish)
          LOWER(COALESCE(metadata ->> 'origin', metadata ->> 'source', '')) = 'telegram'
        SQL
      when "web"
        scope.where.not("metadata ->> 'surface' IN (?)", %w[comms_sms_draft comms_email_draft])
          .where(<<~SQL.squish)
            LOWER(COALESCE(metadata ->> 'origin', metadata ->> 'source', '')) <> 'telegram'
          SQL
      when "weather"
        scope.where("metadata ->> 'surface' = ?", "weather_outcome_analysis")
      when "sms", "comms"
        scope.where("metadata ->> 'surface' IN (?)", %w[comms_sms_draft comms_email_draft dojo_judge])
      else
        scope
      end
    end

    def self.normalize_worker_queue(value)
      queue = value.to_s.downcase.strip
      WORKER_QUEUES.include?(queue) ? queue : "all"
    end

    def self.priority_work_scope
      AutosQuestion
        .where(status: "queued", answer: [nil, ""])
        .where(LOCAL_WORKER_ONLY_SQL)
        .where("metadata ->> 'surface' IN (?)", PRIORITY_SURFACES)
        .where(<<~SQL.squish, cutoff: CLAIM_TIMEOUT.ago)
          ((metadata -> 'local_worker' ->> 'status') IN ('queued', 'retry'))
          OR ((metadata -> 'local_worker' ->> 'status') = 'claimed' AND updated_at >= :cutoff)
        SQL
    end

    def self.queue_priority_order_sql
      <<~SQL.squish
        CASE
          WHEN metadata ->> 'surface' = 'comms_sms_draft'
            AND COALESCE(metadata ->> 'ask_autopilot_test', metadata ->> 'comms_simulation_mode', 'false') NOT IN ('true', '1', 'yes', 'on')
            THEN 0
          WHEN metadata ->> 'surface' = 'dojo_judge'
            THEN 1
          WHEN metadata ->> 'surface' = 'comms_sms_draft'
            THEN 2
          WHEN COALESCE(metadata ->> 'surface', 'ask') = 'ask'
            THEN 3
          WHEN metadata ->> 'surface' = 'comms_email_draft'
            THEN 4
          WHEN metadata ->> 'surface' = 'weather_outcome_analysis'
            THEN 8
          ELSE 5
        END ASC
      SQL
    end

    def self.claimed_scope
      AutosQuestion
        .where(status: "queued", answer: [nil, ""])
        .where(LOCAL_WORKER_ONLY_SQL)
        .where("metadata -> 'local_worker' ->> 'status' = 'claimed'")
        .where(updated_at: CLAIM_TIMEOUT.ago..)
    end

    def self.cloud_sms_writer_question?(question)
      ActiveModel::Type::Boolean.new.cast(question.metadata.to_h["cloud_sms_writer"])
    end

    def self.local_model
      WizwikiSettings.autos_local_model
    end

    def self.local_frontier_model
      ENV["WIZWIKI_AUTOS_LOCAL_FRONTIER_MODEL"].presence || ENV["AUTOS_LOCAL_FRONTIER_MODEL"].presence || "qwen3.6:35b-mlx"
    end

    def self.weather_calibration_model
      WizwikiSettings.normalize_report_local_model_alias(
        ENV["WIZWIKI_WEATHER_CALIBRATION_MODEL"].presence ||
          ENV["WIZWIKI_AUTOS_WEATHER_QWEN_MODEL"].presence ||
          "qwen3:30b"
      )
    end

    def self.local_model_for_surface(surface, metadata = {})
      return weather_calibration_model if surface.to_s == "weather_outcome_analysis"

      metadata.to_h["writer_model"].presence || local_model
    end

    def self.local_frontier_model_for_surface(surface)
      return weather_calibration_model if surface.to_s == "weather_outcome_analysis"

      local_frontier_model
    end

    def self.embedder_model
      WizwikiSettings.normalize_report_embedder_model_alias(
        ENV["WIZWIKI_AUTOS_EMBEDDER_MODEL"].presence ||
          ENV["AUTOS_CC_EMBED_MODEL"].presence ||
          WizwikiSettings.report_embedder_model
      )
    end

    def self.retrieval_contract_for(question, surface, metadata)
      source_types = retrieval_source_types_for(surface)
      {
        "enabled" => true,
        "provider" => "wizwiki_pgvector_hybrid",
        "mode" => "hybrid_vector_keyword",
        "search_path" => "/autos_worker/embeddings/search",
        "scope" => retrieval_scope_for(surface, metadata),
        "surface" => surface.to_s.presence || "ask",
        "embedding_model" => embedder_model,
        "query" => retrieval_query_for(question, surface, metadata),
        "limit" => retrieval_limit_for(surface),
        "candidate_limit" => retrieval_candidate_limit_for(surface),
        "source_types" => source_types,
        "requires_query_embedding" => true,
        "fallback" => "keyword_only_when_embedding_missing",
        "rerank" => {
          "stage" => "server_weighted_hybrid",
          "future" => "local_cross_encoder_or_nim_reranker"
        }
      }.compact_blank
    end

    def self.retrieval_query_for(question, surface, metadata)
      metadata["semantic_query"].presence ||
        metadata["retrieval"].to_h["query"].presence ||
        weather_retrieval_query_for(question, surface).presence ||
        comms_retrieval_query_for(question, surface, metadata).presence ||
        [question.question, question.context.to_s[0, 1_200]].compact.join("\n").squish.truncate(1_600)
    end

    def self.weather_retrieval_query_for(question, surface)
      return nil unless surface.to_s == "weather_outcome_analysis"

      [
        "Kalshi weather calibration official NWS station forecast residual source bias Brier score fee-adjusted ROI data quality",
        question.context.to_s[0, 1_000]
      ].join("\n").squish.truncate(1_400)
    end

    def self.retrieval_scope_for(surface, metadata = {})
      return "weather_calibration" if surface.to_s == "weather_outcome_analysis"
      return metadata.to_h["rag_scope"].to_s if comms_draft_surface?(surface) && metadata.to_h["rag_scope"].present?
      if comms_draft_surface?(surface) && defined?(Comms::RagProfile) && metadata.to_h["rag_profile"].present?
        return Comms::RagProfile.fetch(metadata.to_h["rag_profile"]).fetch("scope")
      end

      Autos::EmbeddingQueue::DEFAULT_SCOPE
    end

    def self.comms_retrieval_query_for(question, surface, metadata)
      return nil unless comms_draft_surface?(surface)

      conversation_state = metadata["conversation_state"].to_h
      latest_inbound_event = metadata["latest_inbound_event"].to_h
      latest_sms_event = metadata["latest_sms_event"].to_h
      candidates = [
        metadata["latest_inbound_text"],
        metadata["latest_customer_message"],
        conversation_state["latest_inbound_text"],
        conversation_state["latest_customer_message"],
        latest_inbound_event["body"],
        latest_sms_event["body"],
        question.question
      ]
      candidates.compact_blank.join("\n").squish.truncate(1_200)
    end

    def self.retrieval_limit_for(surface)
      default = case surface.to_s
      when "comms_sms_draft"
        6
      when "comms_email_draft"
        8
      when "dojo_judge"
        6
      else
        8
      end
      ENV.fetch("WIZWIKI_RAG_LIMIT", default).to_i.clamp(1, 12)
    end

    def self.retrieval_candidate_limit_for(_surface)
      ENV.fetch("WIZWIKI_RAG_CANDIDATE_LIMIT", "40").to_i.clamp(10, 50)
    end

    def self.retrieval_source_types_for(surface)
      case surface.to_s
      when "comms_sms_draft", "comms_email_draft"
        %w[TrainingDocument TrainingVaultDocument CrmRecordArtifact PlaybookCall FathomCall CrmRecord CrmAddressRecord]
      when "dojo_judge"
        %w[TrainingDocument TrainingVaultDocument CrmRecordArtifact]
      when "weather_outcome_analysis"
        %w[AutosQuestion TrainingDocument]
      else
        nil
      end
    end

    def self.answer_contract_for(question)
      if question.metadata.to_h["surface"].to_s == "comms_sms_draft"
        {
          "style" => "sms_draft",
          "requested_items" => nil,
          "max_chars" => 480,
          "max_lines" => 4,
          "instructions" => [
            "Return exactly one customer-facing SMS body.",
            "No markdown, labels, wrappers, JSON, bullets, emojis, fake stats, hidden notes, or bracket placeholders.",
            "Do not introduce, quote, or describe the message; never write prefixes like 'Here's the next SMS body:', 'Suggested reply:', or 'Message for Sample Contact:'.",
            "Never mention source names or internal reasoning such as context, training, skills, playbooks, rules, design_process, product_decision_guide, or 'according to'. Convert those details into plain customer-facing language.",
            current_specials_sms_instruction,
            "Use Thumper from WIZWIKI Marketing as the speaker only when it helps the conversation.",
            "Answer the latest customer message first, then include one short next-step question unless the SMS is only a checkout link, opt-out confirmation, or AM handoff confirmation.",
            "Use the supplied comms JSON and recent SMS thread as conversation memory."
          ].compact_blank
        }
      elsif question.metadata.to_h["surface"].to_s == "comms_email_draft"
        {
          "style" => "email_draft_json",
          "requested_items" => nil,
          "max_chars" => 3_500,
          "max_lines" => 80,
          "instructions" => [
            "Return strict JSON only with subject, body, and reason keys.",
            "Write one human-approved outbound sales email from Thumper at WIZWIKI Marketing.",
            "Use the supplied comms JSON, CRM account context, product data, fine-training examples, SMS thread, and email thread.",
            "Do not send the email or claim it was sent.",
            "No markdown, labels, fake stats, hidden notes, or bracket placeholders."
          ]
        }
      elsif question.metadata.to_h["surface"].to_s == "weather_outcome_analysis"
        {
          "style" => "dojo_judge_json",
          "requested_items" => nil,
          "max_chars" => 2_400,
          "max_lines" => 40,
          "instructions" => [
            "Use only the compact officially settled exact-station evidence supplied by SUN.",
            "Return exactly one JSON object matching the requested weather schema; no markdown, prose wrapper, or reasoning preamble.",
            "Acknowledge the final NWS Daily Climate Report, strict one-sided strikes, inclusive ranges, and fee-adjusted out-of-sample EV.",
            "Qwen may identify patterns and conservatively block; it must not recommend, place, size, or execute a wager."
          ]
        }
      elsif question.metadata.to_h["surface"].to_s == "dojo_judge"
        {
          "style" => "dojo_judge_json",
          "requested_items" => nil,
          "max_chars" => 3_000,
          "max_lines" => 80,
          "instructions" => [
            "The answer must start with { and end with }.",
            "Return strict JSON only.",
            "Grade the supplied Thumper SMS answer using the schema in the prompt.",
            "Do not restate the customer scenario or Thumper answer.",
            "Do not include markdown, code fences, analysis prose, or customer-facing filler outside the JSON object."
          ]
        }
      elsif analysis_list_prompt?(question)
        requested_items = requested_item_count(question)
        {
          "style" => "analysis_list",
          "requested_items" => requested_items,
          "max_chars" => 4_000,
          "max_lines" => 24,
          "instructions" => [
            "This is an analysis/list answer, not a tiny chat answer.",
            "If the user asks for a count, return up to that many numbered recommendations.",
            "For account recommendations, use one compact item per account: account, contact methods, preferred contact path, reason, next action.",
            "If fewer than the requested number exist in context, say how many were found and list all of them.",
            "Do not compress a requested list into one sentence."
          ]
        }
      elsif thoughtful_answer_prompt?(question)
        {
          "style" => "thoughtful_answer",
          "requested_items" => nil,
          "max_chars" => 1_200,
          "max_lines" => 10,
          "instructions" => [
            "Give a thoughtful but still concise answer.",
            "Answer the user's direct question first, then add the useful context that helps them decide.",
            "Use relevant retrieved WIZWIKI memory when available, but do not mention retrieval mechanics.",
            "Prefer 2 to 5 short paragraphs or bullets when the answer needs process, tradeoffs, or next steps.",
            "Do not over-compress a good answer into one vague sentence."
          ]
        }
      else
        {
          "style" => "short_answer",
          "requested_items" => nil,
          "max_chars" => Autos::Settings.max_answer_chars,
          "max_lines" => Autos::Settings.max_answer_lines,
          "instructions" => [
            "Default to 1 to 2 short sentences.",
            "Use at most 4 short lines unless the user explicitly asks for analysis, a list, or a report."
          ]
        }
      end
    end

    def self.current_specials_sms_instruction
      return unless defined?(Comms::CurrentSpecials)

      Comms::CurrentSpecials.prompt_instruction
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerQueue] current specials instruction unavailable #{error.class}: #{error.message}")
      nil
    end

    def self.context_for(question, surface:)
      return direct_payload_context(question, surface: surface) if direct_payload_surface?(surface)
      return Autos::ContextBuilder.call(question) unless comms_draft_surface?(surface)

      direct_payload_context(question, surface: surface)
    end

    def self.direct_payload_context(question, surface:)
      text = question.context.to_s
      count_key = comms_draft_surface?(surface) ? :comms_context : :direct_payload_context
      {
        text: text,
        counts: {
          count_key => text.present? ? 1 : 0,
          normal_context_skipped: true
        }
      }
    end

    def self.direct_payload_surface?(surface)
      surface.to_s.in?(%w[comms_sms_draft comms_email_draft weather_outcome_analysis dojo_judge])
    end

    def self.system_prompt_for(_question, surface)
      if surface.to_s == "weather_outcome_analysis"
        return <<~TEXT.squish
          You are a local quantitative weather calibration analyst. Use only SUN's supplied official-station evidence and canonical Kalshi rules. Return strict JSON matching the answer contract. Never expose scratchpad reasoning, invent facts, authorize a live trade, or override deterministic settlement and risk controls.
        TEXT
      end
      return Autos::OpenaiAnswerer::INSTRUCTIONS unless surface.to_s == "dojo_judge"

      <<~TEXT.squish
        You are Recursive Dojo, a strict JSON-only quality judge for WIZWIKI Marketing's Thumper von AUTOS SMS agent. You are not writing to a customer. Grade the supplied scenario and Thumper answer. Return exactly one JSON object with score, verdict, findings, rewrite, and embedding_lesson. Do not include markdown, code fences, prose before JSON, analysis outside JSON, or a customer-facing SMS.
      TEXT
    end

    def self.comms_draft_surface?(surface)
      surface.to_s.in?(%w[comms_sms_draft comms_email_draft])
    end

    def self.memory_brain_type_for(surface)
      return "weather_calibration" if surface.to_s == "weather_outcome_analysis"
      return "wizwiki_comms" if comms_draft_surface?(surface)

      "wizwiki_ask"
    end

    def self.shared_brain_types_for(surface)
      surface.to_s == "weather_outcome_analysis" ? [] : %w[common market_report]
    end

    def self.analysis_list_prompt?(question)
      text = [question&.question, question&.context].compact.join(" ").downcase
      text.match?(/\b(playbook|call|calls|accounts?|companies?|tickets?|analy[sz]e|analysis|list|rank|recommend|connect with|opportunit(?:y|ies)|prioritize)\b/)
    end

    def self.thoughtful_answer_prompt?(question)
      metadata = question.metadata.to_h
      return true if ActiveModel::Type::Boolean.new.cast(metadata["full_talk"])
      return true if metadata["answer_style"].to_s == "thoughtful"

      text = [question&.question, question&.context].compact.join(" ").downcase
      text.match?(/\b(explain|walk me through|why|how should|what should|what went wrong|diagnose|compare|process|strategy|train|training|improve|thoughtful|thorough|detailed)\b/)
    end

    def self.requested_item_count(question)
      text = question&.question.to_s
      match = text.match(/\b(?:top\s*)?(\d{1,2})\b/)
      (match ? match[1].to_i : 6).clamp(3, 10)
    end

    def self.analysis_links_for(question)
      organization = organization_for(question)
      return [] if organization.blank?
      return [] unless analysis_list_prompt?(question)

      calls = organization.playbook_calls.active.recent.includes(:crm_record).limit(40)
      links_by_record_id = {}

      calls.each do |call|
        associated_records_for_call(call).each do |record|
          link = links_by_record_id[record.id] ||= {
            "label" => record.name,
            "record_type" => record.record_type,
            "url" => Rails.application.routes.url_helpers.crm_record_path(record),
            "call_count" => 0,
            "evidence" => []
          }
          link["call_count"] += 1
          link["evidence"] << call.title if call.title.present?
        end
      end

      links_by_record_id.values.each do |link|
        link["evidence"] = link["evidence"].uniq.first(3)
      end.sort_by do |link|
        priority = %w[company ticket deal contact].index(link["record_type"]).presence || 99
        [-link["call_count"].to_i, priority, link["label"].to_s.downcase]
      end.first(10)
    end

    def self.associated_records_for_call(call)
      records = []
      records << call.crm_record if call.crm_record.present?

      ANALYSIS_LINK_RECORDS.each do |object_type, (record_type, source)|
        ids = Array(call.associations.to_h[object_type]).map(&:to_s).reject(&:blank?)
        next if ids.blank?

        records.concat(call.organization.crm_records.where(record_type: record_type, source: source, source_uid: ids))
        records.concat(call.organization.crm_records.where(record_type: record_type, source_uid: ids))
      end

      records.compact.uniq(&:id)
    end

    def self.analysis_items_for(question)
      organization = organization_for(question)
      return [] if organization.blank?
      return [] unless analysis_list_prompt?(question)

      grouped = {}
      calls = organization.playbook_calls.active.recent.includes(:crm_record).limit(40).to_a

      calls.each do |call|
        records = associated_records_for_call(call)
        company = records.find { |record| record.record_type == "company" }
        ticket = records.find { |record| record.record_type == "ticket" }
        deal = records.find { |record| record.record_type == "deal" }
        contact = records.find { |record| record.record_type == "contact" }
        primary_record = company || deal || ticket || contact || call.crm_record
        associations = call.associations.to_h
        key = [
          associations["companies"]&.first,
          associations["contacts"]&.first,
          primary_record&.id,
          clean_call_name(call.title)
        ].compact.first.to_s
        key = "playbook-call-#{call.id}" if key.blank?

        item = grouped[key] ||= {
          "account" => primary_record&.name.presence || clean_call_name(call.title).presence || "Playbook call #{call.id}",
          "contact" => contact&.name.presence || clean_call_name(call.title),
          "call_count" => 0,
          "last_call_at" => nil,
          "why" => nil,
          "next_action" => nil,
          "contact_methods" => [],
          "preferred_contact" => nil,
          "local_links" => [],
          "hubspot_refs" => {},
          "evidence" => []
        }

        item["call_count"] += 1
        item["last_call_at"] = [item["last_call_at"], call.occurred_at&.iso8601].compact.max
        item["why"] ||= call.summary.presence
        item["next_action"] ||= call.suggested_next_actions.presence
        item["evidence"] << call.compact_context(max_chars: 420)
        item["hubspot_refs"] = merge_hubspot_refs(item["hubspot_refs"], associations)

        records.each do |record|
          item["contact_methods"].concat(contact_methods_for_record(record))
          item["local_links"] << {
            "label" => record.name,
            "record_type" => record.record_type,
            "url" => Rails.application.routes.url_helpers.crm_record_path(record)
          }
        end
      end

      grouped.values.each do |item|
        item["contact_methods"] = item["contact_methods"].uniq { |method| [method["type"], method["value"]] }.first(8)
        item["preferred_contact"] = preferred_contact_for(item["contact_methods"])
        item["why"] ||= "#{item["call_count"]} recent playbook #{'call'.pluralize(item["call_count"])} indicate this account has fresh activity."
        item["next_action"] ||= next_action_for_analysis_item(item)
        item["local_links"] = item["local_links"].uniq { |link| [link["record_type"], link["url"]] }.first(4)
        item["evidence"] = item["evidence"].uniq.first(3)
      end.sort_by do |item|
        [-item["call_count"].to_i, item["account"].to_s.downcase]
      end.first(requested_item_count(question))
    end

    def self.organization_for(question)
      return unless question.respond_to?(:organization)

      question.organization
    end

    def self.clean_call_name(title)
      title.to_s.sub(/\Acall with\s+/i, "").strip.presence
    end

    def self.contact_methods_for_record(record)
      methods = []
      methods << { "type" => "email", "label" => "#{record.record_type} email", "value" => record.email } if record.email.present?
      methods << { "type" => "phone", "label" => "#{record.record_type} phone", "value" => record.phone } if record.phone.present?

      hubspot_properties = record.properties.to_h.dig("hubspot", "properties").to_h
      website = hubspot_properties["website"].presence || hubspot_properties["domain"].presence || record.domain.presence
      if website.present?
        url = website.to_s.match?(/\Ahttps?:\/\//i) ? website.to_s : "https://#{website}"
        methods << { "type" => "website", "label" => "#{record.record_type} website/form", "value" => url }
      end

      methods
    end

    def self.preferred_contact_for(methods)
      methods = Array(methods)
      return "phone" if methods.any? { |method| method["type"] == "phone" }
      return "email" if methods.any? { |method| method["type"] == "email" }
      return "website/form" if methods.any? { |method| method["type"] == "website" }

      "review linked HubSpot/local card"
    end

    def self.next_action_for_analysis_item(item)
      preferred = item["preferred_contact"].presence || "review linked HubSpot/local card"
      contact = item["contact"].presence || item["account"]
      "Use #{preferred} for #{contact}; review the latest playbook notes before outreach."
    end

    def self.merge_hubspot_refs(existing, associations)
      merged = existing.to_h.deep_dup
      associations.to_h.each do |object_type, ids|
        merged[object_type] = (Array(merged[object_type]) + Array(ids).map(&:to_s)).reject(&:blank?).uniq.first(5)
      end
      merged
    end

    def self.broadcast(question)
      Turbo::StreamsChannel.broadcast_replace_to(
        "autos_questions_user_#{question.user_id}",
        target: "autos_question_#{question.id}",
        partial: "asks/question",
        locals: { question: question }
      )
    rescue StandardError => error
      Rails.logger.warn("Autos Alice broadcast failed: #{error.class} - #{error.message}")
    end

    def self.skip_ui_broadcast?(question)
      ActiveModel::Type::Boolean.new.cast(question.metadata.to_h["skip_ui_broadcast"])
    end

    def self.enqueue_comms_sms_writeback!(question, reason: nil)
      return false unless defined?(Comms::SmsDraftWritebackJob)

      Comms::SmsDraftWritebackJob.perform_later(
        autos_question_id: question.id,
        reason: reason.presence
      )
      true
    rescue StandardError => error
      Rails.logger.warn("[Autos::WorkerQueue] comms SMS writeback enqueue failed question=#{question&.id} #{error.class}: #{error.message}")
      DealReports::CommsDraftWriter.apply_worker_rejection!(question.reload, reason: reason) if reason.present? && defined?(DealReports::CommsDraftWriter)
      DealReports::CommsDraftWriter.apply_worker_answer!(question.reload) if reason.blank? && defined?(DealReports::CommsDraftWriter)
      false
    end

    def self.invalid_comms_sms_answer?(answer)
      return true if wrapped_comms_sms_answer?(answer)

      body = unwrap_comms_sms_answer(answer).squish.downcase
      return true if body.blank?
      return true if body.match?(/\A(?:starter_pack|pro_pack|lawn_signs|eddm|neighborhood_blitz|custom_artwork)\z/)
      return true if body.match?(/\A[a-z0-9]+(?:_[a-z0-9]+)+\z/)
      return true if body.match?(/\b(?:starter_pack|pro_pack|lawn_signs|neighborhood_blitz|custom_artwork|direct_mail)\b/)
      return true if body.match?(%r{https?://(?:shop\.)?wizwikimarketing\.com/products/[^ \t\r\n]*\bdane\b})
      return true if body.match?(/\A(?:please\s+)?(?:apologize|mention|reconnect|follow|convert|write|draft|ask)\b/)
      return true if body.match?(/\b(?:operator instruction|follow the operator|ask at most one useful next question|reconnect to the current thread|mention my boss|mention the boss|in a casual human way)\b/)
      return true if body.match?(/\A(?:use when|fit\s*:|usage_rule\s*:|recommended_next_question\s*:)/)
      return true if body.match?(/\b(?:missing_fields|next_missing_field|prompt_if_missing|current_next_text|captured_contact_name|captured_company_name|captured_industry|customer_first_name|customer_company_name|context_json|identity_capture|conversation_state|conversation\s+state|latest_inbound_event|latest_sms_event|latest_outbound_event|latest\s+inbound\s+message|recent_unsent_drafts|recent_outbound_texts|prior_thumper_messages|operator_prompt|thread_authority|full_sms_thread|recent_sms_thread|product_decision_guide|product\s+decision\s+guide|decision_guide|decision\s+guide|design_process|fine_training|training\s+context|skill\s+["']?[\w\s-]+["']?|playbook|campaign_fit_payload|campaign_fit|product_interest|route_code|shopify_link|product_key|product_label|checkout_url|style_variation|artwork_status|missing\s+fit\s+signal|sign_quantity|ask_if_unclear)\b/)
      return true if body.match?(/\A[-*]\s*(?:the\s+)?(?:route|route_code|shopify_link|product_key|known|missing|latest|prior|context|answer|fit|usage_rule|steps?)\b/)
      body.match?(/\A(?:however,?\s+)?(?:important|note that|let me|looking at|we are drafting|we are in\b|we are in the middle of|i need to|i should|analysis|reasoning|based on the context|from the context|from the conversation|the context shows|the context says|the conversation|the customer'?s latest|the previous sms|the latest inbound|the latest outbound|latest inbound|latest outbound|the latest inbound message|context json|conversation_state|steps?)\b/) ||
        body.match?(/\A(?:to the question about|this answers|the next step is to (?:provide|ask|collect|route)|they (?:want|asked|said|need|gave)|they'?ve (?:given|asked|said)|we'?ve (?:learned|got|received)|we have (?:learned|got|received))\b/) ||
        body.match?(/\b(?:let me analyze|looking at the context|context from the json|current situation|craft the next sms|latest inbound event|latest outbound event|household count question|from the context|from the conversation|the context shows|the context says|operator_prompt|context json|conversation_state|customer-facing sms|return only the sms|we are given|we are in (?:the\s+)?["']?[a-z_]+["']?\s+lane|we are to answer|we are to write|we are writing|we have to answer|we must ask|we must not|we must answer|we need to answer|we know the customer|we know they|we do not have|we don't have|must answer this directly|ask at most one short next-step question|the route code is|the shopify link is|the product_decision_guide|the product decision guide|the design_process|according to (?:the\s+)?(?:product\s+)?(?:decision guide|design_process|skill|playbook|context)|the decision guide|the guide says|the skill says|the playbook says|use when they only need|use when the customer|the customer has already been engaged|history of conversation)\b/)
    end

    def self.salvage_comms_sms_answer(answer)
      body = unwrap_comms_sms_answer(answer).to_s
      return body.squish if body.blank?

      salvaged = body.sub(
        /\s+(?:Answer proof\/design directly|Answer proof\/design questions directly|Open answer requirements|Campaign fit|Knowledge base only|Use Thumper from WIZWIKI Marketing|Answer the latest customer message first|Use the supplied comms JSON|Never mention source names|Return exactly one customer-facing SMS body|No markdown)\b[:\s].*\z/im,
        ""
      ).squish
      salvaged.presence || body.squish
    end

    def self.comms_sms_rush_checkout_boundary_rewrite(answer, metadata)
      body = unwrap_comms_sms_answer(answer).squish
      return body if body.blank?

      prompt = [
        metadata["operator_prompt"],
        metadata["guardrail_retry_instruction"],
        metadata.dig("answer_contract", "prompt")
      ].compact.join(" ").downcase
      return body unless prompt.match?(/\b(?:rush|rushed|asap|expedite|next\s+friday|deadline|faster|hurry|hurray)\b/)
      return body unless prompt.match?(/\b(?:normal|standard|regular)\b.{0,50}\b(?:checkout|check\s+out)\b|\b(?:checkout|check\s+out)\b.{0,80}\b(?:rush|rushed|normal|standard|regular)\b/)
      return body if body.downcase.match?(/\b(?:do not|don'?t|dont|should not|shouldn'?t|not|outside|instead)\b.{0,120}\b(?:normal|standard|regular|checkout|check\s+out)\b/)
      return body unless body.downcase.match?(/\brush\b/) && body.downcase.match?(/\b(?:marketing consultant|consultant)\b/)

      "For a rush yard-sign order, do not use the normal checkout. A marketing consultant needs to confirm availability and pricing first; rush starts after proof approval, moves production ahead, and shipping is still usually 2-5 business days by UPS/FedEx Ground. Want me to have a marketing consultant check this with you?"
    end

    def self.unwrap_comms_sms_answer(answer)
      answer.to_s.gsub(comms_sms_wrapper_prefix_pattern, "")
    end

    def self.wrapped_comms_sms_answer?(answer)
      answer.to_s.squish.match?(comms_sms_wrapper_prefix_pattern)
    end

    def self.comms_sms_wrapper_prefix_pattern
      return Comms::SmsBodySafety::ANSWER_WRAPPER_PREFIX_PATTERN if defined?(Comms::SmsBodySafety::ANSWER_WRAPPER_PREFIX_PATTERN)

      /\A(?:(?:here(?:'|’)?s|here\s+is)\s+)?(?:the\s+)?(?:(?:best|strongest|recommended|suggested|cleanest|next|short|quick|final|sendable|customer[-\s]?facing|customer\s+ready)\s+)*(?:sms|text|body|reply|draft|answer|message)(?:\s+(?:sms|text|body|reply|draft|answer|message))*?(?:\s+(?:as|for|to\s+send\s+to|to)\s+[^:\n]{1,140})?\s*:\s*/i
    end
  end
end
