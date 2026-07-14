require "open3"

class TrainingDocumentsController < ApplicationController
  MAX_TRAINING_BYTES = 5.megabytes
  MAX_TRAINING_TOTAL_BYTES = 50.megabytes
  MAX_TRAINING_FILES = 200
  ALLOWED_TRAINING_EXTENSIONS = %w[.txt .md .markdown .csv .json .pdf].freeze
  ALLOWED_TRAINING_CONTENT_TYPES = %w[
    text/plain
    text/markdown
    text/csv
    application/csv
    application/json
    application/pdf
  ].freeze

  before_action :require_organization!
  before_action :require_training_admin!, only: [
    :create,
    :fine_training,
    :update,
    :enqueue_fine_training,
    :adaptive_learning_feed,
    :scan_adaptive_learning,
    :approve_adaptive_learning,
    :reject_adaptive_learning,
    :revoke_adaptive_learning
  ]
  before_action :set_training_document, only: [:update]
  before_action :set_adaptive_learning_document, only: [:approve_adaptive_learning, :reject_adaptive_learning, :revoke_adaptive_learning]

  def index
    @training_document = TrainingDocument.new
    @training_vault_document = TrainingVaultDocument.new
    @design_report = DesignReport.new
    training_document_scope = current_organization.training_documents
      .where.not(status: "archived")
      .includes(:user)
    training_document_scope = training_document_scope.where(user: current_user) unless current_user.primary_membership&.admin?
    sorted_training_documents = training_document_scope.to_a
      .sort_by { |document| [(document.file_name.presence || document.title).to_s.downcase, document.created_at || Time.at(0)] }
    @training_document_shelf_total = sorted_training_documents.length
    @recent_training_documents = sorted_training_documents.first(300)
    @recent_training_vault_documents = current_organization.training_vault_documents
      .active
      .recent
      .limit(12)
    @training_vault_encryption_ready = TrainingVaultDocument.encryption_ready?
    @playbook_sync_status = Hubspot::PlaybookCallSyncStatus.for(current_organization)
    @playbook_call_count = current_organization.playbook_calls.active.count
    @recent_playbook_calls = current_organization.playbook_calls.active.recent.limit(8)
    @fathom_configured = WizwikiSettings.fathom_configured?
    @fathom_sync_status = Fathom::DailyCallSyncStatus.for(current_organization)
    @fathom_call_count = current_organization.fathom_calls.active.count
    @recent_fathom_calls = current_organization.fathom_calls.active.recent.limit(8)
    @memory_embedder_model_options = WizwikiSettings.report_embedder_model_options
    @memory_selected_embedder_model = memory_embedder_model_param
    @memory_status = Autos::EmbeddingQueue.status_for(worker_id: "train-page", embedding_model: @memory_selected_embedder_model)
    if current_user.primary_membership&.admin?
      @voice_training_documents = voice_training_document_scope.limit(80)
      @fine_training_embedding_status = fine_training_embedding_status(@memory_selected_embedder_model)
      @adaptive_learning_pending_count = Comms::AdaptiveLearningReview.candidate_scope(current_organization).count
    end
  end

  def fine_training
    @memory_selected_embedder_model = memory_embedder_model_param
    @voice_training_documents = voice_training_document_scope.limit(300)
    @fine_training_embedding_status = fine_training_embedding_status(@memory_selected_embedder_model)
  end

  def adaptive_learning_feed
    render json: Comms::AdaptiveLearningReview.feed(organization: current_organization)
  rescue StandardError => error
    Rails.logger.warn("[TrainingDocuments] adaptive learning feed failed #{error.class}: #{error.message}")
    render json: { error: "Adaptive learning feed is temporarily unavailable." }, status: :service_unavailable
  end

  def scan_adaptive_learning
    job = Comms::AutopilotLearningJob.perform_later(organization_id: current_organization.id)
    render json: { ok: true, job_id: job.job_id, message: "Learning scan queued." }, status: :accepted
  rescue StandardError => error
    Rails.logger.warn("[TrainingDocuments] adaptive learning scan failed #{error.class}: #{error.message}")
    render json: { error: "Learning scan could not be queued." }, status: :unprocessable_entity
  end

  def approve_adaptive_learning
    result = Comms::AdaptiveLearningReview.approve!(
      document: @adaptive_learning_document,
      reviewer: current_user,
      note: params[:review_note]
    )
    render json: result.merge(message: result[:queued] ? "Approved and queued for isolated SMS memory." : "Approved; embedding queue will retry automatically.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def reject_adaptive_learning
    result = Comms::AdaptiveLearningReview.reject!(
      document: @adaptive_learning_document,
      reviewer: current_user,
      note: params[:review_note]
    )
    render json: result.merge(message: "Candidate rejected and kept out of vector memory.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def revoke_adaptive_learning
    result = Comms::AdaptiveLearningReview.revoke!(
      document: @adaptive_learning_document,
      reviewer: current_user,
      note: params[:review_note]
    )
    render json: result.merge(message: "Approved memory revoked and removed from retrieval.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def create
    @training_upload_stats = {
      received: uploaded_files.size,
      total_bytes: uploaded_files.sum { |file| file.size.to_i },
      stored: 0,
      replaced: 0,
      skipped: 0
    }
    Rails.logger.warn(
      "[TrainingDocuments] fine_training_upload_received user_id=#{current_user.id} organization_id=#{current_organization.id} files=#{uploaded_files.size} bytes=#{uploaded_files.sum { |file| file.size.to_i }} manifest_entries=#{upload_manifest_entries.size} manifest_folder_entries=#{upload_manifest_entries.count { |entry| entry['relative_path'].to_s.include?('/') }} rack_file_limit=#{Rack::Utils.multipart_file_limit if Rack::Utils.respond_to?(:multipart_file_limit)} rack_part_limit=#{Rack::Utils.multipart_part_limit if Rack::Utils.respond_to?(:multipart_part_limit)}"
    )

    if pasted_text_too_large?
      redirect_to train_path(anchor: "fine-training"), alert: "Training text is too large. Keep pasted text under #{helpers.number_to_human_size(MAX_TRAINING_BYTES)}."
      return
    end

    if too_many_files?
      redirect_to train_path(anchor: "fine-training"), alert: "Upload #{MAX_TRAINING_FILES} training files or fewer at a time."
      return
    end

    if total_upload_too_large?
      redirect_to train_path(anchor: "fine-training"), alert: "Training upload is too large. Keep each batch under #{helpers.number_to_human_size(MAX_TRAINING_TOTAL_BYTES)}."
      return
    end

    @training_upload_skips = []
    created = create_from_text + create_from_files
    skipped = @training_upload_skips
    @training_upload_stats[:stored] = created
    @training_upload_stats[:skipped] = skipped.size
    queued = @training_upload_stats[:queued].to_i
    Rails.logger.warn(
      "[TrainingDocuments] fine_training_upload_result user_id=#{current_user.id} organization_id=#{current_organization.id} received=#{@training_upload_stats[:received]} stored=#{created} queued=#{queued} replaced=#{@training_upload_stats[:replaced]} skipped=#{skipped.size}"
    )

    if created.positive?
      redirect_to train_path(anchor: "fine-training"), notice: training_upload_notice(created, skipped)
    else
      redirect_to train_path(anchor: "fine-training"), alert: training_upload_alert(skipped)
    end
  end

  def sync_playbooks
    if Hubspot::PlaybookCallSyncStatus.active?(current_organization)
      redirect_to train_path(anchor: "playbook-analyzer"), notice: "Playbook analyzer is already running. This page will keep the last status after refresh."
      return
    end

    request_id = SecureRandom.uuid
    requested_at = Time.current
    Hubspot::PlaybookCallSyncStatus.mark_queued!(
      organization: current_organization,
      request_id: request_id,
      requested_by_user_id: current_user.id,
      requested_by: current_user.display_name,
      requested_at: requested_at
    )
    job = Hubspot::PlaybookCallSyncJob.perform_later(
      organization_id: current_organization.id,
      requested_by_user_id: current_user.id,
      requested_at: requested_at.iso8601,
      request_id: request_id
    )
    Hubspot::PlaybookCallSyncStatus.mark_enqueued!(organization: current_organization, request_id: request_id, job_id: job.job_id)

    redirect_to train_path(anchor: "playbook-analyzer"), notice: "Playbook analyzer started. WIZWIKI will read HubSpot ticket-associated Zoom/playbook calls in the background."
  rescue Hubspot::Error, ActiveRecord::ActiveRecordError => error
    redirect_to train_path(anchor: "playbook-analyzer"), alert: "Playbook analyzer could not start: #{error.message}"
  end

  def sync_fathom
    unless WizwikiSettings.fathom_configured?
      redirect_to train_path(anchor: "fathom-analyzer"), alert: "Fathom API is not configured for WIZWIKI."
      return
    end

    if Fathom::DailyCallSyncStatus.active?(current_organization)
      redirect_to train_path(anchor: "fathom-analyzer"), notice: "Fathom sync is already running. This page will keep the latest status after refresh."
      return
    end

    sync_date = Time.current.in_time_zone("Central Time (US & Canada)").to_date
    result = WizwikiBrain::Thumper.enqueue_fathom!(
      organization: current_organization,
      date: sync_date,
      trigger: "manual",
      force: true
    )

    if result[:skipped]
      redirect_to train_path(anchor: "fathom-analyzer"), notice: result[:reason]
    else
      redirect_to train_path(anchor: "fathom-analyzer"), notice: "Fathom Brain thumper started. Thumper will sync calls, embed them, create the Google Doc, and email only after verification."
    end
  rescue Fathom::Error, ActiveRecord::ActiveRecordError => error
    redirect_to train_path(anchor: "fathom-analyzer"), alert: "Fathom sync could not start: #{error.message}"
  end

  def enqueue_memory
    unless current_user.primary_membership&.admin?
      redirect_to train_path(anchor: "computed-memory"), alert: "Only admins can queue stored training material into Thumper vector memory."
      return
    end

    selected_embedder_model = memory_embedder_model_param
    result = Autos::EmbeddingQueue.enqueue_recent!(organization: current_organization, limit: 250, embedding_model: selected_embedder_model)
    if result[:ok]
      redirect_to train_path(memory_embedder_model: selected_embedder_model, anchor: "computed-memory"), notice: "Manual search-memory refresh queued for Alice using #{WizwikiSettings.report_embedder_model_label(selected_embedder_model)}. #{result[:queued]} chunks are waiting for embeddings."
    else
      redirect_to train_path(memory_embedder_model: selected_embedder_model, anchor: "computed-memory"), alert: "Manual search-memory refresh is waiting for pgvector on SUN: #{result[:error]}"
    end
  end

  def enqueue_fine_training
    selected_embedder_model = memory_embedder_model_param
    unless Autos::EmbeddingQueue.storage_ready?
      redirect_back fallback_location: train_path(anchor: "voice-editor"), alert: "Fine Training embedding is waiting for pgvector on SUN."
      return
    end

    documents = current_organization.training_documents
      .waiting_for_embedding
      .where.not(status: "archived")
      .where(<<~SQL.squish)
        NOT (
          COALESCE(metadata ->> 'training_kind', '') = '#{Comms::AutopilotLearning::TRAINING_KIND}'
          AND COALESCE(metadata ->> 'learning_status', '') <> '#{Comms::AdaptiveLearningReview::APPROVED_STATUS}'
        )
      SQL

    queued = 0
    failed = 0
    documents.find_each do |document|
      if Autos::EmbeddingQueue.enqueue_source!(document, embedding_model: selected_embedder_model)
        queued += 1
      else
        failed += 1
      end
    end

    status = fine_training_embedding_status(selected_embedder_model)
    message = "Fine Training only: queued #{queued} new/changed document#{'s' unless queued == 1} for #{WizwikiSettings.report_embedder_model_label(selected_embedder_model)}. Embedded #{status[:embedded]} // new #{status[:new]} // processing #{status[:processing]}."
    if failed.positive?
      redirect_back fallback_location: train_path(anchor: "voice-editor"), alert: "#{message} #{failed} document#{'s' unless failed == 1} could not be queued."
    else
      redirect_back fallback_location: train_path(anchor: "voice-editor"), notice: message
    end
  end

  def update
    body = training_document_params[:body].to_s.scrub
    title = training_document_params[:title].to_s.strip.presence || @training_document.title

    if body.blank?
      redirect_back fallback_location: train_path(anchor: "voice-editor"), alert: "Voice training body cannot be blank."
      return
    end

    if body.bytesize > MAX_TRAINING_BYTES
      redirect_back fallback_location: train_path(anchor: "voice-editor"), alert: "Voice training text is too large. Keep it under #{helpers.number_to_human_size(MAX_TRAINING_BYTES)}."
      return
    end

    source_changed = @training_document.title.to_s != title || @training_document.body.to_s != body
    @training_document.assign_attributes(
      title: title,
      body: body,
      byte_size: body.bytesize,
      status: "ingested",
      metadata: @training_document.metadata.to_h.merge(
        "training_kind" => "copywriter_voice",
        "voice_editor_updated_by_user_id" => current_user.id,
        "voice_editor_updated_by" => current_user.display_name,
        "voice_editor_updated_at" => Time.current.iso8601,
        "vector_policy" => "source_edited_reembed_required"
      )
    )
    @training_document.save!

    Autos::EmbeddingQueue.delete_source!(@training_document) if source_changed
    queued = source_changed ? queue_training_embedding!(@training_document) : false

    notice = if queued
      "Voice training saved and queued for #{WizwikiSettings.report_embedder_model_label(memory_embedder_model_param)} embedding."
    elsif source_changed
      "Voice training saved. Old vectors were marked stale; automatic embedding queue will retry shortly."
    else
      "Voice training saved."
    end

    redirect_back fallback_location: train_path(anchor: "voice-editor"), notice: notice
  rescue ActiveRecord::RecordInvalid => error
    redirect_back fallback_location: train_path(anchor: "voice-editor"), alert: "Voice training could not be saved: #{error.record.errors.full_messages.to_sentence}"
  end

  private

  def memory_embedder_model_param
    WizwikiSettings.normalize_report_embedder_model(params[:memory_embedder_model])
  end

  def set_training_document
    @training_document = current_organization.training_documents.where.not(status: "archived").find(params[:id])
  end

  def set_adaptive_learning_document
    @adaptive_learning_document = current_organization.training_documents
      .where(source_type: Comms::AutopilotLearning::SOURCE_TYPE)
      .where("metadata ->> 'training_kind' = ?", Comms::AutopilotLearning::TRAINING_KIND)
      .find(params[:id])
  end

  def require_training_admin!
    return if current_user.primary_membership&.admin?

    if request.format.json?
      render json: { error: "Only admins can review adaptive learning memory." }, status: :forbidden
      return
    end

    redirect_to train_path(anchor: "fine-training"), alert: "Only admins can edit Thumper voice training."
  end

  def training_document_params
    params.require(:training_document).permit(:title, :body)
  end

  def voice_training_document_scope
    current_organization.training_documents
      .where.not(status: "archived")
      .includes(:user)
      .order(updated_at: :desc, created_at: :desc)
  end

  def fine_training_embedding_status(embedding_model = memory_embedder_model_param)
    scope = current_organization.training_documents.where.not(status: "archived")
    result = {
      total: scope.count,
      new: scope.where(status: "ingested").count,
      processing: scope.where(status: "processing").count,
      embedded: scope.where(status: "indexed").count,
      failed: 0,
      chunks_pending: 0,
      chunks_claimed: 0,
      chunks_embedded: 0,
      chunks_failed: 0,
      embedder_model: embedding_model
    }
    return result unless Autos::EmbeddingQueue.storage_ready?

    chunk_scope = AutosEmbeddingChunk.where(
      organization: current_organization,
      source_type: "TrainingDocument",
      source_id: scope.select(:id),
      embedding_model: embedding_model
    )
    counts = chunk_scope.group(:status).count
    result.merge(
      failed: counts["failed"].to_i,
      chunks_pending: counts["pending"].to_i,
      chunks_claimed: counts["claimed"].to_i,
      chunks_embedded: counts["embedded"].to_i,
      chunks_failed: counts["failed"].to_i
    )
  rescue StandardError => error
    Rails.logger.warn("[TrainingDocuments] fine training status failed #{error.class}: #{error.message}")
    {
      total: 0,
      new: 0,
      processing: 0,
      embedded: 0,
      failed: 0,
      chunks_pending: 0,
      chunks_claimed: 0,
      chunks_embedded: 0,
      chunks_failed: 0,
      embedder_model: embedding_model
    }
  end

  def create_from_text
    body = params.dig(:training_document, :body).to_s.strip
    return 0 if body.blank?

    document = current_organization.training_documents.create!(
      user: current_user,
      title: params.dig(:training_document, :title).presence || "Fine training note",
      source_type: "pasted_text",
      body: body,
      byte_size: body.bytesize,
      status: "ingested",
      metadata: training_metadata.merge(
        "upload_kind" => "pasted_text",
        "vector_policy" => "auto_embed_on_ingest"
      )
    )
    queue_training_embedding!(document)
    1
  end

  def create_from_files
    uploaded_files.each_with_index.count do |file, index|
      original_name = original_upload_name_for(file, index)

      unless allowed_training_file?(file)
        skip_training_file(original_name, "unsupported type")
        next false
      end

      raw = training_text_for(file)
      if raw.blank?
        skip_training_file(original_name, "no readable text")
        next false
      end

      if raw.bytesize > MAX_TRAINING_BYTES
        skip_training_file(original_name, "over #{helpers.number_to_human_size(MAX_TRAINING_BYTES)} after text extraction")
        next false
      end

      body = raw.to_s.scrub
      file_name = sanitized_filename(original_name)
      replaced = replace_matching_training_documents!(file_name: file_name, original_name: original_name, byte_size: body.bytesize)
      @training_upload_stats[:replaced] += replaced

      document = current_organization.training_documents.create!(
        user: current_user,
        title: params.dig(:training_document, :title).presence || training_title_for(original_name),
        source_type: folder_upload?(original_name) ? "folder_upload" : "text_file",
        body: body,
        file_name: file_name,
        content_type: file.content_type,
        byte_size: body.bytesize,
        status: "ingested",
        metadata: training_metadata.merge(
          "upload_kind" => folder_upload?(original_name) ? "folder_upload" : "file_upload",
          "file_kind" => pdf_file?(file) ? "pdf" : "text",
          "original_filename" => original_name.first(300),
          "folder_path" => sanitized_folder_path(original_name),
          "replaced_existing_count" => (replaced if replaced.positive?),
          "vector_policy" => "auto_embed_on_ingest"
        ).compact
      )
      queue_training_embedding!(document)
      true
    end
  end

  def queue_training_embedding!(document, embedding_model: memory_embedder_model_param)
    @training_upload_stats ||= {}
    if Autos::EmbeddingQueue.enqueue_source!(document, embedding_model: embedding_model)
      @training_upload_stats[:queued] = @training_upload_stats[:queued].to_i + 1
      true
    else
      @training_upload_stats[:queue_failed] = @training_upload_stats[:queue_failed].to_i + 1
      Rails.logger.warn("[TrainingDocuments] auto embedding queue failed document_id=#{document.id} model=#{embedding_model}")
      false
    end
  end

  def uploaded_files
    @uploaded_files ||= Array(params.dig(:training_document, :files)).reject(&:blank?)
  end

  def upload_manifest_entries
    @upload_manifest_entries ||= begin
      raw = params.dig(:training_document, :upload_manifest).to_s
      parsed = JSON.parse(raw.presence || "[]")
      Array(parsed).select { |entry| entry.is_a?(Hash) }
    rescue JSON::ParserError => error
      Rails.logger.warn("[TrainingDocuments] upload manifest parse failed #{error.class}: #{error.message}")
      []
    end
  end

  def original_upload_name_for(file, index)
    entry = upload_manifest_entry_for(file, index)
    relative_path = entry.to_h["relative_path"].to_s
    return relative_path if relative_path.present?

    file.original_filename.to_s
  end

  def upload_manifest_entry_for(file, index)
    indexed_entry = upload_manifest_entries[index]
    return indexed_entry if manifest_entry_matches_file?(indexed_entry, file)

    upload_manifest_entries.find { |entry| manifest_entry_matches_file?(entry, file) }
  end

  def manifest_entry_matches_file?(entry, file)
    return false unless entry.is_a?(Hash)

    entry["name"].to_s == file.original_filename.to_s &&
      entry["size"].to_i == file.size.to_i
  end

  def too_many_files?
    uploaded_files.size > MAX_TRAINING_FILES
  end

  def total_upload_too_large?
    uploaded_files.sum { |file| file.size.to_i } > MAX_TRAINING_TOTAL_BYTES
  end

  def pasted_text_too_large?
    params.dig(:training_document, :body).to_s.bytesize > MAX_TRAINING_BYTES
  end

  def allowed_training_file?(file)
    extension = File.extname(file.original_filename.to_s).downcase
    ALLOWED_TRAINING_EXTENSIONS.include?(extension) || ALLOWED_TRAINING_CONTENT_TYPES.include?(file.content_type.to_s)
  end

  def training_text_for(file)
    return extract_pdf_text(file) if pdf_file?(file)

    file.read(MAX_TRAINING_BYTES + 1).to_s.scrub
  ensure
    file.rewind if file.respond_to?(:rewind)
  end

  def pdf_file?(file)
    File.extname(file.original_filename.to_s).downcase == ".pdf" || file.content_type.to_s == "application/pdf"
  end

  def extract_pdf_text(file)
    stdout, stderr, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", file.tempfile.path, "-")
    return stdout.to_s.scrub.strip if status.success? && stdout.present?

    Rails.logger.warn("[TrainingDocuments] PDF text extraction failed for #{file.original_filename}: #{stderr.to_s.squish.first(240)}")
    ""
  end

  def folder_upload?(filename)
    filename.to_s.include?("/")
  end

  def training_title_for(filename)
    File.basename(filename.to_s).presence || "Fine training file"
  end

  def sanitized_filename(filename)
    File.basename(filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").first(160)
  end

  def sanitized_folder_path(filename)
    parts = filename.to_s.split("/")[0...-1].to_a
    return nil if parts.blank?

    parts.map { |part| part.gsub(/[^a-zA-Z0-9._ -]/, "_").squish.first(80) }.join("/").first(500)
  end

  def replace_matching_training_documents!(file_name:, original_name:, byte_size:)
    return 0 if file_name.blank? || byte_size.to_i <= 0

    candidates = current_organization.training_documents
      .where(file_name: file_name, byte_size: byte_size)
      .to_a
    exact_path_matches = candidates.select { |document| document.metadata.to_h["original_filename"].to_s == original_name.to_s }
    legacy_basename_matches = candidates.select do |document|
      stored_name = document.metadata.to_h["original_filename"].to_s
      stored_name.blank? || (!stored_name.include?("/") && stored_name == file_name)
    end
    existing_documents = exact_path_matches.presence || legacy_basename_matches
    return 0 if existing_documents.blank?

    existing_documents.each do |document|
      Autos::EmbeddingQueue.delete_source!(document)
      document.destroy!
    end
    Rails.logger.warn(
      "[TrainingDocuments] replaced_existing_training_documents user_id=#{current_user.id} organization_id=#{current_organization.id} file_name=#{file_name} byte_size=#{byte_size} count=#{existing_documents.size}"
    )
    existing_documents.size
  end

  def training_metadata
    {
      "uploaded_by_user_id" => current_user.id,
      "uploaded_at" => Time.current.iso8601,
      "brain_types" => %w[wizwiki_ask market_report comms],
      "training_kind" => "fine_training_document"
    }
  end

  def skip_training_file(filename, reason)
    @training_upload_skips ||= []
    @training_upload_skips << "#{File.basename(filename.to_s).presence || 'unnamed file'} (#{reason})"
    Rails.logger.warn(
      "[TrainingDocuments] fine_training_upload_skip user_id=#{current_user.id} organization_id=#{current_organization.id} file=#{File.basename(filename.to_s).presence || 'unnamed file'} reason=#{reason}"
    )
  end

  def training_upload_notice(created, skipped)
    stats = @training_upload_stats.to_h
    message = "Received #{stats[:received].to_i} file#{'s' unless stats[:received].to_i == 1}; stored #{created} fine training document#{'s' unless created == 1} for Thumper."
    if stats[:queued].to_i.positive?
      message += " Queued #{stats[:queued]} for automatic Thumper vector memory."
    end
    if stats[:queue_failed].to_i.positive?
      message += " #{stats[:queue_failed]} could not be queued immediately and will be picked up by the nightly sweep."
    end
    if stats[:replaced].to_i.positive?
      message += " Replaced #{stats[:replaced]} matching existing file#{'s' unless stats[:replaced].to_i == 1} by exact filename and size."
    end
    message += " Thumper will retrieve these embeddings automatically in /ask, AI LAB, reports, and comms."
    return message if skipped.blank?

    "#{message} Skipped #{skipped.size} file#{'s' unless skipped.size == 1}: #{skipped.first(4).join(', ')}#{'...' if skipped.size > 4}."
  end

  def training_upload_alert(skipped)
    stats = @training_upload_stats.to_h
    return "Add pasted text or upload one or more text/PDF files. Rails received #{stats[:received].to_i} file#{'s' unless stats[:received].to_i == 1} in this request." if skipped.blank?

    "No training documents were stored. Rails received #{stats[:received].to_i} file#{'s' unless stats[:received].to_i == 1}; skipped #{skipped.size} file#{'s' unless skipped.size == 1}: #{skipped.first(5).join(', ')}#{'...' if skipped.size > 5}. Use TXT, MD, CSV, JSON, or PDF for fine training."
  end
end
