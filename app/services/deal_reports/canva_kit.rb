require "base64"
require "cgi"
require "json"
require "open3"
require "tempfile"
require "zip"

module DealReports
  class CanvaKit
    CONTENT_TYPE = "application/zip".freeze
    Result = Struct.new(:file, :filename, :content_type, :manifest, keyword_init: true)

    def self.build!(artifact:, report_file:, report_filename:, manifest:, published:)
      new(artifact:, report_file:, report_filename:, manifest:, published:).build!
    end

    def initialize(artifact:, report_file:, report_filename:, manifest:, published:)
      @artifact = artifact
      @report_file = report_file
      @report_filename = report_filename.to_s.presence || "market_strategy_report.docx"
      @manifest = manifest.to_h
      @published = published.to_h
    end

    def build!
      tmp = Tempfile.new(["wizwiki-canva-kit-#{artifact.id}-", ".zip"])
      tmp.binmode
      tmp.close

      Zip::File.open(tmp.path, create: true) do |zip|
        add_report_docx(zip)
        add_text(zip, "README.md", readme)
        add_text(zip, "manifest.json", JSON.pretty_generate(kit_manifest))
        add_text(zip, "design_spec.json", JSON.pretty_generate(design_spec))
        add_text(zip, "wizwiki_style_system.md", style_system_readme)
        add_text(zip, "canva_page_plan.md", canva_page_plan)
        add_text(zip, "canva_copy_blocks.md", canva_copy_blocks)
        add_text(zip, "creative_briefs/postcard.md", creative_brief("Postcard"))
        add_text(zip, "creative_briefs/yard_sign.md", creative_brief("Yard Sign"))
        add_text(zip, "creative_briefs/door_hanger.md", creative_brief("Door Hanger"))
        add_text(zip, "assets/README.md", assets_readme)
        add_text(zip, "source/report_manifest.json", JSON.pretty_generate(source_manifest))
        if design_press_enabled?
          add_text(zip, "design_press/README.md", design_press_readme)
          design_press_preview_files.each do |file|
            add_binary(zip, file.fetch(:path), file.fetch(:data))
          end
          if (file = openai_design_press_preview_file)
            add_binary(zip, file.fetch(:path), file.fetch(:data))
          end
          if (file = openai_design_press_prompt_file)
            add_text(zip, file.fetch(:path), file.fetch(:text))
          end
        end
      end

      tmp.open
      Result.new(file: tmp, filename: filename, content_type: CONTENT_TYPE, manifest: kit_manifest)
    rescue StandardError
      tmp&.close!
      raise
    end

    private

    attr_reader :artifact, :report_file, :report_filename, :manifest, :published

    def add_report_docx(zip)
      report_file.rewind if report_file.respond_to?(:rewind)
      data = report_file.respond_to?(:read) ? report_file.read : report_file.to_s.b
      report_file.rewind if report_file.respond_to?(:rewind)
      add_binary(zip, "01_report/#{safe_filename(report_filename, fallback: 'market_strategy_report.docx')}", data)
    end

    def add_text(zip, path, text)
      zip.get_output_stream(path) { |io| io.write(text.to_s) }
    end

    def add_binary(zip, path, data)
      zip.get_output_stream(path) { |io| io.write(data.to_s.b) }
    end

    def filename
      "canva-build-kit-#{artifact.crm_record.name.to_s.parameterize.presence || artifact.crm_record_id}-#{Time.current.strftime('%Y%m%d%H%M%S')}.zip"
    end

    def safe_filename(value, fallback:)
      name = File.basename(value.to_s).presence || fallback
      name.gsub(/[^A-Za-z0-9._-]+/, "-")
    end

    def kit_manifest
      @kit_manifest ||= {
        kit_type: "canva_build_kit",
        kit_version: "2026-06-02.bold-market-report.1",
        artifact_id: artifact.id,
        deal_id: artifact.crm_record_id,
        deal_name: artifact.crm_record.name,
        company_name: artifact.metadata.to_h["company_name"],
        created_at: Time.current.iso8601,
        report_document: {
          filename: report_filename,
          storage_key: published["storage_key"] || published[:storage_key],
          file_url: published["file_url"] || published[:file_url],
          byte_size: published["byte_size"] || published[:byte_size]
        },
        design_system: {
          theme: design_spec.fetch(:theme),
          palette: design_spec.fetch(:color_palette),
          font_roles: design_spec.fetch(:font_roles),
          page_count: design_spec.fetch(:pages).size
        },
        canva_handoff: {
          ready_for_human_designer: true,
          actual_canva_template_created: false,
          note: "This zip is the Canva Build Kit. It contains the report, WIZWIKI Bold Market Report design spec, copy blocks, page plan, creative briefs, manifest, and asset instructions. It is not a Canva design URL yet."
        },
        design_press: design_press_manifest,
        included_files: included_files,
        quality: {
          docx_signature: manifest.dig("quality", "docx_signature") || manifest["docx_signature"],
          word_count: manifest.dig("quality", "word_count") || manifest["word_count"],
          validation_passed: manifest.dig("quality", "validation_passed")
        }
      }
    end

    def included_files
      files = [
        "01_report/#{safe_filename(report_filename, fallback: 'market_strategy_report.docx')}",
        "README.md",
        "manifest.json",
        "design_spec.json",
        "wizwiki_style_system.md",
        "canva_page_plan.md",
        "canva_copy_blocks.md",
        "creative_briefs/postcard.md",
        "creative_briefs/yard_sign.md",
        "creative_briefs/door_hanger.md",
        "assets/README.md",
        "source/report_manifest.json"
      ]
      if design_press_enabled?
        files << "design_press/README.md"
        files.concat(design_press_preview_files.map { |file| file.fetch(:path) })
        files << openai_design_press_preview_file.fetch(:path) if openai_design_press_preview_file
        files << openai_design_press_prompt_file.fetch(:path) if openai_design_press_prompt_file
      end
      files
    end

    def source_manifest
      @source_manifest ||= begin
        payload = JSON.parse(JSON.generate(manifest))
        preview = payload.dig("design_press", "openai_preview")
        if preview.is_a?(Hash)
          preview.delete("image_base64")
          preview.delete("b64_json")
        end
        payload
      end
    end

    def design_spec
      @design_spec ||= DealReports::MarketStrategyContract.design_spec(
        DealReports::MarketStrategyContract.report_audience(artifact)
      )
    end

    def style_system
      @style_system ||= DealReports::MarketStrategyContract.report_style_system
    end

    def style_system_readme
      palette = style_system.fetch(:color_palette)
      <<~TEXT
        # WIZWIKI Bold Market Report Style System

        Visual direction:
        Bold, clean, confident, high-contrast, black/white/red/charcoal, sales-ready, print-friendly.

        Core palette:
        - WIZWIKI red: #{palette.fetch(:wizwiki_red)}
        - Black: #{palette.fetch(:black)}
        - Charcoal: #{palette.fetch(:charcoal)}
        - Dark gray: #{palette.fetch(:dark_gray)}
        - Light gray: #{palette.fetch(:light_gray)}
        - White: #{palette.fetch(:white)}

        Font roles:
        - Cover title: bold condensed sans serif.
        - Page title: heavy modern sans serif.
        - Section heading: bold modern sans serif.
        - Body: clean readable sans serif.
        - Table: compact readable sans serif.
        - Callout: bold sans serif.

        Approved components:
        #{style_system.fetch(:approved_components).map { |component| "- #{component}" }.join("\n")}

        Page density rules:
        #{style_system.fetch(:page_density_rules).map { |rule| "- #{rule}" }.join("\n")}

        Avoid:
        - Plain essay layout.
        - Tiny text.
        - Long walls of copy.
        - Generic corporate blue.
        - Low contrast text.
        - Unsupported exact statistics.
      TEXT
    end

    def readme
      <<~TEXT
        # WIZWIKI Marketing Canva Build Kit

        This package keeps the deal in the Processing Bay until the full handoff exists.

        Included:
        - Editable DOCX report in `01_report/`.
        - WIZWIKI Bold Market Report design spec in `design_spec.json`.
        - WIZWIKI red/black style-system handoff in `wizwiki_style_system.md`.
        - Canva page plan.
        - Canva copy blocks.
        - Creative briefs for postcard, yard sign, and door hanger.
        - Source manifest and asset instructions.
        #{design_press_enabled? ? "- Design Press proof image in `design_press/`." : nil}

        Current state:
        - This is not an actual Canva template URL yet.
        - Human designer or future Canva automation should use this kit to build the print-ready PDF and editable Canva design.
      TEXT
    end

    def design_press_enabled?
      truthy_value?(manifest.dig("design_press", "enabled")) ||
        truthy_value?(manifest.dig("pipeline", "design_press_enabled")) ||
        truthy_value?(artifact.metadata.to_h["report_design_press_enabled"])
    end

    def design_press_settings
      press = manifest.fetch("design_press", {}).to_h
      metadata = artifact.metadata.to_h
      {
        template: press["template"].presence || metadata["report_design_press_template"].presence || "market_one_sheet",
        style: press["style"].presence || metadata["report_design_press_style"].presence || "wizwiki_clean",
        output: press["output"].presence || metadata["report_design_press_output"].presence || "print_png_pdf",
        renderer: press["renderer"].presence || metadata["report_design_press_renderer"].presence || "alice-design-press",
        notes: press["notes"].presence || metadata["report_design_press_notes"].presence,
        canvas: press["canvas"].presence || "8.5x11 portrait"
      }
    end

    def design_press_manifest
      settings = design_press_settings
      local_preview = design_press_enabled? ? design_press_preview_files : []
      openai_preview_file = openai_design_press_preview_file
      preview_files = local_preview.map { |file| file.slice(:path, :content_type, :byte_size) }
      preview_files << openai_preview_file.slice(:path, :content_type, :byte_size) if openai_preview_file
      {
        enabled: design_press_enabled?,
        template: settings[:template],
        style: settings[:style],
        output: settings[:output],
        renderer: settings[:renderer],
        canvas: settings[:canvas],
        notes: settings[:notes],
        preview_files: preview_files,
        openai_preview: sanitized_openai_design_press_preview,
        note: design_press_enabled? ? "Design Press generated proof assets inside this kit. Use them as boss-review visuals, not final print approval." : "Design Press was not requested for this report."
      }
    end

    def openai_design_press_preview
      manifest.fetch("design_press", {}).to_h.fetch("openai_preview", {}).to_h
    end

    def openai_design_press_preview_file
      return nil unless design_press_enabled?

      @openai_design_press_preview_file ||= begin
        preview = openai_design_press_preview
        encoded = preview["image_base64"].presence || preview["b64_json"].presence
        if encoded.blank?
          nil
        else
          data = Base64.decode64(encoded.to_s)
          if data.blank?
            nil
          else
            {
              path: safe_zip_path(preview["path"], fallback: "design_press/openai-press-sheet.jpg"),
              content_type: preview["content_type"].presence || "image/jpeg",
              data: data,
              byte_size: data.bytesize
            }
          end
        end
      rescue ArgumentError => error
        Rails.logger.warn("[DealReports::CanvaKit] OpenAI Design Press image decode failed artifact=#{artifact.id}: #{error.message}")
        nil
      end
    end

    def openai_design_press_prompt_file
      return nil unless design_press_enabled?

      @openai_design_press_prompt_file ||= begin
        preview = openai_design_press_preview
        prompt = preview["prompt"].to_s.strip
        if prompt.blank?
          nil
        else
          {
            path: safe_zip_path(preview["prompt_path"], fallback: "design_press/openai-prompt.txt"),
            text: prompt
          }
        end
      end
    end

    def sanitized_openai_design_press_preview
      preview = openai_design_press_preview
      return nil if preview.blank?

      sanitized = preview.except("image_base64", "b64_json", "prompt")
      if (file = openai_design_press_preview_file)
        sanitized["path"] = file.fetch(:path)
        sanitized["content_type"] = file.fetch(:content_type)
        sanitized["byte_size"] = file.fetch(:byte_size)
      end
      if (file = openai_design_press_prompt_file)
        sanitized["prompt_path"] = file.fetch(:path)
      end
      sanitized
    end

    def safe_zip_path(value, fallback:)
      path = value.to_s.tr("\\", "/").strip.presence || fallback
      parts = path.split("/").reject { |part| part.blank? || part == "." || part == ".." }
      parts.join("/").presence || fallback
    end

    def design_press_preview_files
      return [] unless design_press_enabled?

      @design_press_preview_files ||= begin
        svg = design_press_svg
        files = [
          { path: "design_press/press-sheet.svg", content_type: "image/svg+xml", data: svg }
        ]
        if (jpeg = convert_svg_to_jpeg(svg))
          files.unshift({ path: "design_press/press-sheet.jpg", content_type: "image/jpeg", data: jpeg })
        end
        files.each { |file| file[:byte_size] = file.fetch(:data).bytesize }
      end
    end

    def convert_svg_to_jpeg(svg)
      return unless system_convert_path.present?

      Tempfile.create(["wizwiki-design-press-#{artifact.id}-", ".svg"]) do |svg_file|
        Tempfile.create(["wizwiki-design-press-#{artifact.id}-", ".jpg"]) do |jpg_file|
          svg_file.binmode
          svg_file.write(svg)
          svg_file.flush
          stdout, stderr, status = Open3.capture3(system_convert_path, "-background", "white", "-alpha", "remove", "-quality", "92", svg_file.path, jpg_file.path)
          Rails.logger.warn("[DealReports::CanvaKit] Design Press JPEG failed artifact=#{artifact.id}: #{stderr.presence || stdout}") unless status.success?
          return File.binread(jpg_file.path) if status.success? && File.size?(jpg_file.path)
        end
      end
      nil
    rescue StandardError => error
      Rails.logger.warn("[DealReports::CanvaKit] Design Press JPEG error artifact=#{artifact.id}: #{error.class}: #{error.message}")
      nil
    end

    def system_convert_path
      @system_convert_path ||= [ENV["IMAGEMAGICK_CONVERT"], "/usr/bin/convert", "/usr/local/bin/convert", "/opt/homebrew/bin/convert"].find { |path| path.present? && File.executable?(path) }
    end

    def design_press_svg
      settings = design_press_settings
      palette = style_system.fetch(:color_palette)
      title = plain_text(manifest["report_title"].presence || artifact.title)
      company = plain_text(artifact.metadata.to_h["company_name"].presence || artifact.crm_record.name)
      industry = plain_text(artifact.metadata.to_h["industry"].presence || "Local service business")
      service_area = plain_text(artifact.metadata.to_h["service_area"].presence || artifact.metadata.to_h["city"].presence || "Local market")
      date = Time.current.strftime("%B %-d, %Y")
      summary_lines = wrapped_lines(manifest["summary"].presence || "A focused neighborhood campaign built around clear timing, simple offers, and measurable local response.", max_chars: 58, max_lines: 7)
      sections = Array(manifest["sections"]).first(6).map { |section| plain_text(section) }.reject(&:blank?)
      sections = ["Market Snapshot", "Seasonality", "Recommended Campaign", "Channel Strategy", "Timeline", "Final Recommendation"] if sections.blank?
      notes = wrapped_lines(settings[:notes].presence || "No-Canva proof sheet generated from validated report copy and WIZWIKI style rules.", max_chars: 48, max_lines: 3)
      red = palette[:wizwiki_red] || "#E10600"
      black = palette[:black] || "#0B0B0B"
      charcoal = palette[:charcoal] || "#1A1A1A"
      light = palette[:light_gray] || "#F2F2F2"

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="2550" height="3300" viewBox="0 0 2550 3300">
          <rect width="2550" height="3300" fill="#{e(light)}"/>
          <rect x="0" y="0" width="2550" height="540" fill="#{e(black)}"/>
          <rect x="0" y="540" width="2550" height="34" fill="#{e(red)}"/>
          <rect x="144" y="132" width="2262" height="276" fill="none" stroke="#{e(red)}" stroke-width="8"/>
          <text x="176" y="222" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="58" font-weight="900" letter-spacing="8">WIZWIKI MARKETING</text>
          <text x="176" y="315" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="86" font-weight="900">#{e(title.first(62))}</text>
          <text x="176" y="390" fill="#D7D7D7" font-family="Helvetica, Arial, sans-serif" font-size="34" font-weight="700">#{e(company)} // #{e(industry)} // #{e(service_area)}</text>
          <text x="176" y="455" fill="#FFFFFF" font-family="Helvetica, Arial, sans-serif" font-size="28" font-weight="700">DESIGN PRESS PROOF // #{e(settings[:template].to_s.upcase)} // #{e(settings[:style].to_s.upcase)} // #{e(date)}</text>

          <rect x="144" y="690" width="1010" height="1020" rx="0" fill="#FFFFFF" stroke="#1A1A1A" stroke-width="4"/>
          <rect x="144" y="690" width="1010" height="96" fill="#{e(red)}"/>
          <text x="190" y="755" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="36" font-weight="900">THE BEST PLAY</text>
          #{svg_lines(summary_lines, x: 190, y: 870, size: 42, fill: charcoal, weight: 700, line_height: 62)}

          <rect x="1240" y="690" width="1166" height="1020" rx="0" fill="#{e(charcoal)}"/>
          <text x="1290" y="780" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="44" font-weight="900">REPORT MAP</text>
          #{svg_numbered_list(sections, x: 1290, y: 890, red: red)}

          <rect x="144" y="1840" width="2262" height="750" rx="0" fill="#FFFFFF" stroke="#1A1A1A" stroke-width="4"/>
          <rect x="144" y="1840" width="2262" height="110" fill="#{e(black)}"/>
          <text x="190" y="1912" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="42" font-weight="900">PRESS DIRECTION</text>
          <rect x="190" y="2030" width="660" height="420" fill="#{e(red)}"/>
          <text x="238" y="2132" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="56" font-weight="900">8.5x11</text>
          <text x="238" y="2210" fill="#FFFFFF" font-family="Helvetica, Arial, sans-serif" font-size="34" font-weight="800">PRINT PROOF</text>
          <text x="238" y="2286" fill="#FFFFFF" font-family="Helvetica, Arial, sans-serif" font-size="28" font-weight="700">PNG/PDF path ready</text>
          <text x="930" y="2078" fill="#1A1A1A" font-family="Arial Black, Helvetica, sans-serif" font-size="38" font-weight="900">Design note</text>
          #{svg_lines(notes, x: 930, y: 2160, size: 36, fill: charcoal, weight: 700, line_height: 56)}
          <text x="930" y="2405" fill="#555555" font-family="Helvetica, Arial, sans-serif" font-size="28" font-weight="700">This preview is generated from validated report copy. Final print approval still belongs to the AM/designer.</text>

          <rect x="144" y="2788" width="2262" height="256" fill="#{e(black)}"/>
          <text x="190" y="2870" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="40" font-weight="900">NO-CANVA DESIGN PRESS</text>
          <text x="190" y="2945" fill="#D7D7D7" font-family="Helvetica, Arial, sans-serif" font-size="30" font-weight="700">A local proof sheet for boss review, client direction, and future OpenAI visual polish.</text>
          <text x="190" y="3015" fill="#FFFFFF" font-family="Helvetica, Arial, sans-serif" font-size="28" font-weight="700">Artifact ##{artifact.id} // #{e(settings[:output])} // renderer #{e(settings[:renderer])}</text>
        </svg>
      SVG
    end

    def svg_lines(lines, x:, y:, size:, fill:, weight:, line_height:)
      lines.each_with_index.map do |line, index|
        %(<text x="#{x}" y="#{y + (index * line_height)}" fill="#{e(fill)}" font-family="Helvetica, Arial, sans-serif" font-size="#{size}" font-weight="#{weight}">#{e(line)}</text>)
      end.join("\n")
    end

    def svg_numbered_list(items, x:, y:, red:)
      items.each_with_index.map do |item, index|
        top = y + (index * 122)
        <<~SVG
          <circle cx="#{x + 28}" cy="#{top - 13}" r="34" fill="#{e(red)}"/>
          <text x="#{x + 18}" y="#{top}" fill="#FFFFFF" font-family="Arial Black, Helvetica, sans-serif" font-size="30" font-weight="900">#{index + 1}</text>
          <text x="#{x + 92}" y="#{top}" fill="#FFFFFF" font-family="Helvetica, Arial, sans-serif" font-size="36" font-weight="800">#{e(item.first(42))}</text>
        SVG
      end.join("\n")
    end

    def wrapped_lines(value, max_chars:, max_lines:)
      words = plain_text(value).split(/\s+/)
      lines = []
      current = +""
      words.each do |word|
        candidate = current.blank? ? word : "#{current} #{word}"
        if candidate.length > max_chars && current.present?
          lines << current
          current = word
          break if lines.size >= max_lines
        else
          current = candidate
        end
      end
      lines << current if current.present? && lines.size < max_lines
      lines.presence || ["Design Press proof generated from report copy."]
    end

    def plain_text(value)
      value.to_s
        .gsub(/[#*_`>|]/, " ")
        .gsub(/\s+/, " ")
        .strip
    end

    def truthy_value?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end

    def e(value)
      CGI.escapeHTML(value.to_s)
    end

    def design_press_readme
      settings = design_press_settings
      <<~TEXT
        # Design Press

        This folder is the first no-Canva visual proof.

        Files:
        - `press-sheet.jpg`: 8.5x11 proof image generated from validated report copy.
        - `press-sheet.svg`: editable vector source for the proof.
        #{openai_design_press_preview_file ? "- `#{openai_design_press_preview_file.fetch(:path)}`: OpenAI Design Press visual pass generated after report validation." : nil}
        #{openai_design_press_prompt_file ? "- `#{openai_design_press_prompt_file.fetch(:path)}`: Prompt used for the OpenAI visual pass." : nil}

        Settings:
        - Template: #{settings[:template]}
        - Style: #{settings[:style]}
        - Output: #{settings[:output]}
        - Renderer: #{settings[:renderer]}

        Note:
        This is a proof sheet, not final print approval. The next stage can use the same manifest to create a higher-polish PDF or optional OpenAI visual pass.
      TEXT
    end

    def canva_page_plan
      <<~TEXT
        # Canva Page-by-Page Layout Plan

        Theme: WIZWIKI Bold Market Report
        Palette: black #0B0B0B, charcoal #1A1A1A, WIZWIKI red #E10600, light gray #F2F2F2, white #FFFFFF.
        Rule: Make this a designed marketing intelligence brief, not a plain essay.

        1. Cover / COVER_DARK_HERO: black or charcoal background, large white title, red slash/bar, client name, industry, service area, report date, WIZWIKI byline.
        2. Executive Summary / BEST_OPPORTUNITY_CALLOUT: 2-3 short paragraphs, red left-border callout, 1-3 big stat cards.
        3. Market Snapshot / BIG_STAT_CARD: customer mindset, buying triggers, local opportunity, why print/direct mail fits.
        4. Seasonality Timeline / SEASONAL_TIMELINE: pre-season, peak, follow-up, slow-season retention windows.
        5. Recommended Campaign / CAMPAIGN_RECOMMENDATION_CARD: primary and backup campaign cards plus best action callout.
        6. Channel Strategy / CHANNEL_COMPARISON_TABLE: direct mail, yard signs, door hangers, multi-touch sequence.
        7. Neighborhood Targeting / BIG_STAT_CARD: best-fit neighborhoods, jobsite neighbor logic, current customer areas, high-intent ZIPs.
        8. Offer Strategy / OFFER_STACK: three stacked offer cards with CTA.
        9. Timeline / Launch Plan / NEXT_STEPS_BLOCK: week-by-week campaign rhythm.
        10. Final Recommendation / NEXT_STEPS_BLOCK: campaign, timing, products, message, CTA, next step.

        Canva build notes:
        - Use large headings and short copy blocks.
        - Use red for section numbers, action labels, divider lines, and priority callouts.
        - Use black/charcoal for headers, card tops, and footer bands.
        - Use white/light gray for body areas and readable tables.
        - Keep every page skimmable in one glance.
      TEXT
    end

    def canva_copy_blocks
      title = manifest["report_title"].presence || artifact.title
      <<~TEXT
        # Canva Copy Blocks

        Report title:
        #{title}

        Byline:
        Prepared by WIZWIKI Marketing. Created using the WIZWIKI market analyzer.

        Best Opportunity block:
        Pull the strongest Best Opportunity callout from the DOCX executive summary and place it inside a light gray or black box with a red left border.

        Campaign cards:
        Pull the primary and backup campaign recommendations. Use black card headers and red campaign labels.

        Timeline blocks:
        Pull the seasonality and launch plan sections. Use red highlights for priority windows and gray for secondary windows.

        CTA block:
        Choose one clear action: approve campaign, select offer, send assets, schedule campaign, or confirm launch date.

        Designer note:
        Use the DOCX as source copy. Use `design_spec.json` as the layout source. Shorten visible text for Canva pages and keep detail in the Word companion.
      TEXT
    end

    def creative_brief(product)
      <<~TEXT
        # #{product} Creative Brief

        Goal:
        Translate the Market Strategy Report into a #{product.downcase} concept.

        Audience:
        Use the report target customer and neighborhood targeting sections.

        Message:
        Use one seasonal buying trigger and one clear customer benefit.

        Offer:
        Use one of the three offers from the Offer Strategy section.

        CTA:
        Keep it short, trackable, and action-oriented.

        Design notes:
        High contrast, readable from real-world distance, client logo when available, WIZWIKI production notes in margin or internal layer only.
      TEXT
    end

    def assets_readme
      <<~TEXT
        # Assets

        Use uploaded deal media from WIZWIKI as source assets.

        Priority:
        1. WIZWIKI Marketing agency logo.
        2. Client logo or brand colors.
        3. Client photos / product / local-market imagery.
        4. Campaign product mockups.

        If client logo or brand colors are missing, request them from the account manager before final PDF export.
      TEXT
    end
  end
end
