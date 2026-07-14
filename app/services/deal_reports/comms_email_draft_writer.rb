require "json"
require "net/http"
require "uri"

module DealReports
  class CommsEmailDraftWriter
    PRODUCT_OFFERINGS_PATH = Rails.root.join("config", "autos", "product_offerings.md")
    STARTER_EMAIL_SUBJECT = "A practical next step from WIZWIKI"
    MAX_CONTEXT_TEXT = 7_500
    MAX_TRAINING_DOCS = 14
    MAX_TRAINING_CHUNKS = 16

    def self.call(stage:, user:, operator_prompt: nil, writer_model: nil, schedule_context: nil)
      new(stage: stage, user: user, operator_prompt: operator_prompt, writer_model: writer_model, schedule_context: schedule_context).call
    end

    def self.queue_background(stage:, user:, operator_prompt: nil, writer_model: nil, schedule_context: nil)
      new(stage: stage, user: user, operator_prompt: operator_prompt, writer_model: writer_model, schedule_context: schedule_context, background: true).queue_background
    end

    def self.apply_worker_answer!(question)
      metadata = question.metadata.to_h
      return false unless metadata["surface"].to_s == "comms_email_draft"

      stage = CrmRecordArtifact.find_by(id: metadata["comms_stage_id"])
      return false unless stage.present?

      new(stage: stage, user: question.user, schedule_context: metadata["email_schedule_context"]).apply_worker_answer!(question)
    end

    def self.apply_worker_failure!(question, reason: nil)
      metadata = question.metadata.to_h
      return false unless metadata["surface"].to_s == "comms_email_draft"

      stage = CrmRecordArtifact.find_by(id: metadata["comms_stage_id"])
      return false unless stage.present?

      new(stage: stage, user: question.user, schedule_context: metadata["email_schedule_context"]).mark_background_failure!(question, reason.presence || metadata.dig("local_worker", "last_error").presence || "worker_failed")
    end

    def initialize(stage:, user:, operator_prompt: nil, writer_model: nil, schedule_context: nil, background: false)
      @stage = stage
      @user = user
      @operator_prompt = operator_prompt.to_s.strip
      @writer_model = normalize_writer_model(writer_model.presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_MODEL"].presence || ENV["WIZWIKI_COMMS_EMAIL_DRAFT_BACKGROUND_MODEL"].presence || "qwen3:8b")
      @writer_model_label = if defined?(WizwikiSettings)
        WizwikiSettings.sms_writer_model_label(@writer_model)
      else
        @writer_model
      end
      @schedule_context = schedule_context.respond_to?(:to_h) ? schedule_context.to_h.compact_blank : {}
      @background = ActiveModel::Type::Boolean.new.cast(background)
      @metadata = stage.metadata.to_h
    end

    def call
      draft = alice_draft
      return draft if acceptable_draft?(draft)

      draft = ollama_draft
      return draft if acceptable_draft?(draft)

      fallback_draft(draft.to_h["error"])
    end

    def queue_background
      question = enqueue_alice_draft_question
      pending_draft_for(question)
    rescue StandardError => error
      {
        "subject" => nil,
        "body" => nil,
        "provider" => "alice/local_cc",
        "model" => @writer_model,
        "writer_model" => @writer_model,
        "writer_model_label" => @writer_model_label,
        "draft_source" => "email_background_error",
        "background_queued" => false,
        "pending" => false,
        "error" => "#{error.class}: #{error.message}"
      }.compact_blank
    end

    def apply_worker_answer!(question)
      return false unless question.status == "answered" && question.answer.present?

      @stage.with_lock do
        @stage.reload
        @metadata = @stage.metadata.to_h.deep_dup
        return mark_background_failure!(question, "ignored_inactive_stage") unless @stage.status.in?(%w[staged aircall_ready aircall_sent aircall_failed])
        return mark_background_failure!(question, "ignored_superseded") if superseded_background_answer?(question)
        return mark_background_failure!(question, "ignored_after_thread_changed") if sms_thread_changed_after?(question.created_at)

        parsed = parse_model_response(question.answer)
        subject = sanitize_subject(parsed["subject"])
        email_body = sanitize_body(parsed["body"].presence || parsed["email_body"].presence || parsed["email"])
        return mark_background_failure!(question, "rejected_empty_email") if subject.blank? || email_body.blank?

        applied_at = Time.current
        draft_time_seconds = question.created_at.present? ? (applied_at - question.created_at).round(1) : nil
        worker = question.metadata.to_h["local_worker"].to_h
        result = {
          "subject" => subject,
          "body" => email_body,
          "provider" => worker["provider"].presence || "alice/local_cc",
          "model" => worker["model"].presence || question.metadata.to_h["writer_model"].presence || @writer_model,
          "writer_model" => question.metadata.to_h["writer_model"].presence || @writer_model,
          "writer_model_label" => question.metadata.to_h["writer_model_label"].presence || @writer_model_label,
          "draft_source" => "scheduled_email_predraft",
          "email_generation_pipeline" => "low_priority_alice_email_writer",
          "reason" => parsed["reason"].to_s.squish.presence || "Generated by Alice local worker as a low-priority scheduled email draft.",
          "operator_prompt" => question.metadata.to_h["operator_prompt"].presence || @operator_prompt.presence,
          "autos_question_id" => question.id,
          "background_queued" => true,
          "pending" => false,
          "late_worker_writeback" => true,
          "draft_time_seconds" => draft_time_seconds,
          "draft_time_label" => draft_time_seconds.present? ? "#{draft_time_seconds}s" : nil,
          "email_follow_up_date" => question.metadata.to_h["email_follow_up_date"].presence,
          "email_follow_up_day" => question.metadata.to_h["email_follow_up_day"].presence,
          "email_follow_up_action" => question.metadata.to_h["email_follow_up_action"].presence,
          "email_follow_up_due_at" => question.metadata.to_h["email_follow_up_due_at"].presence,
          "email_follow_up_draft_key" => question.metadata.to_h["email_follow_up_draft_key"].presence,
          "created_at" => applied_at.iso8601
        }.compact_blank

        history = Array(@metadata["email_draft_history"]).last(24)
        history << result.slice(
          "subject", "body", "provider", "model", "writer_model", "writer_model_label",
          "draft_source", "email_generation_pipeline", "reason", "operator_prompt",
          "autos_question_id", "draft_time_seconds", "draft_time_label", "email_follow_up_date",
          "email_follow_up_day", "email_follow_up_action", "created_at"
        ).merge("id" => SecureRandom.uuid).compact_blank

        @stage.update!(
          generated_at: applied_at,
          metadata: @metadata.merge(
            "comms_command_email_prompt" => result["operator_prompt"],
            "comms_command_email_draft" => result,
            "email_draft_history" => history,
            "composed_email_subject" => subject,
            "composed_email_body" => email_body,
            "comms_command_email_background_question_id" => question.id,
            "comms_command_email_background_status" => "applied",
            "comms_command_email_background_at" => applied_at.iso8601,
            "comms_command_email_background_error" => nil,
            "comms_command_email_background_completed_at" => applied_at.iso8601
          ).compact_blank
        )
      end
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsEmailDraftWriter] apply worker answer failed question=#{question&.id} stage=#{@stage&.id}: #{error.class}: #{error.message}")
      false
    end

    def mark_background_failure!(question, reason)
      @stage.reload
      metadata = @stage.metadata.to_h.deep_dup
      draft_question_id = metadata.dig("comms_command_email_draft", "autos_question_id").to_s
      stage_question_id = question.metadata.to_h["comms_stage_id"].to_s
      return false unless draft_question_id == question.id.to_s || stage_question_id == @stage.id.to_s

      @stage.update!(
        metadata: metadata.merge(
          "comms_command_email_background_question_id" => question.id,
          "comms_command_email_background_status" => reason.to_s,
          "comms_command_email_background_error" => question.answer.to_s.squish.first(300).presence || reason.to_s,
          "comms_command_email_background_at" => Time.current.iso8601
        ).compact_blank
      )
      true
    rescue StandardError => error
      Rails.logger.warn("[CommsEmailDraftWriter] mark background failure failed question=#{question&.id} stage=#{@stage&.id}: #{error.class}: #{error.message}")
      false
    end

    private

    def ollama_draft
      return { "error" => "local email draft model disabled" } unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_EMAIL_DRAFT_LLM_ENABLED", "1"))

      base = URI.parse(ENV["WIZWIKI_COMMS_EMAIL_DRAFT_URL"].presence || ENV["WIZWIKI_COMMS_DRAFT_URL"].presence || ENV["WIZWIKI_COMMS_SELECTOR_URL"].presence || ENV["OLLAMA_URL"].presence || "http://127.0.0.1:11434")
      uri = URI.join(base.to_s.chomp("/") + "/", "api/generate")
      model = @writer_model
      payload = {
        model: model,
        stream: false,
        format: "json",
        options: {
          temperature: @operator_prompt.present? ? 0.46 : 0.58,
          top_p: 0.9,
          repeat_penalty: 1.08
        },
        prompt: prompt
      }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 90) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        http.request(request)
      end
      return { "error" => "local email draft model returned HTTP #{response.code}", "provider" => "ollama/local", "model" => model } unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      parsed = parse_model_response(body["response"])
      subject = sanitize_subject(parsed["subject"])
      email_body = sanitize_body(parsed["body"].presence || parsed["email_body"].presence || parsed["email"])
      return { "error" => "local email draft model returned empty email", "provider" => "ollama/local", "model" => body["model"].presence || model } if subject.blank? || email_body.blank?

      {
        "subject" => subject,
        "body" => email_body,
        "provider" => "ollama/local",
        "model" => body["model"].presence || model,
        "reason" => parsed["reason"].to_s.squish.presence || "Generated from WIZWIKI COMMS account context, fine training, product docs, and thread history.",
        "operator_prompt" => @operator_prompt.presence
      }.compact_blank
    rescue StandardError => error
      {
        "provider" => "ollama/local",
        "model" => @writer_model,
        "error" => "#{error.class}: #{error.message}"
      }
    end

    def prompt
      <<~PROMPT
        You are Thumper, the Thumper von AUTOS, writing one human-approved outbound sales email from Thumper at WIZWIKI Marketing.
        Return strict JSON only: {"subject":"...","body":"...","reason":"..."}.

        PARAMOUNT Thumper VOICE:
        #{Thumper::VoiceGuide.email_prompt}

        MODE:
        #{email_scope_instruction}

        Rules:
        - Write as Thumper from WIZWIKI: practical, direct, candid, and specific to the customer.
        - The WIZWIKI Copy Playbook and Sample Operator Fathom voice analysis override older samples for tone and structure.
        - Use the account/contact context, CRM notes, prior SMS/email thread, product offerings, and fine-training context.
        - If the operator prompt is present, follow it as the rewrite direction.
        - For manual Email COMM KIT drafts, include a useful targeted marketing plan in natural email prose: the likely need, the best-fit package/deal/special when supported, why it fits, and one clear next step.
        - Use the recipient first name when known. Do not use a fake name.
        - Keep the subject under 80 characters.
        - Keep the body between 90 and 230 words unless the operator asks for shorter.
        - Plain text only. No markdown, tables, labels, fake statistics, unsupported discounts, or internal notes.
        - Do not pretend the email was already sent. The human will review before sending.
        - If product links or pricing are supplied, use them accurately. Put only one best-fit link unless the operator asks for multiple.
        - If exact pricing or a custom quantity is not supplied, say a WIZWIKI teammate can confirm exact pricing instead of inventing it.
        - Make the email specific to this account. Avoid generic "just checking in" filler.
        - Do not use corporate words, fake-energy exclamation points, em dashes, or premature goodbye language.

        OPERATOR PROMPT:
        #{@operator_prompt.presence || "(blank - create the best useful email from context)"}

        CONTEXT JSON:
        #{JSON.pretty_generate(context_payload)}
      PROMPT
    end

    def context_payload
      {
        account: account_payload,
        recipient: {
          contact: selected_option("contact_options", "selected_contact_id"),
          email: selected_option("recipient_email_options", "selected_recipient_email_id"),
          phone: selected_option("phone_options", "selected_phone_id"),
          first_name: recipient_first_name
        }.compact_blank,
        sender: {
          name: @metadata.dig("sender_profile", "name").presence || @metadata["sender_name"].presence || @user&.display_name,
          email: @metadata.dig("sender_profile", "email").presence || @user&.email_address,
          phone: @metadata.dig("sender_profile", "phone").presence || @metadata["sender_phone"].presence
        }.compact_blank,
        email_kit: {
          mode: @background ? "scheduled_email_predraft" : "focused_call_block_email_kit",
          instruction: email_scope_instruction,
          operator_prompt: @operator_prompt.presence
        }.compact_blank,
        discovery_mode: discovery_payload,
        current_email: {
          subject: current_subject,
          body: current_body
        }.compact_blank,
        email_schedule: @schedule_context.presence,
        sms_thread: compact_events(@metadata["sms_thread"], limit: 24),
        email_thread: compact_events(@metadata["email_thread"], limit: 8),
        product_offerings_document: product_offerings_document,
        fine_training_context: fine_training_context,
        related_records: associated_records_payload,
        stage_metadata: safe_stage_metadata
      }.compact_blank
    end

    def account_payload
      record = @stage.crm_record
      {
        stage_id: @stage.id,
        stage_title: @stage.title,
        company_name: company_name,
        deal_name: @metadata["deal_name"].presence,
        industry: @metadata["industry"].presence || @metadata["captured_industry"].presence,
        campaign_status: @metadata["comms_command_last_status"].presence,
        processing_label: @metadata["processing_label"].presence,
        route: @metadata["processing_code"].presence,
        crm_record: record && {
          id: record.id,
          type: record.record_type,
          name: record.name,
          status: record.status,
          email: record.email,
          phone: record.phone,
          domain: record.domain,
          source: record.source,
          source_uid: record.source_uid,
          properties: summarize_hash(record.properties)
        }.compact_blank
      }.compact_blank
    end

    def associated_records_payload
      record = @stage.crm_record
      return [] unless record

      outbound = record.outbound_associations.includes(:to_record).limit(8).map do |assoc|
        associated_record_item(assoc.to_record, assoc.association_type)
      end
      inbound = record.inbound_associations.includes(:from_record).limit(8).map do |assoc|
        associated_record_item(assoc.from_record, assoc.association_type)
      end
      (outbound + inbound).compact.uniq { |item| [item[:id], item[:type]] }.first(12)
    rescue StandardError => error
      Rails.logger.warn("[CommsEmailDraftWriter] associated records unavailable stage=#{@stage&.id}: #{error.class}: #{error.message}")
      []
    end

    def associated_record_item(record, association_type)
      return unless record

      {
        association: association_type,
        id: record.id,
        type: record.record_type,
        name: record.name,
        email: record.email,
        phone: record.phone,
        domain: record.domain,
        status: record.status,
        properties: summarize_hash(record.properties)
      }.compact_blank
    end

    def fine_training_context
      organization = @stage.organization || @stage.crm_record&.organization
      return if organization.blank? || !defined?(TrainingDocument)

      keywords = fine_training_keywords
      documents = organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"]).order(updated_at: :desc).limit(220).to_a
      documents += organization.training_vault_documents.where(status: %w[approved indexed]).order(updated_at: :desc).limit(220).to_a if defined?(TrainingVaultDocument)
      selected_documents = rank_text_records(documents, keywords).first(MAX_TRAINING_DOCS)

      chunks = if defined?(AutosEmbeddingChunk) && ActiveRecord::Base.connection.table_exists?(:autos_embedding_chunks)
        AutosEmbeddingChunk.embedded
          .where(organization: organization, source_type: ["TrainingDocument", "TrainingVaultDocument"])
          .order(updated_at: :desc)
          .limit(350)
          .to_a
      else
        []
      end
      selected_chunks = rank_text_records(chunks, keywords, content_method: :content).first(MAX_TRAINING_CHUNKS)

      {
        documents_scanned: documents.length,
        embedded_chunks_scanned: chunks.length,
        selection_reason: "Selected fine-training documents and embedded chunks using the account name, contact name, company name, industry, product hints, operator prompt, recent thread terms, and paramount Thumper/Copy Playbook priority.",
        selected_documents: selected_documents.map { |document, score| training_document_payload(document, score) },
        selected_chunks: selected_chunks.map { |chunk, score| training_chunk_payload(chunk, score) }
      }.compact_blank
    rescue StandardError => error
      Rails.logger.warn("[CommsEmailDraftWriter] fine training unavailable stage=#{@stage&.id}: #{error.class}: #{error.message}")
      nil
    end

    def product_offerings_document
      return unless File.exist?(PRODUCT_OFFERINGS_PATH)

      File.read(PRODUCT_OFFERINGS_PATH).to_s.truncate(MAX_CONTEXT_TEXT, omission: "\n...")
    rescue StandardError => error
      Rails.logger.warn("[CommsEmailDraftWriter] product offerings unavailable: #{error.class}: #{error.message}")
      nil
    end

    def fine_training_keywords
      [
        @operator_prompt,
        company_name,
        recipient_first_name,
        @metadata["industry"],
        @metadata["captured_industry"],
        @metadata["processing_code"],
        @metadata["processing_label"],
        @metadata["manual_comms_notes"],
        latest_thread_text
      ].compact.join(" ").downcase.scan(/[a-z0-9][a-z0-9'\-]{2,}/).uniq.first(120)
    end

    def rank_text_records(records, keywords, content_method: :body)
      records.map do |record|
        text = [
          record.respond_to?(:title) ? record.title : nil,
          record.respond_to?(:label) ? record.label : nil,
          record.respond_to?(:file_name) ? record.file_name : nil,
          record.respond_to?(content_method) ? record.public_send(content_method) : nil
        ].compact.join("\n")
        score = keywords.count { |keyword| text.downcase.include?(keyword) }
        score += 80 if text.match?(/\b(paramount|thumper carroll|copy playbook|how wizwiki talks|fathom-derived thumper voice)\b/i)
        score += 3 if text.match?(/\b(email|sales|sms|follow.?up|postcard|yard sign|starter pack|pro pack|door hanger|edDM|neighborhood)\b/i)
        score += 1 if record.respond_to?(:updated_at) && record.updated_at.present? && record.updated_at > 30.days.ago
        [record, score]
      end.sort_by { |record, score| [-score, -(record.respond_to?(:updated_at) && record.updated_at ? record.updated_at.to_i : 0)] }
    end

    def training_document_payload(document, score)
      {
        title: document.title,
        source_type: document.respond_to?(:source_type) ? document.source_type : document.class.name,
        score: score,
        updated_at: document.updated_at&.to_date&.iso8601,
        excerpt: document.body.to_s.squish.truncate(1_200, omission: "...")
      }.compact_blank
    end

    def training_chunk_payload(chunk, score)
      {
        label: chunk.label,
        source_type: chunk.source_type,
        source_id: chunk.source_id,
        score: score,
        updated_at: chunk.updated_at&.to_date&.iso8601,
        excerpt: chunk.content.to_s.squish.truncate(900, omission: "...")
      }.compact_blank
    end

    def selected_option(options_key, selected_key)
      selected_id = @metadata[selected_key].to_s
      options = Array(@metadata[options_key])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      candidate = selected || options.first
      candidate.respond_to?(:to_h) ? candidate.to_h : {}
    end

    def current_subject
      draft = completed_email_draft
      return draft["subject"].to_s if draft["subject"].present?
      return if starter_email_placeholder?

      @metadata["composed_email_subject"].presence ||
        @metadata["aircall_composed_email_subject"].presence
    end

    def current_body
      draft = completed_email_draft
      return draft["body"].to_s if draft["body"].present?
      return if starter_email_placeholder?

      @metadata["composed_email_body"].presence ||
        @metadata["aircall_composed_email_body"].presence
    end

    def completed_email_draft
      draft = @metadata["comms_command_email_draft"].to_h
      return {} if ActiveModel::Type::Boolean.new.cast(draft["pending"])

      draft
    end

    def starter_email_placeholder?
      return false if completed_email_draft["subject"].present?
      return false if Array(@metadata["email_draft_history"]).present?

      subject = [
        @metadata["composed_email_subject"],
        @metadata["aircall_composed_email_subject"],
        selected_option("email_options", "selected_email_id")["subject"]
      ].compact.map(&:to_s)
      return false unless subject.any? { |value| value.squish == STARTER_EMAIL_SUBJECT }

      option_ids = Array(@metadata["email_options"]).map { |option| option.to_h["id"].to_s }
      selected_id = @metadata["selected_email_id"].to_s
      ([selected_id] + option_ids).any? { |id| id.match?(/\b(?:manual|claimed|wob)-email-draft\b/) }
    end

    def company_name
      @metadata["company_name"].presence || @stage.crm_record&.name.to_s.presence || @stage.title
    end

    def recipient_first_name
      name = @metadata["captured_contact_name"].presence ||
        @metadata.dig("comms_bot_state", "contact_name").presence ||
        selected_option("contact_options", "selected_contact_id")["name"].presence
      first = name.to_s.squish.split(/\s+/).first.to_s.gsub(/[^[:alpha:]'\-]/, "")
      return if first.blank? || first.length < 2 || first.match?(/\A(?:wizwiki|comms|contact|customer|sample)\z/i)

      first
    end

    def latest_thread_text
      compact_events(@metadata["sms_thread"], limit: 16).map { |event| event[:body] }.join(" ")
    end

    def compact_events(events, limit:)
      Array(events).last(limit).map do |event|
        event = event.to_h
        {
          at: event["created_at"],
          channel: event["channel"],
          direction: event["direction"],
          status: event["status"],
          subject: event["subject"].to_s.squish.presence,
          body: event["body"].to_s.squish.truncate(700, omission: "...")
        }.compact_blank
      end
    end

    def safe_stage_metadata
      allowed = %w[
        manual_comms_notes manual_comms_source hubspot_lead_owner hubspot_owner_id
        captured_contact_name captured_company_name captured_email captured_industry
        industry processing_code processing_label processing_summary comm_kit_direction_label
        recipient_selection_summary contact_intelligence campaign_fit sms_captured_budget
        sms_captured_quantity sms_captured_product_interest sms_captured_company_name
      ]
      @metadata.slice(*allowed).compact_blank
    end

    def discovery_payload
      bot_state = @metadata["comms_bot_state"].to_h
      latest_customer_sms = compact_events(@metadata["sms_thread"], limit: 10).reverse.find { |event| event[:direction].to_s == "inbound" }.to_h[:body].to_s.squish
      @metadata.slice(
        "captured_contact_name",
        "captured_company_name",
        "captured_industry",
        "captured_email",
        "manual_comms_zip",
        "proof_delivery_email",
        "proof_delivery_method",
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
        "bot_state" => summarize_hash(bot_state).presence,
        "latest_customer_sms" => latest_customer_sms.presence
      ).compact_blank
    end

    def summarize_hash(value)
      value.to_h.each_with_object({}) do |(key, item), memo|
        next if item.blank?
        next if key.to_s.match?(/token|secret|password|key|credential/i)

        memo[key.to_s] = if item.is_a?(Hash)
          summarize_hash(item).presence
        elsif item.is_a?(Array)
          item.first(8)
        else
          item.to_s.squish.truncate(260, omission: "...")
        end
      end.compact_blank
    end

    def parse_model_response(value)
      text = value.to_s.strip
      text = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      JSON.parse(text)
    rescue JSON::ParserError
      { "body" => text }
    end

    def alice_draft
      question = enqueue_alice_draft_question
      deadline = Time.current + alice_wait_seconds.seconds
      loop do
        question.reload
        if question.status == "answered" && question.answer.present?
          parsed = parse_model_response(question.answer)
          subject = sanitize_subject(parsed["subject"])
          email_body = sanitize_body(parsed["body"].presence || parsed["email_body"].presence || parsed["email"])
          return {
            "subject" => subject,
            "body" => email_body,
            "provider" => question.metadata.to_h.dig("local_worker", "provider").presence || "alice/local_cc",
            "model" => question.metadata.to_h.dig("local_worker", "model").presence || @writer_model,
            "writer_model" => question.metadata.to_h["writer_model"].presence || @writer_model,
            "writer_model_label" => question.metadata.to_h["writer_model_label"].presence || @writer_model_label,
            "reason" => parsed["reason"].to_s.squish.presence || "Generated by Alice local worker from WIZWIKI COMMS account context.",
            "operator_prompt" => @operator_prompt.presence,
            "autos_question_id" => question.id
          }.compact_blank if subject.present? && email_body.present?

          return { "error" => "Alice returned an empty email draft", "autos_question_id" => question.id }
        end
        return { "error" => "Alice email draft failed: #{question.answer.presence || question.metadata.to_h.dig('local_worker', 'last_error')}", "autos_question_id" => question.id } if question.status == "failed"
        break if Time.current >= deadline

        sleep 0.75
      end

      { "error" => "Alice email draft timed out after #{alice_wait_seconds}s", "autos_question_id" => question.id }
    rescue StandardError => error
      {
            "provider" => "alice/local_cc",
            "model" => @writer_model,
            "writer_model" => @writer_model,
            "writer_model_label" => @writer_model_label,
        "error" => "#{error.class}: #{error.message}"
      }.compact_blank
    end

    def enqueue_alice_draft_question
      raise "Alice email draft disabled" unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_COMMS_ALICE_EMAIL_DRAFT_ENABLED", "1"))
      raise "Alice worker queue disabled" unless defined?(Autos::WorkerQueue) && Autos::WorkerQueue.enabled?

      organization = @stage.organization || @stage.crm_record&.organization
      user = @user || @stage.user
      raise "Alice email draft missing organization/user" if organization.blank? || user.blank?

      payload = context_payload
      context_json = JSON.pretty_generate(payload)
      question = organization.autos_questions.create!(
        user: user,
        status: "queued",
        question: alice_prompt,
        context: context_json,
        metadata: {
          "surface" => "comms_email_draft",
          "context_mode" => "compact_email",
          "context_chars" => context_json.length,
          "input_mode" => "internal_comms",
          "email_draft_scope" => @background ? "follow_up_predraft" : "manual",
          "operator_prompt" => @operator_prompt.presence,
          "skip_voice" => true,
          "skip_chat_memory" => true,
          "skip_ui_broadcast" => true,
          "comms_stage_id" => @stage.id,
          "comms_company_name" => company_name,
          "writer_model" => @writer_model,
          "writer_model_label" => @writer_model_label,
          "email_generation_pipeline" => @background ? "low_priority_alice_email_writer" : "manual_alice_email_writer",
          "email_schedule_context" => @schedule_context.presence,
          "email_follow_up_date" => @schedule_context["date"].presence,
          "email_follow_up_day" => @schedule_context["day"].presence,
          "email_follow_up_weekday" => @schedule_context["weekday"].presence,
          "email_follow_up_action" => @schedule_context["action"].presence,
          "email_follow_up_due_at" => @schedule_context["due_at"].presence,
          "email_follow_up_draft_key" => @schedule_context["draft_key"].presence,
          "semantic_query" => fine_training_keywords.join(" "),
          "submitted_at" => Time.current.iso8601
        }.compact_blank
      )
      Autos::WorkerQueue.queue!(question)
      question
    end

    def pending_draft_for(question)
      metadata = question.metadata.to_h
      {
        "subject" => nil,
        "body" => nil,
        "provider" => metadata.dig("local_worker", "provider").presence || "alice/local_cc",
        "model" => metadata.dig("local_worker", "model").presence || @writer_model,
        "writer_model" => metadata["writer_model"].presence || @writer_model,
        "writer_model_label" => metadata["writer_model_label"].presence || @writer_model_label,
        "draft_source" => "scheduled_email_predraft_pending",
        "email_generation_pipeline" => metadata["email_generation_pipeline"].presence || "low_priority_alice_email_writer",
        "reason" => "Alice is composing this scheduled email draft in the low-priority background lane.",
        "operator_prompt" => @operator_prompt.presence,
        "autos_question_id" => question.id,
        "background_queued" => true,
        "pending" => true,
        "email_follow_up_date" => metadata["email_follow_up_date"].presence,
        "email_follow_up_day" => metadata["email_follow_up_day"].presence,
        "email_follow_up_action" => metadata["email_follow_up_action"].presence,
        "email_follow_up_due_at" => metadata["email_follow_up_due_at"].presence,
        "email_follow_up_draft_key" => metadata["email_follow_up_draft_key"].presence,
        "created_at" => Time.current.iso8601
      }.compact_blank
    end

    def alice_wait_seconds
      ENV.fetch("WIZWIKI_COMMS_ALICE_EMAIL_DRAFT_WAIT_SECONDS", ENV.fetch("WIZWIKI_COMMS_ALICE_DRAFT_WAIT_SECONDS", "75")).to_i.clamp(2, 180)
    end

    def alice_prompt
      <<~PROMPT.squish
        Write one human-approved outbound sales email from Thumper at WIZWIKI Marketing.
        #{Thumper::VoiceGuide.email_prompt}
        #{email_scope_instruction}
        Return strict JSON only: {"subject":"...","body":"...","reason":"..."}.
        No markdown, no labels, no fake stats, no hidden notes, no bracket placeholders.
        Use the supplied JSON as authority: account context, contact info, CRM notes, prior SMS/email thread, product offerings, fine-training examples, and embedded training chunks.
        Subject must be under 80 characters. Body should be 90 to 230 words unless the operator prompt asks for shorter.
        Use the recipient first name when known. Make the email specific to this account, useful, practical, and clear.
        If the operator prompt is present, follow it as the rewrite instruction.
        If pricing or product links are supplied, use them accurately. If exact pricing/custom quantity is not supplied, say a WIZWIKI teammate can confirm exact pricing instead of inventing it.
      PROMPT
    end

    def email_scope_instruction
      if @background
        "This is a low-priority scheduled email pre-draft. Create one review-ready email for the scheduled follow-up lane, using the schedule day/action plus the latest discovery context. Do not send it or imply it has already been sent."
      else
        "This is the focused Email COMM KIT from a call block. Create one review-ready email with a targeted marketing plan for this client: answer the current need, recommend the best-fit package/deal/special when supported, explain one practical reason it fits, and close with one soft next step. Do not copy starter samples."
      end
    end

    def sanitize_subject(value)
      value.to_s.gsub(/[\r\n]+/, " ").squish.truncate(80, omission: "...")
    end

    def sanitize_body(value)
      value.to_s.gsub(/\r\n?/, "\n").strip.gsub(/\n{3,}/, "\n\n").truncate(3_000, omission: "\n...")
    end

    def acceptable_draft?(draft)
      draft.to_h["subject"].to_s.squish.present? && draft.to_h["body"].to_s.squish.length >= 60
    end

    def superseded_background_answer?(question)
      question_key = question.metadata.to_h["email_follow_up_draft_key"].to_s
      return false if question_key.blank?

      current_key = @metadata.dig("comms_command_email_draft", "email_follow_up_draft_key").to_s
      current_question_id = @metadata.dig("comms_command_email_draft", "autos_question_id").to_s
      current_key.present? && current_key != question_key && current_question_id != question.id.to_s
    end

    def sms_thread_changed_after?(time)
      return false if time.blank?

      compact_events(@metadata["sms_thread"], limit: 6).any? do |event|
        event_time = Time.zone.parse(event[:at].to_s) rescue nil
        event_time.present? && event_time > time
      end
    end

    def normalize_writer_model(value)
      if defined?(WizwikiSettings)
        WizwikiSettings.normalize_sms_writer_model_alias(value.presence || "qwen3:8b")
      else
        value.presence || "qwen3:8b"
      end
    end

    def fallback_draft(error = nil)
      {
        "provider" => "local/fallback",
        "model" => "none",
        "reason" => ["Email kit draft left blank because no local model returned a complete subject/body.", error].compact.join(" "),
        "error" => error
      }.compact_blank
    end
  end
end
