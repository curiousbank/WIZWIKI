require "base64"
require "stringio"

class WizwikiWorkerController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :verify_authenticity_token
  before_action :authenticate_worker!

  def report_status
    render json: DealReports::WorkerQueue.status_for(worker_id: worker_id)
  end

  def recent_reports
    render json: {
      ok: true,
      worker_id: worker_id,
      reports: DealReports::WorkerQueue.recent_reports(limit: params[:limit].presence || 25)
    }
  end

  def agency_logo
    path = agency_logo_file_path
    return head :no_content if path.blank?

    send_file path, type: "image/svg+xml", disposition: "inline"
  end

  def next_report
    return head :no_content unless WizwikiSettings.wizwiki_report_worker_enabled?

    artifact = DealReports::WorkerQueue.claim_next!(worker_id: worker_id)
    return head :no_content if artifact.blank?

    render json: DealReports::WorkerQueue.payload_for(artifact)
  end

  def logo
    artifact = CrmRecordArtifact.includes(crm_record: { deal_media_attachments: :blob }).find(params[:id])
    url = DealReports::WorkerQueue.logo_url_for(artifact.crm_record)
    return redirect_to(url, allow_other_host: true) if url.present?

    attachment = DealReports::WorkerQueue.logo_attachment_for(artifact.crm_record)
    return head :no_content if attachment.blank?

    send_active_storage_attachment(attachment, disposition: "inline")
  end

  def media
    artifact = CrmRecordArtifact.includes(crm_record: { deal_media_attachments: :blob }).find(params[:id])
    attachment = artifact.crm_record.deal_media.attachments.find(params[:attachment_id])

    send_active_storage_attachment(attachment, disposition: params[:disposition].presence || "attachment")
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def complete_report
    artifact = CrmRecordArtifact.includes(:crm_record, :organization).find(worker_artifact_id)
    payload = worker_payload
    file, filename, content_type = report_file_from_request(payload)
    manifest = parse_json_field(payload["manifest"])

    DealReports::WorkerQueue.complete!(
      artifact,
      file: file,
      filename: filename,
      content_type: content_type,
      manifest: manifest,
      worker_payload: payload
    )

    artifact.reload
    canva_kit = artifact.metadata.to_h.fetch("canva_kit", {}).to_h

    render json: {
      ok: true,
      id: artifact.id,
      status: artifact.status,
      file_url: artifact.file_url,
      storage_key: artifact.storage_key,
      byte_size: artifact.byte_size,
      canva_kit: canva_kit.slice("file_url", "storage_key", "byte_size", "filename", "content_type")
    }
  rescue DealReports::WorkerQueue::CanceledError => error
    Rails.logger.info("[WizwikiWorker] complete ignored for canceled artifact=#{worker_artifact_id}: #{error.message}")
    render json: { ok: false, id: worker_artifact_id, status: "canceled", canceled: true, error: error.message }, status: :conflict
  rescue StandardError => error
    Rails.logger.error("[WizwikiWorker] complete failed artifact=#{worker_artifact_id} #{error.class}: #{error.message}")
    render json: { ok: false, error: error.message }, status: :unprocessable_entity
  end

  def heartbeat_report
    artifact = CrmRecordArtifact.find(worker_artifact_id)

    render json: DealReports::WorkerQueue.heartbeat!(artifact, worker_id: worker_id, worker_payload: worker_payload)
  rescue StandardError => error
    Rails.logger.warn("[WizwikiWorker] heartbeat failed artifact=#{worker_artifact_id} #{error.class}: #{error.message}")
    render json: { ok: false, error: error.message }, status: :unprocessable_entity
  end

  def fail_report
    artifact = CrmRecordArtifact.find(worker_artifact_id)
    payload = worker_payload

    DealReports::WorkerQueue.fail!(
      artifact,
      error: payload["error"].presence || payload["message"].presence || "worker failed",
      worker_payload: payload
    )

    render json: { ok: true, id: artifact.id, status: artifact.reload.status }
  end

  private

  def authenticate_worker!
    expected = WizwikiSettings.wizwiki_report_worker_token.to_s
    return head :service_unavailable if expected.blank?

    supplied = request.authorization.to_s.sub(/\ABearer\s+/i, "").strip
    return head :unauthorized if supplied.blank? || supplied.bytesize != expected.bytesize
    return if ActiveSupport::SecurityUtils.secure_compare(supplied, expected)

    head :unauthorized
  end

  def worker_id
    request.headers["X-Wizwiki-Worker-Id"].presence ||
      request.headers["X-Autos-Worker-Id"].presence ||
      request.query_parameters["worker_id"].presence ||
      worker_payload["worker_id"].presence ||
      "alice-wizwiki-reports-01"
  end

  def worker_artifact_id
    request.path_parameters[:id] || params[:id]
  end

  def worker_payload
    @worker_payload ||= parsed_worker_payload.except("file")
  end

  def parsed_worker_payload
    return parsed_json_worker_payload if json_worker_request?

    request.request_parameters.to_h
  end

  def json_worker_request?
    request.media_type == "application/json"
  end

  def parsed_json_worker_payload
    raw = request.raw_post.to_s
    return {} if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError => error
    raise ArgumentError, "invalid JSON worker payload: #{error.message}"
  end

  def report_file_from_request(payload = worker_payload)
    unless json_worker_request?
      upload = params[:file]
      if upload.present?
        return [
          upload.tempfile,
          upload.original_filename,
          upload.content_type
        ]
      end
    end

    encoded = payload["file_base64"].presence || payload["document_base64"].presence
    raise ArgumentError, "file or file_base64 is required" if encoded.blank?

    [
      StringIO.new(Base64.decode64(encoded)),
      payload["filename"].presence || "am-market-report-#{worker_artifact_id}.docx",
      payload["content_type"].presence || "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ]
  end

  def send_active_storage_attachment(attachment, disposition:)
    send_data(
      attachment.download,
      filename: attachment.filename.to_s,
      type: attachment.blob.content_type,
      disposition: disposition
    )
  end


  def agency_logo_file_path
    [
      Rails.root.join("app/assets/images/logo.svg"),
      Rails.root.join("public/logo.svg"),
      Rails.root.join("public/icon.svg")
    ].find { |path| path.file? }
  end

  def parse_json_field(value)
    return {} if value.blank?
    return value.to_h if value.respond_to?(:to_h)

    JSON.parse(value.to_s)
  rescue JSON::ParserError
    { "raw" => value.to_s }
  end
end
