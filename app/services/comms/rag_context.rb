# frozen_string_literal: true

module Comms
  class RagContext
    STOPWORDS = %w[a an and are as at be by can do for from has have how i in is it of on or our that the this to we what when where which who why with you your].freeze
    LIMIT = 4

    class << self
      def call(organization:, profile:, query:, limit: LIMIT)
        new(organization: organization, profile: profile, query: query, limit: limit).call
      end
    end

    def initialize(organization:, profile:, query:, limit:)
      @organization = organization
      @profile = Comms::RagProfile.fetch(profile, organization: organization)
      @query = query.to_s.squish
      @limit = limit.to_i.clamp(1, 8)
    end

    def call
      return empty_result("organization missing") if organization.blank?

      documents = organization.training_documents
        .where.not(status: "archived")
        .where("metadata ->> 'rag_profile' = ?", profile.fetch("key"))
        .order(updated_at: :desc)
        .limit(40)
        .to_a
      ranked = documents.map { |document| [document, score(document)] }
        .sort_by { |document, score| [-score, -(document.updated_at&.to_i || 0)] }
        .first(limit)

      {
        profile: profile.fetch("key"),
        profile_label: profile.fetch("label"),
        scope: profile.fetch("scope"),
        mode: "versioned_document_keyword",
        query: query,
        selected_documents: ranked.map do |document, document_score|
          {
            id: document.id,
            title: document.title,
            source_url: document.metadata.to_h["source_url"],
            source_digest: document.metadata.to_h["source_digest"],
            score: document_score.round(4),
            excerpt: relevant_excerpt(document.body)
          }.compact_blank
        end
      }
    rescue StandardError => error
      Rails.logger.warn("[Comms::RagContext] retrieval failed profile=#{profile['key']} #{error.class}: #{error.message}")
      empty_result("#{error.class}: #{error.message}")
    end

    private

    attr_reader :organization, :profile, :query, :limit

    def terms
      @terms ||= query.downcase.scan(/[a-z0-9]{2,}/).reject { |term| STOPWORDS.include?(term) }.uniq.first(18)
    end

    def score(document)
      haystack = [document.title, document.body].join(" ").downcase
      term_score = terms.sum { |term| haystack.scan(/\b#{Regexp.escape(term)}\b/).length.clamp(0, 8) }
      authority = document.metadata.to_h["retrieval_priority"].to_s == "paramount" ? 3 : 0
      term_score + authority
    end

    def relevant_excerpt(body)
      lines = body.to_s.lines.map(&:squish).compact_blank
      matching = lines.select { |line| terms.any? { |term| line.downcase.include?(term) } }
      selected = (matching.first(10) + lines.first(4)).uniq
      selected.join("\n").truncate(3_500, omission: "...")
    end

    def empty_result(reason)
      {
        profile: profile.fetch("key"),
        profile_label: profile.fetch("label"),
        scope: profile.fetch("scope"),
        mode: "versioned_document_keyword",
        query: query,
        selected_documents: [],
        reason: reason
      }.compact_blank
    end
  end
end
