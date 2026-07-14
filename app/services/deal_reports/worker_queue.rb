require "cgi"
require "stringio"
require "securerandom"
require "time"
require "uri"
require "zip"

module DealReports
  module WorkerQueue
    module_function

    MINIMUM_DOCX_BYTES = (ENV["WIZWIKI_REPORT_MINIMUM_DOCX_BYTES"].presence || 12_000).to_i
    WORKER_LEASE_SECONDS = [(ENV["WIZWIKI_REPORT_WORKER_LEASE_SECONDS"].presence || 600).to_i, 120].max
    WORKER_LEASE_STALE_GRACE_SECONDS = [(ENV["WIZWIKI_REPORT_WORKER_STALE_GRACE_SECONDS"].presence || 90).to_i, 0].max
    CanceledError = Class.new(StandardError)
    QualityError = Class.new(StandardError)

    def status_for(worker_id:)
      scope = CrmRecordArtifact.where(artifact_type: "market_report")
      {
        ok: true,
        worker_id: worker_id,
        configured: WizwikiSettings.wizwiki_report_worker_configured?,
        enabled: WizwikiSettings.wizwiki_report_worker_enabled?,
        provider: WizwikiSettings.wizwiki_report_provider,
        target_model: WizwikiSettings.wizwiki_report_target_model,
        report_lanes: WizwikiSettings.report_lane_options,
        report_local_models: WizwikiSettings.report_local_model_options.map { |label, model| { label: label, model: model } },
        report_embedder_models: WizwikiSettings.report_embedder_model_options.map { |label, model| { label: label, model: model } },
        qwen_only: WizwikiSettings.qwen_only?,
        openai_runtime_enabled: WizwikiSettings.openai_runtime_enabled?,
        queued: scope.where(status: "queued").count,
        priority_queued: scope.joins(:crm_record).where(status: "queued").where(priority_report_where_sql).count,
        generating: scope.where(status: "generating").count,
        report_ready: scope.where(status: "report_ready").count,
        canva_kit_ready: scope.where(status: "canva_kit_ready").count,
        ready: scope.where(status: %w[canva_kit_ready ready]).count,
        failed: scope.where(status: "failed").count,
        archived: scope.where(status: "archived").count,
        completed: final_scope(scope).count,
        stale_generating: stale_generating_count(scope),
        worker_lease_seconds: WORKER_LEASE_SECONDS,
        minimum_docx_bytes: MINIMUM_DOCX_BYTES
      }
    end



    def priority_claim_sort_sql
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

    def priority_report_where_sql
      artifact_priority = "LOWER(COALESCE(NULLIF(crm_record_artifacts.metadata ->> 'priority_level', ''), NULLIF(crm_records.priority_level, ''), 'normal'))"
      hubspot = "LOWER(COALESCE(crm_records.properties #>> '{hubspot,labeled_properties,Ticket Priority}', crm_records.properties #>> '{hubspot,properties,hs_ticket_priority}', ''))"

      <<~SQL.squish
        (#{artifact_priority} IN ('urgent', 'priority')
          OR #{hubspot} LIKE '%urgent%'
          OR #{hubspot} LIKE '%critical%'
          OR #{hubspot} LIKE '%rush%'
          OR #{hubspot} LIKE '%asap%'
          OR #{hubspot} LIKE '%high%')
      SQL
    end

    def final_scope(scope)
      scope.where(status: %w[canva_kit_ready ready]).or(
        scope.where(status: "archived").where("metadata -> 'canva_kit' ->> 'storage_key' IS NOT NULL")
      )
    end

    def recent_reports(limit: 25)
      CrmRecordArtifact
        .includes(:crm_record, :user)
        .where(artifact_type: "market_report")
        .order(Arel.sql("CASE WHEN crm_record_artifacts.storage_key IS NULL THEN 1 ELSE 0 END ASC, COALESCE(crm_record_artifacts.generated_at, crm_record_artifacts.created_at) DESC"))
        .limit(limit.to_i.clamp(1, 100))
        .map { |artifact| recent_report_payload(artifact) }
    end

    def claim_next!(worker_id:)
      release_stale_generating!
      artifact = nil

      CrmRecordArtifact.transaction do
        artifact = CrmRecordArtifact
          .joins(:crm_record)
          .where(artifact_type: "market_report", status: "queued")
          .order(Arel.sql(priority_claim_sort_sql))
          .lock("FOR UPDATE SKIP LOCKED")
          .first

        next if artifact.blank?

        now = Time.current
        metadata = artifact.metadata.to_h
        metadata["worker_id"] = worker_id
        metadata["claim_token"] = SecureRandom.hex(24)
        metadata["queued_at"] ||= artifact.created_at.iso8601
        metadata["claimed_at"] = now.iso8601
        metadata["build_started_at"] ||= now.iso8601
        metadata["docx_build_started_at"] ||= now.iso8601
        metadata["queue_wait_seconds"] = duration_seconds(artifact.created_at, now)
        metadata["heartbeat_at"] = now.iso8601
        metadata["lease_expires_at"] = (now + WORKER_LEASE_SECONDS.seconds).iso8601
        metadata["lease_seconds"] = WORKER_LEASE_SECONDS
        metadata["run_id"] ||= run_id_for(artifact)
        metadata["rore_run_id"] ||= metadata["run_id"]
        artifact.update!(status: "generating", metadata: metadata)
      end

      record_run_event!(artifact, "wizwiki.report.claimed", status: "generating", agent: worker_id, payload: {
        report_audience: artifact.metadata.to_h["report_audience"].presence || "client",
        report_lane: artifact.metadata.to_h["report_lane"],
        queue_wait_seconds: artifact.metadata.to_h["queue_wait_seconds"]
      }) if artifact.present?
      artifact
    end

    def heartbeat!(artifact, worker_id:, worker_payload: {})
      return { ok: true, id: artifact.id, status: artifact.status, ignored: true } unless artifact.status == "generating"

      metadata = artifact.metadata.to_h
      validate_claim!(artifact, worker_payload: worker_payload, worker_id: worker_id, metadata: metadata)
      assigned_worker_id = metadata["worker_id"].to_s
      if assigned_worker_id.present? && assigned_worker_id != worker_id.to_s
        raise ArgumentError, "worker mismatch for report #{artifact.id}"
      end

      now = Time.current
      metadata["worker_id"] = worker_id
      metadata["heartbeat_at"] = now.iso8601
      metadata["lease_expires_at"] = (now + WORKER_LEASE_SECONDS.seconds).iso8601
      metadata["lease_seconds"] = WORKER_LEASE_SECONDS
      artifact.update!(metadata: metadata)
      record_run_event!(artifact.reload, "wizwiki.report.heartbeat", status: artifact.status, agent: worker_id, payload: {
        lease_expires_at: metadata["lease_expires_at"],
        worker_lease_seconds: WORKER_LEASE_SECONDS
      })

      {
        ok: true,
        id: artifact.id,
        status: artifact.reload.status,
        lease_expires_at: metadata["lease_expires_at"],
        worker_lease_seconds: WORKER_LEASE_SECONDS
      }
    end

    def release_stale_generating!
      released = []

      stale_generating_artifacts.each do |artifact|
        CrmRecordArtifact.transaction do
          locked = CrmRecordArtifact.lock.find_by(id: artifact.id)
          next if locked.blank?
          next unless locked.status == "generating"
          next unless stale_generating?(locked)

          metadata = locked.metadata.to_h
          metadata["previous_worker_id"] = metadata["worker_id"] if metadata["worker_id"].present?
          metadata["previous_claimed_at"] = metadata["claimed_at"] if metadata["claimed_at"].present?
          metadata.delete("worker_id")
          metadata.delete("heartbeat_at")
          metadata.delete("lease_expires_at")
          metadata["stale_requeued_at"] = Time.current.iso8601
          metadata["stale_requeue_reason"] = "worker lease expired"

          locked.update!(status: "queued", metadata: metadata)
          released << locked.id
        end
      end

      released
    end

    def payload_for(artifact)
      crm_record = artifact.crm_record
      hubspot = crm_record.properties.to_h.fetch("hubspot", {}).to_h
      labeled = hubspot.fetch("labeled_properties", {}).to_h
      raw = hubspot.fetch("properties", {}).to_h
      full_properties = compact_hash(raw)
      labeled_properties = compact_hash(labeled)
      selected_report_model = report_local_model_for(artifact)
      selected_model_ladder = report_model_ladder_for(artifact, selected_report_model)
      selected_report_model_label = WizwikiSettings.report_local_model_label(selected_report_model)
      selected_embedder_model = report_embedder_model_for(artifact)
      selected_embedder_model_label = WizwikiSettings.report_embedder_model_label(selected_embedder_model)
      copy_maker_cloud_provider = artifact.metadata.to_h["copy_maker_cloud_provider"].presence || "nvidia"
      copy_maker_openai_selected = artifact.metadata.to_h["report_audience"].to_s == "copy_maker" && copy_maker_cloud_provider == "openai"
      copy_maker_qwen_selected = artifact.metadata.to_h["report_audience"].to_s == "copy_maker" && copy_maker_qwen_provider?(copy_maker_cloud_provider)
      contact_intelligence = DealReports::ContactIntelligence.for_record(
        crm_record,
        direction: artifact.metadata.to_h["copy_maker_comm_kit_direction"].presence || "wizwiki_out"
      )
      industry_strategy = industry_strategy_payload(artifact, crm_record, labeled, raw)
      voice_training = voice_training_payload(artifact, selected_embedder_model)
      weather_opportunity = report_weather_opportunity_payload(artifact, crm_record)
      record_run_event!(artifact, "wizwiki.report.payload_ready", status: artifact.status, agent: artifact.metadata.to_h["worker_id"], payload: {
        report_audience: artifact.metadata.to_h["report_audience"].presence || "client",
        model_ladder: selected_model_ladder,
        local_model: selected_report_model,
        embedder_model: selected_embedder_model,
        industry_strategy: industry_strategy["label"],
        industry_strategy_confidence: industry_strategy["confidence"],
        weather_opportunity_active: weather_opportunity["active"],
        voice_training_documents: voice_training[:document_count],
        voice_training_indexed_documents: voice_training[:indexed_count],
        hubspot_property_count: full_properties.size,
        media_count: crm_record.deal_media.attachments.count
      }, memory: {
        surface: "RPT",
        brain_type: "market_report",
        organization_id: artifact.organization_id,
        crm_record_id: crm_record.id,
        title: artifact.title
      })

      {
        id: artifact.id,
        artifact_type: artifact.artifact_type,
        title: artifact.title,
        status: artifact.status,
        queued_at: artifact.created_at.iso8601,
        metadata: artifact.metadata.to_h.slice(
          "report_number", "report_audience", "report_mode", "requested_output", "queued_by", "queued_by_phone", "queued_from",
          "report_lane", "report_lane_label", "report_lane_description", "report_model_ladder", "report_model_flow",
          "report_local_model", "report_local_model_label", "target_model", "ai_provider",
          "report_embedder_model", "report_embedder_model_label", "embedding_provider",
          "report_preflight_scan_enabled", "report_preflight_vision_model", "report_preflight_ocr_model",
          "report_post_review_enabled", "report_post_review_model",
          "report_page_visual_qa_enabled", "report_page_visual_qa_model", "report_page_visual_qa_renderer",
          "report_design_press_enabled", "report_design_press_stage", "report_design_press_template",
          "report_design_press_style", "report_design_press_output", "report_design_press_notes",
          "report_design_press_renderer",
          "report_context_prompt",
          "industry_strategy_lens", "industry_strategy", "industry_strategy_label", "industry_strategy_detected",
          "industry_strategy_confidence", "industry_strategy_campaigns", "industry_strategy_output_sections",
          "weather_opportunity", "weather_opportunity_active", "weather_opportunity_summary",
          "copy_maker_enabled", "copy_maker_prompt", "copy_maker_cloud_provider", "copy_maker_cloud_label",
          "copy_maker_cloud_model", "copy_maker_cloud_base_url", "copy_maker_cloud_api_key_env", "copy_maker_pipeline",
          "copy_maker_comm_kit_enabled", "copy_maker_local_prep_enabled", "copy_maker_deliverables", "copy_maker_comm_kit_contract", "copy_maker_sender_profile",
          "priority_level", "priority_label", "priority_source", "priority_note", "priority_marked_at", "priority_marked_by"
        ),
        deal: deal_payload(crm_record, labeled, raw, artifact),
        company: company_payload(crm_record, labeled, raw, artifact),
        commerce: commerce_payload(crm_record, labeled),
        timing_context: timing_context_payload,
        ai_runtime: {
          provider: WizwikiSettings.wizwiki_report_provider,
          target_model: selected_report_model,
          local_model: selected_report_model,
          local_model_label: selected_report_model_label,
          model_ladder: selected_model_ladder,
          report_rounds: selected_model_ladder.size,
          pipeline_mode: "dynamic_two_round_rag",
          retry_context_strategy: "vectorize_hubspot_facts_first_draft_and_quality_errors_before_second_round",
          scout_model: selected_model_ladder.first,
          frontier_model: selected_model_ladder.last,
          preflight_visual_scan_enabled: truthy_manifest_value?(artifact.metadata.to_h["report_preflight_scan_enabled"]),
          preflight_vision_model: artifact.metadata.to_h["report_preflight_vision_model"].presence || "qwen3-vl:8b",
          preflight_ocr_model: artifact.metadata.to_h["report_preflight_ocr_model"].presence || "glm-ocr:bf16",
          post_generation_review_enabled: truthy_manifest_value?(artifact.metadata.to_h["report_post_review_enabled"]),
          post_generation_review_model: artifact.metadata.to_h["report_post_review_model"].presence || selected_report_model,
          page_visual_qa_enabled: truthy_manifest_value?(artifact.metadata.to_h["report_page_visual_qa_enabled"]),
          page_visual_qa_model: artifact.metadata.to_h["report_page_visual_qa_model"].presence || "qwen3-vl:8b",
          page_visual_qa_renderer: artifact.metadata.to_h["report_page_visual_qa_renderer"].presence || "libreoffice+poppler",
          design_press_enabled: truthy_manifest_value?(artifact.metadata.to_h["report_design_press_enabled"]),
          design_press_template: artifact.metadata.to_h["report_design_press_template"].presence || "market_one_sheet",
          design_press_style: artifact.metadata.to_h["report_design_press_style"].presence || "wizwiki_clean",
          design_press_output: artifact.metadata.to_h["report_design_press_output"].presence || "print_png_pdf",
          design_press_renderer: artifact.metadata.to_h["report_design_press_renderer"].presence || "alice-design-press",
          report_context_prompt: artifact.metadata.to_h["report_context_prompt"].presence,
          industry_strategy: industry_strategy,
          weather_opportunity: weather_opportunity,
          contact_intelligence: contact_intelligence,
          voice_training: voice_training.slice(:enabled, :document_count, :indexed_count, :embedding_model, :scope, :source_type, :required_when_available),
          copy_maker_enabled: truthy_manifest_value?(artifact.metadata.to_h["copy_maker_enabled"]),
          copy_maker_comm_kit_enabled: truthy_manifest_value?(artifact.metadata.to_h["copy_maker_comm_kit_enabled"]),
          copy_maker_local_prep_enabled: truthy_manifest_value?(artifact.metadata.to_h["copy_maker_local_prep_enabled"]),
          copy_maker_deliverables: Array(artifact.metadata.to_h["copy_maker_deliverables"]).presence || [],
          copy_maker_comm_kit_contract: artifact.metadata.to_h["copy_maker_comm_kit_contract"].presence,
          copy_maker_cloud_provider: artifact.metadata.to_h["copy_maker_cloud_provider"].presence,
          copy_maker_cloud_label: artifact.metadata.to_h["copy_maker_cloud_label"].presence,
          copy_maker_cloud_model: artifact.metadata.to_h["copy_maker_cloud_model"].presence,
          copy_maker_cloud_base_url: artifact.metadata.to_h["copy_maker_cloud_base_url"].presence,
          copy_maker_cloud_api_key_env: artifact.metadata.to_h["copy_maker_cloud_api_key_env"].presence,
          copy_maker_sender_profile: artifact.metadata.to_h["copy_maker_sender_profile"].presence,
          qwen_only: WizwikiSettings.qwen_only?,
          openai_allowed: WizwikiSettings.openai_runtime_enabled? || copy_maker_openai_selected,
          force_local: WizwikiSettings.qwen_only?,
          forbidden_providers: WizwikiSettings.qwen_only? && !copy_maker_openai_selected ? ["openai"] : [],
          runtime_note: if copy_maker_openai_selected
            "Copy Maker job selected OpenAI for the final cloud copy pass after local CRM-aware prep. Alice must use OPENAI_API_KEY privately and must not include credentials in output."
                        elsif copy_maker_qwen_selected
            "Copy Maker job selected #{artifact.metadata.to_h["copy_maker_cloud_label"].presence || "Qwen Local"} for both source-aware prep and final visible copy. No cloud API key is required for the final pass."
                        elsif WizwikiSettings.qwen_only?
            "Local-only report job. Do not call OpenAI. Complete manifest must report provider qwen/local and the selected local model: #{selected_report_model}."
                        else
            "Use configured report runtime."
                        end
        },
        embedding_runtime: {
          provider: "ollama/local",
          model: selected_embedder_model,
          model_label: selected_embedder_model_label,
          purpose: "Retrieve, rank, and condense HubSpot ticket/company/media/weather context chunks plus Thumper fine-training voice chunks before report writing.",
          selected_by: "WIZWIKI RPT lane selector",
          required: false,
          voice_training_required_when_available: voice_training[:required_when_available],
          voice_training_scope: voice_training[:scope],
          voice_training_source_type: voice_training[:source_type],
          fallback: "If the requested embedder is unavailable, use qwen3-embedding:4b balanced fallback mode and report embedder_model_fallback in the manifest.",
          first_round_sources: ["thumper_voice_training", "fine_training_documents", "weather_storm_watch", "hubspot_labeled_properties", "hubspot_raw_properties", "deal", "company", "industry_strategy_playbook", "account_graph", "playbook_calls", "uploaded_media", "report_contract"],
          second_round_sources: ["thumper_voice_training", "fine_training_documents", "weather_storm_watch", "hubspot_labeled_properties", "hubspot_raw_properties", "industry_strategy_playbook", "playbook_calls", "first_draft_copy", "quality_errors", "validator_retry_note"],
          retry_context_strategy: "Vectorize the first draft plus validation errors together with HubSpot facts and Thumper voice-training rules before the second LLM pass. Do not vectorize validation errors alone."
        },
        voice_training: voice_training,
        copy_maker: copy_maker_payload(artifact, selected_report_model, selected_embedder_model, voice_training),
        design_press_runtime: {
          enabled: truthy_manifest_value?(artifact.metadata.to_h["report_design_press_enabled"]),
          stage: artifact.metadata.to_h["report_design_press_stage"].presence || "off",
          template: artifact.metadata.to_h["report_design_press_template"].presence || "market_one_sheet",
          style: artifact.metadata.to_h["report_design_press_style"].presence || "wizwiki_clean",
          output: artifact.metadata.to_h["report_design_press_output"].presence || "print_png_pdf",
          renderer: artifact.metadata.to_h["report_design_press_renderer"].presence || "alice-design-press",
          notes: artifact.metadata.to_h["report_design_press_notes"].presence,
          canvas: "8.5x11 portrait",
          purpose: "Create a press-ready visual report output after the strategy copy is validated. Keep the strategy factual; use the visual stage for layout, typography, image placement, and print polish."
        },
        generation_prompt: generation_prompt_payload(artifact, crm_record, labeled, raw),
        industry_strategy: industry_strategy,
        weather_opportunity: weather_opportunity,
        campaign_context: campaign_context_payload(artifact, crm_record, labeled, raw),
        account_graph: account_graph_payload(crm_record),
        contact_intelligence: contact_intelligence,
        playbook_context: playbook_context_payload(crm_record),
        hubspot_context: {
          labeled_properties: labeled_properties,
          raw_properties: full_properties,
          label_property_names: hubspot.fetch("label_property_names", {}).to_h,
          missing_core_fields: missing_core_fields(labeled, raw),
          property_count: full_properties.size
        },
        report_contract: report_contract_payload(artifact, crm_record, labeled, raw),
        assets: {
          agency_logo: agency_logo_payload,
          logo_url: logo_url_for(crm_record),
          logo_endpoint: "/wizwiki_worker/reports/#{artifact.id}/logo",
          uploaded_media: media_payload(artifact, crm_record)
        },
        output: {
          claim_token: artifact.metadata.to_h["claim_token"],
          expected_content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          preferred_extension: "docx",
          minimum_docx_bytes: MINIMUM_DOCX_BYTES,
          heartbeat_endpoint: "/wizwiki_worker/reports/#{artifact.id}/heartbeat",
          complete_endpoint: "/wizwiki_worker/reports/#{artifact.id}/complete",
          complete_transport: "application/json or multipart/form-data",
          complete_transport_note: "For file_base64/document_base64 payloads, POST application/json. Do not use application/x-www-form-urlencoded; large DOCX payloads exceed Rack form query limits before Rails can parse them.",
          fail_endpoint: "/wizwiki_worker/reports/#{artifact.id}/fail"
        },
        claim_token: artifact.metadata.to_h["claim_token"]
      }
    end

    def report_local_model_for(artifact)
      metadata = artifact.metadata.to_h
      WizwikiSettings.normalize_report_local_model(
        metadata["report_local_model"].presence || metadata["target_model"].presence || WizwikiSettings.qwen_model
      )
    end

    def report_embedder_model_for(artifact)
      metadata = artifact.metadata.to_h
      WizwikiSettings.normalize_report_embedder_model(
        metadata["report_embedder_model"].presence || metadata["embedding_model"].presence || WizwikiSettings.report_embedder_model
      )
    end

    def report_model_ladder_for(artifact, selected_model)
      metadata_ladder = Array(artifact.metadata.to_h["report_model_ladder"])
        .map { |model| WizwikiSettings.normalize_report_local_model(model) }
        .reject(&:blank?)
      return metadata_ladder if metadata_ladder.present?

      [WizwikiSettings.normalize_report_local_model(selected_model)]
    end

    def copy_maker_qwen_provider?(provider)
      provider.to_s.start_with?("qwen")
    end

    def copy_maker_cloud_label_for(provider, metadata)
      metadata["copy_maker_cloud_label"].presence ||
        case provider.to_s
        when "qwen" then "Qwen Local 8B"
        when "qwen_9b" then "Qwen Local 9B MLX"
        when "qwen_30b" then "Qwen Local 30B"
        when "qwen_35b" then "Qwen Local 35B MLX"
        when "openai" then "OpenAI"
        else "NVIDIA Nemotron"
        end
    end

    def copy_maker_cloud_model_for(provider, metadata)
      metadata["copy_maker_cloud_model"].presence ||
        case provider.to_s
        when "qwen" then "qwen3:8b"
        when "qwen_9b" then "qwen3.5:9b-mlx"
        when "qwen_30b" then "qwen3:30b"
        when "qwen_35b" then "qwen3.6:35b-mlx"
        when "openai" then WizwikiSettings.openai_model
        else "nvidia/nemotron-3-ultra-550b-a55b"
        end
    end

    def voice_training_payload(artifact, selected_embedder_model, limit: 12)
      organization = artifact.organization || artifact.crm_record&.organization
      return { enabled: false, reason: "organization_missing", source_type: "TrainingDocument" } if organization.blank?

      documents = organization.training_documents.where.not(status: "archived")
      document_count = documents.count
      indexed_count = documents.where(status: "indexed").count
      processing_count = documents.where(status: "processing").count
      chunk_counts = {}
      if defined?(AutosEmbeddingChunk) && Autos::EmbeddingQueue.storage_ready?
        chunk_counts = AutosEmbeddingChunk.where(
          organization: organization,
          source_type: "TrainingDocument",
          source_id: documents.select(:id),
          embedding_model: selected_embedder_model
        ).group(:status).count
      end
      sample_scope = documents.where(status: "indexed")
      sample_scope = documents if sample_scope.none?
      sample_documents = sample_scope.order(updated_at: :desc).limit(limit).map do |document|
        {
          id: document.id,
          title: document.title,
          file_name: document.file_name,
          status: document.status,
          source_type: document.source_type,
          training_kind: document.metadata.to_h["training_kind"],
          body_sample: document.body.to_s.squish.truncate(700)
        }.compact_blank
      end
      inventory_titles = documents.order(:title).limit(250).pluck(:title).compact_blank

      {
        enabled: document_count.positive?,
        required_when_available: document_count.positive?,
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        source_type: "TrainingDocument",
        embedding_model: selected_embedder_model,
        brain_types: %w[wizwiki_ask market_report wizwiki_comms comms common],
        document_count: document_count,
        indexed_count: indexed_count,
        processing_count: processing_count,
        chunk_counts: chunk_counts,
        inventory_titles: inventory_titles,
        sample_documents: sample_documents,
        retrieval_policy: [
          "Before writing visible copy, retrieve semantically relevant organization-owned TrainingDocument chunks from the configured WIZWIKI scope.",
          "Use documents marked training_priority=paramount first, but treat them as operator guidance rather than independent factual authority.",
          Thumper::VoiceGuide.system,
          "If semantic retrieval returns no voice chunks, use the paramount sample_documents and inventory as fallback style guardrails.",
          "Do not quote internal file names or training inventory in client-facing output."
        ],
        writing_policy: Thumper::VoiceGuide.email_prompt
      }
    rescue StandardError => error
      {
        enabled: false,
        required_when_available: false,
        source_type: "TrainingDocument",
        embedding_model: selected_embedder_model,
        error: error.message.to_s.truncate(180)
      }
    end

    def copy_maker_payload(artifact, selected_report_model, selected_embedder_model, voice_training = nil)
      metadata = artifact.metadata.to_h
      enabled = metadata["report_audience"].to_s == "copy_maker" || truthy_manifest_value?(metadata["copy_maker_enabled"])
      provider = metadata["copy_maker_cloud_provider"].presence || "nvidia"
      openai = provider == "openai"
      qwen = copy_maker_qwen_provider?(provider)
      {
        enabled: enabled,
        prompt: metadata["copy_maker_prompt"].presence || metadata["report_context_prompt"].presence,
        report_context_prompt: metadata["report_context_prompt"].presence,
        local_embedder_model: selected_embedder_model,
        local_llm_model: selected_report_model,
        voice_training: voice_training,
        local_prep_required: enabled && truthy_manifest_value?(metadata.fetch("copy_maker_local_prep_enabled", true)),
        comm_kit_enabled: truthy_manifest_value?(metadata["copy_maker_comm_kit_enabled"]),
        comm_kit_direction: metadata["copy_maker_comm_kit_direction"].presence || "wizwiki_out",
        comm_kit_direction_label: metadata["copy_maker_comm_kit_direction_label"].presence || "WIZWIKI OUT",
        industry_strategy: metadata["industry_strategy"].presence,
        sender_profile: metadata["copy_maker_sender_profile"].presence || {
          "name" => metadata["queued_by"],
          "phone" => metadata["queued_by_phone"]
        }.compact_blank,
        deliverables: Array(metadata["copy_maker_deliverables"]).presence || [],
        comm_kit_contract: metadata["copy_maker_comm_kit_contract"].presence,
        cloud_provider: provider,
        cloud_label: copy_maker_cloud_label_for(provider, metadata),
        cloud_base_url: metadata["copy_maker_cloud_base_url"].presence || (openai ? "https://api.openai.com/v1" : (qwen ? "http://127.0.0.1:11434" : "https://integrate.api.nvidia.com/v1")),
        cloud_model: copy_maker_cloud_model_for(provider, metadata),
        api_key_env: metadata["copy_maker_cloud_api_key_env"].presence || (openai ? "OPENAI_API_KEY" : (qwen ? nil : "NVIDIA_API_KEY")),
        pipeline: metadata["copy_maker_pipeline"].presence || (qwen ? "local_embedder_local_llm_prep_then_qwen_local_copy" : "local_embedder_local_llm_prep_then_#{provider}_cloud_copy"),
        safety: qwen ? "No cloud API key is required for Qwen Local Copy Maker. Do not include private metadata or credentials in the output or manifest." : "Do not include credentials in the payload or manifest. Alice must read the cloud API key from private environment variables."
      }
    end

    def complete!(artifact, file:, filename:, content_type:, manifest:, worker_payload:)
      completion_signal_at = Time.current
      initial_metadata = artifact.metadata.to_h
      validate_claim!(artifact, worker_payload: worker_payload, worker_id: worker_payload["worker_id"], metadata: initial_metadata)
      build_started_at = parse_worker_time(initial_metadata["build_started_at"]) ||
        parse_worker_time(initial_metadata["docx_build_started_at"]) ||
        parse_worker_time(initial_metadata["claimed_at"]) ||
        artifact.created_at
      docx_build_started_at = parse_worker_time(initial_metadata["docx_build_started_at"]) || build_started_at

      quality = quality_result_for(file: file, manifest: manifest, artifact: artifact)
      if quality[:errors].any?
        fail!(
          artifact,
          error: "quality rejected: #{quality[:errors].join('; ')}",
          worker_payload: worker_payload.merge("quality" => quality)
        )
        raise QualityError, quality[:errors].join("; ")
      end

      published = DealReports::Publisher.publish!(
        artifact: artifact,
        file: file,
        filename: filename,
        content_type: content_type,
        manifest: manifest
      )

      docx_published_at = Time.current
      sanitized_worker_payload = worker_payload.except("file_base64", "file", "document_base64")
      selected_model = artifact.metadata.to_h["report_local_model"].to_s
      actual_model = manifest["model"].presence || quality[:model].presence || sanitized_worker_payload["model"].presence
      copy_maker_report = artifact.metadata.to_h["report_audience"].to_s == "copy_maker"
      model_mismatch = !copy_maker_report && selected_model.present? && actual_model.present? && selected_model != actual_model.to_s

      metadata = artifact.metadata.to_h.merge(
        "report_ready_at" => docx_published_at.iso8601,
        "docx_finished_at" => completion_signal_at.iso8601,
        "docx_published_at" => docx_published_at.iso8601,
        "docx_build_seconds" => duration_seconds(docx_build_started_at, completion_signal_at),
        "worker_payload" => sanitized_worker_payload,
        "manifest" => manifest,
        "publisher" => published,
        "quality" => quality,
        "actual_report_model" => actual_model,
        "report_model_mismatch" => model_mismatch,
        "report_model_mismatch_note" => (model_mismatch ? "Selected #{selected_model}, but worker completed with #{actual_model}." : nil),
        "processing_stage" => "report_ready_building_canva_kit"
      ).except("claim_token")

      artifact.update!(
        status: "report_ready",
        generated_at: Time.current,
        storage_provider: published[:storage_provider],
        storage_bucket: published[:storage_bucket],
        storage_key: published[:storage_key],
        file_url: published[:file_url],
        content_type: content_type.presence || published[:content_type],
        byte_size: published[:byte_size],
        metadata: metadata
      )

      canva_kit_started_at = Time.current
      kit = DealReports::CanvaKit.build!(
        artifact: artifact.reload,
        report_file: file,
        report_filename: filename.presence || "market_strategy_report.docx",
        manifest: manifest,
        published: published
      )

      kit_published = DealReports::Publisher.publish_sidecar!(
        artifact: artifact,
        file: kit.file,
        filename: kit.filename,
        content_type: kit.content_type,
        file_url: "/leads/reports/#{artifact.id}/canva-kit"
      )

      canva_kit_finished_at = Time.current
      timing = artifact.metadata.to_h.fetch("timing", {}).to_h.merge(
        "queued_at" => artifact.created_at.iso8601,
        "build_started_at" => build_started_at.iso8601,
        "docx_build_started_at" => docx_build_started_at.iso8601,
        "docx_finished_at" => completion_signal_at.iso8601,
        "docx_published_at" => docx_published_at.iso8601,
        "canva_kit_started_at" => canva_kit_started_at.iso8601,
        "canva_kit_finished_at" => canva_kit_finished_at.iso8601,
        "completed_at" => canva_kit_finished_at.iso8601,
        "queue_wait_seconds" => duration_seconds(artifact.created_at, build_started_at),
        "docx_build_seconds" => duration_seconds(docx_build_started_at, completion_signal_at),
        "docx_publish_seconds" => duration_seconds(completion_signal_at, docx_published_at),
        "canva_kit_build_seconds" => duration_seconds(canva_kit_started_at, canva_kit_finished_at),
        "total_build_seconds" => duration_seconds(build_started_at, canva_kit_finished_at),
        "total_elapsed_seconds" => duration_seconds(artifact.created_at, canva_kit_finished_at)
      )

      final_metadata = artifact.metadata.to_h.merge(
        "completed_at" => canva_kit_finished_at.iso8601,
        "canva_kit_started_at" => canva_kit_started_at.iso8601,
        "canva_kit_finished_at" => canva_kit_finished_at.iso8601,
        "canva_kit_build_seconds" => timing["canva_kit_build_seconds"],
        "total_build_seconds" => timing["total_build_seconds"],
        "total_elapsed_seconds" => timing["total_elapsed_seconds"],
        "timing" => timing,
        "processing_stage" => "canva_kit_ready",
        "canva_kit" => kit_published.merge(
          "filename" => kit.filename,
          "manifest" => kit.manifest,
          "created_at" => canva_kit_finished_at.iso8601,
          "build_seconds" => timing["canva_kit_build_seconds"]
        )
      )

      artifact.update!(
        status: "canva_kit_ready",
        metadata: final_metadata
      )
      record_run_event!(artifact.reload, "wizwiki.report.complete", status: "canva_kit_ready", agent: artifact.metadata.to_h["worker_id"], payload: {
        provider: manifest["provider"],
        model: manifest["model"],
        embedder_model: manifest["embedder_model"].presence || artifact.metadata.to_h["report_embedder_model"],
        byte_size: artifact.byte_size,
        storage_key: artifact.storage_key,
        canva_kit_storage_key: artifact.metadata.to_h.dig("canva_kit", "storage_key"),
        total_elapsed_seconds: timing["total_elapsed_seconds"]
      })

      Canva::ReportAutofill.call(artifact.reload) if WizwikiSettings.canva_auto_build_enabled?
    ensure
      kit&.file&.close!
    end

    def fail!(artifact, error:, worker_payload: {})
      validate_claim!(artifact, worker_payload: worker_payload, worker_id: worker_payload["worker_id"])

      metadata = artifact.metadata.to_h.merge(
        "failed_at" => Time.current.iso8601,
        "error" => error.to_s.first(2_000),
        "worker_payload" => worker_payload.except("file_base64", "file", "document_base64")
      ).except("claim_token")
      artifact.update!(status: "failed", metadata: metadata)
      record_run_event!(artifact.reload, "wizwiki.report.failed", status: "failed", agent: metadata["worker_id"], payload: {
        error: error.to_s.truncate(500),
        stage: metadata["processing_stage"],
        model: worker_payload["model"].presence || metadata["actual_report_model"],
        provider: worker_payload["provider"]
      })
    end

    def validate_claim!(artifact, worker_payload:, worker_id: nil, metadata: nil)
      metadata ||= artifact.metadata.to_h
      expected = metadata["claim_token"].to_s
      supplied = worker_payload.to_h["claim_token"].to_s
      raise ArgumentError, "report claim token missing" if expected.blank? || supplied.blank?

      unless expected.bytesize == supplied.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
        raise ArgumentError, "report claim token mismatch"
      end

      assigned_worker = metadata["worker_id"].to_s
      return true if worker_id.blank? || assigned_worker.blank? || assigned_worker == worker_id.to_s

      raise ArgumentError, "report worker mismatch"
    end

    def stale_generating_count(scope)
      stale_generating_artifacts(scope).size
    end

    def stale_generating_artifacts(scope = CrmRecordArtifact.where(artifact_type: "market_report"))
      scope
        .where(artifact_type: "market_report", status: "generating", generated_at: nil)
        .where(storage_key: [nil, ""])
        .to_a
        .select { |artifact| stale_generating?(artifact) }
    end

    def stale_generating?(artifact)
      metadata = artifact.metadata.to_h
      lease_expires_at = parse_worker_time(metadata["lease_expires_at"])
      return lease_expires_at < Time.current if lease_expires_at.present?

      claimed_at = parse_worker_time(metadata["claimed_at"])
      cutoff = Time.current - (WORKER_LEASE_SECONDS + WORKER_LEASE_STALE_GRACE_SECONDS).seconds
      return claimed_at < cutoff if claimed_at.present?

      artifact.updated_at.present? && artifact.updated_at < cutoff
    end


    def duration_seconds(start_time, end_time)
      start_at = start_time.is_a?(Time) ? start_time : parse_worker_time(start_time)
      end_at = end_time.is_a?(Time) ? end_time : parse_worker_time(end_time)
      return unless start_at.present? && end_at.present?

      [(end_at - start_at).round, 0].max
    end

    def parse_worker_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def logo_url_for(crm_record)
      hubspot = crm_record.properties.to_h.fetch("hubspot", {}).to_h
      labeled = hubspot.fetch("labeled_properties", {}).to_h
      value = labeled["Free Postcard Logo"].to_s.strip
      uri = URI.parse(value)
      value if uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      nil
    end

    def logo_attachment_for(crm_record)
      attachments = crm_record.deal_media.attachments.to_a
      images = attachments.select { |attachment| attachment.blob.content_type.to_s.start_with?("image/") }
      images.find { |attachment| attachment.filename.to_s.downcase.include?("logo") } || images.first
    end

    def media_payload(artifact, crm_record)
      crm_record.deal_media.attachments.map do |attachment|
        {
          id: attachment.id,
          filename: attachment.filename.to_s,
          content_type: attachment.blob.content_type,
          byte_size: attachment.blob.byte_size,
          created_at: attachment.created_at&.iso8601,
          role: attachment == logo_attachment_for(crm_record) ? "logo_candidate" : "supporting_media",
          endpoint: "/wizwiki_worker/reports/#{artifact.id}/media/#{attachment.id}"
        }
      end
    end

    def agency_logo_payload
      {
        name: "WIZWIKI MARKETING agency logo",
        required: true,
        endpoint: "/wizwiki_worker/agency_logo",
        preferred_local_filenames: ["logo.svg", "wizwiki-logo.svg", "wizwiki-marketing-logo.svg"],
        preferred_local_search_roots: ["WIZWIKI report worker directory", "~/.config/autos", "~/.config/autos/reports/wizwiki"],
        placement: ["cover header lockup", "running footer or final signature"],
        alt_text: "WIZWIKI MARKETING",
        report_byline: "Generated by WIZWIKI",
        fallback: "If the local logo.svg exists in the report worker directory, use it first. Otherwise fetch this endpoint. Record agency_logo_embedded and agency_logo_source in the manifest."
      }
    end

    def recent_report_payload(artifact)
      manifest = artifact.metadata.to_h.fetch("manifest", {}).to_h
      publisher = artifact.metadata.to_h.fetch("publisher", {}).to_h
      quality = artifact.metadata.to_h.fetch("quality", {}).to_h
      canva_kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h

      {
        artifact_id: artifact.id,
        deal_id: artifact.crm_record_id,
        deal_name: artifact.crm_record&.name,
        title: manifest["report_title"].presence || artifact.title,
        status: artifact.status,
        report_audience: artifact.metadata.to_h["report_audience"].presence || "client",
        local_path: manifest["local_path"],
        file_url: canva_kit["file_url"].presence || artifact.file_url.presence || publisher["file_url"],
        docx_file_url: artifact.file_url.presence || publisher["file_url"],
        storage_provider: artifact.storage_provider.presence || publisher["storage_provider"],
        storage_bucket: artifact.storage_bucket.presence || publisher["storage_bucket"],
        storage_key: artifact.storage_key.presence || publisher["storage_key"],
        byte_size: artifact.byte_size.presence || publisher["byte_size"].presence || manifest["byte_size"].presence || quality["byte_size"],
        canva_kit: canva_kit.slice("file_url", "storage_key", "byte_size", "filename", "content_type", "created_at", "build_seconds"),
        timing: artifact.metadata.to_h.fetch("timing", {}).to_h,
        model: manifest["model"].presence || quality["model"],
        provider: manifest["provider"],
        embedder_model: manifest["embedder_model"].presence || artifact.metadata.to_h["report_embedder_model"],
        embedding_provider: manifest["embedding_provider"].presence || artifact.metadata.to_h["embedding_provider"],
        generated_at: artifact.generated_at&.iso8601 || manifest["generated_at"],
        completed_at: artifact.metadata.to_h["completed_at"].presence || manifest["generated_at"],
        logo_embedded: manifest["logo_embedded"] == true,
        logo_reason: manifest["logo_reason"].presence || manifest.dig("media", "logo_reason"),
        quality: {
          errors: Array(quality["errors"]) + Array(manifest["quality_errors"]),
          warnings: Array(quality["warnings"]) + Array(manifest["quality_warnings"]),
          signature: quality["signature"].presence || manifest["docx_signature"],
          minimum_docx_bytes: quality["minimum_docx_bytes"].presence || manifest["minimum_docx_bytes"]
        },
        source: {
          worker_id: manifest["worker_id"].presence || artifact.metadata.to_h["worker_id"],
          requested_by: artifact.user&.display_name,
          created_at: artifact.created_at.iso8601
        }
      }
    end

    def deal_payload(crm_record, labeled, raw, artifact = nil)
      company_name = effective_company_name(crm_record, labeled, raw, artifact)
      {
        id: crm_record.id,
        hubspot_id: crm_record.source_uid,
        name: crm_record.name,
        company_name: company_name,
        stage: crm_record.stage,
        status: crm_record.status,
        amount: crm_record.amount&.to_s,
        close_date: crm_record.close_date&.iso8601,
        source: crm_record.source,
        source_uid: crm_record.source_uid,
        created_at: crm_record.created_at.iso8601,
        updated_at: crm_record.updated_at.iso8601,
        priority_level: crm_record.effective_priority_level,
        priority_label: crm_record.effective_priority_level == "urgent" ? "URGENT" : crm_record.effective_priority_level == "priority" ? "PRIORITY" : "STANDARD",
        priority_source: crm_record.priority_source,
        priority_note: crm_record.priority_note,
        hubspot_ticket_priority: crm_record.hubspot_ticket_priority
      }
    end

    def company_payload(crm_record, labeled, raw, artifact = nil)
      company_record = preferred_company_record(crm_record)
      company_properties = hubspot_properties_for(company_record)
      {
        name: effective_company_name(crm_record, labeled, raw, artifact),
        status: labeled["Company Status"].presence || company_properties["lifecyclestage"],
        new_company: labeled["New Company"],
        website_url: labeled["Website URL"].presence || raw["website"].presence || raw["website_url"].presence || company_properties["website"].presence || company_record&.domain,
        industry: labeled["Industry"].presence || raw["industry"].presence || company_properties["industry"].presence || company_properties["hs_industry_group"].presence || infer_company_industry(effective_company_name(crm_record, labeled, raw, artifact), company_record),
        crm_used: labeled["CRM Used"],
        latest_traffic_source: labeled["Latest Traffic Source"],
        last_contacted: labeled["Last Contacted"],
        deal_owner: labeled["Deal owner"]
      }
    end

    def effective_company_name(crm_record, labeled, raw, artifact = nil)
      company_record = preferred_company_record(crm_record)
      company_properties = hubspot_properties_for(company_record)
      labeled["Company Name"].presence ||
        raw["company_name"].presence ||
        raw["company"].presence ||
        artifact&.metadata.to_h["company_name"].presence ||
        company_properties["name"].presence ||
        company_record&.name.presence ||
        crm_record.name
    end

    def preferred_company_record(crm_record)
      return crm_record if crm_record&.record_type == "company"

      associated_record_edges(crm_record).map { |edge| edge[:record] }.find { |record| record&.record_type == "company" }
    rescue StandardError
      nil
    end

    def hubspot_properties_for(record)
      record&.properties.to_h.fetch("hubspot", {}).to_h.fetch("properties", {}).to_h
    end

    def infer_company_industry(company_name, company_record = nil)
      haystack = [company_name, company_record&.name, company_record&.domain].compact.join(" ").downcase
      case haystack
      when /mechanical|hvac|heating|cooling|air\s*conditioning|furnace|ventilation/
        "HVAC and mechanical services"
      when /plumb|drain|sewer|water\s*heater/
        "plumbing services"
      when /roof|gutter|siding|exterior/
        "roofing and exterior services"
      when /electric|electrical|solar/
        "electrical services"
      when /landscap|lawn|mow|tree|irrigation/
        "landscaping and lawn care services"
      when /pool|spa/
        "pool and spa services"
      when /clean|maid|janitorial|restoration|pressure\s*wash/
        "cleaning and restoration services"
      when /pest|termite/
        "pest control services"
      else
        "local home and property services"
      end
    end

    def commerce_payload(crm_record, labeled)
      {
        amount: crm_record.amount&.to_s,
        quote_purchase_link: labeled["Quote Purchase Link"],
        shopify_payment_link: labeled["Shopify Payment Link"],
        shopify_order: labeled["Shopify Order?"],
        monday_order_number: labeled["Monday Order Number"]
      }
    end

    def account_graph_payload(crm_record)
      associations = associated_record_edges(crm_record).map do |edge|
        association = edge[:association]
        record = edge[:record]
        next if record.blank?

        hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
        properties = hubspot.fetch("properties", {}).to_h
        {
          association_type: association.association_type,
          association_direction: edge[:direction],
          record_type: record.record_type,
          name: record.name,
          source: record.source,
          source_uid: record.source_uid,
          email: record.record_type == "contact" ? record.email : nil,
          domain: record.record_type == "company" ? record.domain : nil,
          amount: record.record_type == "deal" ? record.amount&.to_s : nil,
          stage: record.stage,
          status: record.status,
          hubspot_properties: compact_hash(properties)
        }.compact
      end.compact

      {
        companies: associations.select { |item| item[:record_type] == "company" },
        contacts: associations.select { |item| item[:record_type] == "contact" },
        deals: associations.select { |item| item[:record_type] == "deal" },
        association_count: associations.size
      }
    end

    def playbook_context_payload(crm_record)
      calls = PlaybookCall.for_crm_record_graph(crm_record).limit(8).to_a
      account_linked = calls.present?
      calls = crm_record.organization.playbook_calls.active.recent.limit(4).to_a if calls.blank?

      {
        total_for_record_graph: PlaybookCall.for_crm_record_graph(crm_record).count,
        included_count: calls.length,
        source: account_linked ? "HubSpot calls associated with this ticket/company/contact/deal graph" : "Recent organization playbook calls; not directly associated with this ticket graph",
        account_linked: account_linked,
        analyzer_note: account_linked ?
          "Use these calls as discovery context for customer needs, goals, objections, urgency, decision criteria, and follow-up actions. Do not expose private internal IDs or raw recording URLs in visible client copy." :
          "Use these unlinked recent calls only as general sales-language and discovery-pattern training. Do not treat them as facts about this client.",
        calls: calls.map do |call|
          {
            id: call.id,
            hubspot_call_id: call.hubspot_call_id,
            title: call.title,
            occurred_at: call.occurred_at&.iso8601,
            owner_name: call.owner_name,
            call_status: call.call_status,
            call_direction: call.call_direction,
            call_disposition: call.call_disposition,
            duration_ms: call.duration_ms,
            has_transcript: call.has_transcript,
            zoom_meeting_uuid_present: call.zoom_meeting_uuid.present?,
            summary: call.summary,
            suggested_next_actions: call.suggested_next_actions,
            analyzer_text: call.analyzer_text.to_s.truncate(2_500, omission: "\n..."),
            associated_record_id: call.crm_record_id
          }.compact
        end
      }
    end

    def associated_record_edges(crm_record)
      edges = []

      crm_record.outbound_associations.includes(:to_record).each do |association|
        edges << { association: association, record: association.to_record, direction: "outbound" }
      end

      crm_record.inbound_associations.includes(:from_record).each do |association|
        edges << { association: association, record: association.from_record, direction: "inbound" }
      end

      seen = {}
      edges.select do |edge|
        record = edge[:record]
        next false if record.blank?

        key = [record.id, edge[:association].association_type]
        next false if seen[key]

        seen[key] = true
      end
    end

    def campaign_context_payload(artifact, crm_record, labeled, raw)
      {
        deal_description: labeled["Deal Description"],
        free_postcard_logo: labeled["Free Postcard Logo"],
        agency_deal_type: labeled["Agency Deal Type"],
        requested_output: generation_prompt_payload(artifact, crm_record, labeled, raw),
        timing_context: timing_context_payload
      }
    end

    def timing_context_payload
      now = Time.current
      current_date = now.to_date
      lead_days = ENV.fetch("WIZWIKI_REPORT_PRODUCTION_LEAD_DAYS", "14").to_i
      lead_days = 14 if lead_days < 1
      earliest_start = current_date + lead_days

      {
        generated_at: now.iso8601,
        current_date: current_date.iso8601,
        current_time_zone: Time.zone&.name || now.zone,
        minimum_production_lead_days: lead_days,
        earliest_production_ready_date: earliest_start.iso8601,
        timing_rule: "Base all timing recommendations on current_date. Allow at least #{lead_days} calendar days for strategy approval, design, proofing, print setup, production, and mail/drop preparation before recommending a launch or first-mail date.",
        recommendation_rule: "Use seasonal logic relative to today. If the ideal seasonal window is inside the production lead window, recommend the next practical window instead of implying immediate execution."
      }
    end

    def generation_prompt_payload(artifact, crm_record, labeled, raw)
      DealReports::MarketStrategyContract.prompt(
        artifact: artifact,
        crm_record: crm_record,
        labeled: labeled,
        raw: raw,
        minimum_docx_bytes: MINIMUM_DOCX_BYTES
      )
    end

    def report_contract_payload(artifact, crm_record, labeled, raw)
      DealReports::MarketStrategyContract.payload(
        artifact: artifact,
        crm_record: crm_record,
        labeled: labeled,
        raw: raw,
        minimum_docx_bytes: MINIMUM_DOCX_BYTES
      )
    end

    def industry_strategy_payload(artifact, crm_record, labeled, raw)
      metadata = artifact.metadata.to_h
      stored = metadata["industry_strategy"].is_a?(Hash) ? metadata["industry_strategy"] : {}
      return stored if stored["industry"].present?

      company = company_payload(crm_record, labeled, raw, artifact)
      DealReports::IndustryStrategyPlaybook.payload_for(
        metadata["industry_strategy_lens"].presence || "auto",
        crm_record: crm_record,
        labeled: labeled,
        raw: raw,
        company_name: company[:name],
        industry: company[:industry].presence || metadata["industry"],
        services: labeled["Main Services"].presence || raw["main_services"].presence || labeled["Deal Description"].presence || crm_record.name,
        audience: metadata["report_audience"].presence || "client"
      )
    end

    def report_weather_opportunity_payload(artifact, crm_record)
      metadata = artifact.metadata.to_h
      stored = metadata["weather_opportunity"].is_a?(Hash) ? metadata["weather_opportunity"] : {}
      return stored if stored["active"].to_s == "true" || stored["signals"].present?

      weather = crm_record.properties.to_h.fetch("weather_lead", {}).to_h
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

      return { "active" => false, "source" => "Weather.gov Storm Watch", "summary" => "No active Storm Watch match is attached to this record." } if signals.blank?

      events = signals.map { |signal| signal["event"] }.compact_blank.uniq.first(4)
      locations = signals.flat_map { |signal| Array(signal["postal_codes"]).presence || Array(signal["states"]) }.compact_blank.uniq.first(8)

      {
        "active" => true,
        "source" => "Weather.gov Storm Watch",
        "matched_at" => weather["flagged_at"].presence,
        "signals_count" => weather["signals_count"].presence || signals.length,
        "events" => events,
        "locations" => locations,
        "summary" => "Storm Watch matched #{events.presence&.join(", ") || "recent storm activity"} near #{locations.presence&.join(", ") || "the service area"}.",
        "restoration_angle" => "If this client's services include restoration, roofing, exterior repair, plumbing, flooring, landscaping, tree work, HVAC, electrical, fencing, windows/doors, cleaning, mitigation, construction, or other home-service repair work, frame the weather signal as a timely opportunity to offer inspections, cleanup, repairs, and restoration services.",
        "truth_policy" => "Use only supplied weather events and locations. Do not claim confirmed damage at a specific property, do not invent forecasts, and do not use unsupported exact statistics.",
        "signals" => signals
      }.compact_blank
    end

    def report_sections_payload(industry)
      [
        {
          id: "cover_summary",
          title: "Cover Summary",
          minimum_words: 120,
          instructions: "Name the client, industry, deal context, report purpose, and the three highest-priority AM takeaways."
        },
        {
          id: "source_facts",
          title: "Known Facts From HubSpot",
          minimum_words: 140,
          requires_table: "source_facts_table",
          instructions: "Summarize known fields and explain what is missing. Do not invent facts."
        },
        {
          id: "buyer_context",
          title: "Industry And Buyer Context",
          minimum_words: 180,
          instructions: "Provide practical buyer assumptions for #{industry}. Label assumptions clearly and tie them to campaign choices."
        },
        {
          id: "campaign_calendar",
          title: "90-Day Campaign Calendar",
          minimum_words: 220,
          requires_table: "campaign_calendar_table",
          instructions: "Split into weeks 1-2, 3-4, 5-8, and 9-12 with AM, design, production, and follow-up responsibilities."
        },
        {
          id: "campaign_concepts",
          title: "Three Campaign Concepts",
          minimum_words: 360,
          instructions: "Create exactly three direct-mail/postcard concepts. Each must include audience, message, offer, CTA, design notes, required assets, and follow-up path."
        },
        {
          id: "edm_followup",
          title: "EDM And Email Follow-Up",
          minimum_words: 180,
          instructions: "Create a practical email follow-up sequence with subject angles, timing, segmentation notes, and AM handoff."
        },
        {
          id: "print_production_plan",
          title: "Print And Production Plan",
          minimum_words: 200,
          instructions: "List assets needed, proofing steps, list/data requirements, print timing, and production risk checks."
        },
        {
          id: "measurement_plan",
          title: "Measurement Plan",
          minimum_words: 180,
          requires_table: "measurement_table",
          instructions: "Define response signals, CRM fields to update, KPIs, and next-deal triggers."
        },
        {
          id: "am_call_script",
          title: "AM Call Script",
          minimum_words: 180,
          instructions: "Write short talking points and discovery questions an account manager can use immediately."
        },
        {
          id: "designer_brief",
          title: "Designer Brief",
          minimum_words: 200,
          instructions: "Give visual direction, tone, layout notes, copy angle, image/logo handling, and required assets."
        },
        {
          id: "next_actions",
          title: "Immediate Next Actions",
          minimum_words: 160,
          instructions: "List at least eight ordered actions with owner and reason. Include missing-data requests when applicable."
        }
      ]
    end

    def missing_core_fields(labeled, raw)
      {
        company_name: labeled["Company Name"].presence || raw["company_name"].presence,
        website_url: labeled["Website URL"],
        industry: labeled["Industry"].presence || raw["industry"].presence,
        crm_used: labeled["CRM Used"],
        deal_description: labeled["Deal Description"],
        free_postcard_logo: labeled["Free Postcard Logo"],
        shopify_payment_link: labeled["Shopify Payment Link"],
        quote_purchase_link: labeled["Quote Purchase Link"]
      }.select { |_key, value| value.blank? }.keys
    end

    def compact_hash(hash)
      hash.to_h.each_with_object({}) do |(key, value), memo|
        next if value.blank?

        memo[key.to_s] = value
      end
    end

    def quality_result_for(file:, manifest:, artifact: nil)
      payload = read_file_payload(file)
      output_tokens = manifest_value(manifest, "usage", "output_tokens").to_i
      errors = []
      warnings = []
      observation_mode = truthy_manifest_value?(manifest_value(manifest, "observation_mode"))
      copy_maker_report = copy_maker_report?(artifact)

      errors << "DOCX payload is not a zip/docx file" unless payload[:signature] == "PK"
      errors << "DOCX payload is too small (#{payload[:byte_size]} bytes; minimum #{MINIMUM_DOCX_BYTES})" if payload[:byte_size] < MINIMUM_DOCX_BYTES
      forbidden_sections = forbidden_visible_sections(manifest)
      errors << "visible document includes internal-only sections: #{forbidden_sections.join(', ')}" if forbidden_sections.any?
      unless copy_maker_report
        missing_sections = missing_required_sections(manifest)
        if missing_sections.any?
          message = "visible client report is missing required sections: #{missing_sections.join(', ')}"
          observation_mode ? warnings << message : errors << message
        end
        missing_tables = missing_required_tables(manifest)
        if missing_tables.any?
          message = "visible client report is missing required tables: #{missing_tables.join(', ')}"
          observation_mode ? warnings << message : errors << message
        end
      end
      errors << "visible document contains prompt echo or model scratchpad text" if prompt_echo_text?(payload[:text].to_s) || prompt_echo_text?(manifest_value(manifest, "summary").to_s)
      provider = manifest_value(manifest, "provider").to_s
      model = manifest_value(manifest, "model").to_s
      openai_manifest = [provider, model].any? { |value| value.match?(/openai|gpt/i) }
      if WizwikiSettings.qwen_only? && openai_manifest && !copy_maker_openai_final_allowed?(artifact)
        errors << "qwen-only mode rejected non-local report provider/model: #{[provider, model].reject(&:blank?).join(' / ')}"
      end
      warnings << "Copy Maker used configured OpenAI final pass while WIZWIKI qwen-only mode is active" if WizwikiSettings.qwen_only? && openai_manifest && copy_maker_openai_final_allowed?(artifact)
      warnings << "output token count is low for a client report (#{output_tokens})" if !copy_maker_report && output_tokens.positive? && output_tokens < 700
      warnings << "worker did not report model" if model.blank?

      {
        byte_size: payload[:byte_size],
        signature: payload[:signature],
        minimum_docx_bytes: MINIMUM_DOCX_BYTES,
        output_tokens: output_tokens,
        model: manifest_value(manifest, "model"),
        observation_mode: observation_mode,
        errors: errors,
        warnings: warnings
      }
    end

    def copy_maker_report?(artifact)
      metadata = artifact&.metadata.to_h
      metadata["report_audience"].to_s == "copy_maker" ||
        truthy_manifest_value?(metadata["copy_maker_enabled"])
    end

    def copy_maker_openai_final_allowed?(artifact)
      metadata = artifact&.metadata.to_h
      copy_maker_report?(artifact) &&
        metadata["copy_maker_cloud_provider"].to_s == "openai"
    end

    def forbidden_visible_sections(manifest)
      forbidden_patterns = [
        /\bAM[- ]?Facing\b/i,
        /\bAM\b.*\b(Action|Handoff|Note|Takeaway)/i,
        /designer notes?/i,
        /print production/i,
        /production notes?/i,
        /implementation notes?/i,
        /source data appendix/i,
        /raw hubspot/i,
        /hubspot (properties|ids?)/i,
        /missing core fields/i,
        /canva (data postcard|handoff|workflow|page data)/i,
        /asset list/i,
        /human approval gates?/i,
        /source notes?/i,
        /appendix/i,
        /^important$/i,
        /^assumptions?$/i,
        /payload/i,
        /report_contract/i,
        /sections? to include/i,
        /let'?s structure/i,
        /now we write/i,
        /visible document must start/i,
        /missing inputs/i,
        /client inputs/i
      ]

      sections = Array(manifest_value(manifest, "sections"))
      section_titles = sections.flat_map do |section|
        case section
        when Hash then [section["title"], section[:title], section["id"], section[:id]]
        else section
        end
      end.compact.map(&:to_s)

      section_titles.select do |title|
        forbidden_patterns.any? { |pattern| title.match?(pattern) }
      end.uniq.first(8)
    end

    def manifest_section_titles(manifest)
      Array(manifest_value(manifest, "sections")).flat_map do |section|
        case section
        when Hash then [section["title"], section[:title], section["id"], section[:id]]
        else section
        end
      end.compact.map { |value| normalize_quality_text(value) }
    end

    def missing_required_sections(manifest)
      required = Array(manifest_value(manifest, "required_sections"))
      return [] if required.blank?

      present = manifest_section_titles(manifest)
      required.filter_map do |section|
        title = normalize_quality_text(section["title"] || section[:title] || section["id"] || section[:id])
        next if title.blank?
        next if present.any? { |value| value == title || value.include?(title) || title.include?(value) }

        section["title"] || section[:title] || section["id"] || section[:id]
      end.first(8)
    end

    def missing_required_tables(manifest)
      required = Array(manifest_value(manifest, "required_tables"))
      return [] if required.blank?

      present = Array(manifest_value(manifest, "tables")).map do |table|
        case table
        when Hash
          [table["id"], table[:id], table["title"], table[:title]].compact.map { |value| normalize_quality_text(value) }
        else
          [normalize_quality_text(table)]
        end
      end.flatten

      required.filter_map do |table|
        id = normalize_quality_text(table["id"] || table[:id])
        title = normalize_quality_text(table["title"] || table[:title])
        next if [id, title].compact_blank.any? { |needle| present.include?(needle) }

        table["title"] || table[:title] || table["id"] || table[:id]
      end.first(8)
    end

    def normalize_quality_text(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def read_file_payload(file)
      file.rewind if file.respond_to?(:rewind)
      data = file.respond_to?(:read) ? file.read : file.to_s.b
      file.rewind if file.respond_to?(:rewind)

      {
        byte_size: data.bytesize,
        signature: data.byteslice(0, 2).to_s,
        text: docx_visible_text(data)
      }
    end

    def docx_visible_text(data)
      return "" unless data.byteslice(0, 2).to_s == "PK"

      Zip::File.open_buffer(StringIO.new(data)) do |zip|
        entry = zip.find_entry("word/document.xml")
        return "" if entry.blank?

        xml = entry.get_input_stream.read.to_s
        xml.scan(%r{<w:t[^>]*>(.*?)</w:t>}m).flatten.map { |value| CGI.unescapeHTML(value) }.join(" ").squish
      end
    rescue StandardError
      ""
    end

    def prompt_echo_text?(text)
      value = text.to_s.downcase
      return false if value.blank?

      forbidden_phrases = [
        "</think>",
        "we are creating",
        "the payload specifies",
        "the payload includes",
        "visible document must start",
        "let's structure",
        "now we write",
        "report_contract",
        "missing inputs:",
        "internal notes:",
        "assumptions:",
        "important:"
      ]

      forbidden_phrases.any? { |phrase| value.include?(phrase) }
    end

    def truthy_manifest_value?(value)
      value == true || %w[1 true yes on].include?(value.to_s.strip.downcase)
    end

    def manifest_value(manifest, *keys)
      keys.reduce(manifest.to_h) do |value, key|
        break nil unless value.respond_to?(:[])

      value[key.to_s] || value[key.to_sym]
      end
    end

    def run_id_for(artifact)
      artifact.metadata.to_h["run_id"].presence ||
        artifact.metadata.to_h["rore_run_id"].presence ||
        Autos::MemoryBus.run_id_for(source: "wizwiki", record_type: "CrmRecordArtifact", record_id: artifact.id)
    end

    def record_run_event!(artifact, event, status:, agent: nil, payload: {}, memory: {})
      return unless artifact.present?

      metadata = artifact.metadata.to_h
      crm_record = artifact.crm_record
      Autos::MemoryBus.record_run!(
        run_id: run_id_for(artifact),
        event: event,
        source: "wizwiki",
        record_type: "CrmRecordArtifact",
        record_id: artifact.id,
        status: status,
        agent: agent.presence || metadata["worker_id"],
        payload: payload,
        memory: {
          surface: "market_report",
          brain_type: "market_report",
          organization_id: artifact.organization_id,
          crm_record_id: artifact.crm_record_id,
          report_audience: metadata["report_audience"].presence || "client",
          title: artifact.title,
          deal: {
            id: crm_record&.id,
            name: crm_record&.name,
            record_type: crm_record&.record_type,
            stage: crm_record&.stage,
            priority: crm_record&.effective_priority_level
          },
          queue: {
            status: status,
            worker_id: metadata["worker_id"],
            report_lane: metadata["report_lane"],
            local_model: metadata["report_local_model"],
            embedder_model: metadata["report_embedder_model"]
          }
        }.deep_merge(memory.to_h)
      )
    rescue StandardError => error
      Rails.logger.warn("[DealReports::WorkerQueue#record_run_event!] artifact=#{artifact&.id} #{error.class}: #{error.message}")
    end
  end
end
