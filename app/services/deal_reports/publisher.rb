require "fileutils"
require "open3"
require "tempfile"

module DealReports
  class Publisher
    RCLONE_BIN = ENV.fetch("RCLONE_BIN", "rclone").freeze

    def self.publish!(artifact:, file:, filename:, content_type:, manifest: {})
      new(artifact:, file:, filename:, content_type:, manifest:).publish!
    end

    def self.download_bytes!(artifact)
      new(artifact:, file: nil, filename: nil, content_type: artifact.content_type).download_bytes!
    end

    def self.publish_sidecar!(artifact:, file:, filename:, content_type:, file_url:)
      new(artifact:, file:, filename:, content_type: content_type).publish_sidecar!(file_url: file_url)
    end

    def self.download_key_bytes!(artifact:, storage_key:)
      new(artifact:, file: nil, filename: nil, content_type: artifact.content_type).download_key_bytes!(storage_key)
    end

    def self.delete_keys!(artifact:, keys:)
      new(artifact:, file: nil, filename: nil, content_type: artifact.content_type).delete_keys!(keys)
    end

    def initialize(artifact:, file:, filename:, content_type:, manifest: {})
      @artifact = artifact
      @file = file
      @filename = filename.to_s.presence || default_filename
      @content_type = content_type.to_s.presence || "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      @manifest = manifest.to_h
    end

    def publish!
      raise ArgumentError, "report file is required" if file.blank?

      with_temp_file do |tmp|
        copy_file_to_temp(file, tmp)
        key = storage_key_for(filename)

        if rclone_configured?
          upload_with_rclone!(tmp.path, key)
          build_result(
            storage_provider: "backblaze",
            storage_bucket: WizwikiSettings.backblaze_bucket,
            storage_key: key,
            byte_size: File.size(tmp.path),
            file_url: public_file_url_for(key, fallback: download_path)
          )
        else
          local_path = Rails.root.join("storage", "deal_reports", key)
          FileUtils.mkdir_p(local_path.dirname)
          FileUtils.cp(tmp.path, local_path)
          build_result(storage_provider: "local", storage_bucket: nil, storage_key: key, byte_size: File.size(local_path))
        end
      end
    end

    def publish_sidecar!(file_url:)
      raise ArgumentError, "sidecar file is required" if file.blank?

      with_temp_file do |tmp|
        copy_file_to_temp(file, tmp)
        key = storage_key_for(filename)

        if rclone_configured?
          upload_with_rclone!(tmp.path, key)
          build_result(
            storage_provider: "backblaze",
            storage_bucket: WizwikiSettings.backblaze_bucket,
            storage_key: key,
            byte_size: File.size(tmp.path),
            file_url: public_file_url_for(key, fallback: file_url)
          )
        else
          local_path = Rails.root.join("storage", "deal_reports", key)
          FileUtils.mkdir_p(local_path.dirname)
          FileUtils.cp(tmp.path, local_path)
          build_result(storage_provider: "local", storage_bucket: nil, storage_key: key, byte_size: File.size(local_path), file_url: file_url)
        end
      end
    end

    def download_bytes!
      raise ArgumentError, "artifact has no storage key" if artifact.storage_key.blank?

      download_key_bytes!(artifact.storage_key)
    end

    def download_key_bytes!(key)
      key = key.to_s.strip
      raise ArgumentError, "storage key is required" if key.blank?

      if artifact.storage_provider == "backblaze" && rclone_configured?
        stdout, stderr, status = Open3.capture3(rclone_bin, "cat", remote_path(key))
        raise "rclone cat failed: #{stderr.to_s.first(300)}" unless status.success?

        stdout
      else
        local_path = Rails.root.join("storage", "deal_reports", key)
        File.binread(local_path)
      end
    end

    def delete_keys!(keys)
      Array(keys).map(&:to_s).map(&:strip).reject(&:blank?).uniq.each do |key|
        if artifact.storage_provider == "backblaze" && rclone_configured?
          stdout, stderr, status = Open3.capture3(rclone_bin, "deletefile", remote_path(key))
          Rails.logger.warn("[DealReports::Publisher] rclone delete failed for #{key}: #{stderr.presence || stdout}") unless status.success?
        else
          local_root = Rails.root.join("storage", "deal_reports").expand_path
          local_path = local_root.join(key).expand_path
          unless local_path.to_s.start_with?(local_root.to_s)
            Rails.logger.warn("[DealReports::Publisher] refused local delete outside deal_reports: #{key}")
            next
          end

          FileUtils.rm_f(local_path)
        end
      rescue StandardError => error
        Rails.logger.warn("[DealReports::Publisher] delete failed for #{key}: #{error.class}: #{error.message}")
      end
    end

    private

    attr_reader :artifact, :file, :filename, :content_type, :manifest

    def default_filename
      "#{artifact.artifact_type}-#{artifact.crm_record.name}-#{Time.current.strftime("%Y%m%d%H%M%S")}.docx"
    end

    def with_temp_file
      ext = File.extname(filename).presence || ".docx"
      tmp = Tempfile.new(["wizwiki-report-#{artifact.id}-", ext])
      tmp.binmode
      yield tmp
    ensure
      tmp&.close!
    end

    def copy_file_to_temp(source, tmp)
      if source.respond_to?(:read)
        source.rewind if source.respond_to?(:rewind)
        IO.copy_stream(source, tmp)
      else
        tmp.write(source.to_s.b)
      end
      tmp.flush
    end

    def storage_key_for(name)
      DealReports::StorageKey.call(
        crm_record: artifact.crm_record,
        artifact_type: artifact.artifact_type,
        filename: name,
        extension: File.extname(name).delete(".").presence || "docx"
      )
    end

    def build_result(storage_provider:, storage_bucket:, storage_key:, byte_size:, file_url: nil)
      {
        storage_provider: storage_provider,
        storage_bucket: storage_bucket,
        storage_key: storage_key,
        file_url: file_url.presence || download_path,
        content_type: content_type,
        byte_size: byte_size
      }
    end

    def download_path
      "/leads/reports/#{artifact.id}/download"
    end

    def rclone_configured?
      WizwikiSettings.backblaze_rclone_remote.present? && WizwikiSettings.backblaze_bucket.present? && File.executable?(rclone_bin)
    end

    def upload_with_rclone!(path, key)
      stdout, stderr, status = Open3.capture3(rclone_bin, "copyto", path, remote_path(key), "--checksum")
      raise "rclone upload failed: #{stderr.presence || stdout}" unless status.success?
    end

    def public_file_url_for(key, fallback:)
      rclone_public_link(key).presence || configured_public_url(key).presence || fallback
    end

    def rclone_public_link(key)
      stdout, stderr, status = Open3.capture3(rclone_bin, "link", remote_path(key))
      return stdout.to_s.lines.first.to_s.strip if status.success? && stdout.to_s.strip.present?

      Rails.logger.warn("[DealReports::Publisher] rclone link failed for #{key}: #{stderr.to_s.first(240)}") if stderr.present?
      nil
    rescue StandardError => e
      Rails.logger.warn("[DealReports::Publisher] rclone link failed for #{key}: #{e.class}: #{e.message}")
      nil
    end

    def configured_public_url(key)
      base = WizwikiSettings.backblaze_public_base_url.to_s.strip
      return nil if base.blank?

      "#{base.sub(%r{/+\z}, "")}/#{key.to_s.sub(%r{\A/+}, "")}"
    end

    def remote_path(key)
      remote = WizwikiSettings.backblaze_rclone_remote.to_s.sub(/:+\z/, "")
      bucket = WizwikiSettings.backblaze_bucket.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      "#{remote}:#{bucket}/#{key}"
    end

    def rclone_bin
      ENV["RCLONE_BIN"].presence || RCLONE_BIN
    end
  end
end
