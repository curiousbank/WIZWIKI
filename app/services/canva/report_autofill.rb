require "json"
require "tempfile"
require "zip"

module Canva
  class ReportAutofill
    POLL_INTERVAL = 3.seconds
    TEXT_LIMIT = 1_500
    EXPORT_CONTENT_TYPES = {
      "pdf" => "application/pdf",
      "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "png" => "image/png",
      "jpg" => "image/jpeg"
    }.freeze

    def self.call(artifact)
      new(artifact).call
    end

    def initialize(artifact)
      @artifact = artifact
    end

    def call
      return mark_waiting("Canva OAuth is not configured.") unless WizwikiSettings.canva_configured?

      connection = canva_connection
      return mark_waiting("No connected Canva account found for this organization.") if connection.blank?

      client = Canva::ApiClient.new(connection)
      if WizwikiSettings.canva_brand_template_id.present?
        build_from_brand_template(client, connection)
      else
        build_docx_import(client, connection)
      end
    rescue StandardError => error
      Rails.logger.error("[Canva::ReportAutofill] artifact=#{artifact.id} #{error.class}: #{error.message}")
      mark_failed(error.message)
    ensure
      package&.close!
    end

    private

    attr_reader :artifact, :package

    def build_from_brand_template(client, connection)
      dataset = dataset_for(client)
      autofill_data = data_for(dataset)
      return mark_waiting("Canva brand template has no matching text fields for this report.", extra: { "dataset_fields" => dataset.keys }) if autofill_data.blank?

      started = client.post("/autofills", {
        brand_template_id: WizwikiSettings.canva_brand_template_id,
        data: autofill_data
      })
      job_id = started.dig("job", "id")
      raise Canva::ApiError, "Canva autofill job ID was missing." if job_id.blank?

      update_canva_metadata(
        "status" => "autofill_in_progress",
        "mode" => "brand_template_autofill",
        "brand_template_id" => WizwikiSettings.canva_brand_template_id,
        "connection_user_id" => connection.user_id,
        "autofill_job_id" => job_id,
        "autofill_data_keys" => autofill_data.keys,
        "started_at" => Time.current.iso8601
      )

      job = poll_job(client, "/autofills/#{job_id}", max_seconds: WizwikiSettings.canva_poll_seconds)
      status = job.dig("job", "status")
      if status != "success"
        return mark_failed("Canva autofill did not complete: #{job_error(job) || status}", extra: { "autofill_job" => job["job"] })
      end

      design = job.dig("job", "result", "design").to_h
      design_id = design["id"].presence
      raise Canva::ApiError, "Canva design ID was missing from autofill result." if design_id.blank?

      finish_output_package(
        client: client,
        connection: connection,
        design: design,
        job: job.fetch("job", {}),
        mode: "brand_template_autofill"
      )
    end

def build_docx_import(client, connection)
  docx_bytes = DealReports::Publisher.download_bytes!(artifact).to_s.b
  raise Canva::ApiError, "DOCX report bytes are missing; generate the report before building Canva output." if docx_bytes.bytesize.zero?

  started = client.import_design(
    bytes: docx_bytes,
    title: canva_import_title,
    mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  )
  job_id = started.dig("job", "id")
  raise Canva::ApiError, "Canva DOCX import job ID was missing." if job_id.blank?

  update_canva_metadata(
    "status" => "docx_import_in_progress",
    "mode" => "docx_import",
    "message" => "No CANVA_BRAND_TEMPLATE_ID set. Importing the WIZWIKI market analyzer DOCX report into Canva, then exporting and packaging the result.",
    "connection_user_id" => connection.user_id,
    "import_job_id" => job_id,
    "started_at" => Time.current.iso8601
  )

  job = poll_job(client, "/imports/#{job_id}", max_seconds: WizwikiSettings.canva_poll_seconds)
  status = job.dig("job", "status")
  if status != "success"
    return mark_failed("Canva DOCX import did not complete: #{job_error(job) || status}", extra: { "import_job" => job["job"] })
  end

  designs = Array(job.dig("job", "result", "designs"))
  design = designs.first.to_h
  design_id = design["id"].presence
  raise Canva::ApiError, "Canva DOCX import did not return a design ID." if design_id.blank?

  finish_output_package(
    client: client,
    connection: connection,
    design: design,
    job: job.fetch("job", {}).merge("imported_design_count" => designs.size),
    mode: "docx_import"
  )
end

    def finish_output_package(client:, connection:, design:, job:, mode:)
      existing_canva = artifact.metadata.to_h.fetch("canva", {}).to_h
      canva_started_at = parse_canva_time(existing_canva["started_at"]) || Time.current
      design_id = design.fetch("id")
      exports = export_design(client, design_id)
      @package = build_output_package(design: design, canva_job: job, exports: exports, mode: mode)
      published = DealReports::Publisher.publish_sidecar!(
        artifact: artifact,
        file: package,
        filename: output_filename,
        content_type: "application/zip",
        file_url: "/deals/reports/#{artifact.id}/canva-output"
      )

      canva_completed_at = Time.current
      canva_build_seconds = duration_seconds(canva_started_at, canva_completed_at)

      update_canva_metadata(
        "status" => "ready",
        "mode" => mode,
        "completed_at" => canva_completed_at.iso8601,
        "build_seconds" => canva_build_seconds,
        "brand_template_id" => WizwikiSettings.canva_brand_template_id,
        "connection_user_id" => connection.user_id,
        "autofill_job_id" => job["id"],
        "design" => compact_design(design),
        "exports" => compact_exports(exports),
        "output_package" => published.merge(
          "filename" => output_filename,
          "created_at" => canva_completed_at.iso8601,
          "build_seconds" => canva_build_seconds
        )
      )
      artifact.update!(status: "ready")
      { status: "ready", design_id: design_id, output_package: published, mode: mode }
    end

    def canva_connection
      scope = artifact.organization.canva_connections.where(status: "connected")
      scope.find_by(user_id: artifact.user_id) || scope.order(updated_at: :desc).first
    end

    def dataset_for(client)
      response = client.get("/brand-templates/#{WizwikiSettings.canva_brand_template_id}/dataset")
      response.fetch("dataset", {}).to_h
    end

    def data_for(dataset)
      values = report_values
      dataset.each_with_object({}) do |(field, definition), data|
        next unless definition.to_h["type"] == "text"

        value = value_for_field(field, values)
        next if value.blank?

        data[field] = { type: "text", text: safe_text(value, limit: TEXT_LIMIT) }
      end
    end

    def report_values
      manifest = artifact.metadata.to_h.fetch("manifest", {}).to_h
      quality = artifact.metadata.to_h.fetch("quality", {}).to_h
      crm = artifact.crm_record
      properties = crm.properties.to_h
      hubspot = properties.dig("hubspot", "properties").to_h
      company_name = artifact.metadata.to_h["company_name"].presence || hubspot["company"].presence || crm.name

      {
        "artifact_id" => artifact.id,
        "deal_id" => crm.id,
        "business_name" => company_name,
        "client_name" => company_name,
        "company_name" => company_name,
        "report_title" => manifest["report_title"].presence || artifact.title,
        "industry" => artifact.metadata.to_h["industry"].presence || hubspot["industry"].presence || crm.stage,
        "service_area" => hubspot["service_area"].presence || hubspot["city"].presence || hubspot["zip"].presence || "Local service area",
        "campaign_window" => "Next 90 days",
        "recommended_campaign" => "Market Strategy & Seasonality Campaign",
        "best_opportunity" => best_opportunity_text(manifest),
        "executive_summary" => section_text(manifest, "executive_summary"),
        "market_snapshot" => section_text(manifest, "market_snapshot"),
        "seasonality" => section_text(manifest, "seasonality_analysis"),
        "campaign_recommendation" => section_text(manifest, "campaign_recommendation"),
        "product_strategy" => section_text(manifest, "product_strategy"),
        "neighborhood_targeting" => section_text(manifest, "neighborhood_targeting"),
        "offer_strategy" => section_text(manifest, "offer_strategy"),
        "next_steps" => section_text(manifest, "final_recommendation_summary"),
        "model" => manifest["model"].presence || quality["model"].presence || "WIZWIKI market analyzer"
      }
    end

    def value_for_field(field, values)
      normalized = field.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      values[normalized].presence || values[field.to_s.downcase].presence || fuzzy_value(normalized, values)
    end

    def fuzzy_value(normalized, values)
      return values["business_name"] if normalized.include?("business") || normalized.include?("client") || normalized.include?("company")
      return values["report_title"] if normalized.include?("title")
      return values["executive_summary"] if normalized.include?("summary")
      return values["best_opportunity"] if normalized.include?("opportunity")
      return values["recommended_campaign"] if normalized.include?("campaign")
      return values["service_area"] if normalized.include?("area") || normalized.include?("location")
      return values["offer_strategy"] if normalized.include?("offer")
      return values["next_steps"] if normalized.include?("next") || normalized.include?("cta")

      nil
    end

    def section_text(manifest, key)
      sections = manifest["sections"]
      if sections.is_a?(Hash)
        value = sections[key] || sections[key.to_s]
        return stringify_section(value) if value.present?
      elsif sections.is_a?(Array)
        found = sections.find { |section| section.to_h["id"].to_s == key || section.to_h["title"].to_s.downcase.include?(key.tr("_", " ")) }
        return stringify_section(found) if found.present?
      end
      "See generated DOCX report for #{key.tr('_', ' ')}."
    end

    def stringify_section(value)
      case value
      when String then value
      when Array then value.map { |item| stringify_section(item) }.join("\n")
      when Hash then value.values.map { |item| stringify_section(item) }.join("\n")
      else value.to_s
      end.squish
    end

    def best_opportunity_text(manifest)
      text = section_text(manifest, "executive_summary")
      text.presence || "Use the next 90 days to turn local timing into direct-mail and neighborhood campaign momentum."
    end

    def poll_job(client, path, max_seconds:)
      deadline = Time.current + max_seconds.to_i.seconds
      last = nil
      loop do
        last = client.get(path)
        status = last.dig("job", "status")
        return last if status.in?(%w[success failed]) || Time.current >= deadline

        sleep POLL_INTERVAL
      end
      last
    end

    def export_design(client, design_id)
      WizwikiSettings.canva_export_formats.filter_map do |format|
        export_one(client, design_id, format)
      rescue StandardError => error
        Rails.logger.warn("[Canva::ReportAutofill] export #{format} failed artifact=#{artifact.id}: #{error.message}")
        {
          "format" => format,
          "status" => "failed",
          "error" => safe_text(error.message, limit: 500)
        }
      end
    end

    def export_one(client, design_id, format)
      started = client.post("/exports", {
        design_id: design_id,
        format: export_format_payload(format)
      })
      export_id = started.dig("job", "id")
      raise Canva::ApiError, "Canva export job ID missing for #{format}." if export_id.blank?

      job = poll_job(client, "/exports/#{export_id}", max_seconds: WizwikiSettings.canva_poll_seconds)
      status = job.dig("job", "status")
      urls = Array(job.dig("job", "urls"))
      files = []
      if status == "success"
        urls.each_with_index do |url, index|
          files << {
            "filename" => export_filename(format, index),
            "content_type" => EXPORT_CONTENT_TYPES.fetch(format, "application/octet-stream"),
            "bytes" => client.download(url)
          }
        end
      end

      {
        "format" => format,
        "status" => status,
        "export_job_id" => export_id,
        "url_count" => urls.size,
        "files" => files,
        "error" => job_error(job)
      }.compact
    end

    def export_format_payload(format)
      case format
      when "pdf" then { type: "pdf" }
      when "pptx" then { type: "pptx" }
      when "png" then { type: "png" }
      when "jpg" then { type: "jpg", quality: 90 }
      else { type: format }
      end
    end


    def publish_export_files!(exports)
      exports.each do |export|
        next unless export["status"] == "success"

        Array(export["files"]).each do |file|
          bytes = file["bytes"].to_s.b
          next if bytes.bytesize.zero?

          filename = safe_export_filename(file["filename"], export["format"])
          published = DealReports::Publisher.publish_sidecar!(
            artifact: artifact,
            file: StringIO.new(bytes),
            filename: filename,
            content_type: file["content_type"].presence || EXPORT_CONTENT_TYPES.fetch(export["format"], "application/octet-stream"),
            file_url: export_file_url(filename)
          ).stringify_keys

          file.merge!(published).merge!("filename" => filename)
        end
      end
    end

    def safe_export_filename(filename, format)
      basename = File.basename(filename.to_s).presence || export_filename(format, 0)
      basename.gsub(/[^A-Za-z0-9._-]+/, "-")
    end

    def export_file_url(filename)
      "/deals/reports/#{artifact.id}/canva-export/#{CGI.escape(filename)}"
    end

    def build_output_package(design:, canva_job:, exports:, mode:)
      tmp = Tempfile.new(["wizwiki-canva-output-#{artifact.id}-", ".zip"])
      tmp.binmode
      tmp.close

      Zip::File.open(tmp.path, create: true) do |zip|
        add_text(zip, "README.md", output_readme(design, mode))
        add_text(zip, "manifest.json", safe_json(output_manifest(design, canva_job, exports, mode)))
        add_text(zip, "canva_design_links.md", design_links(design, mode))
        exports.each do |export|
          Array(export["files"]).each do |file|
            next if file["bytes"].to_s.bytesize.zero?

            zip.get_output_stream("exports/#{file['filename']}") { |io| io.write(file["bytes"].to_s.b) }
          end
        end
      end
      tmp.open
      tmp
    end

    def output_manifest(design, canva_job, exports, mode)
      {
        package_type: "canva_output_package",
        package_version: "2026-05-30.1",
        mode: mode,
        artifact_id: artifact.id,
        deal_id: artifact.crm_record_id,
        created_at: Time.current.iso8601,
        brand_template_id: WizwikiSettings.canva_brand_template_id,
        canva_job: canva_job.slice("id", "status", "mode"),
        design: compact_design(design),
        exports: compact_exports(exports)
      }
    end

    def output_readme(design, mode)
      warning = if mode == "docx_import"
        "\nDOCX import mode: Canva imported the WIZWIKI market analyzer report as an editable Canva design before WIZWIKI exported and packaged the result."
      end

      <<~TEXT
        # WIZWIKI Canva Output Package

        This package was created after the Canva Build Kit finished.
        #{warning}

        Included when Canva export succeeds:
        - Canva design links in `canva_design_links.md`.
        - Exported files in `exports/`.
        - Machine manifest in `manifest.json`.

        Design ID: #{design["id"]}
        Design URL: #{design["url"] || design.dig("urls", "edit_url")}
      TEXT
    end

    def design_links(design, mode)
      <<~TEXT
        # Canva Design Links

        Mode: #{mode}
        Design ID: #{design["id"]}
        Title: #{design["title"]}
        Public design URL: #{design["url"]}
        Temporary edit URL: #{design.dig("urls", "edit_url")}
        Temporary view URL: #{design.dig("urls", "view_url")}

        Note: Canva temporary edit/view URLs may expire. The exported files in this package are stored by WIZWIKI.
      TEXT
    end

    def compact_design(design)
      design.slice("id", "title", "url", "urls", "created_at", "updated_at", "page_count", "thumbnail")
    end

    def compact_exports(exports)
      exports.map do |export|
        export.merge(
          "files" => Array(export["files"]).map { |file| file.except("bytes") }
        )
      end
    end

    def add_text(zip, path, text)
      zip.get_output_stream(path) { |io| io.write(safe_text(text)) }
    end

    def canva_import_title
      safe_text("WIZWIKI report import: #{artifact.crm_record.name}", limit: 50)
    end

    def output_filename
      "canva-output-#{record_slug}-#{Time.current.strftime('%Y%m%d%H%M%S')}.zip"
    end

    def export_filename(format, index)
      suffix = index.zero? ? "" : "-page-#{index + 1}"
      "#{record_slug}#{suffix}.#{format}"
    end

def record_slug
  safe_text(artifact.crm_record.name).parameterize.presence || artifact.crm_record_id
end

def safe_json(value)
  JSON.pretty_generate(deep_safe(value))
end

def deep_safe(value)
  case value
  when Hash
    value.each_with_object({}) { |(key, item), memo| memo[safe_text(key)] = deep_safe(item) }
  when Array
    value.map { |item| deep_safe(item) }
  when String, Symbol
    safe_text(value)
  else
    value
  end
end

def safe_text(value, limit: nil)
  text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").scrub
  limit.present? ? text.first(limit) : text
end

    def parse_canva_time(value)
      return value if value.is_a?(Time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def duration_seconds(start_time, end_time)
      start_at = start_time.is_a?(Time) ? start_time : parse_canva_time(start_time)
      end_at = end_time.is_a?(Time) ? end_time : parse_canva_time(end_time)
      return unless start_at.present? && end_at.present?

      [(end_at - start_at).round, 0].max
    end

    def job_error(job)
      error = job.dig("job", "error").to_h
      [error["code"], error["message"]].compact.join(": ").presence
    end

    def mark_waiting(message, extra: {})
      update_canva_metadata({ "status" => "waiting", "message" => message, "updated_at" => Time.current.iso8601 }.merge(extra))
      { status: "waiting", message: message }
    end

    def mark_failed(message, extra: {})
      update_canva_metadata({ "status" => "failed", "message" => safe_text(message, limit: 1_000), "updated_at" => Time.current.iso8601 }.merge(extra))
      { status: "failed", message: message }
    end

    def update_canva_metadata(data)
      artifact.update!(metadata: artifact.metadata.to_h.merge("canva" => artifact.metadata.to_h.fetch("canva", {}).to_h.merge(data)))
    end
  end
end
