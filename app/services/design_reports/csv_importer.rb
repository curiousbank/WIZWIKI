require "csv"
require "digest"

module DesignReports
  class CsvImporter
    MAX_BYTES = 2.megabytes
    REQUIRED_HEADERS = ["Item Name", "Order #", "Customer Email"].freeze
    HEADER_ALIASES = {
      item_name: ["Item Name", "Item", "Design", "Design Name"],
      designer_name: ["Designer", "Assigned Designer"],
      product_name: ["Product", "Product Name"],
      biz_days_in_stage: ["Biz Days in Stage", "Business Days in Stage", "Days in Stage"],
      biz_days_overall: ["Biz Days Overall", "Business Days Overall", "Days in Queue", "Days In Queue", "Days In", "Days in"],
      revisions: ["Revisions", "Revision Count"],
      customer_email: ["Customer Email", "Email"],
      order_number: ["Order #", "Order Number", "Order"],
      start_date: ["Start Date", "Created Date"],
      monday_url: ["Monday Link", "Monday URL", "Board Link"]
    }.freeze

    Result = Data.define(:report, :created_count, :updated_count, :completed_count, :skipped_count)

    def self.call(organization:, user:, file:, title: nil)
      new(organization:, user:, file:, title:).call
    end

    def initialize(organization:, user:, file:, title: nil)
      @organization = organization
      @user = user
      @file = file
      @title = clean_string(title).presence
    end

    def call
      validate_file!
      raw = read_file
      csv = CSV.parse(raw, headers: true)
      headers = csv.headers.compact.map { |header| clean_string(header) }.reject(&:blank?)
      validate_headers!(headers)

      created_count = 0
      updated_count = 0
      completed_count = 0
      skipped_count = 0
      imported_source_uids = []
      report = nil

      ActiveRecord::Base.transaction do
        report = organization.design_reports.create!(
          user: user,
          title: title || default_title,
          file_name: sanitized_filename(original_filename),
          content_type: content_type,
          byte_size: raw.bytesize,
          row_count: csv.length,
          headers: headers,
          status: "imported"
        )

        csv.each.with_index(1) do |row, row_number|
          payload = clean_payload(row.to_h)
          attrs = attributes_for(payload, row_number)

          if attrs[:item_name].blank? && attrs[:order_number].blank?
            skipped_count += 1
            next
          end

          imported_source_uids << attrs[:source_uid]
          design_order = organization.design_orders.find_or_initialize_by(source_uid: attrs[:source_uid])
          created = design_order.new_record?
          design_order.assign_attributes(attrs.merge(design_report: report, user: user))
          design_order.save!
          created ? created_count += 1 : updated_count += 1
        end

        completed_count = complete_missing_queue_orders(imported_source_uids)

        report.update!(metadata: {
          "created_count" => created_count,
          "updated_count" => updated_count,
          "completed_count" => completed_count,
          "skipped_count" => skipped_count
        })
      end

      Result.new(report:, created_count:, updated_count:, completed_count:, skipped_count:)
    end

    private

    attr_reader :organization, :user, :file, :title

    def validate_file!
      raise ArgumentError, "Choose a CSV file to import." if file.blank?
      raise ArgumentError, "Design report is too large. Keep CSV uploads under #{MAX_BYTES / 1.megabyte} MB." if file_size > MAX_BYTES
      raise ArgumentError, "Design report must be a .csv file." unless csv_file?
    end

    def read_file
      file.rewind if file.respond_to?(:rewind)
      clean_csv_text(file.read(MAX_BYTES + 1))
    ensure
      file.rewind if file.respond_to?(:rewind)
    end

    def validate_headers!(headers)
      missing = REQUIRED_HEADERS.reject { |header| headers.include?(header) }
      return if missing.blank?

      raise ArgumentError, "CSV missing required column#{'s' if missing.length > 1}: #{missing.join(', ')}."
    end

    def attributes_for(payload, row_number)
      item_name = value_for(payload, :item_name)
      order_number = value_for(payload, :order_number)
      monday_url = value_for(payload, :monday_url)
      start_date = date_for(value_for(payload, :start_date))
      inferred_days_in_queue = business_days_since(start_date)
      biz_days_in_stage = integer_for(value_for(payload, :biz_days_in_stage))
      biz_days_overall = integer_for(value_for(payload, :biz_days_overall))

      {
        source_uid: source_uid_for(item_name:, order_number:, monday_url:),
        item_name: item_name,
        designer_name: value_for(payload, :designer_name),
        product_name: value_for(payload, :product_name),
        biz_days_in_stage: biz_days_in_stage.nil? ? inferred_days_in_queue : biz_days_in_stage,
        biz_days_overall: biz_days_overall.nil? ? inferred_days_in_queue : biz_days_overall,
        revisions: integer_for(value_for(payload, :revisions)).to_i,
        customer_email: value_for(payload, :customer_email),
        order_number: order_number,
        start_date: start_date,
        monday_url: monday_url,
        stage: "design",
        status: nil,
        row_number: row_number,
        raw_payload: payload
      }
    end

    def complete_missing_queue_orders(imported_source_uids)
      return 0 if imported_source_uids.blank?

      organization.design_orders
        .queued
        .where.not(source_uid: imported_source_uids.uniq)
        .update_all(status: DesignOrder::COMPLETE_STATUS, updated_at: Time.current)
    end

    def clean_payload(payload)
      payload.to_h.each_with_object({}) do |(key, value), memo|
        clean_key = clean_string(key)
        next if clean_key.blank?

        memo[clean_key] = value.is_a?(String) ? clean_string(value) : value
      end
    end

    def value_for(payload, attribute)
      HEADER_ALIASES.fetch(attribute).lazy.map { |header| payload[header].presence }.find(&:present?)
    end

    def source_uid_for(item_name:, order_number:, monday_url:)
      Digest::SHA256.hexdigest([organization.id, order_number, item_name, monday_url].join("|"))
    end

    def integer_for(value)
      value.to_s.gsub(/[^0-9-]/, "").presence&.to_i
    end

    def date_for(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def business_days_since(start_date)
      return if start_date.blank?

      today = Time.zone.today
      return 0 if start_date >= today

      (start_date.next_day..today).count { |date| !date.saturday? && !date.sunday? }
    end

    def clean_csv_text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def clean_string(value)
      clean_csv_text(value).squish
    end

    def csv_file?
      File.extname(original_filename).downcase == ".csv" || content_type.in?(%w[text/csv application/csv application/vnd.ms-excel text/plain])
    end

    def file_size
      file.respond_to?(:size) ? file.size.to_i : 0
    end

    def original_filename
      file.respond_to?(:original_filename) ? file.original_filename.to_s : "design_report.csv"
    end

    def content_type
      file.respond_to?(:content_type) ? file.content_type.to_s : "text/csv"
    end

    def sanitized_filename(filename)
      File.basename(filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").first(120)
    end

    def default_title
      "Design report #{Time.current.strftime('%Y-%m-%d %H:%M')}"
    end
  end
end
