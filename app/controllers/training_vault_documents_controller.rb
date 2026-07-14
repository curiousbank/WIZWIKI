class TrainingVaultDocumentsController < ApplicationController
  MAX_VAULT_FILE_BYTES = 5.megabytes
  MAX_VAULT_TOTAL_BYTES = 20.megabytes
  MAX_VAULT_FILES = 50
  ALLOWED_EXTENSIONS = %w[.txt .md .markdown .csv .json].freeze
  ALLOWED_CONTENT_TYPES = %w[
    text/plain
    text/markdown
    text/csv
    application/csv
    application/json
  ].freeze

  before_action :require_organization!
  before_action :require_training_admin!, only: [:approve, :archive]

  def create
    unless TrainingVaultDocument.encryption_ready?
      redirect_to train_path(anchor: "training-vault"), alert: "Training vault is locked until Rails encryption keys are configured."
      return
    end

    if too_many_files?
      redirect_to train_path(anchor: "training-vault"), alert: "Vault upload accepts #{MAX_VAULT_FILES} files or fewer at a time."
      return
    end

    if total_upload_too_large?
      redirect_to train_path(anchor: "training-vault"), alert: "Vault upload is too large. Keep each batch under #{helpers.number_to_human_size(MAX_VAULT_TOTAL_BYTES)}."
      return
    end

    created = create_from_text + create_from_files

    if created.positive?
      redirect_to train_path(anchor: "training-vault"), notice: "#{created} vault document#{'s' unless created == 1} stored for review. Approve only clean, useful data before vectoring."
    else
      redirect_to train_path(anchor: "training-vault"), alert: "Add trusted text or upload text-like files."
    end
  end

  def approve
    document = current_organization.training_vault_documents.active.find(params[:id])

    if document.approve_for_embedding!(approver: current_user)
      redirect_to train_path(anchor: "training-vault"), notice: "#{document.title} approved and queued for Thumper vector memory."
    else
      redirect_to train_path(anchor: "training-vault"), alert: "#{document.title} was approved, but vector storage is not ready."
    end
  end

  def archive
    document = current_organization.training_vault_documents.active.find(params[:id])
    document.archive!
    redirect_to train_path(anchor: "training-vault"), notice: "#{document.title} archived and removed from vector memory."
  end

  private

  def create_from_text
    body = params.dig(:training_vault_document, :body).to_s.strip
    return 0 if body.blank?
    return 0 if body.bytesize > MAX_VAULT_FILE_BYTES

    current_organization.training_vault_documents.create!(
      user: current_user,
      title: params.dig(:training_vault_document, :title).presence || "Vault training note",
      source_type: "pasted_text",
      body: body,
      byte_size: body.bytesize,
      status: "review",
      metadata: base_metadata.merge("upload_kind" => "pasted_text")
    )
    1
  end

  def create_from_files
    uploaded_files.count do |file|
      next false unless allowed_file?(file)

      raw = file.read(MAX_VAULT_FILE_BYTES + 1)
      next false if raw.bytesize > MAX_VAULT_FILE_BYTES

      original_name = file.original_filename.to_s
      current_organization.training_vault_documents.create!(
        user: current_user,
        title: params.dig(:training_vault_document, :title).presence || vault_title_for(original_name),
        source_type: folder_upload?(original_name) ? "folder_upload" : "vault_upload",
        body: raw.to_s.scrub,
        file_name: sanitized_filename(original_name),
        folder_path: sanitized_folder_path(original_name),
        content_type: file.content_type,
        byte_size: raw.bytesize,
        status: "review",
        metadata: base_metadata.merge(
          "upload_kind" => folder_upload?(original_name) ? "folder_upload" : "file_upload",
          "original_filename" => original_name.to_s.first(300)
        )
      )
      true
    end
  end

  def uploaded_files
    @uploaded_files ||= Array(params.dig(:training_vault_document, :files)).reject(&:blank?)
  end

  def too_many_files?
    uploaded_files.size > MAX_VAULT_FILES
  end

  def total_upload_too_large?
    uploaded_files.sum { |file| file.size.to_i } > MAX_VAULT_TOTAL_BYTES
  end

  def allowed_file?(file)
    extension = File.extname(file.original_filename.to_s).downcase
    ALLOWED_EXTENSIONS.include?(extension) || ALLOWED_CONTENT_TYPES.include?(file.content_type.to_s)
  end

  def folder_upload?(filename)
    filename.to_s.include?("/")
  end

  def vault_title_for(filename)
    File.basename(filename.to_s).presence || "Vault training file"
  end

  def sanitized_filename(filename)
    File.basename(filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").first(160)
  end

  def sanitized_folder_path(filename)
    parts = filename.to_s.split("/")[0...-1].to_a
    return nil if parts.blank?

    parts.map { |part| part.gsub(/[^a-zA-Z0-9._ -]/, "_").squish.first(80) }.join("/").first(500)
  end

  def base_metadata
    {
      "vault" => true,
      "security_note" => "encrypted_source_review_required_before_vector_memory",
      "uploaded_by_user_id" => current_user.id,
      "uploaded_at" => Time.current.iso8601
    }
  end

  def require_training_admin!
    return if current_user.primary_membership&.admin?

    redirect_to train_path(anchor: "training-vault"), alert: "Only admins can approve, vector, or archive trusted training material."
  end
end
