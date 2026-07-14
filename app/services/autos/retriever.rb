# frozen_string_literal: true

module Autos
  class Retriever
    DEFAULT_SCOPE = Autos::EmbeddingQueue::DEFAULT_SCOPE
    DEFAULT_LIMIT = 8
    DEFAULT_CANDIDATE_LIMIT = 40
    TERM_LIMIT = 14
    STOPWORDS = %w[
      about after again also around because before being build can could did does dont each from give have into just
      like make need only over please should some than that their them then there these they this want what when where
      which with would your youre you and are for how the use was were why yes
    ].freeze

    SOURCE_WEIGHTS = {
      "TrainingDocument" => 1.22,
      "TrainingVaultDocument" => 1.2,
      "CrmRecordArtifact" => 1.08,
      "PlaybookCall" => 1.04,
      "FathomCall" => 1.04,
      "CrmRecord" => 0.96,
      "CrmAddressRecord" => 0.92,
      "WeatherLeadSignal" => 0.88,
      "AutosQuestion" => 0.82
    }.freeze

    COMMS_SOURCE_WEIGHTS = SOURCE_WEIGHTS.merge(
      "TrainingDocument" => 1.3,
      "TrainingVaultDocument" => 1.26,
      "CrmRecordArtifact" => 1.16,
      "PlaybookCall" => 1.08,
      "FathomCall" => 1.08
    ).freeze

    AUTHORITY_WEIGHTS = {
      "paramount" => 1.2,
      "canonical" => 1.18,
      "pricing" => 1.16,
      "product" => 1.12,
      "high" => 1.1,
      "medium" => 1.0,
      "low" => 0.9
    }.freeze

    RETRIEVAL_ROLE_WEIGHTS = {
      "voice_authority" => 1.24,
      "fact_authority" => 1.22,
      "procedural_skill" => 1.16,
      "guardrail" => 1.1,
      "curated_example" => 1.08,
      "positive_example" => 1.06,
      "training_reference" => 1.0
    }.freeze
    COMPOSITION_BLOCKED_ROLES = %w[judge_calibration quarantined_memory negative_example].freeze

    class << self
      def call(organization:, query:, embedding: nil, embedding_model: nil, scope: DEFAULT_SCOPE, surface: nil, limit: DEFAULT_LIMIT, candidate_limit: DEFAULT_CANDIDATE_LIMIT, source_types: nil)
        new(
          organization: organization,
          query: query,
          embedding: embedding,
          embedding_model: embedding_model,
          scope: scope,
          surface: surface,
          limit: limit,
          candidate_limit: candidate_limit,
          source_types: source_types
        ).call
      end

      def citations_for(results)
        Array(results).map do |result|
          item = result.to_h
          {
            chunk_id: item[:id] || item["id"],
            source_type: item[:source_type] || item["source_type"],
            source_id: item[:source_id] || item["source_id"],
            label: item[:label] || item["label"],
            citation: item[:citation] || item["citation"],
            score: item[:score] || item["score"]
          }.compact_blank
        end
      end
    end

    def initialize(organization:, query:, embedding:, embedding_model:, scope:, surface:, limit:, candidate_limit:, source_types:)
      @organization = organization
      @query = query.to_s.squish
      @embedding = embedding
      @embedding_model = embedding_model.to_s.presence || Autos::EmbeddingQueue.embedder_model
      @scope = scope.to_s.presence || DEFAULT_SCOPE
      @surface = surface.to_s.presence || "ask"
      @limit = limit.to_i.clamp(1, 30)
      @candidate_limit = candidate_limit.to_i.clamp(@limit, 50)
      @source_types = Array(source_types).flat_map { |value| value.to_s.split(",") }.map(&:strip).compact_blank.presence
      @terms = query_terms(@query)
    end

    def call
      return empty_pack(reason: "vector storage not ready") unless storage_ready?
      return empty_pack(reason: "organization missing") if organization.blank?
      return empty_pack(reason: "query and embedding missing") if query.blank? && normalized_embedding.blank?

      vector = vector_candidates
      keyword = keyword_candidates
      merged = merge_candidates(vector, keyword)
      ranked = merged.sort_by { |item| [-(item[:rank_score] || item[:score]).to_f, item[:distance].to_f, item[:label].to_s] }.first(limit)

      {
        ok: true,
        query: query,
        rewritten_query: rewritten_query,
        scope: scope,
        surface: surface,
        embedding_model: embedding_model,
        results: ranked,
        evidence: self.class.citations_for(ranked),
        retrieval_debug: {
          mode: retrieval_mode(vector, keyword),
          vector_candidates: vector.length,
          keyword_candidates: keyword.length,
          merged_candidates: merged.length,
          returned: ranked.length,
          candidate_limit: candidate_limit,
          limit: limit,
          terms: terms,
          source_types: source_types
        }.compact_blank
      }
    rescue StandardError => error
      Rails.logger.warn("[Autos::Retriever] failed org=#{organization&.id} surface=#{surface} #{error.class}: #{error.message}")
      empty_pack(reason: "#{error.class}: #{error.message}", ok: false)
    end

    private

    attr_reader :organization, :query, :embedding, :embedding_model, :scope, :surface, :limit, :candidate_limit, :source_types, :terms

    def vector_candidates
      return [] if normalized_embedding.blank?

      Autos::EmbeddingQueue.search(
        organization: organization,
        embedding: normalized_embedding,
        embedding_model: embedding_model,
        scope: scope,
        limit: candidate_limit,
        source_types: source_types
      ).select do |item|
        source_allowed?(item[:source_type] || item["source_type"]) && candidate_allowed?(item)
      end
    end

    def keyword_candidates
      return [] if terms.blank?

      resource_candidates = keyword_rows(canonical_resource_scope_for_search, candidate_limit)
        .map { |row| result_from_row(row, keyword_score: keyword_score_for(row)) }
        .select { |item| candidate_allowed?(item) }
      return resource_candidates.first(candidate_limit) if strong_resource_match?(resource_candidates)

      source_aware_candidates = source_aware_keyword_candidates
      return source_aware_candidates if source_aware_candidates.present?

      fallback_limit = resource_candidates.present? ? [candidate_limit - resource_candidates.length, limit].min : candidate_limit
      fallback_scope = scope_for_search
      fallback_scope = fallback_scope.where.not(id: resource_candidates.map { |item| item.fetch(:id) }) if resource_candidates.present?
      fallback_candidates = if fallback_limit.positive?
        keyword_rows(fallback_scope, fallback_limit)
          .map { |row| result_from_row(row, keyword_score: keyword_score_for(row)) }
          .select { |item| candidate_allowed?(item) }
      else
        []
      end

      (resource_candidates + fallback_candidates)
        .first(candidate_limit)
    end

    def keyword_rows(rows, row_limit)
      return [] if row_limit.to_i <= 0

      rows
        .where([keyword_clauses, *keyword_binds])
        .order(updated_at: :desc, id: :desc)
        .limit(row_limit)
    end

    def scope_for_search
      # Pending content is not query-ready and can turn keyword fallback into a multi-million-row scan.
      rows = AutosEmbeddingChunk
        .where(organization: organization, scope: scope, embedding_model: embedding_model)
        .where(status: "embedded")
      rows = rows.where(source_type: source_types) if source_types.present?
      if comms_composition_surface?
        rows = rows.where("COALESCE(metadata ->> 'composition_eligible', 'true') <> 'false'")
          .where("COALESCE(metadata ->> 'retrieval_role', '') NOT IN (?)", COMPOSITION_BLOCKED_ROLES)
      end
      rows
    end

    def canonical_resource_scope_for_search
      resource_ids = TrainingDocument
        .where(organization: organization)
        .where("metadata ->> 'training_kind' = ?", "rag_canonical_resource")
        .pluck(:id)
      return scope_for_search.none if resource_ids.blank?

      scope_for_search.where(source_type: "TrainingDocument", source_id: resource_ids)
    rescue StandardError
      scope_for_search.none
    end

    def source_aware_keyword_candidates
      rows, prefix = if recent_call_recommendation_query?
        [
          recent_call_rows(limit),
          "Source-aware ask fallback: recent calls; call summaries; suggested next actions; associated CRM records."
        ]
      elsif crm_pipeline_query?
        return (crm_pipeline_candidates((limit / 2.0).ceil) + recent_call_candidates((limit / 2.0).floor)).first(limit)
      else
        [[], nil]
      end

      rows.map { |row| result_from_row(row, keyword_score: 0.42, text_prefix: prefix) }
    end

    def recent_call_recommendation_query?
      terms.include?("recent") && terms.any? { |term| term.in?(%w[call calls]) } && terms.any? { |term| term.in?(%w[account accounts recommendation recommendations]) }
    end

    def crm_pipeline_query?
      terms.include?("crm") && terms.any? { |term| term.in?(%w[opportunity opportunities ticket tickets deal deals]) }
    end

    def recent_call_rows(row_limit)
      rows = []

      if source_allowed?("FathomCall") && defined?(FathomCall)
        source_ids = FathomCall.where(organization: organization).active.recent.limit(row_limit).pluck(:id)
        rows.concat(rows_for_source_ids("FathomCall", source_ids, row_limit))
      end

      if rows.length < row_limit && source_allowed?("PlaybookCall") && defined?(PlaybookCall)
        source_ids = PlaybookCall
          .where(organization: organization)
          .where.not(status: "archived")
          .order(occurred_at: :desc, updated_at: :desc)
          .limit(row_limit)
          .pluck(:id)
        rows.concat(rows_for_source_ids("PlaybookCall", source_ids, row_limit - rows.length))
      end

      rows.first(row_limit)
    end

    def recent_call_candidates(row_limit)
      prefix = "Source-aware ask fallback: tickets; deals; recent call evidence; company links."
      recent_call_rows(row_limit).map { |row| result_from_row(row, keyword_score: 0.42, text_prefix: prefix) }
    end

    def crm_pipeline_candidates(row_limit)
      return [] unless source_allowed?("CrmRecord") && defined?(CrmRecord)

      CrmRecord
        .where(organization: organization, record_type: %w[deal ticket])
        .where(status: %w[open active])
        .order(updated_at: :desc, id: :desc)
        .limit(row_limit)
        .map { |record| result_from_crm_record(record, keyword_score: 0.42) }
    end

    def rows_for_source_ids(source_type, source_ids, row_limit)
      return [] if source_ids.blank? || row_limit.to_i <= 0

      rows = scope_for_search
        .where(source_type: source_type, source_id: source_ids, chunk_index: 0)
        .to_a
      order = source_ids.each_with_index.to_h
      rows.sort_by { |row| order.fetch(row.source_id, source_ids.length) }.first(row_limit)
    end

    def result_from_crm_record(record, keyword_score:)
      {
        id: "crm-record-#{record.id}",
        source_type: "CrmRecord",
        source_id: record.id,
        chunk_index: nil,
        label: record.name,
        text: crm_record_source_text(record),
        distance: nil,
        score: keyword_score,
        vector_score: 0.0,
        keyword_score: keyword_score,
        retrieval_channels: ["keyword", "source_aware"],
        model: embedding_model,
        scope: scope,
        metadata: {
          "record_type" => record.record_type,
          "status" => record.status,
          "stage" => record.stage,
          "updated_at" => record.updated_at&.iso8601
        }.compact,
        citation: "CrmRecord##{record.id}"
      }
    end

    def crm_record_source_text(record)
      [
        "Source-aware ask fallback: tickets; deals; recent call evidence; company links.",
        "CRM #{record.record_type.to_s.upcase}",
        "name=#{record.name}",
        record.stage.present? ? "stage=#{record.stage}" : nil,
        record.status.present? ? "status=#{record.status}" : nil,
        record.amount.present? ? "amount=#{record.amount}" : nil,
        record.close_date.present? ? "close_date=#{record.close_date}" : nil,
        record.domain.present? ? "company_link=#{record.domain}" : nil,
        record.email.present? ? "email=#{record.email}" : nil,
        record.phone.present? ? "phone=#{record.phone}" : nil
      ].compact.join("\n")
    end

    def strong_resource_match?(candidates)
      return false if candidates.blank?

      candidates.any? { |item| item[:keyword_score].to_f >= 0.75 } ||
        (candidates.length >= [limit, 5].min && candidates.any? { |item| item[:keyword_score].to_f >= 0.45 })
    end

    def merge_candidates(vector, keyword)
      by_id = {}

      vector.each do |item|
        normalized = normalize_result(item)
        by_id[normalized.fetch(:id)] = normalized
      end

      keyword.each do |item|
        normalized = normalize_result(item)
        existing = by_id[normalized.fetch(:id)]
        by_id[normalized.fetch(:id)] = existing ? merge_result(existing, normalized) : normalized
      end

      deduplicate_results(by_id.values.map { |item| score_result(item) })
    end

    def deduplicate_results(items)
      items.group_by { |item| item[:content_digest].presence || item[:text].to_s.squish.downcase }
        .values
        .map { |duplicates| duplicates.max_by { |item| item[:rank_score].to_f } }
    end

    def normalize_result(item)
      data = item.to_h.symbolize_keys
      data[:metadata] = data[:metadata].to_h
      data[:vector_score] = data[:score].to_f if data[:vector_score].blank? && data[:distance].present?
      data[:keyword_score] = data[:keyword_score].to_f
      data[:retrieval_channels] = normalized_channels(data)
      data[:text] = data[:text].to_s
      data[:label] = data[:label].to_s
      data[:chunk_index] ||= data[:metadata]["chunk_index"] || data[:metadata][:chunk_index]
      data[:citation] ||= citation_for(data)
      data
    end

    def result_from_row(row, keyword_score:, text_prefix: nil)
      {
        id: row.id,
        content_digest: row.content_digest,
        source_type: row.source_type,
        source_id: row.source_id,
        chunk_index: row.chunk_index,
        label: row.label,
        text: [text_prefix, row.content].compact_blank.join("\n"),
        distance: nil,
        score: keyword_score,
        vector_score: 0.0,
        keyword_score: keyword_score,
        retrieval_channels: ["keyword"],
        model: row.embedding_model,
        scope: row.scope,
        metadata: row.metadata.to_h,
        citation: citation_for(row)
      }
    end

    def merge_result(left, right)
      left.merge(
        keyword_score: [left[:keyword_score].to_f, right[:keyword_score].to_f].max,
        vector_score: [left[:vector_score].to_f, right[:vector_score].to_f].max,
        score: [left[:score].to_f, right[:score].to_f].max,
        retrieval_channels: (Array(left[:retrieval_channels]) + Array(right[:retrieval_channels])).compact_blank.uniq
      )
    end

    def score_result(item)
      vector_score = item[:vector_score].to_f
      keyword_score = item[:keyword_score].to_f
      base = if vector_score.positive? && keyword_score.positive?
        (vector_score * 0.62) + (keyword_score * 0.38)
      elsif vector_score.positive?
        vector_score * 0.9
      else
        keyword_score * 0.92
      end

      source_weight = source_weight_for(item)
      authority_weight = authority_weight_for(item)
      weighted = base * source_weight * authority_weight
      bonus = exact_signal_bonus(item)
      rank_score = [weighted + bonus, 1.25].min.round(6)
      final = [rank_score, 1.0].min.round(6)
      item.merge(
        score: final,
        rank_score: rank_score,
        vector_score: vector_score.round(6),
        keyword_score: keyword_score.round(6),
        source_weight: source_weight,
        authority_weight: authority_weight,
        reason: reason_for(item.merge(authority_weight: authority_weight), final)
      )
    end

    def keyword_score_for(row)
      haystack = [row.label, row.content, row.metadata.to_h.values_at("training_kind", "category", "retrieval_priority", "training_priority")].flatten.compact.join(" ").downcase
      matched = terms.count { |term| haystack.include?(term) }
      return 0.0 if matched.zero?

      ratio = matched.to_f / terms.length
      phrase_boost = query.length >= 10 && haystack.include?(query.downcase) ? 0.22 : 0.0
      label_boost = terms.any? { |term| row.label.to_s.downcase.include?(term) } ? 0.08 : 0.0
      [[(ratio * 0.72) + phrase_boost + label_boost, 1.0].min, 0.05].max.round(6)
    end

    def keyword_clauses
      @keyword_clauses ||= keyword_patterns.map { "(LOWER(content) LIKE ? OR LOWER(COALESCE(label, '')) LIKE ?)" }.join(" OR ")
    end

    def keyword_binds
      @keyword_binds ||= keyword_patterns.flat_map { |pattern| [pattern, pattern] }
    end

    def keyword_patterns
      @keyword_patterns ||= terms.map { |term| "%#{ActiveRecord::Base.sanitize_sql_like(term)}%" }
    end

    def exact_signal_bonus(item)
      text = [item[:label], item[:text]].join(" ").downcase
      bonus = 0.0
      bonus += 0.05 if query.present? && query.length >= 10 && text.include?(query.downcase)
      bonus += 0.04 if terms.any? { |term| term.match?(/\A(?:\$\d+|\d{3,})\z/) && text.include?(term) }
      bonus
    end

    def source_weight_for(item)
      weights = surface.to_s.in?(%w[comms_sms_draft comms_email_draft]) ? COMMS_SOURCE_WEIGHTS : SOURCE_WEIGHTS
      weights.fetch(item[:source_type].to_s, 1.0)
    end

    def authority_weight_for(item)
      metadata = item[:metadata].to_h
      raw = metadata.values_at("retrieval_priority", "training_priority", "priority", "category", "training_kind").compact.join(" ").downcase
      authority = AUTHORITY_WEIGHTS.find { |key, _weight| raw.include?(key) }&.last || 1.0
      role = metadata["retrieval_role"].to_s.presence || metadata[:retrieval_role].to_s
      (authority * RETRIEVAL_ROLE_WEIGHTS.fetch(role, 1.0)).round(4)
    end

    def reason_for(item, final_score)
      reasons = []
      reasons << "vector=#{item[:vector_score]}" if item[:vector_score].to_f.positive?
      reasons << "keyword=#{item[:keyword_score]}" if item[:keyword_score].to_f.positive?
      reasons << "source=#{item[:source_type]}"
      reasons << "authority=#{item[:authority_weight]}" if item[:authority_weight].to_f != 1.0
      reasons << "final=#{final_score}"
      reasons.join(" | ")
    end

    def query_terms(text)
      text.to_s.downcase.scan(/[a-z0-9$][a-z0-9$.-]{1,}/)
        .map { |term| term.delete_suffix(".") }
        .reject { |term| STOPWORDS.include?(term) || term.length < 2 }
        .uniq
        .first(TERM_LIMIT)
    end

    def rewritten_query
      terms.presence&.join(" ") || query.presence
    end

    def citation_for(item)
      if item.respond_to?(:source_type)
        "#{item.source_type}##{item.source_id} chunk #{item.chunk_index}"
      else
        metadata = item[:metadata].to_h
        "#{item[:source_type]}##{item[:source_id]} chunk #{item[:chunk_index] || metadata['chunk_index'] || metadata[:chunk_index] || '?'}"
      end
    end

    def normalized_channels(item)
      channels = Array(item[:retrieval_channels])
      channels << "vector" if item[:distance].present? || item[:vector_score].to_f.positive?
      channels << "keyword" if item[:keyword_score].to_f.positive?
      channels.compact_blank.uniq
    end

    def retrieval_mode(vector, keyword)
      return "hybrid" if vector.present? && keyword.present?
      return "vector" if vector.present?
      return "keyword" if keyword.present?

      "empty"
    end

    def source_allowed?(source_type)
      source_types.blank? || source_types.include?(source_type.to_s)
    end

    def candidate_allowed?(item)
      return true unless comms_composition_surface?

      values = item.to_h
      metadata = (values[:metadata] || values["metadata"]).to_h.stringify_keys
      if metadata["training_kind"].to_s == "comms_playbook_memory"
        return false unless metadata["learning_status"].to_s == "approved_positive"
        return false unless ActiveModel::Type::Boolean.new.cast(metadata["human_reviewed"])
      end
      return false if metadata["composition_eligible"].to_s == "false"
      return false if COMPOSITION_BLOCKED_ROLES.include?(metadata["retrieval_role"].to_s)

      true
    end

    def comms_composition_surface?
      surface.to_s.in?(%w[comms_sms_draft comms_email_draft])
    end

    def normalized_embedding
      @normalized_embedding ||= Autos::EmbeddingQueue.send(:normalize_embedding, embedding)
    rescue StandardError
      []
    end

    def storage_ready?
      defined?(AutosEmbeddingChunk) && defined?(Autos::EmbeddingQueue) && Autos::EmbeddingQueue.storage_ready?
    end

    def empty_pack(reason:, ok: true)
      {
        ok: ok,
        query: query,
        rewritten_query: rewritten_query,
        scope: scope,
        surface: surface,
        embedding_model: embedding_model,
        results: [],
        evidence: [],
        retrieval_debug: {
          mode: "empty",
          reason: reason,
          terms: terms,
          source_types: source_types,
          candidate_limit: candidate_limit,
          limit: limit
        }.compact_blank
      }
    end
  end
end
