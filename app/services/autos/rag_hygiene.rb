# frozen_string_literal: true

module Autos
  class RagHygiene
    DEFAULT_SCOPE = Autos::EmbeddingQueue::DEFAULT_SCOPE
    DEFAULT_CLAIMED_STALE_MINUTES = 30
    DEFAULT_RECLAIM_LIMIT = 1_000
    BULK_PENDING_SOURCE_TYPES = %w[CrmRecord CrmAddressRecord WeatherLeadSignal].freeze

    class << self
      def call(**options)
        new(**options).call
      end

      def env_options(env = ENV)
        {
          organization_id: env["ORGANIZATION_ID"].presence,
          scope: env["SCOPE"].presence,
          embedding_model: env["EMBEDDING_MODEL"].presence,
          claimed_stale_minutes: env["CLAIMED_STALE_MINUTES"].presence,
          reclaim_limit: env["RECLAIM_LIMIT"].presence,
          prune_stale_days: env["PRUNE_STALE_DAYS"].presence,
          dry_run: env["DRY_RUN"].presence,
          output_path: env["OUTPUT_PATH"].presence
        }.compact_blank
      end
    end

    def initialize(organization: nil, organization_id: nil, scope: nil, embedding_model: nil, claimed_stale_minutes: nil, reclaim_limit: nil, prune_stale_days: nil, dry_run: nil, output_path: nil)
      @organization = organization
      @organization_id = organization_id
      @scope = scope.presence || DEFAULT_SCOPE
      @embedding_model = embedding_model.presence || Autos::EmbeddingQueue.embedder_model
      @claimed_stale_minutes = (claimed_stale_minutes.presence || DEFAULT_CLAIMED_STALE_MINUTES).to_i.clamp(1, 24.hours.to_i / 60)
      @reclaim_limit = (reclaim_limit.presence || DEFAULT_RECLAIM_LIMIT).to_i.clamp(1, 100_000)
      @prune_stale_days = prune_stale_days.present? ? prune_stale_days.to_i.clamp(1, 3650) : nil
      @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
      @output_path = output_path.presence
    end

    def call
      raise ArgumentError, "organization required" unless organization.present?
      raise "vector storage is not ready" unless Autos::EmbeddingQueue.storage_ready?

      before = queue_report
      reclaimed = reclaim_stale_claims
      pruned = prune_old_stale_chunks
      after = queue_report

      result = {
        ok: true,
        dry_run: dry_run,
        generated_at: Time.current.iso8601,
        organization_id: organization.id,
        organization_name: organization.name,
        scope: scope,
        embedding_model: embedding_model,
        claimed_stale_minutes: claimed_stale_minutes,
        reclaim_limit: reclaim_limit,
        prune_stale_days: prune_stale_days,
        before: before,
        reclaimed_stale_claims: reclaimed,
        pruned_stale_chunks: pruned,
        after: after,
        recommendations: recommendations(after)
      }

      write_output(result) if output_path.present?
      result
    end

    private

    attr_reader :organization_id, :scope, :embedding_model, :claimed_stale_minutes,
      :reclaim_limit, :prune_stale_days, :dry_run, :output_path

    def organization
      @organization ||= organization_id.present? ? Organization.find(organization_id) : Organization.order(:id).first
    end

    def chunk_scope
      AutosEmbeddingChunk.where(
        organization: organization,
        scope: scope,
        embedding_model: embedding_model
      )
    end

    def stale_claimed_scope
      cutoff = claimed_stale_minutes.minutes.ago
      chunk_scope.where(status: "claimed").where("claimed_at IS NULL OR claimed_at < ?", cutoff)
    end

    def queue_report
      pending_scope = chunk_scope.where(status: "pending")
      bulk_scope = pending_scope.where(source_type: BULK_PENDING_SOURCE_TYPES)

      {
        counts_by_status: chunk_scope.group(:status).count,
        pending_by_source: pending_scope.group(:source_type).count,
        bulk_pending_by_source: bulk_scope.group(:source_type).count,
        priority_pending_count: pending_scope.where.not(source_type: BULK_PENDING_SOURCE_TYPES).count,
        stale_claimed_by_source: stale_claimed_scope.group(:source_type).count,
        stale_claimed_count: stale_claimed_scope.count,
        old_stale_count: old_stale_scope.count,
        queue_status: safe_queue_status
      }
    end

    def reclaim_stale_claims
      scope = stale_claimed_scope.order(Arel.sql("claimed_at NULLS FIRST"), :updated_at, :id).limit(reclaim_limit)
      ids = scope.pluck(:id)
      by_source = AutosEmbeddingChunk.where(id: ids).group(:source_type).count
      return { count: ids.length, by_source: by_source, ids: ids.first(20), dry_run: true } if dry_run || ids.blank?

      now = Time.current
      AutosEmbeddingChunk.where(id: ids).find_each do |chunk|
        previous_metadata = chunk.metadata.to_h
        chunk.update!(
          status: "pending",
          worker_id: nil,
          claimed_at: nil,
          last_error: nil,
          metadata: previous_metadata.except("claim_token").merge(
            "hygiene_reclaimed_at" => now.iso8601,
            "hygiene_previous_worker_id" => chunk.worker_id.to_s.presence,
            "hygiene_previous_claimed_at" => chunk.claimed_at&.iso8601
          ).compact
        )
      end

      { count: ids.length, by_source: by_source, ids: ids.first(20), dry_run: false }
    end

    def prune_old_stale_chunks
      return { count: 0, by_source: {}, dry_run: dry_run, skipped: "set PRUNE_STALE_DAYS to delete old stale chunks" } if prune_stale_days.blank?

      scope = old_stale_scope
      ids = scope.limit(100_000).pluck(:id)
      by_source = AutosEmbeddingChunk.where(id: ids).group(:source_type).count
      return { count: ids.length, by_source: by_source, ids: ids.first(20), dry_run: true } if dry_run || ids.blank?

      deleted = AutosEmbeddingChunk.where(id: ids).delete_all
      { count: deleted, by_source: by_source, ids: ids.first(20), dry_run: false }
    end

    def old_stale_scope
      return chunk_scope.none if prune_stale_days.blank?

      chunk_scope.where(status: "stale").where("updated_at < ?", prune_stale_days.days.ago)
    end

    def safe_queue_status
      Autos::EmbeddingQueue.status_for(worker_id: "rag-hygiene", embedding_model: embedding_model)
    rescue StandardError => error
      { ok: false, error: error.message }
    end

    def recommendations(report)
      items = []
      stale_claimed = report.fetch(:stale_claimed_count).to_i
      priority_pending = report.fetch(:priority_pending_count).to_i
      bulk_pending = report.fetch(:bulk_pending_by_source).values.sum.to_i

      items << "Run autos:rag_hygiene again if stale claimed chunks remain." if stale_claimed.positive?
      items << "Keep embedding workers focused on priority sources before bulk CRM/weather backlog." if priority_pending.positive?
      items << "Bulk CRM/weather pending backlog is #{bulk_pending}; this is queued memory, not canonical RAG failure." if bulk_pending.positive?
      items << "Use PRUNE_STALE_DAYS=30 DRY_RUN=1 first if stale rows need disk cleanup."
      items
    end

    def write_output(result)
      path = Pathname.new(output_path)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.pretty_generate(result))
    end
  end
end
