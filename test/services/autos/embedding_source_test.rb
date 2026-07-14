# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "digest"

module Autos
  class EmbeddingSourceTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "Embedding Policy #{suffix}", slug: "embedding-policy-#{suffix}")
      @user = users(:one)
    end

    test "copies training role and composition policy to every embedding chunk" do
      document = @organization.training_documents.create!(
        user: @user,
        title: "Thumper Voice Guide",
        body: ("Thumper is practical, direct, candid, and useful. " * 50).strip,
        source_type: "comms_playbook_memory",
        status: "indexed",
        metadata: {
          "training_kind" => "thumper_voice_canon",
          "retrieval_priority" => "paramount"
        }
      )

      chunks = EmbeddingSource.chunks_for(document)

      assert_operator chunks.length, :>, 1
      assert chunks.all? { |chunk| chunk.dig(:metadata, "retrieval_role") == "voice_authority" }
      assert chunks.all? { |chunk| chunk.dig(:metadata, "composition_eligible") == true }
      assert chunks.all? { |chunk| chunk.dig(:metadata, "training_kind") == "thumper_voice_canon" }
    end

    test "marks unapproved raw conversation chunks as ineligible" do
      document = @organization.training_documents.create!(
        user: @user,
        title: "Legacy raw COMMS memory",
        body: ("Customer and bot transcript with unreviewed wording. " * 8).strip,
        source_type: "comms_playbook_memory",
        status: "indexed",
        metadata: { "training_kind" => "comms_playbook_memory" }
      )

      metadata = EmbeddingSource.chunks_for(document).first.fetch(:metadata)

      assert_equal "quarantined_memory", metadata["retrieval_role"]
      assert_equal false, metadata["composition_eligible"]
    end

    test "refuses to embed a pending adaptive learning candidate" do
      document = @organization.training_documents.create!(
        user: @user,
        title: "Pending SMS learning",
        body: ("A sanitized conversation pattern awaiting review. " * 4).strip,
        source_type: "comms_playbook_memory",
        status: "ingested",
        metadata: {
          "training_kind" => "comms_playbook_memory",
          "learning_status" => "pending_review",
          "human_reviewed" => false
        }
      )

      result = EmbeddingQueue.enqueue_source_with_result!(document)

      assert_equal :quarantined, result[:status]
      refute AutosEmbeddingChunk.exists?(source_type: "TrainingDocument", source_id: document.id)
    end

    test "routes human-approved adaptive memory to its isolated scope" do
      document = @organization.training_documents.create!(
        user: @user,
        title: "Approved SMS learning",
        body: ("A human-approved conversation pattern with redacted contact data. " * 4).strip,
        source_type: "comms_playbook_memory",
        status: "ingested",
        metadata: {
          "training_kind" => "comms_playbook_memory",
          "learning_status" => "approved_positive",
          "human_reviewed" => true,
          "composition_eligible" => true
        }
      )

      assert EmbeddingQueue.enqueue_source!(document)

      chunks = AutosEmbeddingChunk.where(source_type: "TrainingDocument", source_id: document.id)
      assert chunks.exists?
      assert_equal [EmbeddingQueue::ADAPTIVE_SMS_SCOPE], chunks.distinct.pluck(:scope)
      assert chunks.all? { |chunk| chunk.metadata["human_reviewed"] == true }
    end

    test "refreshes chunk policy metadata without re-embedding unchanged content" do
      document = @organization.training_documents.create!(
        user: @user,
        title: "Thumper Voice Guide",
        body: ("Thumper gives a direct answer, one useful reason, and one clear next step. " * 4).strip,
        source_type: "comms_playbook_memory",
        status: "indexed",
        metadata: { "training_kind" => "thumper_voice_canon", "retrieval_priority" => "paramount" }
      )
      chunks = EmbeddingSource.chunks_for(document)
      chunk = chunks.first
      row = AutosEmbeddingChunk.create!(
        organization: @organization,
        source_type: "TrainingDocument",
        source_id: document.id,
        chunk_index: 0,
        label: chunk[:label],
        content: chunk[:content],
        source_digest: Digest::SHA256.hexdigest(chunks.map { |item| item[:content] }.join("\n\n")),
        content_digest: Digest::SHA256.hexdigest(chunk[:content]),
        embedding_model: EmbeddingQueue.embedder_model,
        embedding_dimensions: 3,
        status: "embedded",
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        metadata: { "source_type" => "TrainingDocument", "source_id" => document.id }
      )

      assert EmbeddingQueue.enqueue_source!(document)

      row.reload
      assert_equal "embedded", row.status
      assert_equal "voice_authority", row.metadata["retrieval_role"]
      assert_equal true, row.metadata["composition_eligible"]
    end

    test "crm embeddings exclude repeated schema and full weather payloads" do
      property_labels = 900.times.to_h { |index| ["internal_#{index}", "UNHELPFUL SCHEMA LABEL #{index}"] }
      weather_signals = 100.times.map do |index|
        {
          "id" => index,
          "type" => "alert",
          "event" => "Storm Warning",
          "severity" => "severe",
          "states" => ["MI"],
          "postal_codes" => Array.new(250, "99999")
        }
      end
      record = @organization.crm_records.create!(
        record_type: "deal",
        name: "Compact CRM Deal #{SecureRandom.hex(3)}",
        status: "open",
        source: "hubspot",
        source_uid: SecureRandom.hex(8),
        properties: {
          "hubspot" => {
            "property_labels" => property_labels,
            "labeled_properties" => { "Deal Stage" => "Qualified", "Deal owner" => "Sample Owner" },
            "properties" => { "dealname" => "Compact CRM Deal", "dealstage" => "qualified" }
          },
          "weather_lead" => {
            "lead_source" => "weather",
            "signals_count" => weather_signals.length,
            "signals" => weather_signals
          }
        }
      )

      chunks = EmbeddingSource.chunks_for(record)
      content = chunks.map { |chunk| chunk.fetch(:content) }.join("\n")

      assert_operator chunks.length, :<=, EmbeddingSource::CRM_MAX_CHUNKS
      assert_includes content, "Qualified"
      assert_includes content, "Compact CRM Deal"
      refute_includes content, "Storm Warning"
      assert_includes content, '"signals_count":"100"'
      refute_includes content, "UNHELPFUL SCHEMA LABEL"
      refute_includes content, "99999"
      assert_equal EmbeddingSource::CRM_SOURCE_SCHEMA_VERSION, chunks.first.dig(:metadata, "source_schema_version")
    end

    test "does not reset an unchanged claimed crm chunk" do
      record = @organization.crm_records.create!(
        record_type: "company",
        name: "Claim-safe CRM #{SecureRandom.hex(3)}",
        status: "active",
        source: "hubspot_company",
        source_uid: SecureRandom.hex(8),
        properties: { "hubspot" => { "properties" => { "industry" => "Roofing" } } }
      )
      first = EmbeddingQueue.enqueue_source_with_result!(record)
      chunk = AutosEmbeddingChunk.find_by!(
        organization: @organization,
        source_type: "CrmRecord",
        source_id: record.id,
        chunk_index: 0,
        embedding_model: EmbeddingQueue.embedder_model
      )
      chunk.update!(status: "claimed", worker_id: "embedding-test", claimed_at: Time.current, metadata: chunk.metadata.to_h.merge("claim_token" => "keep-me"))

      second = EmbeddingQueue.enqueue_source_with_result!(record.reload)

      assert_equal :queued, first.fetch(:status)
      assert_equal :already_queued, second.fetch(:status)
      assert_equal "claimed", chunk.reload.status
      assert_equal "keep-me", chunk.metadata["claim_token"]
    end

    test "nightly crm enqueue only examines recently changed records" do
      recent = @organization.crm_records.create!(
        record_type: "company",
        name: "Recent CRM #{SecureRandom.hex(3)}",
        status: "active",
        source: "hubspot_company",
        source_uid: SecureRandom.hex(8)
      )
      old = @organization.crm_records.create!(
        record_type: "company",
        name: "Old CRM #{SecureRandom.hex(3)}",
        status: "active",
        source: "hubspot_company",
        source_uid: SecureRandom.hex(8)
      )
      old.update_columns(created_at: 10.days.ago, updated_at: 10.days.ago)

      result = EmbeddingQueue.enqueue_crm_recent!(organization: @organization)
      second = EmbeddingQueue.enqueue_crm_recent!(organization: @organization)

      assert_equal 1, result.fetch(:queued)
      assert_equal 0, second.fetch(:queued)
      assert AutosEmbeddingChunk.exists?(source_type: "CrmRecord", source_id: recent.id)
      refute AutosEmbeddingChunk.exists?(source_type: "CrmRecord", source_id: old.id)
    end

    test "legacy crm cleanup preserves embedded vectors unless explicitly requested" do
      model = EmbeddingQueue.embedder_model
      pending = legacy_crm_chunk(source_id: 91, status: "pending", model: model)
      embedded = legacy_crm_chunk(source_id: 92, status: "embedded", model: model, embedding_dimensions: 3)

      result = EmbeddingQueue.discard_legacy_crm_backlog!(organization: @organization, embedding_model: model)

      assert_equal 1, result.fetch(:deleted)
      assert_nil AutosEmbeddingChunk.find_by(id: pending.id)
      assert AutosEmbeddingChunk.find_by(id: embedded.id).present?
    end

    test "full legacy crm cleanup removes expired claims but preserves active claims" do
      model = EmbeddingQueue.embedder_model
      expired = legacy_crm_chunk(source_id: 93, status: "claimed", model: model)
      expired.update!(claimed_at: 1.hour.ago, worker_id: "expired-worker")
      active = legacy_crm_chunk(source_id: 94, status: "claimed", model: model)
      active.update!(claimed_at: Time.current, worker_id: "active-worker")

      result = EmbeddingQueue.discard_legacy_crm_backlog!(
        organization: @organization,
        embedding_model: model,
        include_embedded: true
      )

      assert_equal 1, result.fetch(:deleted)
      assert_nil AutosEmbeddingChunk.find_by(id: expired.id)
      assert AutosEmbeddingChunk.find_by(id: active.id).present?
    end

    test "weather analysis memory is compact and isolated from generic chat" do
      question = @organization.autos_questions.create!(
        user: @user,
        question: "Analyze weather calibration.",
        context: "x" * 50_000,
        answer: JSON.generate(weather_analysis_answer),
        status: "answered",
        metadata: weather_analysis_metadata
      )

      chunks = EmbeddingSource.chunks_for(question)
      content = chunks.map { |chunk| chunk.fetch(:content) }.join("\n")

      assert_includes content, "Thumper WEATHER CALIBRATION MEMORY"
      assert_includes content, "brain_type=weather_calibration"
      assert_includes content, "fee_adjusted_out_of_sample_ev"
      refute_includes content, "USER ADDED CONTEXT"
      assert_operator content.length, :<, 4_000
      assert chunks.all? { |chunk| chunk.dig(:metadata, "brain_type") == "weather_calibration" }
      assert chunks.all? { |chunk| chunk.dig(:metadata, "weather_analysis_valid") == true }
    end

    test "chat memory recorder stores only validated weather analysis in its own scope" do
      valid = @organization.autos_questions.create!(
        user: @user,
        question: "Analyze valid weather calibration.",
        answer: JSON.generate(weather_analysis_answer),
        status: "answered",
        metadata: weather_analysis_metadata
      )
      invalid = @organization.autos_questions.create!(
        user: @user,
        question: "Analyze invalid weather calibration.",
        answer: "Let me analyze this first.",
        status: "answered",
        metadata: weather_analysis_metadata.deep_merge("weather_analysis_validation" => { "valid" => false })
      )

      assert ChatMemoryRecorder.record!(valid)
      assert_equal false, ChatMemoryRecorder.record!(invalid)

      chunk = AutosEmbeddingChunk.find_by!(source_type: "AutosQuestion", source_id: valid.id)
      assert_equal "weather_calibration", chunk.scope
      assert_equal "weather_calibration", valid.reload.metadata.dig("memory", "brain_type")
      refute AutosEmbeddingChunk.exists?(source_type: "AutosQuestion", source_id: invalid.id)
    end

    private

    def weather_analysis_metadata
      {
        "surface" => "weather_outcome_analysis",
        "weather_schema_version" => Kalshi::WeatherAnalysisContract::SCHEMA_VERSION,
        "weather_knowledge_version" => Kalshi::WeatherAnalysisKnowledge::VERSION,
        "weather_batch_digest" => "weather-batch-1",
        "weather_sample_size" => 8,
        "weather_analysis_validation" => { "valid" => true },
        "local_worker" => { "model" => "qwen3:30b", "provider" => "local_cc" }
      }
    end

    def weather_analysis_answer
      {
        "schema_version" => Kalshi::WeatherAnalysisContract::SCHEMA_VERSION,
        "knowledge_version" => Kalshi::WeatherAnalysisKnowledge::VERSION,
        "batch_digest" => "weather-batch-1",
        "sample_size" => 8,
        "analysis_complete" => true,
        "verdict" => "insufficient_data",
        "risk_gate" => "block",
        "summary" => "The station sample is below the promotion minimum.",
        "findings" => [
          { "type" => "sample_size", "evidence" => "8 events are below 30.", "confidence" => 1.0 }
        ],
        "data_quality_flags" => ["sample below minimum"],
        "next_instrumentation" => "Collect another official station outcome.",
        "rule_ack" => {
          "settlement_source" => "final_nws_daily_climate_report",
          "one_sided_strikes" => "strict",
          "between_bounds" => "inclusive",
          "objective" => "fee_adjusted_out_of_sample_ev"
        }
      }
    end

    def legacy_crm_chunk(source_id:, status:, model:, embedding_dimensions: nil)
      content = "Legacy CRM content #{source_id}"
      AutosEmbeddingChunk.create!(
        organization: @organization,
        source_type: "CrmRecord",
        source_id: source_id,
        chunk_index: 0,
        label: "Legacy CRM #{source_id}",
        content: content,
        source_digest: Digest::SHA256.hexdigest(content),
        content_digest: Digest::SHA256.hexdigest(content),
        embedding_model: model,
        embedding_dimensions: embedding_dimensions,
        status: status,
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        metadata: {}
      )
    end
  end
end
