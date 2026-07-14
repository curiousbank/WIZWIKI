class AutosWorkerController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :verify_authenticity_token
  before_action :authenticate_worker!

  def status
    payload = if lightweight_status_request?
      Autos::WorkerStatus.lightweight(worker_id: worker_id, worker_queue: worker_queue)
    else
      Autos::WorkerStatus.full(worker_id: worker_id, worker_queue: worker_queue, embedding_model: worker_embedder_model)
    end
    render json: payload
  end

  def next
    question = Autos::WorkerQueue.claim_next!(worker_id: worker_id, worker_queue: worker_queue)
    return head :no_content unless question.present?

    render json: Autos::WorkerQueue.payload_for(question)
  end

  def embedding_status
    render json: Autos::EmbeddingQueue.status_for(worker_id: worker_id, embedding_model: worker_embedder_model)
  end

  def next_embedding
    chunk = Autos::EmbeddingQueue.claim_next!(worker_id: worker_id, embedding_model: worker_embedder_model)
    return head :no_content unless chunk.present?

    render json: Autos::EmbeddingQueue.payload_for(chunk)
  end

  def search_embeddings
    organization = current_embedding_organization
    retrieval = Autos::Retriever.call(
      organization: organization,
      query: retrieval_query,
      embedding: worker_payload["embedding"],
      embedding_model: worker_payload["embedding_model"].presence || worker_embedder_model,
      scope: worker_payload["scope"].presence || retrieval_request["scope"].presence || Autos::EmbeddingQueue::DEFAULT_SCOPE,
      surface: retrieval_surface,
      limit: worker_payload["limit"].presence || retrieval_request["limit"].presence || 8,
      candidate_limit: worker_payload["candidate_limit"].presence || retrieval_request["candidate_limit"].presence || 40,
      source_types: worker_payload["source_types"].presence || retrieval_request["source_types"].presence
    )
    results = comms_sms_embedding_results(retrieval.fetch(:results, []))
    evidence = Autos::Retriever.citations_for(results)

    render json: {
      ok: retrieval.fetch(:ok, true),
      vector_store: Autos::EmbeddingQueue.status_for(worker_id: worker_id),
      results: results,
      evidence: evidence,
      retrieval: {
        mode: retrieval.dig(:retrieval_debug, :mode),
        query: retrieval[:query],
        rewritten_query: retrieval[:rewritten_query],
        scope: retrieval[:scope],
        surface: retrieval[:surface],
        embedding_model: retrieval[:embedding_model],
        evidence_count: evidence.length
      }.compact_blank,
      retrieval_debug: retrieval.fetch(:retrieval_debug, {}).merge(filtered_results: results.length)
    }
  end

  def complete_embedding
    chunk = AutosEmbeddingChunk.find(params[:id])
    Autos::EmbeddingQueue.complete!(chunk, embedding: worker_payload["embedding"], worker_payload: worker_payload.merge("worker_id" => worker_id))

    render json: { ok: true, id: chunk.id, status: chunk.reload.status, embedded_at: chunk.embedded_at&.iso8601 }
  rescue StandardError => error
    Rails.logger.warn("[AutosWorker] embedding complete failed chunk=#{params[:id]} #{error.class}: #{error.message}")
    render json: { ok: false, error: error.message }, status: :unprocessable_entity
  end

  def fail_embedding
    chunk = AutosEmbeddingChunk.find(params[:id])
    Autos::EmbeddingQueue.fail!(chunk, error: worker_payload["error"].presence || worker_payload["message"].presence || "embedding worker failed")

    render json: { ok: true, id: chunk.id, status: chunk.reload.status }
  end

  def complete
    question = AutosQuestion.find(params[:id])
    blocked_reason = blocked_worker_completion_reason(question)
    if blocked_reason.present?
      cancel_worker_question!(question, blocked_reason)
      return render json: { ok: true, id: question.id, status: question.reload.status, ignored: true, reason: blocked_reason }
    end

    Autos::WorkerQueue.complete!(question, worker_payload: worker_payload)
    Autos::VoiceJob.perform_later(question.id) unless ActiveModel::Type::Boolean.new.cast(question.metadata.to_h["skip_voice"])

    render json: { ok: true, id: question.id, status: question.status }
  end

  def fail
    question = AutosQuestion.find(params[:id])
    blocked_reason = blocked_worker_completion_reason(question)
    if blocked_reason.present?
      cancel_worker_question!(question, blocked_reason)
      return render json: { ok: true, id: question.id, status: question.reload.status, ignored: true, reason: blocked_reason }
    end

    Autos::WorkerQueue.fail!(question, error: worker_payload["error"].presence || worker_payload["message"].presence || "worker failed")

    render json: { ok: true, id: question.id, status: question.status }
  end

  private

  def blocked_worker_completion_reason(question)
    return "question_closed" if question.status.to_s.in?(%w[canceled cancelled archived ignored])

    metadata = question.metadata.to_h
    return nil unless metadata["surface"].to_s == "comms_sms_draft"

    stage_id = metadata["comms_stage_id"].to_s.presence
    return nil if stage_id.blank?

    stage = CrmRecordArtifact.find_by(id: stage_id)
    return nil unless stage&.metadata.to_h["recursive_dojo_status"].to_s.in?(%w[canceled cancelled])

    "recursive_dojo_canceled"
  end

  def lightweight_status_request?
    worker_queue.to_s.in?(%w[sms comms]) ||
      ActiveModel::Type::Boolean.new.cast(params[:lightweight])
  end

  def cancel_worker_question!(question, reason)
    return if question.status.to_s.in?(%w[canceled cancelled archived ignored])

    metadata = question.metadata.to_h
    question.update_columns(
      status: "canceled",
      metadata: metadata.merge(
        "canceled_at" => Time.current.iso8601,
        "cancel_reason" => reason
      ),
      updated_at: Time.current
    )
  end

  def comms_sms_embedding_results(results)
    memory = worker_payload["memory"].to_h
    surface = memory["surface"].presence || worker_payload["surface"].presence
    return results unless surface.to_s == "comms_sms_draft"

    limit = (worker_payload["limit"].presence || retrieval_request["limit"].presence || 6).to_i.clamp(1, 8)
    Array(results).reject { |result| noisy_comms_embedding_result?(result.to_h) }.first(limit)
  end

  def noisy_comms_embedding_result?(result)
    metadata = (result["metadata"] || result[:metadata]).to_h
    label = result["label"] || result[:label]
    text = [label, result["text"] || result[:text]].compact.join(" ")
    lower = text.downcase

    return true if metadata["training_kind"].to_s == "comms_playbook_memory" &&
      ActiveModel::Type::Boolean.new.cast(metadata["autogenerated"]) &&
      label.to_s.match?(/\bcustomer\b/i)

    lower.match?(/\b(thank you for choosing wizwiki|if you need creative|nice to meet you|let me know if you need anything else)\b/)
  end

  def retrieval_request
    worker_payload["retrieval"].to_h
  end

  def retrieval_query
    memory = worker_payload["memory"].to_h
    worker_payload["query"].presence ||
      retrieval_request["query"].presence ||
      worker_payload["semantic_query"].presence ||
      memory["semantic_query"].presence ||
      worker_payload["prompt"].presence ||
      ""
  end

  def retrieval_surface
    memory = worker_payload["memory"].to_h
    worker_payload["surface"].presence ||
      retrieval_request["surface"].presence ||
      memory["surface"].presence ||
      "ask"
  end

  def authenticate_worker!
    expected = WizwikiSettings.autos_worker_token.to_s
    return head :service_unavailable if expected.blank?

    supplied = request.authorization.to_s.sub(/\ABearer\s+/i, "").strip
    return head :unauthorized if supplied.blank? || supplied.bytesize != expected.bytesize
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
  end

  def worker_id
    request.headers["X-Autos-Worker-Id"].presence || params[:worker_id].presence || "alice-wizwiki-01"
  end

  def worker_queue
    request.headers["X-Autos-Worker-Queue"].presence || params[:worker_queue].presence || "all"
  end

  def worker_payload
    request.request_parameters.to_h
  end

  def worker_embedder_model
    request.headers["X-Autos-Embedder-Model"].presence || Autos::EmbeddingQueue.embedder_model
  end

  def current_embedding_organization
    organization_id = worker_payload["organization_id"].presence || params[:organization_id].presence
    return Organization.find(organization_id) if organization_id.present?

    Organization.order(:id).first || raise(ActiveRecord::RecordNotFound, "organization required")
  end
end
