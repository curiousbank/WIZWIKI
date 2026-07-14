require "json"
require "net/http"
require "securerandom"
require "uri"

module GoogleWorkspace
  class DriveClient
    API_URL = "https://www.googleapis.com/drive/v3/files".freeze
    UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files".freeze

    def initialize(oauth_client: OauthClient.new)
      @oauth_client = oauth_client
    end

    def create_google_doc(name:, html:, folder_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      metadata = {
        name: name,
        mimeType: "application/vnd.google-apps.document"
      }
      metadata[:parents] = [folder_id] if folder_id.present?

      response = multipart_upload(
        metadata: metadata,
        content: html.to_s,
        content_type: "text/html; charset=UTF-8"
      )

      {
        "id" => response["id"],
        "name" => response["name"],
        "webViewLink" => response["webViewLink"],
        "mimeType" => response["mimeType"],
        "modifiedTime" => response["modifiedTime"]
      }.compact
    end

    def upsert_google_doc(name:, html:, folder_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      existing_docs = find_google_docs(name: name, folder_id: folder_id)
      existing = existing_docs.first
      result = if existing.present?
        update_google_doc(file_id: existing["id"], name: name, html: html)
      else
        create_google_doc(name: name, html: html, folder_id: folder_id)
      end

      result.merge(
        "updatedExisting" => existing.present?,
        "duplicateCount" => [existing_docs.length - 1, 0].max,
        "duplicateIds" => existing_docs.drop(1).filter_map { |doc| doc["id"] }
      ).compact
    end

    def find_google_docs(name:, folder_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      query_parts = [
        "mimeType = 'application/vnd.google-apps.document'",
        "name = '#{drive_query_escape(name)}'",
        "trashed = false"
      ]
      query_parts << "'#{drive_query_escape(folder_id)}' in parents" if folder_id.present?
      uri = URI("#{API_URL}?#{URI.encode_www_form(q: query_parts.join(' and '), fields: 'files(id,name,webViewLink,mimeType,createdTime,modifiedTime)', orderBy: 'createdTime', pageSize: '20', supportsAllDrives: 'true', includeItemsFromAllDrives: 'true')}")
      response = request_json(Net::HTTP::Get, uri)
      Array(response["files"])
    end

    def update_google_doc(file_id:, name:, html:)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      metadata = {
        name: name,
        mimeType: "application/vnd.google-apps.document"
      }

      response = multipart_update(
        file_id: file_id,
        metadata: metadata,
        content: html.to_s,
        content_type: "text/html; charset=UTF-8"
      )

      {
        "id" => response["id"],
        "name" => response["name"],
        "webViewLink" => response["webViewLink"],
        "mimeType" => response["mimeType"],
        "modifiedTime" => response["modifiedTime"]
      }.compact
    end

    def find_or_create_folder(name:, parent_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      existing = find_folder(name: name, parent_id: parent_id)
      return existing if existing.present?

      create_folder(name: name, parent_id: parent_id)
    end

    def find_folder(name:, parent_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      query_parts = [
        "mimeType = 'application/vnd.google-apps.folder'",
        "name = '#{drive_query_escape(name)}'",
        "trashed = false"
      ]
      query_parts << "'#{drive_query_escape(parent_id)}' in parents" if parent_id.present?
      uri = URI("#{API_URL}?#{URI.encode_www_form(q: query_parts.join(' and '), fields: 'files(id,name,webViewLink,mimeType)', supportsAllDrives: 'true', includeItemsFromAllDrives: 'true')}")
      response = request_json(Net::HTTP::Get, uri)
      Array(response["files"]).first
    end

    def create_folder(name:, parent_id: ENV["GOOGLE_DRIVE_FOLDER_ID"].presence)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      metadata = {
        name: name,
        mimeType: "application/vnd.google-apps.folder"
      }
      metadata[:parents] = [parent_id] if parent_id.present?
      response = request_json(
        Net::HTTP::Post,
        URI("#{API_URL}?#{URI.encode_www_form(fields: 'id,name,webViewLink,mimeType', supportsAllDrives: 'true')}"),
        body: metadata
      )
      response.slice("id", "name", "webViewLink", "mimeType")
    end

    def share_anyone(file_id:, role: "reader")
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      response = request_json(
        Net::HTTP::Post,
        URI("#{API_URL}/#{encoded_file_id(file_id)}/permissions?#{URI.encode_www_form(fields: 'id,type,role', supportsAllDrives: 'true')}"),
        body: {
          type: "anyone",
          role: role
        }
      )
      response.merge("alreadyPresent" => false)
    rescue Error => error
      raise unless error.message.include?("HTTP 409")

      { "type" => "anyone", "role" => role, "alreadyPresent" => true }
    end

    def permissions(file_id:)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      response = request_json(
        Net::HTTP::Get,
        URI("#{API_URL}/#{encoded_file_id(file_id)}/permissions?#{permissions_query}")
      )

      Array(response["permissions"])
    end

    def share_file(file_id:, email:, role: "reader", send_notification_email: false)
      raise Error, "Google Workspace OAuth is not configured" unless OauthClient.configured?

      existing = existing_permission(file_id: file_id, email: email)
      return existing.merge("alreadyPresent" => true) if existing.present?

      request_body = {
        type: "user",
        role: role,
        emailAddress: email
      }

      response = request_json(
        Net::HTTP::Post,
        URI("#{API_URL}/#{encoded_file_id(file_id)}/permissions?#{share_query(send_notification_email)}"),
        body: request_body
      )

      response.merge("alreadyPresent" => false)
    rescue Error => error
      raise unless error.message.include?("HTTP 409")

      existing = existing_permission(file_id: file_id, email: email)
      raise unless existing.present?

      existing.merge("alreadyPresent" => true)
    end

    private

    attr_reader :oauth_client

    def request_json(http_class, uri, body: nil)
      request = http_class.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{oauth_client.access_token}"
      if body
        request["Content-Type"] = "application/json; charset=UTF-8"
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 90, open_timeout: 20) do |http|
        http.request(request)
      end

      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "Google Drive request failed: #{error.class}"
    end

    def existing_permission(file_id:, email:)
      permissions(file_id: file_id).find do |permission|
        permission["emailAddress"].to_s.casecmp?(email.to_s)
      end
    end

    def encoded_file_id(file_id)
      URI.encode_www_form_component(file_id.to_s)
    end

    def drive_query_escape(value)
      value.to_s.gsub("\\", "\\\\").gsub("'", "\\'")
    end

    def permissions_query
      URI.encode_www_form(
        fields: "permissions(id,emailAddress,role,type,displayName)",
        supportsAllDrives: "true"
      )
    end

    def share_query(send_notification_email)
      URI.encode_www_form(
        fields: "id,emailAddress,role,type,displayName",
        sendNotificationEmail: send_notification_email ? "true" : "false",
        supportsAllDrives: "true"
      )
    end

    def multipart_upload(metadata:, content:, content_type:)
      boundary = "wizwiki-autos-#{SecureRandom.hex(12)}"
      uri = URI("#{UPLOAD_URL}?#{URI.encode_www_form(uploadType: 'multipart', fields: 'id,name,webViewLink,mimeType,modifiedTime', supportsAllDrives: 'true')}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{oauth_client.access_token}"
      request["Content-Type"] = "multipart/related; boundary=#{boundary}"
      request.body = multipart_body(boundary: boundary, metadata: metadata, content: content, content_type: content_type)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 90, open_timeout: 20) do |http|
        http.request(request)
      end

      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "Google Drive upload failed: #{error.class}"
    end

    def multipart_update(file_id:, metadata:, content:, content_type:)
      boundary = "wizwiki-autos-#{SecureRandom.hex(12)}"
      uri = URI("#{UPLOAD_URL}/#{encoded_file_id(file_id)}?#{URI.encode_www_form(uploadType: 'multipart', fields: 'id,name,webViewLink,mimeType,modifiedTime', supportsAllDrives: 'true')}")
      request = Net::HTTP::Patch.new(uri)
      request["Authorization"] = "Bearer #{oauth_client.access_token}"
      request["Content-Type"] = "multipart/related; boundary=#{boundary}"
      request.body = multipart_body(boundary: boundary, metadata: metadata, content: content, content_type: content_type)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 90, open_timeout: 20) do |http|
        http.request(request)
      end

      parse_response(response)
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "Google Drive update failed: #{error.class}"
    end

    def multipart_body(boundary:, metadata:, content:, content_type:)
      [
        "--#{boundary}",
        "Content-Type: application/json; charset=UTF-8",
        "",
        JSON.generate(metadata),
        "--#{boundary}",
        "Content-Type: #{content_type}",
        "",
        content,
        "--#{boundary}--",
        ""
      ].join("\r\n")
    end

    def parse_response(response)
      body = response.body.to_s
      case response
      when Net::HTTPSuccess
        body.blank? ? {} : JSON.parse(body)
      else
        raise Error, "Google Drive HTTP #{response.code}: #{body.squish.truncate(260)}"
      end
    rescue JSON::ParserError => error
      raise Error, "Google Drive response was not valid JSON: #{error.message}"
    end
  end
end
