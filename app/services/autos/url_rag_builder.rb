# frozen_string_literal: true

require "digest"
require "net/http"
require "nokogiri"
require "uri"

module Autos
  class UrlRagBuilder
    MAX_PAGES = 20
    MAX_REDIRECTS = 3

    class << self
      def call(organization:, user:, profile_key:, profile_label:, pages:, profile_kind: "support", description: nil, enqueue_embeddings: false)
        new(
          organization: organization,
          user: user,
          profile_key: profile_key,
          profile_label: profile_label,
          pages: pages,
          profile_kind: profile_kind,
          description: description,
          enqueue_embeddings: enqueue_embeddings
        ).call
      end
    end

    def initialize(organization:, user:, profile_key:, profile_label:, pages:, profile_kind:, description:, enqueue_embeddings:)
      @organization = organization
      @user = user
      @profile_key = profile_key
      @profile_label = profile_label
      @pages = pages.to_h.stringify_keys.first(MAX_PAGES).to_h
      @profile_kind = profile_kind
      @description = description
      @enqueue_embeddings = ActiveModel::Type::Boolean.new.cast(enqueue_embeddings)
    end

    def call
      raise ArgumentError, "organization required" if organization.blank?
      raise ArgumentError, "user required" if user.blank?
      raise ArgumentError, "at least one named URL is required" if pages.blank?

      fetched = pages.map do |key, url|
        [key, url, fetch_page_text(url)]
      end
      profile = Comms::RagProfile.register!(
        organization: organization,
        key: profile_key,
        label: profile_label,
        scope: profile_key,
        kind: profile_kind,
        description: description
      )
      documents = organization.transaction do
        fetched.map { |key, url, body| upsert_document!(profile: profile, key: key, url: url, body: body) }
      end

      {
        ok: true,
        profile: profile,
        documents: documents,
        embeddings_requested: enqueue_embeddings,
        continuous_embedding_worker_required: false
      }
    end

    private

    attr_reader :organization, :user, :profile_key, :profile_label, :pages, :profile_kind, :description, :enqueue_embeddings

    def fetch_page_text(url, redirects: 0)
      uri = URI.parse(url.to_s)
      raise ArgumentError, "RAG URL must use http or https" unless uri.is_a?(URI::HTTP) && uri.host.present?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 8, read_timeout: 15) do |http|
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "AUTOS-RAG-BUILDER/1.0", "Accept" => "text/html,text/plain")
        http.request(request)
      end
      if response.is_a?(Net::HTTPRedirection) && response["location"].present?
        raise "too many redirects for #{url}" if redirects >= MAX_REDIRECTS

        return fetch_page_text(URI.join(uri.to_s, response["location"]).to_s, redirects: redirects + 1)
      end
      raise "#{url} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      document = Nokogiri::HTML(response.body)
      document.css("script, style, nav, footer, noscript").remove
      text = document.at_css("main")&.text.presence || document.at_css("body")&.text.to_s
      text.lines.map(&:squish).compact_blank.join("\n").truncate(TrainingDocument::MAX_BODY_LENGTH)
    rescue URI::InvalidURIError => error
      raise ArgumentError, "invalid RAG URL #{url.inspect}: #{error.message}"
    end

    def upsert_document!(profile:, key:, url:, body:)
      raise "#{url} produced no support text" if body.blank?

      page_key = key.to_s.parameterize(separator: "_").presence || Digest::SHA256.hexdigest(url.to_s).first(12)
      source_key = "#{profile.fetch('key')}_url_#{page_key}"
      document = organization.training_documents
        .where("metadata ->> 'rag_source_key' = ?", source_key)
        .first_or_initialize
      digest = Digest::SHA256.hexdigest(body)
      document.assign_attributes(
        user: user,
        title: "#{profile.fetch('label')} // #{key.to_s.upcase}",
        body: body,
        source_type: "pasted_text",
        status: "ingested",
        content_type: "text/plain",
        file_name: "#{profile.fetch('key')}_#{page_key}.txt",
        byte_size: body.bytesize,
        metadata: document.metadata.to_h.merge(
          "training_kind" => "rag_profile_document",
          "rag_profile" => profile.fetch("key"),
          "rag_profile_label" => profile.fetch("label"),
          "rag_scope" => profile.fetch("scope"),
          "rag_kind" => profile.fetch("kind"),
          "rag_source_key" => source_key,
          "source_url" => url,
          "source_digest" => digest,
          "retrieval_role" => "fact_authority",
          "retrieval_priority" => "paramount",
          "composition_eligible" => true,
          "built_by" => self.class.name,
          "built_at" => Time.current.iso8601
        )
      )
      document.save!

      embedding_result = if enqueue_embeddings
        Autos::EmbeddingQueue.enqueue_source_with_result!(document, scope: profile.fetch("scope"))
      else
        { ok: true, status: :not_requested }
      end

      {
        id: document.id,
        key: key,
        title: document.title,
        source_url: url,
        digest: digest,
        chars: body.length,
        embedding: embedding_result
      }
    end
  end
end
