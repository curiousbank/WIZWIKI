require "stringio"
require "zip"
require "nokogiri"

module DealReports
  class DocxPreview
    def self.call(bytes)
      new(bytes).call
    end

    def initialize(bytes)
      @bytes = bytes.respond_to?(:read) ? bytes.read : bytes
      @bytes = @bytes.to_s.b
    end

    def call
      xml = document_xml
      return [] if xml.blank?

      document = Nokogiri::XML(xml)
      document.remove_namespaces!

      document.xpath("//body/*").filter_map do |node|
        case node.name
        when "p"
          paragraph_block(node)
        when "tbl"
          table_block(node)
        end
      end
    end

    private

    attr_reader :bytes

    def document_xml
      xml = nil
      Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
        xml = zip.read("word/document.xml") if zip.find_entry("word/document.xml")
      end
      xml
    end

    def paragraph_block(node)
      text = normalize_text(node.xpath(".//t").map(&:text).join(" "))
      return if text.blank?

      {
        type: heading?(node, text) ? "heading" : "paragraph",
        text: text
      }
    end

    def table_block(node)
      rows = node.xpath("./tr").filter_map do |row|
        cells = row.xpath("./tc").map { |cell| normalize_text(cell.xpath(".//t").map(&:text).join(" ")) }
        cells = cells.reject(&:blank?)
        cells.presence
      end

      return if rows.blank?

      {
        type: "table",
        rows: rows
      }
    end

    def heading?(node, text)
      style = node.at_xpath(".//pPr/pStyle")
      style_name = style&.attribute("val")&.value.to_s
      return true if style_name.match?(/heading|title/i)

      text.length <= 90 && text == text.upcase && text.match?(/[A-Z]/)
    end

    def normalize_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
