module Comms
  class AutopilotLearning
    TRAINING_KIND = "comms_playbook_memory".freeze
    QUALITY_TRAINING_KIND = "comms_quality_memory".freeze
    DOJO_SCORECARD_TRAINING_KIND = "comms_dojo_scorecard_memory".freeze
    DOJO_JUDGE_TRAINING_KIND = "comms_dojo_judge_memory".freeze
    SOURCE_TYPE = "comms_playbook_memory".freeze
    DEFAULT_LOOKBACK_DAYS = 14
    DEFAULT_LIMIT = 200
    MAX_EVENT_BODY_CHARS = 260
    QUALITY_EXAMPLE_LIMIT = 12
    DEFAULT_STAGE_MEMORY_KEEP_COUNT = 250
    DEFAULT_STAGE_MEMORY_KEEP_DAYS = 45
    DOJO_SCORECARD_MEMORY_LIMIT = 40
    DOJO_SCORECARD_METADATA_EXAMPLE_LIMIT = 12
    DOJO_JUDGE_MEMORY_LIMIT = 40
    DOJO_JUDGE_METADATA_EXAMPLE_LIMIT = 12
    NON_LEARNING_SMS_STATUSES = %w[failed canceled undelivered blocked skipped].freeze

    Result = Struct.new(:threads_scanned, :lessons_created, :lessons_updated, :lessons_skipped, :lessons_embedded, :quality_documents_created, :quality_documents_updated, :quality_documents_skipped, :quality_documents_embedded, :scorecard_documents_created, :scorecard_documents_updated, :scorecard_documents_skipped, :scorecard_documents_embedded, :judge_documents_created, :judge_documents_updated, :judge_documents_skipped, :judge_documents_embedded, :memory_documents_archived, :memory_embedding_sources_staled, :errors, keyword_init: true) do
      def to_h
        {
          threads_scanned: threads_scanned.to_i,
          lessons_created: lessons_created.to_i,
          lessons_updated: lessons_updated.to_i,
          lessons_skipped: lessons_skipped.to_i,
          lessons_embedded: lessons_embedded.to_i,
          quality_documents_created: self[:quality_documents_created].to_i,
          quality_documents_updated: self[:quality_documents_updated].to_i,
          quality_documents_skipped: self[:quality_documents_skipped].to_i,
          quality_documents_embedded: self[:quality_documents_embedded].to_i,
          scorecard_documents_created: self[:scorecard_documents_created].to_i,
          scorecard_documents_updated: self[:scorecard_documents_updated].to_i,
          scorecard_documents_skipped: self[:scorecard_documents_skipped].to_i,
          scorecard_documents_embedded: self[:scorecard_documents_embedded].to_i,
          judge_documents_created: self[:judge_documents_created].to_i,
          judge_documents_updated: self[:judge_documents_updated].to_i,
          judge_documents_skipped: self[:judge_documents_skipped].to_i,
          judge_documents_embedded: self[:judge_documents_embedded].to_i,
          memory_documents_archived: self[:memory_documents_archived].to_i,
          memory_embedding_sources_staled: self[:memory_embedding_sources_staled].to_i,
          errors: Array(errors)
        }
      end
    end

    def self.call(organization:, lookback_days: DEFAULT_LOOKBACK_DAYS, limit: DEFAULT_LIMIT, dry_run: false)
      new(organization: organization, lookback_days: lookback_days, limit: limit, dry_run: dry_run).call
    end

    def initialize(organization:, lookback_days: DEFAULT_LOOKBACK_DAYS, limit: DEFAULT_LIMIT, dry_run: false)
      @organization = organization
      @lookback_days = lookback_days.to_i.clamp(1, 90)
      @limit = limit.to_i.clamp(1, 1_000)
      @dry_run = dry_run
      @errors = []
      @counts = Hash.new(0)
    end

    def call
      return empty_result("missing organization") if organization.blank?
      return empty_result("missing training user") if training_user.blank?

      stages = candidate_scope.to_a
      stages.each do |stage|
        @counts[:threads_scanned] += 1
        promote_stage!(stage)
      rescue StandardError => error
        @errors << "stage=#{stage&.id} #{error.class}: #{error.message}"
        Rails.logger.warn("[Comms::AutopilotLearning] stage=#{stage&.id} failed: #{error.class}: #{error.message}")
      end
      promote_quality_memory!(stages)
      promote_dojo_scorecard_memory!(stages)
      promote_dojo_judge_memory!(stages)
      enforce_memory_retention! unless @dry_run

      publish_result
      result
    end

    private

    attr_reader :organization, :lookback_days, :limit

    def empty_result(message)
      @errors << message
      result
    end

    def result
      Result.new(
        threads_scanned: @counts[:threads_scanned],
        lessons_created: @counts[:lessons_created],
        lessons_updated: @counts[:lessons_updated],
        lessons_skipped: @counts[:lessons_skipped],
        lessons_embedded: @counts[:lessons_embedded],
        quality_documents_created: @counts[:quality_documents_created],
        quality_documents_updated: @counts[:quality_documents_updated],
        quality_documents_skipped: @counts[:quality_documents_skipped],
        quality_documents_embedded: @counts[:quality_documents_embedded],
        scorecard_documents_created: @counts[:scorecard_documents_created],
        scorecard_documents_updated: @counts[:scorecard_documents_updated],
        scorecard_documents_skipped: @counts[:scorecard_documents_skipped],
        scorecard_documents_embedded: @counts[:scorecard_documents_embedded],
        judge_documents_created: @counts[:judge_documents_created],
        judge_documents_updated: @counts[:judge_documents_updated],
        judge_documents_skipped: @counts[:judge_documents_skipped],
        judge_documents_embedded: @counts[:judge_documents_embedded],
        memory_documents_archived: @counts[:memory_documents_archived],
        memory_embedding_sources_staled: @counts[:memory_embedding_sources_staled],
        errors: @errors
      )
    end

    def candidate_scope
      organization.crm_record_artifacts
        .includes(:crm_record, :user)
        .where(artifact_type: "comm_staging")
        .where("crm_record_artifacts.updated_at >= ?", lookback_days.days.ago)
        .where("jsonb_typeof(crm_record_artifacts.metadata -> 'sms_thread') = 'array'")
        .where("jsonb_array_length(crm_record_artifacts.metadata -> 'sms_thread') > 0")
        .order(updated_at: :desc)
        .limit(limit)
    end

    def promote_stage!(stage)
      memory = memory_for(stage)
      unless promotable?(memory)
        retire_unpromotable_stage_memory!(stage, memory)
        @counts[:lessons_skipped] += 1
        return
      end

      document = existing_document_for(stage) || organization.training_documents.build
      created = document.new_record?
      body = training_body(memory)
      metadata = training_metadata(stage, memory)

      if !created && unchanged_review_record?(document, body, metadata)
        @counts[:lessons_skipped] += 1
        return
      end

      return count_dry_run(created) if @dry_run

      clean_metadata = document.metadata.to_h.except(
        "reviewed_by_user_id",
        "reviewed_by",
        "reviewed_at",
        "review_note",
        "revoked_by_user_id",
        "revoked_by",
        "revoked_at",
        "archived_at",
        "archived_reason"
      )
      document.assign_attributes(
        user: training_user,
        title: training_title(stage, memory),
        body: body,
        source_type: SOURCE_TYPE,
        status: "ingested",
        content_type: "text/markdown",
        file_name: "autos-comms-memory-#{stage.id}.md",
        byte_size: body.bytesize,
        metadata: clean_metadata.merge(metadata)
      )
      document.save!

      @counts[created ? :lessons_created : :lessons_updated] += 1
      stale_embedding_source!(document) unless created
    end

    def promote_quality_memory!(stages)
      quality = quality_memory_for(stages)
      document = existing_quality_document || organization.training_documents.build
      created = document.new_record?
      body = quality_training_body(quality)
      metadata = quality_metadata(quality)

      if !created && document.body == body && indexed_same_quality?(document, metadata)
        @counts[:quality_documents_skipped] += 1
        return
      end

      return count_quality_dry_run(created) if @dry_run

      document.assign_attributes(
        user: training_user,
        title: "Thumper COMMS QUALITY MEMORY // recursive communication audit",
        body: body,
        source_type: SOURCE_TYPE,
        status: "ingested",
        content_type: "text/markdown",
        file_name: "autos-comms-quality-memory.md",
        byte_size: body.bytesize,
        metadata: document.metadata.to_h.merge(metadata)
      )
      document.save!

      @counts[created ? :quality_documents_created : :quality_documents_updated] += 1
      enqueue_quality_memory!(document)
    rescue StandardError => error
      @errors << "quality_memory #{error.class}: #{error.message}"
      Rails.logger.warn("[Comms::AutopilotLearning] quality memory failed: #{error.class}: #{error.message}")
    end

    def promote_dojo_scorecard_memory!(stages)
      scorecards = dojo_scorecards_for(stages)
      if scorecards.blank?
        archive_empty_dojo_scorecard_memory!
        @counts[:scorecard_documents_skipped] += 1
        return
      end

      document = existing_dojo_scorecard_document || organization.training_documents.build
      created = document.new_record?
      body = dojo_scorecard_training_body(scorecards)
      metadata = dojo_scorecard_metadata(scorecards)

      if !created && document.body == body && indexed_same_scorecards?(document, metadata)
        @counts[:scorecard_documents_skipped] += 1
        return
      end

      return count_scorecard_dry_run(created) if @dry_run

      document.assign_attributes(
        user: training_user,
        title: "Thumper DOJO SCORECARD MEMORY // direct answers, complete conversations, pricing, proof flow, links",
        body: body,
        source_type: SOURCE_TYPE,
        status: "ingested",
        content_type: "text/markdown",
        file_name: "autos-dojo-scorecard-memory.md",
        byte_size: body.bytesize,
        metadata: document.metadata.to_h.merge(metadata)
      )
      document.save!

      @counts[created ? :scorecard_documents_created : :scorecard_documents_updated] += 1
      enqueue_scorecard_memory!(document)
    rescue StandardError => error
      @errors << "dojo_scorecard_memory #{error.class}: #{error.message}"
      Rails.logger.warn("[Comms::AutopilotLearning] dojo scorecard memory failed: #{error.class}: #{error.message}")
    end

    def archive_empty_dojo_scorecard_memory!
      document = existing_dojo_scorecard_document
      return if document.blank? || @dry_run

      document.update!(
        status: "archived",
        metadata: document.metadata.to_h.merge(
          "archived_by" => "comms_autopilot_learning",
          "archived_reason" => "No usable dojo scorecards after ignored generation filtering.",
          "archived_at" => Time.current.iso8601
        )
      )
      stale_embedding_source!(document)
    end

    def promote_dojo_judge_memory!(stages)
      audits = dojo_judge_audits_for(stages)
      scorecards = dojo_scorecards_for(stages)

      document = existing_dojo_judge_document || organization.training_documents.build
      created = document.new_record?
      body = dojo_judge_training_body(audits, scorecards)
      metadata = dojo_judge_metadata(audits, scorecards)

      if !created && document.body == body && indexed_same_judge_memory?(document, metadata)
        @counts[:judge_documents_skipped] += 1
        return
      end

      return count_judge_dry_run(created) if @dry_run

      document.assign_attributes(
        user: training_user,
        title: "Thumper DOJO JUDGE MEMORY // calibration, scoring, hard misses",
        body: body,
        source_type: SOURCE_TYPE,
        status: "ingested",
        content_type: "text/markdown",
        file_name: "autos-dojo-judge-memory.md",
        byte_size: body.bytesize,
        metadata: document.metadata.to_h.merge(metadata)
      )
      document.save!

      @counts[created ? :judge_documents_created : :judge_documents_updated] += 1
      enqueue_judge_memory!(document)
    rescue StandardError => error
      @errors << "dojo_judge_memory #{error.class}: #{error.message}"
      Rails.logger.warn("[Comms::AutopilotLearning] dojo judge memory failed: #{error.class}: #{error.message}")
    end

    def count_dry_run(created)
      @counts[created ? :lessons_created : :lessons_updated] += 1
    end

    def count_quality_dry_run(created)
      @counts[created ? :quality_documents_created : :quality_documents_updated] += 1
    end

    def count_scorecard_dry_run(created)
      @counts[created ? :scorecard_documents_created : :scorecard_documents_updated] += 1
    end

    def count_judge_dry_run(created)
      @counts[created ? :judge_documents_created : :judge_documents_updated] += 1
    end

    def existing_document_for(stage)
      organization.training_documents
        .where(source_type: SOURCE_TYPE)
        .where("metadata @> ?", { training_kind: TRAINING_KIND, comms_stage_id: stage.id }.to_json)
        .order(updated_at: :desc)
        .first
    end

    def existing_quality_document
      organization.training_documents
        .where(source_type: SOURCE_TYPE)
        .where("metadata @> ?", { training_kind: QUALITY_TRAINING_KIND }.to_json)
        .order(updated_at: :desc)
        .first
    end

    def existing_dojo_scorecard_document
      organization.training_documents
        .where(source_type: SOURCE_TYPE)
        .where("metadata @> ?", { training_kind: DOJO_SCORECARD_TRAINING_KIND }.to_json)
        .where.not(status: "archived")
        .order(updated_at: :desc)
        .first
    end

    def existing_dojo_judge_document
      organization.training_documents
        .where(source_type: SOURCE_TYPE)
        .where("metadata @> ?", { training_kind: DOJO_JUDGE_TRAINING_KIND }.to_json)
        .order(updated_at: :desc)
        .first
    end

    def unchanged_review_record?(document, body, metadata)
      existing = document.metadata.to_h
      return false unless document.body == body
      return false unless existing["sms_thread_digest"].to_s == metadata["sms_thread_digest"].to_s
      return false unless existing["outcome"].to_s == metadata["outcome"].to_s

      learning_status = existing["learning_status"].to_s
      return true if learning_status == "pending_review"
      return true if learning_status.in?(%w[rejected revoked])

      learning_status == "approved_positive" && ActiveModel::Type::Boolean.new.cast(existing["human_reviewed"])
    end

    def indexed_same_quality?(document, metadata)
      document.status == "indexed" &&
        document.metadata.to_h["quality_digest"].to_s == metadata["quality_digest"].to_s
    end

    def indexed_same_scorecards?(document, metadata)
      document.status == "indexed" &&
        document.metadata.to_h["scorecard_digest"].to_s == metadata["scorecard_digest"].to_s
    end

    def indexed_same_judge_memory?(document, metadata)
      document.status == "indexed" &&
        document.metadata.to_h["judge_digest"].to_s == metadata["judge_digest"].to_s
    end

    def enqueue_memory!(document)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      if Autos::EmbeddingQueue.enqueue_source!(document, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
        @counts[:lessons_embedded] += 1
      end
    end

    def enqueue_quality_memory!(document)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      if Autos::EmbeddingQueue.enqueue_source!(document, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
        @counts[:quality_documents_embedded] += 1
      end
    end

    def enqueue_scorecard_memory!(document)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      if Autos::EmbeddingQueue.enqueue_source!(document, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
        @counts[:scorecard_documents_embedded] += 1
      end
    end

    def enqueue_judge_memory!(document)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      if Autos::EmbeddingQueue.enqueue_source!(document, scope: Autos::EmbeddingQueue::DEFAULT_SCOPE)
        @counts[:judge_documents_embedded] += 1
      end
    end

    def enforce_memory_retention!
      archive_old_stage_memory_documents!
      archive_legacy_stage_memory_documents!
      archive_duplicate_singleton_documents!(QUALITY_TRAINING_KIND)
      archive_duplicate_singleton_documents!(DOJO_SCORECARD_TRAINING_KIND)
      archive_duplicate_singleton_documents!(DOJO_JUDGE_TRAINING_KIND)
    rescue StandardError => error
      @errors << "memory_retention #{error.class}: #{error.message}"
      Rails.logger.warn("[Comms::AutopilotLearning] memory retention failed: #{error.class}: #{error.message}")
    end

    def archive_old_stage_memory_documents!
      scope = active_training_documents_for(TRAINING_KIND)
      keep_ids = scope.order(updated_at: :desc, id: :desc).limit(stage_memory_keep_count).pluck(:id)
      overflow_ids = scope.where.not(id: keep_ids).pluck(:id)
      old_ids = scope.where("updated_at < ?", stage_memory_keep_days.days.ago).pluck(:id)
      archive_training_documents!(scope.where(id: (overflow_ids + old_ids).uniq), reason: "rolling_stage_memory_retention")
    end

    def archive_legacy_stage_memory_documents!
      scope = active_training_documents_for(TRAINING_KIND)
        .where("COALESCE(metadata ->> 'learning_status', '') NOT IN (?)", %w[pending_review approved_positive])
      archive_training_documents!(scope, reason: "legacy_stage_memory_without_review_state")
    end

    def retire_unpromotable_stage_memory!(stage, memory)
      document = existing_document_for(stage)
      return if document.blank? || document.status.to_s == "archived" || @dry_run
      return if document.metadata.to_h["learning_status"].to_s == "approved_positive" &&
        ActiveModel::Type::Boolean.new.cast(document.metadata.to_h["human_reviewed"])

      reason = if memory[:simulation]
        "simulator_transcript_not_positive_memory"
      elsif memory[:opt_out]
        "opt_out_transcript_is_safety_memory_only"
      elsif memory[:quality_issues].present?
        "conversation_failed_quality_gate"
      else
        "conversation_no_longer_meets_promotion_gate"
      end
      archive_training_document!(document, reason: reason)
    end

    def archive_duplicate_singleton_documents!(training_kind)
      scope = active_training_documents_for(training_kind).order(updated_at: :desc, id: :desc)
      archive_ids = scope.offset(1).pluck(:id)
      archive_training_documents!(active_training_documents_for(training_kind).where(id: archive_ids), reason: "singleton_memory_consolidation")
    end

    def active_training_documents_for(training_kind)
      organization.training_documents
        .where(source_type: SOURCE_TYPE)
        .where.not(status: "archived")
        .where("metadata @> ?", { training_kind: training_kind }.to_json)
    end

    def archive_training_documents!(documents, reason:)
      documents.find_each do |document|
        archive_training_document!(document, reason: reason)
      end
    end

    def archive_training_document!(document, reason:)
      document.update!(
        status: "archived",
        metadata: document.metadata.to_h.merge(
          "archived_by" => "comms_autopilot_learning_retention",
          "archived_reason" => reason,
          "archived_at" => Time.current.iso8601
        )
      )
      @counts[:memory_documents_archived] += 1
      stale_embedding_source!(document)
    rescue StandardError => error
      @errors << "memory_archive document=#{document&.id} #{error.class}: #{error.message}"
      Rails.logger.warn("[Comms::AutopilotLearning] memory archive failed document=#{document&.id}: #{error.class}: #{error.message}")
    end

    def stale_embedding_source!(document)
      return unless defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?

      if Autos::EmbeddingQueue.delete_source!(document)
        @counts[:memory_embedding_sources_staled] += 1
      end
    end

    def stage_memory_keep_count
      ENV.fetch("THUMPER_AUTOPILOT_STAGE_MEMORY_KEEP_COUNT", DEFAULT_STAGE_MEMORY_KEEP_COUNT.to_s).to_i.clamp(25, 2_000)
    end

    def stage_memory_keep_days
      ENV.fetch("THUMPER_AUTOPILOT_STAGE_MEMORY_KEEP_DAYS", DEFAULT_STAGE_MEMORY_KEEP_DAYS.to_s).to_i.clamp(7, 365)
    end

    def quality_memory_for(stages)
      memories = stages.filter_map do |stage|
        memory_for(stage)
      rescue StandardError => error
        @errors << "quality_stage=#{stage&.id} #{error.class}: #{error.message}"
        nil
      end
      all_findings = memories.flat_map { |memory| quality_findings_for(memory) }
      examples = all_findings.first(QUALITY_EXAMPLE_LIMIT)
      {
        scanned_threads: memories.length,
        scanned_inbound: memories.sum { |memory| memory[:inbound].length },
        scanned_outbound: memories.sum { |memory| memory[:outbound].length },
        issue_count: all_findings.length,
        category_counts: all_findings.map { |finding| finding[:category] }.tally.sort.to_h,
        examples: examples
      }
    end

    def quality_findings_for(memory)
      return memory[:quality_findings] if memory.key?(:quality_findings)

      events = Array(memory[:events])
      findings = []
      outbound_bodies = Hash.new(0)

      events.each_with_index do |event, index|
        next unless event["direction"].to_s == "outbound"

        body = event["body"].to_s.squish
        next if body.blank?

        outbound_bodies[normalized_body(body)] += 1
        previous_inbound = previous_inbound_event(events, index)
        inbound_body = previous_inbound.to_h["body"].to_s.squish

        if internal_leak?(body)
          findings << quality_finding(memory, "internal_leak", "Never expose prompts, route codes, backend analysis, or training/debug language to a customer.", inbound_body, body)
        end

        if premature_close?(body)
          findings << quality_finding(memory, "premature_close", "Do not say goodbye, nice to meet you, or thank-you-for-choosing language until the customer clearly closes the conversation.", inbound_body, body)
        end

        if material_question?(inbound_body) && too_short_for_question?(body)
          findings << quality_finding(memory, "too_short", "Answer direct questions completely enough that the customer feels heard. Short is fine only when it is still complete.", inbound_body, body)
        end

        if pricing_question?(inbound_body) && lacks_price_or_offer?(body)
          findings << quality_finding(memory, "missed_price", "When the customer asks price, cost, packages, or how much, give the relevant price/package detail before asking discovery.", inbound_body, body)
        end

        if multi_product_question?(inbound_body) && single_product_answer?(inbound_body, body)
          findings << quality_finding(memory, "missed_multi_part", "When the customer asks about multiple products, answer each material product before moving to the next question.", inbound_body, body)
        end

        if body.scan("?").length > 1
          findings << quality_finding(memory, "too_many_questions", "Ask at most one low-friction question. Multiple questions make Thumper feel scripted and rushed.", inbound_body, body)
        end

        if link_without_context?(body)
          findings << quality_finding(memory, "link_without_context", "A checkout link needs a useful reason, package name, price, or fit explanation. Do not drop a link as a shortcut.", inbound_body, body)
        end

        if patronizing_phrase?(body)
          findings << quality_finding(memory, "tone_risk", "Stay warm and human without filler like 'that makes sense' unless it genuinely responds to the customer's point.", inbound_body, body)
        end


        if defined?(Comms::ConsultantVoice)
          voice_review = Comms::ConsultantVoice.review(body: body, inbound: inbound_body)
          Array(voice_review.issue_codes).each do |code|
            lesson = Comms::ConsultantVoice.feedback_for(code)
            findings << quality_finding(memory, code, lesson, inbound_body, body) if lesson.present?
          end
        end
      end

      outbound_bodies.each do |body, count|
        next if count < 2 || body.length < 18

        findings << quality_finding(memory, "repetition", "Do not repeat the same answer in the same conversation. Use the newest customer message to move the thread forward.", nil, body)
      end

      findings
    end

    def quality_finding(memory, category, lesson, inbound, outbound)
      {
        category: category,
        lesson: lesson,
        stage_id: memory[:stage]&.id,
        company: memory[:company_name],
        contact: memory[:contact_name],
        inbound: sanitize_body(inbound),
        outbound: sanitize_body(outbound)
      }.compact_blank
    end

    def quality_training_body(quality)
      examples = Array(quality[:examples])
      [
        "# Thumper COMMS QUALITY MEMORY",
        "",
        "Purpose: recursive quality training for Thumper SMS, /ask simulator, follow-up nudges, and email drafting.",
        "Recent audit: #{quality[:scanned_threads]} threads, #{quality[:scanned_inbound]} inbound messages, #{quality[:scanned_outbound]} outbound messages, #{quality[:issue_count]} quality flags.",
        "",
        "## Quality Standard",
        quality_rules.map { |line| "- #{line}" }.join("\n"),
        "",
        "## Recent Quality Findings",
        examples.present? ? examples.map { |finding| quality_finding_line(finding) }.join("\n") : "- No major quality flags in the sampled threads. Keep reinforcing complete, friendly, direct answers.",
        "",
        "## Future Behavior",
        "- Before any customer-facing answer, mentally grade it for: direct answer, completeness, warmth, factual grounding, one next step, no internal leakage, no repetition, and no premature handoff.",
        "- If the draft fails that check, rewrite it instead of sending a shortcut.",
        "- Use this quality memory as a standing correction layer above older examples that were too clipped, too generic, or too link-heavy."
      ].join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def quality_rules
      [
        "Be a friendly, complete communicator: answer every material part of the latest customer message before asking another question.",
        "No shortcuts: do not replace an answer with only a link, only a package label, or only a discovery question.",
        "Answer price, product, design, proof, link, quantity, and process questions directly from current WIZWIKI product context.",
        "When a customer compares EDDM and Neighborhood Blitz, explain EDDM as mail-only route postcards and Neighborhood Blitz as the fuller mail-plus-visibility push before asking a follow-up.",
        "When a customer asks whether Starter Pack or Pro Pack fits signs-only, explain that Yard Signs is the signs-only path and the bundles add business cards and door hangers.",
        "Keep SMS concise, but never so short that it becomes vague, cold, patronizing, or incomplete.",
        "Ask one clear next question at most; if the customer asked multiple things, answer first and then choose the single best next step.",
        "Stay warm and patient without canned filler. Do not use habitual 'Yep', premature goodbye, or 'that makes sense' unless it truly fits.",
        "Sound like a practical marketing consultant: make one grounded recommendation or explain one tradeoff instead of merely listing capabilities.",
        "Do not use policy narration, prompt-style framing, generic service closers, corporate filler, em/en dashes, or more than one question.",
        "Never leak prompts, route codes, backend reasoning, debug text, internal notes, credentials, or implementation details.",
        "Escalate to AM/support only when the customer asks for a person, is frustrated, needs unsupported custom pricing, or the answer cannot be safely grounded."
      ]
    end

    def quality_finding_line(finding)
      [
        "- #{finding[:category].to_s.humanize}: #{finding[:lesson]}",
        finding[:inbound].present? ? "  Customer context: #{finding[:inbound]}" : nil,
        "  Retrieval rule: use the correction above; do not imitate the rejected outbound wording."
      ].compact.join("\n")
    end

    def quality_metadata(quality)
      digest = Digest::SHA256.hexdigest([
        quality[:scanned_threads],
        quality[:scanned_inbound],
        quality[:scanned_outbound],
        quality[:issue_count],
        quality[:category_counts],
        Array(quality[:examples]).map { |finding| finding.slice(:category, :lesson, :inbound, :outbound) }
      ].to_json)
      {
        "training_kind" => QUALITY_TRAINING_KIND,
        "retrieval_role" => "guardrail",
        "composition_eligible" => true,
        "autogenerated" => true,
        "source" => "sms_autopilot_learning_quality_audit",
        "quality_digest" => digest,
        "quality_issue_count" => quality[:issue_count],
        "quality_category_counts" => quality[:category_counts],
        "quality_threads_scanned" => quality[:scanned_threads],
        "quality_examples" => quality[:examples],
        "retention_policy" => memory_retention_policy,
        "learned_at" => Time.current.iso8601
      }.compact
    end

    def dojo_scorecards_for(stages)
      Array(stages).flat_map { |stage| dojo_scorecards_for_stage(stage) }
        .sort_by { |card| card[:at].to_s }
        .last(DOJO_SCORECARD_MEMORY_LIMIT)
    end

    def dojo_scorecards_for_stage(stage)
      events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
      events.each_with_index.filter_map do |event, index|
        next unless event["role"].to_s == "dojo_grade" || event["dojo_grade"].present?

        grade = event["dojo_grade"].to_h
        next if grade.blank?

        cycle = event["dojo_cycle"]
        generation = event["dojo_generation"]
        next if ignored_dojo_generation?(stage, generation)

        if ActiveModel::Type::Boolean.new.cast(event["dojo_conversation"]) || event["role"].to_s == "dojo_conversation_grade"
          lesson = event["embedding_lesson"].presence || grade["embedding_lesson"].presence
          next {
            at: event["created_at"],
            stage_id: stage.id,
            cycle: cycle,
            generation: generation,
            conversation: true,
            conversation_id: event["dojo_conversation_id"].presence,
            conversation_title: sanitize_body(event["dojo_conversation_title"]),
            score: grade["score"].to_i,
            verdict: grade["verdict"].to_s.presence || (grade["score"].to_i >= 85 ? "PASS" : "REVIEW"),
            judge_provider: grade["judge_provider"].presence,
            judge_model: grade["judge_model"].presence,
            scenario: sanitize_body(event["dojo_conversation_transcript"]),
            answer: sanitize_body(event["dojo_conversation_answer_summary"]),
            findings: Array(grade["findings"]).map { |finding| sanitize_body(finding) }.compact_blank.first(8),
            rewrite: sanitize_body(grade["rewrite"]),
            embedding_lesson: sanitize_body(lesson),
            trajectory: event["dojo_trajectory"].presence
          }.compact_blank
        end

        inbound = paired_dojo_event(events, index, direction: "inbound", cycle: cycle, generation: generation)
        answer = paired_dojo_event(events, index, direction: "outbound", role: "dojo_answer", cycle: cycle, generation: generation)
        lesson = event["embedding_lesson"].presence || grade["embedding_lesson"].presence

        {
          at: event["created_at"],
          stage_id: stage.id,
          cycle: cycle,
          generation: generation,
          score: grade["score"].to_i,
          verdict: grade["verdict"].to_s.presence || (grade["score"].to_i >= 85 ? "PASS" : "REVIEW"),
          judge_provider: grade["judge_provider"].presence,
          judge_model: grade["judge_model"].presence,
          scenario: sanitize_body(inbound.to_h["body"]),
          answer: sanitize_body(answer.to_h["body"]),
          findings: Array(grade["findings"]).map { |finding| sanitize_body(finding) }.compact_blank.first(6),
          rewrite: sanitize_body(grade["rewrite"]),
          embedding_lesson: sanitize_body(lesson),
          trajectory: event["dojo_trajectory"].presence
        }.compact_blank
      end
    end

    def paired_dojo_event(events, index, direction:, role: nil, cycle: nil, generation: nil)
      events[0...index].to_a.reverse.find do |event|
        event = event.to_h
        next false unless ActiveModel::Type::Boolean.new.cast(event["recursive_dojo"])
        next false unless event["direction"].to_s == direction.to_s
        next false if role.present? && event["role"].to_s != role.to_s
        next false if cycle.present? && event["dojo_cycle"].to_s != cycle.to_s
        next false if generation.present? && event["dojo_generation"].to_s != generation.to_s

        event["body"].to_s.squish.present?
      end
    end

    def ignored_dojo_generation?(stage, generation)
      generation_key = generation.to_s.presence
      return false if generation_key.blank?

      ignored_dojo_generations(stage).include?(generation_key)
    end

    def ignored_dojo_generations(stage)
      metadata = stage.metadata.to_h
      Array(metadata["recursive_dojo_ignored_generations"]).map(&:to_s) |
        Array(metadata["recursive_dojo_ignore_generations"]).map(&:to_s)
    end

    def dojo_scorecard_training_body(scorecards)
      reviews = Array(scorecards).select { |card| card[:verdict].to_s != "PASS" || card[:score].to_i < 90 }
      passes = Array(scorecards).select { |card| card[:verdict].to_s == "PASS" && card[:score].to_i >= 90 }
      [
        "# Thumper DOJO SCORECARD MEMORY",
        "",
        "Purpose: recursive dojo lessons for Thumper SMS, /ask simulator, follow-up nudges, and email drafting.",
        "This memory is generated from judged practice runs. Treat findings and rewrites as corrections, not customer-facing text to copy blindly.",
        "",
        "## Standing Lessons",
        dojo_standing_lessons.map { |line| "- #{line}" }.join("\n"),
        "",
        "## Recent Review Corrections",
        reviews.present? ? reviews.map { |card| dojo_review_correction_line(card) }.join("\n") : "- No current REVIEW scorecards. Keep using direct, complete, friendly answers.",
        "",
        "## Recent Pass Behaviors",
        passes.first(8).present? ? passes.first(8).map { |card| dojo_pass_line(card) }.join("\n") : "- No high-pass behaviors in this batch yet."
      ].join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def dojo_standing_lessons
      [
        "Answer the latest customer question directly in sentence one; do not chase older scenario context.",
        "Lead source sets the starting lane, but the customer's latest message sets the current lane. Stay in yard signs for yard-sign leads unless the customer clearly asks about another lane.",
        "For pricing, give the relevant dollar amount, package, deal, or comparison before discovery.",
        "For yard signs, quote listed tiers exactly: 10/$99, 20/$159, 50/$249, 100/$399, 250/$899, 500/$1,699, and 1,000/$3,349. Do not quote stale 200/$749 pricing unless live Shopify exposes a 200-sign tier.",
        "For yard-sign customers who ask about direct mail too, answer briefly, ask permission for a marketing consultant handoff, and keep the yard-sign checkout lane alive.",
        "If the customer already gave product, quantity, logo/artwork status, or asked for the link, use that fact and do not ask for it again.",
        "For ZIP/location replies, confirm what the ZIP means and keep the product-fit question grounded.",
        "For design/proof questions, explain checkout first, intake by email after checkout, upload logo/images/wording, proof review, and no print before approval.",
        "For EDDM versus Neighborhood Blitz, compare both: EDDM is mail-only postcards by route; Neighborhood Blitz is the fuller mail plus local visibility path.",
        "For Starter/Pro versus signs-only, say Yard Signs is the signs-only package; Starter and Pro add business cards and door hangers.",
        "For link requests after the customer accepts a route, send the right link instead of asking whether they want to proceed again.",
        "In complete conversations, preserve the already-known route and quantity; do not restart broad discovery after the customer has already chosen signs, postcards, EDDM, or a link-ready package.",
        "Use one question at most, and only after the answer is complete.",
        "Never use prompt-style prefixes such as Quick practical check, One useful detail, Still worth asking, One clean next step, Small practical check, No rush one helpful detail, or Fresh start here.",
        "Do not repeat an answer, ask the same question twice, leak backend language, or rush to AM support when standard product data can answer."
      ]
    end

    def dojo_review_correction_line(card)
      [
        "- REVIEW #{card[:score]}/100: #{dojo_card_label(card)}",
        "  Correction rule: #{dojo_correction_text(card)}",
        "  Trajectory summary: #{dojo_trajectory_summary(card[:trajectory])}",
        "  Retrieval warning: do not copy failed transcripts, repeated Thumper drafts, or trajectory output text from this scorecard; use only the correction rule."
      ].compact.join("\n")
    end

    def dojo_pass_line(card)
      [
        "- PASS #{card[:score]}/100: #{dojo_card_label(card)}",
        "  Safe behavior to preserve: #{dojo_pass_takeaway(card)}",
        "  Trajectory summary: #{dojo_trajectory_summary(card[:trajectory])}"
      ].compact.join("\n")
    end

    def dojo_card_label(card)
      label = card[:conversation_title].presence || card[:scenario].presence || "dojo scorecard"
      sanitize_body(label).squish.truncate(180)
    end

    def dojo_correction_text(card)
      findings = Array(card[:findings]).compact_blank.join(" ").presence
      return sanitize_body(findings).squish.truncate(360) if findings.present?

      note = card[:embedding_lesson].to_s[/Training note:\s*(.+)\z/m, 1].presence
      return sanitize_body(note).squish.truncate(360) if note.present?

      "Answer the latest customer question directly, use known product/quantity/context, and avoid restarting discovery."
    end

    def dojo_pass_takeaway(card)
      title = [card[:conversation_title], card[:scenario]].compact.join(" ").downcase
      if title.include?("checkout") || title.include?("ready to order") || title.include?("link")
        "When the customer has accepted the route or asks for the checkout link, send the correct link instead of repeating pricing or discovery."
      elsif title.include?("postcard") || title.include?("direct mail")
        "When the customer clearly switches lanes, answer the new lane and preserve the original yard-sign context without forcing a combo."
      elsif title.include?("design") || title.include?("artwork") || title.include?("proof")
        "For design questions, explain checkout, intake/upload, proof review, and no printing before approval."
      elsif title.include?("turnaround") || title.include?("timeline") || title.include?("rush")
        "For turnaround questions, answer timing/process first, then ask one practical follow-up only if needed."
      elsif title.include?("pricing") || title.include?("price")
        "For pricing questions, quote the relevant dollar amount first and only ask one natural next question after the answer."
      else
        "Keep the answer direct, complete, friendly, lane-aware, and limited to one natural next question."
      end
    end

    def dojo_trajectory_summary(trajectory)
      payload = trajectory.to_h
      return nil if payload.blank?

      quality = payload["quality"].to_h
      retrieval = payload["retrieval"].to_h
      state = payload["state"].to_h
      [
        "schema=#{payload['schema']}",
        "kind=#{payload['kind']}",
        ("turns=#{payload.dig('input', 'turn_count')}" if payload.dig("input", "turn_count").present?),
        ("score=#{quality['score']}" if quality["score"].present?),
        ("verdict=#{quality['verdict']}" if quality["verdict"].present?),
        ("route=#{state['current_product_lane'] || state['product_interest_code']}" if state["current_product_lane"].presence || state["product_interest_code"].presence),
        ("retrieval_sources=#{Array(retrieval.dig('retrieval', 'source_types')).join(',')}" if Array(retrieval.dig("retrieval", "source_types")).present?)
      ].compact.join("; ").presence
    end

    def compact_dojo_scorecard_example(card)
      {
        stage_id: card[:stage_id],
        cycle: card[:cycle],
        generation: card[:generation],
        conversation: card[:conversation],
        conversation_id: card[:conversation_id],
        conversation_title: card[:conversation_title],
        score: card[:score],
        verdict: card[:verdict],
        correction: dojo_correction_text(card),
        pass_takeaway: card[:verdict].to_s == "PASS" ? dojo_pass_takeaway(card) : nil,
        trajectory_summary: dojo_trajectory_summary(card[:trajectory])
      }.compact_blank
    end

    def dojo_scorecard_metadata(scorecards)
      digest = Digest::SHA256.hexdigest(Array(scorecards).map { |card|
        card.slice(:stage_id, :cycle, :generation, :conversation, :conversation_id, :conversation_title, :score, :verdict, :scenario, :answer, :findings, :rewrite, :embedding_lesson, :trajectory)
      }.to_json)
      {
        "training_kind" => DOJO_SCORECARD_TRAINING_KIND,
        "retrieval_role" => "guardrail",
        "composition_eligible" => true,
        "autogenerated" => true,
        "source" => "recursive_dojo_scorecards",
        "retrieval_priority" => "paramount",
        "scorecard_digest" => digest,
        "scorecard_count" => Array(scorecards).length,
        "scorecard_conversation_count" => Array(scorecards).count { |card| card[:conversation] },
        "scorecard_review_count" => Array(scorecards).count { |card| card[:verdict].to_s != "PASS" || card[:score].to_i < 90 },
        "scorecard_pass_count" => Array(scorecards).count { |card| card[:verdict].to_s == "PASS" && card[:score].to_i >= 90 },
        "scorecard_judges" => Array(scorecards).map { |card| [card[:judge_provider], card[:judge_model]].compact_blank.join(" / ") }.compact_blank.tally,
        "scorecard_examples" => Array(scorecards).last(DOJO_SCORECARD_METADATA_EXAMPLE_LIMIT).map { |card| compact_dojo_scorecard_example(card) },
        "retention_policy" => memory_retention_policy.merge(
          "dojo_scorecard_memory_limit" => DOJO_SCORECARD_MEMORY_LIMIT,
          "dojo_scorecard_metadata_example_limit" => DOJO_SCORECARD_METADATA_EXAMPLE_LIMIT
        ),
        "learned_at" => Time.current.iso8601
      }.compact_blank
    end

    def dojo_judge_audits_for(stages)
      Array(stages).flat_map { |stage| dojo_judge_audits_for_stage(stage) }
        .sort_by { |audit| audit[:at].to_s }
        .last(DOJO_JUDGE_MEMORY_LIMIT)
    end

    def dojo_judge_audits_for_stage(stage)
      events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
      events.each_with_index.filter_map do |event, index|
        next unless event["role"].to_s == "dojo_grade" || event["dojo_grade"].present?

        grade = event["dojo_grade"].to_h
        audit = grade["judge_audit"].to_h
        next if audit.blank?

        cycle = event["dojo_cycle"]
        generation = event["dojo_generation"]
        next if ignored_dojo_generation?(stage, generation)

        inbound = paired_dojo_event(events, index, direction: "inbound", cycle: cycle, generation: generation)
        answer = paired_dojo_event(events, index, direction: "outbound", role: "dojo_answer", cycle: cycle, generation: generation)

        {
          at: event["created_at"],
          stage_id: stage.id,
          cycle: cycle,
          generation: generation,
          audit_status: audit["status"].presence || "accepted",
          original_score: audit["original_score"].presence,
          original_verdict: audit["original_verdict"].presence,
          calibrated_score: audit["calibrated_score"].presence || grade["score"],
          calibrated_verdict: audit["calibrated_verdict"].presence || grade["verdict"],
          max_allowed_score: audit["max_allowed_score"].presence,
          fallback_score: audit["fallback_score"].presence || grade["fallback_score"],
          fallback_verdict: audit["fallback_verdict"].presence || grade["fallback_verdict"],
          judge_provider: grade["judge_provider"].presence,
          judge_model: grade["judge_model"].presence,
          scenario: sanitize_body(inbound.to_h["body"]),
          answer: sanitize_body(answer.to_h["body"]),
          findings: Array(audit["findings"]).presence || Array(grade["findings"]),
          calibration_lessons: Array(audit["calibration_lessons"]).presence,
          embedding_lesson: sanitize_body(grade["embedding_lesson"])
        }.compact_blank
      end
    end

    def dojo_judge_training_body(audits, scorecards)
      calibrated = Array(audits).select { |audit| audit[:audit_status].to_s == "calibrated" }
      accepted = Array(audits).select { |audit| audit[:audit_status].to_s == "accepted" }
      reviews = Array(scorecards).select { |card| card[:verdict].to_s != "PASS" || card[:score].to_i < 90 }
      [
        "# Thumper DOJO JUDGE MEMORY",
        "",
        "Purpose: calibration memory for Recursive Dojo, the independent grader for Thumper. This trains the judge, not the customer-facing copy.",
        "Recent audit: #{Array(audits).length} judge audits and #{Array(scorecards).length} scorecards reviewed.",
        "",
        "## Non Negotiable Judge Rules",
        dojo_judge_rules.map { |line| "- #{line}" }.join("\n"),
        "",
        "## Recent Judge Calibration Misses",
        calibrated.present? ? calibrated.map { |audit| dojo_judge_audit_line(audit) }.join("\n") : "- No recent calibrated misses. Keep applying the hard rules before passing an answer.",
        "",
        "## Accepted Judge Patterns",
        accepted.first(8).present? ? accepted.first(8).map { |audit| dojo_judge_audit_line(audit) }.join("\n") : "- No accepted judge patterns in this batch yet.",
        "",
        "## Scorecard Cross Checks",
        reviews.first(8).present? ? reviews.first(8).map { |card| dojo_judge_scorecard_line(card) }.join("\n") : "- No current REVIEW scorecards needing extra judge calibration."
      ].join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def dojo_judge_rules
      [
        "The judge grades the Thumper answer, not the customer scenario, and must name concrete answer defects.",
        "PASS requires a sendable answer: direct, complete, warm, factually exact, customer-facing, and one question max.",
        "Judge vibe like a senior Thumper operator. A technically safe answer is still REVIEW if it feels clipped, robotic, patronizing, evasive, canned, or over-guardrailed.",
        "Reward practical beauty: direct answer first, a useful reason or detail, plain complete sentences, and one natural next step that feels specific to the customer's message.",
        "Lead source sets the starting lane; the customer's latest message sets the current lane. Penalize broad product discovery when the customer has already chosen yard signs, door hangers, postcards, or a bundle.",
        "Do not let the drafter hide behind policy language such as exact pricing can vary, safely price, or account manager reach-out when standard product guidance can answer first.",
        "Wrong offer names are material. $299 for 20 signs, 500 business cards, and 500 door hangers is Starter Pack, not Yard Signs package.",
        "Wrong offer names are material. $599 for 100 signs, 1,000 business cards, and 1,000 door hangers is Pro Pack, not Yard Signs package.",
        "Yard Signs package tiers are signs-only: 10 signs $99, 20 $159, 50 $249, 100 $399, 250 $899, 500 $1,699, 1,000 $3,349.",
        "Do not quote 200 yard signs for $749 as a standard checkout tier unless live Shopify shows a 200-sign option; current live standard quantities skip from 100 to 250.",
        "A yard-sign customer who asks about direct mail should get a brief direct-mail answer and permission-based marketing consultant handoff while preserving the yard-sign order/link path.",
        "Prompt-style prefixes such as Quick practical check, One useful detail, Still worth asking, One clean next step, Small practical check, No rush one helpful detail, or Fresh start here are material REVIEW.",
        "EDDM versus Neighborhood Blitz is a direct comparison question: PASS requires explaining mail-only EDDM versus fuller mail-plus-visibility Neighborhood Blitz.",
        "Starter/Pro versus signs-only is a direct product-fit question: PASS requires saying Yard Signs is cleaner for signs-only and bundles add business cards and door hangers.",
        "If a customer asks price, package, cost, dollars, bucks, or dolla, the answer needs real dollars before discovery.",
        "If a customer accepts a recommendation or asks for a link, no link means REVIEW unless the answer explains why it cannot safely link.",
        "Design/proof answers must explain checkout first, intake/upload by email after checkout, proof review, and no print before approval.",
        "Internal reasoning, fallback/default text, JSON, route codes, or prompt language leaking to the customer is severe REVIEW.",
        "When deterministic hard checks flag a material issue, the judge must explicitly resolve it or preserve REVIEW."
      ]
    end

    def dojo_judge_audit_line(audit)
      [
        "- #{audit[:audit_status].to_s.upcase}: #{audit[:original_score] || '?'} #{audit[:original_verdict] || '?'} -> #{audit[:calibrated_score] || '?'} #{audit[:calibrated_verdict] || '?'}",
        Array(audit[:calibration_lessons]).present? ? "  Calibration: #{Array(audit[:calibration_lessons]).join(' ')}" : nil,
        Array(audit[:findings]).present? ? "  Findings: #{Array(audit[:findings]).join(' ')}" : nil,
        audit[:scenario].present? ? "  Customer context: #{audit[:scenario]}" : nil,
        "  Retrieval rule: apply the calibration lesson; do not imitate the judged answer."
      ].compact.join("\n")
    end

    def dojo_judge_scorecard_line(card)
      [
        "- #{card[:verdict]} #{card[:score]}/100: #{card[:embedding_lesson].presence || Array(card[:findings]).join(' ')}",
        card[:conversation] && card[:conversation_title].present? ? "  Complete conversation: #{card[:conversation_title]}" : nil,
        card[:scenario].present? ? "  Customer context: #{card[:scenario]}" : nil,
        Array(card[:findings]).present? ? "  Judge findings: #{Array(card[:findings]).join(' ')}" : nil
      ].compact.join("\n")
    end

    def dojo_judge_metadata(audits, scorecards)
      digest = Digest::SHA256.hexdigest({
        audits: Array(audits).map { |audit| audit.slice(:stage_id, :cycle, :generation, :audit_status, :original_score, :calibrated_score, :scenario, :answer, :findings, :calibration_lessons) },
        scorecards: Array(scorecards).map { |card| card.slice(:stage_id, :cycle, :generation, :conversation, :conversation_id, :conversation_title, :score, :verdict, :scenario, :answer, :findings) }
      }.to_json)
      {
        "training_kind" => DOJO_JUDGE_TRAINING_KIND,
        "retrieval_role" => "judge_calibration",
        "composition_eligible" => false,
        "autogenerated" => true,
        "source" => "recursive_dojo_judge_calibration",
        "retrieval_priority" => "paramount",
        "judge_digest" => digest,
        "judge_audit_count" => Array(audits).length,
        "judge_calibrated_count" => Array(audits).count { |audit| audit[:audit_status].to_s == "calibrated" },
        "judge_accepted_count" => Array(audits).count { |audit| audit[:audit_status].to_s == "accepted" },
        "judge_scorecard_count" => Array(scorecards).length,
        "judge_examples" => Array(audits).last(DOJO_JUDGE_METADATA_EXAMPLE_LIMIT),
        "retention_policy" => memory_retention_policy.merge(
          "dojo_judge_memory_limit" => DOJO_JUDGE_MEMORY_LIMIT,
          "dojo_judge_metadata_example_limit" => DOJO_JUDGE_METADATA_EXAMPLE_LIMIT
        ),
        "learned_at" => Time.current.iso8601
      }.compact_blank
    end

    def memory_retention_policy
      {
        "stage_memory_keep_count" => stage_memory_keep_count,
        "stage_memory_keep_days" => stage_memory_keep_days,
        "quality_memory_documents" => 1,
        "dojo_scorecard_memory_documents" => 1,
        "dojo_judge_memory_documents" => 1,
        "archived_embedding_chunks_are_staled" => true
      }
    end

    def previous_inbound_event(events, index)
      events[0...index].to_a.reverse.find { |event| event.to_h["direction"].to_s == "inbound" }
    end

    def normalized_body(body)
      body.to_s.downcase.gsub(%r{https?://\S+}, "[link]").gsub(/\s+/, " ").strip
    end

    def material_question?(body)
      body.to_s.match?(/\?|(?:\b(?:how much|price|pricing|cost|can i|do you|what about|what is|where|when|how do|link|artwork|proof|design|logo|upload|zip|signs?|postcards?|business cards?|door hangers?)\b)/i)
    end

    def pricing_question?(body)
      body.to_s.match?(/\b(price|pricing|cost|how much|\$\d+|dollars?|bucks?|package|deal|special)\b/i)
    end

    def too_short_for_question?(body)
      body.to_s.scan(/[[:alnum:]]+/).length < 18
    end

    def lacks_price_or_offer?(body)
      !body.to_s.match?(/\$\d+|\b\d+\s*(?:signs?|cards?|postcards?|door hangers?)\b|\b(starter|pro|pack|package|deal|special|bundle)\b/i)
    end

    def multi_product_question?(body)
      product_hits(body).length >= 2
    end

    def single_product_answer?(inbound, outbound)
      asked = product_hits(inbound)
      answered = product_hits(outbound)
      asked.length >= 2 && (asked - answered).present?
    end

    def product_hits(body)
      text = body.to_s.downcase
      products = []
      products << "postcards" if text.match?(/\b(postcards?|mailers?|eddm)\b/)
      products << "signs" if text.match?(/\b(signs?|yard signs?|lawn signs?)\b/)
      products << "business cards" if text.match?(/\b(business cards?|cards?)\b/)
      products << "door hangers" if text.match?(/\b(door hangers?|hangers?)\b/)
      products.uniq
    end

    def internal_leak?(body)
      text = body.to_s.squish
      return false if text.blank?

      text = Comms::SmsBodySafety.without_opt_out_notice(text) if defined?(Comms::SmsBodySafety)
      return false if text.blank?
      return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)

      text.match?(/\b(FINAL ANSWER|VISIBLE ANSWER|CUSTOMER-FACING|we are given|voice rules|context provided|processing_code|CONTACT_OWNER|route code|guardrail|fallback|prompt|backend|metadata|json)\b/i)
    end

    def premature_close?(body)
      body.to_s.match?(/\b(goodbye|have a great day|nice to meet you|thank you for choosing)\b/i)
    end

    def link_without_context?(body)
      body.to_s.match?(%r{https?://\S+|shop\.wizwikimarketing\.com}i) &&
        body.to_s.scan(/[[:alnum:]]+/).length < 24
    end

    def patronizing_phrase?(body)
      body.to_s.match?(/\b(that makes sense|obviously|as I said|like I mentioned|you just need to)\b/i)
    end

    def memory_for(stage)
      metadata = stage.metadata.to_h
      events = sms_events(metadata)
      inbound = events.select { |event| event["direction"].to_s == "inbound" }
      outbound = events.select { |event| event["direction"].to_s == "outbound" }
      memory = {
        stage: stage,
        metadata: metadata,
        events: events,
        inbound: inbound,
        outbound: outbound,
        outcome: outcome_for(stage, metadata, events),
        product_code: metadata["product_interest_code"].presence || metadata["processing_code"].presence,
        product_label: metadata["product_interest_label"].presence || metadata["processing_label"].presence,
        support_state: metadata["comms_support_state"].presence,
        company_name: company_name(stage, metadata),
        contact_name: contact_name(metadata),
        link_sent: link_sent?(metadata, events),
        opt_out: do_not_contact?(metadata, events),
        am_handoff: am_handoff?(metadata),
        completed: completed?(metadata),
        simulation: simulation_stage?(metadata),
        thread_digest: Digest::SHA256.hexdigest(events.map { |event| [event["direction"], event["status"], event["body"]].join("|") }.join("\n")),
        useful_patterns: useful_patterns(metadata, events)
      }
      memory[:quality_findings] = quality_findings_for(memory)
      memory[:quality_issues] = memory[:quality_findings].map { |finding| finding[:category] }.uniq
      memory
    end

    def promotable?(memory)
      return false if memory[:simulation] || memory[:opt_out]
      return false if memory[:inbound].blank? || memory[:outbound].blank?
      return false if memory[:quality_issues].present?
      return false unless approved_outbound_sources?(memory[:outbound])
      return true if %w[link_sent am_handoff completed].include?(memory[:outcome])
      return true if memory[:outcome] == "customer_replied" && memory[:inbound].size >= 2 && memory[:outbound].size >= 2

      false
    end

    def outcome_for(_stage, metadata, events)
      return "opt_out" if do_not_contact?(metadata, events)
      return "am_handoff" if am_handoff?(metadata)
      return "completed" if completed?(metadata)
      return "link_sent" if link_sent?(metadata, events)
      return "customer_replied" if events.any? { |event| event["direction"].to_s == "inbound" }

      "open"
    end

    def do_not_contact?(metadata, events)
      ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"]) ||
        metadata["sms_do_not_contact_at"].present? ||
        metadata["comms_command_last_status"].to_s == "do_not_contact" ||
        events.any? { |event| event["direction"].to_s == "inbound" && event["body"].to_s.match?(/\b(stop|unsubscribe|do not text|don't text|dont text|remove me)\b/i) }
    end

    def am_handoff?(metadata)
      metadata["comms_support_state"].to_s == "am_support" ||
        metadata["sms_autopilot_slack_handoff_at"].present? ||
        metadata["sms_autopilot_slack_human_requested_at"].present? ||
        metadata["sms_autopilot_slack_completion_without_purchase_at"].present? ||
        metadata["contact_owner_assigned_at"].present? ||
        metadata["processing_code"].to_s == "CONTACT_OWNER"
    end

    def completed?(metadata)
      metadata["sms_autopilot_completed_at"].present? ||
        metadata["sms_autopilot_completion_sent_at"].present? ||
        ActiveModel::Type::Boolean.new.cast(metadata.dig("comms_bot_state", "autopilot_complete"))
    end

    def link_sent?(metadata, events)
      events.any? { |event| event["direction"].to_s == "outbound" && event["body"].to_s.match?(%r{https?://\S+|shop\.wizwikimarketing\.com}i) }
    end

    def simulation_stage?(metadata)
        ActiveModel::Type::Boolean.new.cast(metadata["ask_autopilot_test"]) ||
        ActiveModel::Type::Boolean.new.cast(metadata["comms_simulation_mode"]) ||
        metadata["recursive_dojo_status"].present? ||
        ActiveModel::Type::Boolean.new.cast(metadata["simulation_mode"])
    end

    def approved_outbound_sources?(outbound)
      Array(outbound).all? do |event|
        status = event["status"].to_s
        source = event["draft_source"].to_s
        !status.in?(%w[failed canceled undelivered blocked skipped]) &&
          !source.in?(%w[fallback guardrail_override])
      end
    end

    def useful_patterns(metadata, events)
      text = events.map { |event| event["body"].to_s }.join("\n")
      patterns = []
      patterns << "customer asked a pricing or cost question" if text.match?(/\b(price|pricing|cost|how much|\$\d+)\b/i)
      patterns << "customer asked about artwork, logo, or design support" if text.match?(/\b(artwork|design|logo|file|creative)\b/i)
      patterns << "customer asked for an unavailable/custom quantity or bundle change" if text.match?(/\b(\d+\s+(?:signs?|cards?|door hangers?|postcards?)|more\s+door|instead|swap|custom quote|custom quantity)\b/i)
      patterns << "customer changed product direction mid-thread" if product_change_signal?(text)
      patterns << "customer asked for human/account manager help" if text.match?(/\b(person|human|rep|salesperson|account manager|call me|talk to someone)\b/i)
      patterns << "checkout link was sent" if link_sent?(metadata, events)
      patterns << "thread ended with AM support" if am_handoff?(metadata)
      patterns << "thread ended with opt-out" if do_not_contact?(metadata, events)
      patterns.presence || ["general SMS discovery thread"]
    end

    def product_change_signal?(text)
      text.match?(/\b(what about|instead|rather|only|just)\b/i) &&
        text.match?(/\b(postcards?|mailers?|eddm|signs?|yard signs?|lawn signs?|door hangers?|business cards?)\b/i)
    end

    def training_body(memory)
      [
        "# Thumper CONVERSATION LEARNING",
        "",
        "Evidence status: passed automated candidate gates and awaits human review.",
        "Usage after approval: imitate the conversational decision pattern, not exact wording or stale facts.",
        "Outcome: #{memory[:outcome].to_s.humanize}",
        "Product route: #{[memory[:product_code], memory[:product_label]].compact_blank.join(' // ').presence || 'pending'}",
        "Thread shape: #{memory[:inbound].size} inbound / #{memory[:outbound].size} outbound",
        "",
        "## What Thumper Should Learn",
        learning_bullets(memory).map { |line| "- #{line}" }.join("\n"),
        "",
        "## Useful Pattern Tags",
        memory[:useful_patterns].map { |line| "- #{line}" }.join("\n"),
        "",
        "## SMS Thread Excerpts",
        thread_excerpt(memory[:events]).presence || "- No usable excerpt.",
        "",
        "## Future Behavior",
        future_behavior(memory).map { |line| "- #{line}" }.join("\n")
      ].join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def learning_bullets(memory)
      bullets = []
      bullets << "Use the latest inbound SMS as the authority over older vector context."
      bullets << "Answer the customer's direct question first, then ask only one next-step question."
      bullets << "Be friendly and complete: if the customer asks multiple material questions, answer each one before asking anything new."
      bullets << "Do not use a link, package label, or discovery question as a shortcut when the customer needs a real explanation."
      bullets << "Do not repeat any prior outbound wording from the same thread."
      bullets << "When a product fit and one numeric signal are known, recommend the best offer and close with the right Shopify link." if memory[:link_sent]
      bullets << "When the customer asks for unavailable quantities, bundle swaps, custom quotes, order/payment help, or a human, route to an account manager instead of forcing a checkout link." if memory[:am_handoff]
      bullets << "If the customer opts out, stop automation and keep the block out of active COMMS." if memory[:opt_out]
      bullets << "Pricing, artwork, logo, design, turnaround, quantity, and package-fit questions should be answered from normalized product details and fine-training docs before asking another discovery question."
      bullets
    end

    def future_behavior(memory)
      case memory[:outcome]
      when "link_sent"
        ["Use this as a positive example of moving from discovery to a concrete product recommendation.", "After sending a link, future follow-ups should ask whether the option helped or whether they want help choosing."]
      when "am_handoff"
        ["Use this as a handoff example: keep the customer cared for, assign a contact owner, and ask how or when they prefer to be reached.", "Do not keep pushing checkout when the request needs a custom answer."]
      when "opt_out"
        ["Treat similar language as do-not-contact intent and stop sending."]
      when "completed"
        ["Use this as a completion example: thank the customer, confirm WIZWIKI will get the account set up, and stay available for questions."]
      else
        ["Use this as discovery context, not a finished sales pattern.", "Move toward product fit, budget or quantity, and a helpful link without sounding scripted."]
      end
    end

    def thread_excerpt(events)
      events.last(18).map do |event|
        direction = event["direction"].to_s.upcase.presence || "SMS"
        status = event["status"].to_s.presence
        body = sanitize_body(event["body"])
        next if body.blank?

        "- #{direction}#{status.present? ? " / #{status}" : nil}: #{body}"
      end.compact.join("\n")
    end

    def sanitize_body(value)
      value.to_s
        .gsub(/\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i, "[email]")
        .gsub(/\+?\d[\d\s().-]{7,}\d/, "[phone]")
        .squish
        .truncate(MAX_EVENT_BODY_CHARS)
    end

    def training_metadata(stage, memory)
      metadata = {
        "training_kind" => TRAINING_KIND,
        "learning_status" => "pending_review",
        "retrieval_role" => "quarantined_memory",
        "composition_eligible" => false,
        "human_review_required" => true,
        "human_reviewed" => false,
        "quality_gate" => "automated_candidate_passed",
        "quality_issue_count" => 0,
        "candidate_score" => candidate_score(memory),
        "candidate_evidence" => candidate_evidence(memory),
        "autogenerated" => true,
        "source" => "sms_autopilot_learning",
        "comms_stage_id" => stage.id,
        "crm_record_id" => stage.crm_record_id,
        "outcome" => memory[:outcome],
        "product_interest_code" => memory[:product_code],
        "product_interest_label" => memory[:product_label],
        "support_state" => memory[:support_state],
        "sms_event_count" => memory[:events].size,
        "sms_inbound_count" => memory[:inbound].size,
        "sms_outbound_count" => memory[:outbound].size,
        "sms_thread_digest" => memory[:thread_digest],
        "link_sent" => memory[:link_sent],
        "am_handoff" => memory[:am_handoff],
        "opt_out" => memory[:opt_out],
        "completed" => memory[:completed],
        "embedding_scope" => "wizwiki_sms_learning",
        "pii_policy" => "phone_email_redacted_names_excluded_from_vector_body",
        "retention_policy" => memory_retention_policy,
        "learned_at" => Time.current.iso8601
      }
      metadata.compact
    end

    def training_title(stage, memory)
      route = memory[:product_label].presence || memory[:product_code].to_s.humanize.presence || "GENERAL SMS"
      "Thumper LEARNING CANDIDATE // #{route.to_s.squish.truncate(42)} // #{memory[:outcome].to_s.upcase} // STAGE #{stage.id}"
    end

    def candidate_score(memory)
      score = 45
      score += 15 if memory[:inbound].size >= 2
      score += 10 if memory[:outbound].size >= 2
      score += 15 if memory[:outcome].in?(%w[link_sent am_handoff completed])
      score += 5 if memory[:product_code].present? || memory[:product_label].present?
      score += 10 if memory[:quality_issues].blank?
      score.clamp(0, 95)
    end

    def candidate_evidence(memory)
      evidence = [
        "#{memory[:inbound].size} customer message#{'s' unless memory[:inbound].size == 1}",
        "#{memory[:outbound].size} delivered outbound message#{'s' unless memory[:outbound].size == 1}",
        "automated quality and consultant-voice gates passed",
        "observed outcome: #{memory[:outcome].to_s.humanize}"
      ]
      evidence << "product route captured" if memory[:product_code].present? || memory[:product_label].present?
      evidence << "checkout link reached" if memory[:link_sent]
      evidence << "human handoff reached" if memory[:am_handoff]
      evidence << "conversation completion reached" if memory[:completed]
      evidence
    end

    def company_name(stage, metadata)
      metadata["company_name"].presence ||
        metadata["captured_company_name"].presence ||
        stage.crm_record&.name.to_s.presence
    end

    def contact_name(metadata)
      selected_id = metadata["selected_contact_id"].to_s
      contacts = Array(metadata["contact_options"])
      selected = contacts.find { |option| option.to_h["id"].to_s == selected_id }
      selected.to_h["name"].presence ||
        contacts.first.to_h["name"].presence ||
        metadata["captured_contact_name"].presence
    end

    def sms_events(metadata)
      Array(metadata["sms_thread"]).filter_map do |event|
        event = event.to_h
        next unless event["channel"].to_s == "sms"
        next if ActiveModel::Type::Boolean.new.cast(event["recursive_dojo"])
        next if event["role"].to_s.start_with?("dojo_")
        next if ActiveModel::Type::Boolean.new.cast(event["language_preference_notice"])
        next if ActiveModel::Type::Boolean.new.cast(event["do_not_contact_confirmation"])
        next if event["status"].to_s.in?(NON_LEARNING_SMS_STATUSES)

        body = if event["direction"].to_s == "outbound" && event["english_body"].to_s.squish.present?
          event["english_body"].to_s
        else
          event["body"].to_s
        end
        next if body.squish.blank?

        event.slice("direction", "status", "body", "created_at", "processing_code", "processing_label")
          .merge("body" => body)
          .merge(event.slice("draft_source", "sms_quality_gate", "guardrail_override", "provider"))
      end
    end

    def training_user
      @training_user ||= organization.users.order(:id).first
    end

    def publish_result
      return unless defined?(Autos::MemoryBus)

      Autos::MemoryBus.publish("comms.autopilot_learning", {
        organization_id: organization.id,
        result: result.to_h,
        generated_at: Time.current.iso8601
      })
    rescue StandardError => error
      Rails.logger.warn("[Comms::AutopilotLearning] memory bus publish failed #{error.class}: #{error.message}")
    end
  end
end
