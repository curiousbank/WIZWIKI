module DealReports
  module MarketStrategyContract
    module_function

    VERSION = "2026-06-02.bold-market-report.1".freeze

    def payload(artifact:, crm_record:, labeled:, raw:, minimum_docx_bytes:)
      client = client_payload(crm_record, labeled, raw, artifact: artifact)
      audience = report_audience(artifact)
      industry_strategy = industry_strategy_payload(artifact, crm_record, labeled, raw, client: client)
      title = audience == "am" ? "AM Strategy Brief: #{client.fetch(:business_name)}" : "Market Strategy & Seasonality Report: #{client.fetch(:business_name)}"

      {
        contract_version: VERSION,
        product: audience == "am" ? "WIZWIKI Marketing internal AM strategy brief" : "WIZWIKI Marketing client market strategy report",
        target_worker: "WIZWIKI market analyzer",
        target_model: target_model_for(artifact),
        embedder_model: embedder_model_for(artifact),
        embedder_provider: "ollama/local",
        reasoning_effort: WizwikiSettings.wizwiki_report_reasoning_effort,
        agency_brand: agency_brand,
        audience: audience == "am" ? "account manager / internal strategy team" : "client decision makers",
        title: title,
        client: client,
        industry_strategy: industry_strategy,
        required_inputs: input_schema + Array(industry_strategy["input_variables"]).map { |field| "Industry lens: #{field}" },
        missing_inputs: missing_inputs(client),
        output_format: output_format(minimum_docx_bytes, audience: audience),
        quality_gate: quality_gate(minimum_docx_bytes, audience: audience),
        length: legacy_length(audience),
        runtime_rules: runtime_rules(artifact),
        voice_training_policy: voice_training_policy,
        output_parts: output_parts,
        example_style_guide: example_style_guide,
        report_style_system: report_style_system,
        design_spec: design_spec(audience),
        required_sections: required_sections(audience),
        required_tables: required_tables(audience),
        media_rules: media_rules,
        writing_rules: writing_rules(audience),
        canva_rules: canva_rules,
        word_docx_rules: word_docx_rules,
        manifest_schema: manifest_schema,
        preflight_rules: preflight_rules(minimum_docx_bytes, audience: audience),
        llm_prompt: prompt(artifact: artifact, crm_record: crm_record, labeled: labeled, raw: raw, minimum_docx_bytes: minimum_docx_bytes),
        requested_output: "#{audience == "am" ? "Internal AM strategy brief" : "Client-facing WIZWIKI Bold Market Report"} as a real DOCX file"
      }
    end

    def prompt(artifact:, crm_record:, labeled:, raw:, minimum_docx_bytes:)
      client = client_payload(crm_record, labeled, raw, artifact: artifact)
      missing = missing_inputs(client).join(", ").presence || "none"
      campaign_type = campaign_type_for(client)
      audience = report_audience(artifact)
      industry_strategy = industry_strategy_payload(artifact, crm_record, labeled, raw, client: client)
      industry_label = industry_strategy["label"].presence || industry_strategy["industry"].presence || "Local Services"
      industry_confidence = industry_strategy["confidence"].presence || "fallback"
      industry_data_policy = industry_strategy["data_policy"].is_a?(Hash) ? industry_strategy["data_policy"] : DealReports::IndustryStrategyPlaybook.data_policy
      weather_opportunity = weather_opportunity_payload(artifact, crm_record)

      <<~PROMPT
        #{report_instructions_for(audience:, campaign_type:, minimum_docx_bytes:)}

        CLIENT INPUTS:
        Business name: #{client.fetch(:business_name)}.
        Industry: #{client.fetch(:industry)}.
        Website: #{client.fetch(:website)}.
        Logo / brand colors: #{client.fetch(:logo_brand_colors)}.
        Service area: #{client.fetch(:service_area)}.
        Target customer: #{client.fetch(:target_customer)}.
        Main services/products: #{client.fetch(:main_services)}.
        Average ticket value: #{client.fetch(:average_ticket_value)}.
        Busy season: #{client.fetch(:busy_season)}.
        Slow season: #{client.fetch(:slow_season)}.
        Current channels: #{client.fetch(:current_marketing_channels)}.
        Current offers: #{client.fetch(:current_offers)}.
        Competitors: #{client.fetch(:competitors)}.
        Client goal: #{client.fetch(:client_goal)}.
        Preferred campaign types: #{client.fetch(:preferred_campaign_types)}.
        Sales notes: #{client.fetch(:sales_notes)}.
        Pipeline / status: #{client.fetch(:pipeline_status)}.
        Lead source: #{client.fetch(:lead_source)}.
        Company status: #{client.fetch(:company_status)}.
        New or repeat business: #{client.fetch(:new_or_repeat)}.
        CRM used: #{client.fetch(:crm_used)}.
        Last contacted: #{client.fetch(:last_contacted)}.
        Ticket priority: #{client.fetch(:ticket_priority)}.
        Ticket category: #{client.fetch(:ticket_category)}.
        Ticket source: #{client.fetch(:ticket_source)}.
        Associated company context: #{client.fetch(:associated_company_context)}.
        Associated contacts: #{client.fetch(:associated_contact_context)}.
        Associated deals: #{client.fetch(:associated_deal_context)}.
        Playbook call context: #{client.fetch(:playbook_call_context)}.
        Missing inputs: #{missing}.

        INDUSTRY STRATEGY LENS:
        Lens: #{industry_label}.
        Detection confidence: #{industry_confidence}.
        Targeting definition: #{industry_strategy["targeting_definition"].presence || "Use known service, geography, customer, and timing data from CRM without inventing missing facts."}.
        Input variables to look for in CRM/playbook/media: #{Array(industry_strategy["input_variables"]).join("; ")}.
        Intelligence tasks: #{Array(industry_strategy["intelligence_tasks"]).join("; ")}.
        Campaign families to consider: #{Array(industry_strategy["campaign_types"]).join("; ")}.
        Preferred output rhythm: #{Array(industry_strategy["output_sections"]).join("; ")}.
        Mode guidance: #{industry_strategy["mode_guidance"].presence || "Use the lens only when supported by source data."}.
        Data policy: #{industry_data_policy.map { |key, value| "#{key}=#{Array(value).join(", ")}" }.join("; ")}.

        #{weather_opportunity_prompt(weather_opportunity)}

        Thumper VOICE TRAINING:
        - Use documents marked training_priority=paramount first. The WIZWIKI Copy Playbook and Sample Operator Fathom voice analysis are the governing voice, offer, copywriting, and sales-clarity memory.
        - #{Thumper::VoiceGuide.system}
        - Retrieve relevant TrainingDocument chunks with the selected embedder before drafting visible copy.
        - Let the voice training shape rhythm, wording, confidence, brevity, and directness without exposing file names, training inventory, or internal notes.
        - If training guidance conflicts with required report structure or client safety rules, keep the required structure and client safety rules.

        CLIENT DOCUMENT COPY ONLY:
        - The visible DOCX must start with the client-facing header, not with analysis or planning notes.
        - Do not write about the payload, report_contract, instructions, rules, missing inputs, or assumptions.
        - Do not include phrases such as "We are creating", "The payload specifies", "Important", "Assumptions", "Let's structure", "Now we write", or "Note:".
        - Missing inputs are private source context only. Infer quietly in client-friendly language without labeling what was inferred.
        - Machine manifest is allowed for WIZWIKI validation, but it must not appear as visible document copy.
        - The DOCX must begin with a valid PK zip/docx signature, be at least #{minimum_docx_bytes} bytes, and be ready for Canva DOCX import.
      PROMPT
    end

    def report_audience(artifact)
      value = artifact.metadata.to_h["report_audience"].to_s
      value == "am" ? "am" : "client"
    end

    def target_model_for(artifact)
      metadata = artifact.metadata.to_h
      WizwikiSettings.normalize_report_local_model(metadata["report_local_model"].presence || metadata["target_model"].presence)
    end

    def embedder_model_for(artifact)
      metadata = artifact.metadata.to_h
      WizwikiSettings.normalize_report_embedder_model(metadata["report_embedder_model"].presence || metadata["embedding_model"].presence)
    end

    def industry_strategy_payload(artifact, crm_record, labeled, raw, client:)
      metadata = artifact.metadata.to_h
      stored = metadata["industry_strategy"].is_a?(Hash) ? metadata["industry_strategy"] : {}
      return stored if stored["industry"].present?

      DealReports::IndustryStrategyPlaybook.payload_for(
        metadata["industry_strategy_lens"].presence || "auto",
        crm_record: crm_record,
        labeled: labeled,
        raw: raw,
        company_name: client[:business_name],
        industry: client[:industry],
        services: client[:main_services],
        audience: metadata["report_audience"].presence || "client"
      )
    end

    def weather_opportunity_payload(artifact, crm_record)
      metadata = artifact.metadata.to_h
      stored = metadata["weather_opportunity"].is_a?(Hash) ? metadata["weather_opportunity"] : {}
      return stored if stored["active"].to_s == "true" || stored["signals"].present?

      weather = crm_record.properties.to_h.fetch("weather_lead", {}).to_h
      signals = Array(weather["signals"]).filter_map do |signal|
        signal = signal.to_h
        event = signal["event"].presence || "Weather signal"
        postal_codes = Array(signal["postal_codes"]).compact_blank.first(8)
        states = Array(signal["states"]).compact_blank.first(8)

        {
          "event" => event,
          "type" => signal["type"].presence,
          "severity" => signal["severity"].presence,
          "urgency" => signal["urgency"].presence,
          "certainty" => signal["certainty"].presence,
          "states" => states,
          "postal_codes" => postal_codes,
          "expires_at" => signal["expires_at"].presence
        }.compact_blank
      end.first(5)

      return { "active" => false, "source" => "Weather.gov Storm Watch", "summary" => "No active Storm Watch match is attached to this record." } if signals.blank?

      events = signals.map { |signal| signal["event"] }.compact_blank.uniq.first(4)
      locations = signals.flat_map { |signal| Array(signal["postal_codes"]).presence || Array(signal["states"]) }.compact_blank.uniq.first(8)
      {
        "active" => true,
        "source" => "Weather.gov Storm Watch",
        "matched_at" => weather["flagged_at"].presence,
        "signals_count" => weather["signals_count"].presence || signals.length,
        "events" => events,
        "locations" => locations,
        "summary" => "Storm Watch matched #{events.presence&.join(", ") || "recent storm activity"} near #{locations.presence&.join(", ") || "the service area"}.",
        "restoration_angle" => "If this client's services include restoration, roofing, exterior repair, plumbing, flooring, landscaping, tree work, HVAC, electrical, fencing, windows/doors, cleaning, mitigation, construction, or other home-service repair work, frame the weather signal as a timely opportunity to offer inspections, cleanup, repairs, and restoration services.",
        "truth_policy" => "Use only supplied weather events and locations. Do not claim confirmed damage at a specific property, do not invent forecasts, and do not use unsupported exact statistics.",
        "signals" => signals
      }.compact_blank
    end

    def weather_opportunity_prompt(weather_opportunity)
      weather_opportunity = weather_opportunity.to_h
      return <<~PROMPT.squish unless weather_opportunity["active"].to_s == "true"
        WEATHER / RESTORATION OPPORTUNITY: No active Storm Watch match is attached. Use normal seasonality and production-lead timing only; do not invent weather urgency.
      PROMPT

      signal_lines = Array(weather_opportunity["signals"]).first(5).map do |signal|
        signal = signal.to_h
        [
          signal["event"],
          [signal["severity"], signal["urgency"], signal["certainty"]].compact_blank.join(" / "),
          Array(signal["postal_codes"]).compact_blank.first(6).join(", ").presence || Array(signal["states"]).compact_blank.join(", ").presence,
          signal["expires_at"].presence
        ].compact_blank.join(" | ")
      end

      <<~PROMPT
        WEATHER / RESTORATION OPPORTUNITY:
        Source: #{weather_opportunity["source"].presence || "Weather.gov Storm Watch"}.
        Summary: #{weather_opportunity["summary"]}.
        Restoration/service angle: #{weather_opportunity["restoration_angle"]}.
        Truth policy: #{weather_opportunity["truth_policy"]}.
        Signals: #{signal_lines.presence&.join("; ") || "weather signals attached but not expanded"}.
        Report guidance: If the client offers restoration, roofing, exterior repair, plumbing, flooring, landscaping, tree work, HVAC, electrical, fencing, windows/doors, cleaning, mitigation, construction, or relevant home-service work, include a concise recommendation that this weather window is a strong opportunity to offer inspections, repairs, cleanup, restoration, and neighborhood awareness. If the client's services do not fit restoration, translate the weather signal into truthful urgency and seasonality instead.
      PROMPT
    end

    def report_instructions_for(audience:, campaign_type:, minimum_docx_bytes:)
      if audience == "am"
        <<~PROMPT
          Create an internal AM market strategy brief in real DOCX format, not renamed plain text.
          This DOCX is for the account manager and internal sales/design team, not the client.

          TONE & PERSPECTIVE:
          - Write like a practical marketing strategist helping an AM prepare the account.
          - Be direct, useful, and easy to scan.
          - Internal context is allowed when it helps the AM act, but never include credentials, secrets, private personal data, or irrelevant raw dumps.

          STRUCTURE, 4-6 PAGES MAX:
          1. Header: WIZWIKI Marketing name + small line: "Created using the WIZWIKI market analyzer."
          2. Account Snapshot: client, industry, status, pipeline/stage, owner context, known gaps.
          3. Market Opportunity: practical timing, customer behavior, seasonal logic, likely campaign fit.
          4. AM Talking Points: concise call notes, risks, questions to ask, client-safe framing.
          5. Campaign Recommendation: primary campaign, backup campaign, offer angle, CTA, suggested products.
          6. Internal Next Moves: ordered actions for AM/design/production.
          7. Client-Safe Summary: short section the AM can copy into client communication.

          FORMATTING:
          - Headings: bold, 24-34pt where possible.
          - Body: 11-12pt.
          - Tables: simple, 3-4 columns max.
          - Include WIZWIKI Marketing branding in the header.
          - Include this exact small byline in the header or title block: "Created using the WIZWIKI market analyzer."

          The DOCX must begin with a valid PK zip/docx signature, be at least #{minimum_docx_bytes} bytes, and be useful for AM preparation.
        PROMPT
      else
        <<~PROMPT
          Create a client-facing market strategy report in real DOCX format, not renamed plain text.
          This DOCX will be imported into Canva, so it must read like a designed marketing strategy deck crossed with an executive report.
          The visible document must begin with "WIZWIKI MARKETING" and must not include any planning, prompt echo, or instruction summary.

          DESIGN SYSTEM:
          - Theme: WIZWIKI Bold Market Report.
          - Visual mood: bold, clean, confident, high contrast, black/white/red/charcoal, sales-ready, print-friendly.
          - Use black for authority, red for action, white/light gray for readability, charcoal for headers/cards.
          - Use large useful headings, red accent bars, callout boxes, campaign cards, tables, offer stacks, and timeline blocks.
          - Do not create a plain essay. Every page needs one clear job and a visible hierarchy.
          - Avoid tiny text, long walls of copy, generic blue, weak headings, decorative clutter, unsupported stats, duplicate/empty headings, internal workflow status language, and dense paragraph pages.

          TONE & PERSPECTIVE:
          - Write in second person: "you", "your business", "we'll".
          - Warm, confident, practical, client-friendly, sales-supportive. No internal jargon.
          - Focus on action, timing, neighborhood opportunity, campaign approval, and business outcomes.

          STRUCTURE, 8-10 PAGES, VISIBLE DOCX COPY ONLY:
          1. Header / Cover: WIZWIKI MARKETING, report title, client name, industry, service area, report date, prepared by WIZWIKI Marketing.
          2. Executive Summary: 2-3 short paragraphs, Best Opportunity callout, and 1-3 big stat cards.
          3. Market Snapshot: customer mindset, buying triggers, local opportunity, why print/direct mail fits.
          4. Seasonality Timeline: pre-season awareness, peak conversion, follow-up, slow-season retention.
          5. Recommended Campaign: primary campaign card, backup campaign card, best action callout.
          6. Channel Strategy: compare direct mail/postcards, yard signs, door hangers, and multi-touch campaign.
          7. Neighborhood Targeting: best-fit neighborhoods, jobsite neighbors, current customer areas, high-intent ZIPs, visible-need zones.
          8. Offer Strategy: three offer cards with headline, why it works, best product, and CTA.
          9. Timeline / Launch Plan: week-by-week campaign rhythm and next steps block.
          10. Final Recommendation: recommended campaign, timing, products, primary message, best CTA, next step.

          REQUIRED COMPONENTS:
          - COVER_DARK_HERO, SECTION_HEADER_BAND, BEST_OPPORTUNITY_CALLOUT, BIG_STAT_CARD.
          - CAMPAIGN_RECOMMENDATION_CARD, CHANNEL_COMPARISON_TABLE, SEASONAL_TIMELINE, OFFER_STACK, NEXT_STEPS_BLOCK.

          OUTPUT CONTRACT:
          - Build the DOCX from PART A: REPORT_CONTENT.
          - Include PART B: DESIGN_SPEC in the completion manifest or design metadata, not as visible client copy unless a separate design-spec file is requested.
          - The DESIGN_SPEC must use theme "WIZWIKI Bold Market Report" and the red/black palette from report_contract.design_spec.
          - Keep visible DOCX copy client-facing. Do not print JSON inside the report body.

          EXCLUDE FROM VISIBLE DOCX COPY:
          - Internal notes, assumptions tables, data checklists.
          - HubSpot IDs, AM references, technical metadata.
          - Creative briefs, designer notes, production specs.
          - Detailed tracking tables, appendices, source notes, raw properties.
          - Canva handoff notes, implementation notes, approval gates, asset lists.
          - Any explanation of what the AI is doing, what the payload says, or how the document will be structured.
          - Unsupported exact statistics, exact goals, or exact percentages unless the source data provides them.
          - Internal ticket/workflow language such as abandoned, SAM, Ticket status, HubSpot ID, hs_* property names, checklist states, or AM-only status labels.
          - Duplicate section headings or headings with no body content beneath them.
          - Generic industry copy when specific company, service-area, industry, or associated-record context is available.

          DOCX FORMATTING:
          - Cover title: 42-56pt bold condensed/heavy sans serif where possible.
          - Page titles: 28-36pt heavy sans serif.
          - Section headings: 18-24pt bold.
          - Body: 10.5-12pt clean readable sans serif.
          - Tables: compact 9.5-10.5pt body with black header row, white header text, red divider line, alternating light gray rows.
          - Use real DOCX headings, paragraphs, page breaks, shaded boxes, borders, and tables. Keep text editable.
          - Include a client logo placeholder if no client logo is available.
          - Include WIZWIKI Marketing branding in the header.
          - Include this exact small byline in the header or title block: "Created using the WIZWIKI market analyzer."
        PROMPT
      end
    end

    def client_payload(crm_record, labeled, raw, artifact: nil)
      description = labeled["Deal Description"].presence || labeled["Ticket Description"].presence || raw["deal_description"].presence || raw["content"].presence
      company_record = preferred_company_record(crm_record)
      company_properties = hubspot_properties_for(company_record)
      company_labeled = hubspot_labeled_properties_for(company_record)
      company_name = labeled["Company Name"].presence ||
        raw["company_name"].presence ||
        raw["company"].presence ||
        artifact&.metadata.to_h["company_name"].presence ||
        company_labeled["Company Name"].presence ||
        company_properties["name"].presence ||
        company_record&.name.presence ||
        crm_record.name
      website = labeled["Website URL"].presence ||
        raw["website"].presence ||
        raw["website_url"].presence ||
        company_labeled["Website URL"].presence ||
        company_properties["website"].presence ||
        company_record&.domain.presence ||
        "not provided"
      industry = labeled["Industry"].presence ||
        raw["industry"].presence ||
        company_labeled["Industry"].presence ||
        company_properties["industry"].presence ||
        company_properties["hs_industry_group"].presence ||
        infer_industry(company_name, description, company_record)
      service_area = labeled["Service Area"].presence ||
        raw["service_area"].presence ||
        associated_service_area(company_record).presence ||
        infer_service_area(description)
      main_services = labeled["Main Services"].presence ||
        raw["main_services"].presence ||
        description.presence ||
        infer_main_services(industry)

      {
        business_name: company_name,
        industry: industry,
        website: website,
        logo_brand_colors: labeled["Free Postcard Logo"].presence || "use uploaded logo if available; otherwise include a clean logo placeholder",
        service_area: service_area,
        target_customer: labeled["Target Customer"].presence || raw["target_customer"].presence || infer_target_customer(labeled, raw),
        main_services: main_services,
        average_ticket_value: crm_record.amount.present? ? "$#{crm_record.amount.to_i}" : labeled["Average Ticket Value"].presence || raw["average_ticket_value"].presence || "not provided",
        busy_season: labeled["Busy Season"].presence || raw["busy_season"].presence || "seasonal peak window",
        slow_season: labeled["Slow Season"].presence || raw["slow_season"].presence || "slower demand window",
        current_marketing_channels: labeled["Current Marketing Channels"].presence || raw["current_marketing_channels"].presence || "current local marketing",
        current_offers: labeled["Current Offers"].presence || raw["current_offers"].presence || "a simple seasonal offer",
        competitors: labeled["Competitors"].presence || raw["competitors"].presence || "nearby competitors",
        client_goal: labeled["Client Goal"].presence || raw["client_goal"].presence || infer_client_goal(crm_record, labeled, raw),
        preferred_campaign_types: labeled["Preferred Campaign Types"].presence || raw["preferred_campaign_types"].presence || "direct mail postcards, yard signs, door hangers, neighborhood blitz",
        sales_notes: labeled["Sales Notes"].presence || raw["sales_notes"].presence || description.presence || "none supplied",
        pipeline_status: labeled["Ticket Status"].presence || labeled["Deal Stage"].presence || crm_record.stage.presence || "not provided",
        lead_source: labeled["Latest Traffic Source"].presence || raw["hs_analytics_latest_source"].presence || raw["hs_analytics_source"].presence || raw["source_type"].presence || "not provided",
        company_status: labeled["Company Status"].presence || raw["s____company_status"].presence || "not provided",
        new_or_repeat: labeled["New Company"].presence || raw["new_or_repeat_business"].presence || "not provided",
        crm_used: labeled["CRM Used"].presence || raw["clients_crm"].presence || "not provided",
        last_contacted: labeled["Last Contacted"].presence || raw["notes_last_contacted"].presence || raw["hs_lastcontacted"].presence || "not provided",
        ticket_priority: labeled["Ticket Priority"].presence || raw["hs_ticket_priority"].presence || "not provided",
        ticket_category: labeled["Ticket Category"].presence || raw["hs_ticket_category"].presence || "not provided",
        ticket_source: labeled["Ticket Source"].presence || raw["source_type"].presence || "not provided",
        associated_company_context: associated_context(crm_record, "company"),
        associated_contact_context: associated_context(crm_record, "contact"),
        associated_deal_context: associated_context(crm_record, "deal"),
        playbook_call_context: playbook_call_context(crm_record),
        campaign_type: labeled["Campaign Type"].presence || raw["campaign_type"].presence,
        report_date: Time.zone.today.iso8601
      }
    end

    def agency_brand
      {
        name: "WIZWIKI MARKETING",
        tagline: "Direct mail and neighborhood marketing built to move your business forward.",
        report_byline: "Created using the WIZWIKI market analyzer",
        logo_required: true,
        logo_source: "assets.agency_logo",
        tone: "warm, confident, professional, client-facing, benefit-focused"
      }
    end

    def input_schema
      [
        "Business name", "Industry", "Website", "Logo / brand colors", "Service area", "Target customer",
        "Main services/products", "Average ticket value", "Busy season", "Slow season", "Current marketing channels",
        "Current offers/promotions", "Competitors", "Client goal", "Preferred campaign types", "Special sales notes",
        "Pipeline/status", "Lead source", "Company status", "New/repeat business", "CRM used", "Last contacted",
        "Ticket priority", "Ticket category", "Ticket source", "Associated company", "Associated contacts", "Associated deals", "Playbook call context"
      ]
    end

    def missing_inputs(client)
      client.slice(:website, :service_area, :target_customer, :main_services, :average_ticket_value, :busy_season, :slow_season).select { |_key, value| value.to_s.in?(["not provided", "seasonal peak window", "slower demand window", "core services"]) || value.blank? }.keys.map(&:to_s)
    end

def output_format(minimum_docx_bytes, audience: "client")
  {
    primary: audience.to_s == "am" ? "Internal AM strategy DOCX brief" : "Canva-import-friendly WIZWIKI Bold Market Report DOCX",
    worker_output_required: audience.to_s == "am" ? "editable Word / DOCX internal AM strategy brief" : "editable Word / DOCX client market strategy report",
    optional_outputs: [],
    required_content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    required_extension: "docx",
    minimum_docx_bytes: minimum_docx_bytes,
    forbidden_outputs: ["plain text renamed as DOCX", "PDF only", "markdown only", "HTML only"]
  }
end

def quality_gate(minimum_docx_bytes, audience: "client")
  sections = required_sections(audience)
  tables = required_tables(audience)
  minimum_words = audience.to_s == "am" ? 600 : 650
  hard_minimum_words = audience.to_s == "am" ? 450 : 500
  {
    minimum_docx_bytes: minimum_docx_bytes,
    minimum_words: minimum_words,
    hard_minimum_words: hard_minimum_words,
    preferred_words: audience.to_s == "am" ? "800-1,400" : "900-1,600",
    maximum_words: audience.to_s == "am" ? 1_800 : 2_200,
    minimum_sections: sections.length,
    minimum_tables: tables.length,
    minimum_campaign_concepts: 1,
    minimum_offer_ideas: 2,
    target_pages: audience.to_s == "am" ? "4-6 pages max, AM-ready" : "8-10 pages, Canva-import-friendly bold strategic report",
    visible_document_stop_after: audience.to_s == "am" ? "Client-Safe Summary" : "Final Recommendation",
    reject_if_missing_required_section: true,
    reject_if_no_manifest: true,
    reject_if_no_docx_zip_signature: true
  }
end

def legacy_length(audience = "client")
  minimum = audience.to_s == "am" ? 600 : 650
  hard_minimum = audience.to_s == "am" ? 450 : 500
  {
    minimum_words: minimum,
    hard_minimum_words: hard_minimum,
    preferred_words: audience.to_s == "am" ? "800-1,400" : "900-1,600"
  }
end

def runtime_rules(artifact = nil)
  target_model = artifact ? target_model_for(artifact) : WizwikiSettings.qwen_model

  {
    provider: WizwikiSettings.wizwiki_report_provider,
    target_model: target_model,
    qwen_only: WizwikiSettings.qwen_only?,
    openai_allowed: WizwikiSettings.openai_runtime_enabled?,
    instruction: WizwikiSettings.qwen_only? ? "Use the local worker model only. Do not call OpenAI for this report. The completion manifest must use provider qwen/local and the selected local model." : "Use the configured report runtime."
  }
end

def output_parts
  [
    { id: "part_a", title: "REPORT_CONTENT client-facing DOCX" },
    { id: "part_b", title: "DESIGN_SPEC manifest payload" },
    { id: "part_c", title: "Canva Build Kit ZIP" },
    { id: "part_d", title: "Canva DOCX import output package" }
  ]
end

def example_style_guide
  {
    source_folder: "operator-provided private examples",
    format: "bold client market strategy report, not a plain essay",
    theme: "WIZWIKI Bold Market Report",
    tone: "warm, confident, direct, benefit-led, concise, action-oriented",
    layout: "8-10 page deck/report with cover hero, section bands, red/black hierarchy, stat cards, campaign cards, channel table, seasonality timeline, offer stack, and next steps block",
    canva_import_priority: "use real DOCX styles and stable tables/boxes so Canva can convert it into a polished document"
  }
end

def required_sections(audience = "client")
  if audience.to_s == "am"
    return [
      section("header", "Header", "WIZWIKI Marketing name plus WIZWIKI market analyzer byline."),
      section("account_snapshot", "Account Snapshot", "Client, industry, status, pipeline/stage, owner context, and known gaps."),
      section("market_opportunity", "Market Opportunity", "Timing, customer behavior, seasonal logic, and campaign fit."),
      section("am_talking_points", "AM Talking Points", "Call notes, risks, client-safe framing, and questions to ask."),
      section("campaign_recommendation", "Campaign Recommendation", "Primary and backup campaign recommendations with offer angle and CTA.", requires_table: "campaign_table"),
      section("internal_next_moves", "Internal Next Moves", "Ordered actions for AM, design, and production."),
      section("client_safe_summary", "Client-Safe Summary", "Short summary the AM can reuse externally.")
    ]
  end

  [
    section("cover", "Header / Cover", "COVER_DARK_HERO with WIZWIKI Marketing, report title, client name, industry, service area, report date, and prepared-by line."),
    section("executive_summary", "Executive Summary", "2-3 short paragraphs, BEST_OPPORTUNITY_CALLOUT, and BIG_STAT_CARD elements."),
    section("market_snapshot", "Market Snapshot", "Customer mindset, buying triggers, local opportunity, and why print/direct mail fits."),
    section("seasonality_timeline", "Seasonality Timeline", "Pre-season awareness, peak conversion, follow-up, and slow-season retention windows.", requires_table: "seasonality_timeline_table"),
    section("recommended_campaign", "Recommended Campaign", "Primary and backup CAMPAIGN_RECOMMENDATION_CARD sections plus best action callout.", requires_table: "campaign_recommendation_table"),
    section("channel_strategy", "Channel Strategy", "CHANNEL_COMPARISON_TABLE comparing direct mail, yard signs, door hangers, and multi-touch campaign.", requires_table: "channel_comparison_table"),
    section("neighborhood_targeting", "Neighborhood Targeting", "Best-fit neighborhoods, jobsite neighbors, current customer areas, high-intent ZIPs, and visible-need zones."),
    section("offer_strategy", "Offer Strategy", "OFFER_STACK with three campaign-ready offers.", requires_table: "offer_stack_table"),
    section("launch_plan", "Timeline / Launch Plan", "Week-by-week campaign rhythm and NEXT_STEPS_BLOCK."),
    section("final_recommendation", "Final Recommendation", "Recommended campaign, timing, products, primary message, best CTA, and next step.")
  ]
end

def required_tables(audience = "client")
  if audience.to_s == "am"
    return [
      { id: "campaign_table", title: "Campaign Recommendation", columns: ["Move", "Why It Matters", "Owner"], minimum_rows: 3 }
    ]
  end

  [
    { id: "seasonality_timeline_table", title: "Seasonality Timeline", columns: ["Window", "Customer Mindset", "Marketing Opportunity", "Recommended Product"], minimum_rows: 4 },
    { id: "campaign_recommendation_table", title: "Campaign Recommendation", columns: ["Campaign", "Goal", "Timing", "CTA"], minimum_rows: 2 },
    { id: "channel_comparison_table", title: "Channel Strategy", columns: ["Channel", "Best For", "Why It Works", "Recommended Use", "CTA"], minimum_rows: 4 },
    { id: "offer_stack_table", title: "Offer Strategy", columns: ["Offer", "Why It Works", "Best Product", "CTA"], minimum_rows: 3 }
  ]
end

    def voice_training_policy
      {
        source_type: "TrainingDocument",
        scope: Autos::EmbeddingQueue::DEFAULT_SCOPE,
        required_when_available: true,
        applies_to: ["wizwiki_ask", "market_report", "copy_maker", "comm_kit", "comms_sms_draft"],
        retrieval: "Use the selected qwen embedder to retrieve relevant Thumper fine-training chunks before drafting visible copy.",
        visible_copy_rule: "Never print training file names, raw training inventory, or internal training notes unless explicitly asked by an admin."
      }
    end

    def media_rules
      {
        agency_logo: { embed_required: true, source: "assets.agency_logo", placement: "header", alt_text: "WIZWIKI Marketing" },
        client_logo: { embed_if_available: true, sources: ["assets.logo_endpoint", "assets.logo_url", "uploaded logo_candidate media"], fallback: "Use a clean logo placeholder." },
        uploaded_media: { inspect_all: true, embed_supported_images: true, never_fail_only_because_media_is_missing: true }
      }
    end

def writing_rules(audience = "client")
  if audience.to_s == "am"
    return [
      "Write for the account manager and internal sales/design team.",
      "Be direct, concise, and operationally useful.",
      "Use HubSpot/account context to identify risks, questions, talking points, and next moves.",
      "Use playbook call context as discovery input for goals, objections, urgency, and next actions without exposing raw call metadata.",
      "Include a client-safe summary the AM can reuse externally.",
      "Never include credentials, secrets, private personal data, irrelevant raw dumps, or unsupported exact statistics.",
      "No caveman, monster, or old AUTOS voice in AM reports."
    ]
  end

  [
    "Write in second person: you, your business, we'll.",
    "Use warm, confident, professional language.",
    "Focus on client benefits and outcomes.",
    "Keep paragraphs short and easy to scan.",
    "No internal jargon, AM notes, HubSpot IDs, technical metadata, assumptions tables, creative briefs, designer notes, production specs, appendices, source notes, raw properties, Canva handoff notes, implementation notes, approval gates, asset lists, or data checklists.",
    "Stop visible client copy immediately after Final Recommendation. Machine manifest and DESIGN_SPEC may exist only as metadata or build-kit files, not visible document content.",
    "Do not invent exact statistics, percentages, response goals, conversion goals, or performance benchmarks unless the source data provides them.",
    "Do not use internal ticket/workflow status words such as abandoned, SAM, Ticket status, HubSpot ID, hs_* property names, checklist states, or AM-only status labels in visible client copy.",
    "Do not repeat section headings, leave placeholder headings empty, or include generic fallback sections when specific company, industry, service-area, or associated-record context is available.",
    "Use playbook call context as private discovery input for goals, objections, urgency, and next actions, but do not quote raw call notes, recording URLs, Zoom IDs, or private internal metadata in visible client copy.",
    "Use paramount Thumper fine-training documents first. The WIZWIKI Copy Playbook and Sample Operator Fathom voice analysis override older samples for tone, rhythm, offer framing, and clarity without exposing internal training material.",
    "Never echo the prompt or planning process. Do not write phrases like: We are creating, The payload specifies, Important, Assumptions, Let's structure, Now we write, or Note.",
    "Visible client copy must start with WIZWIKI MARKETING or the report title, not with analysis.",
    "Use direct mail, postcards, yard signs, door hangers, neighborhood marketing, and local follow-up only when relevant.",
    "No caveman, monster, or old AUTOS voice in client reports.",
    "Use associated contacts only for audience/stakeholder context. Do not print private contact emails in visible client copy unless the source request explicitly asks for it."
  ]
end

    def canva_rules
      {
        style: "WIZWIKI Bold Market Report: black/white/red/charcoal, bold strategic deck/report, print-friendly",
        layout: "cover dark hero, section header bands, stat cards, callouts, campaign cards, seasonality timeline, channel comparison table, offer stack, next steps block",
        fonts: "cover title 42-56pt bold condensed/heavy sans; page title 28-36pt; section heading 18-24pt; body 10.5-12pt; table body 9.5-10.5pt",
        tables: "black header row, white header text, red divider line, alternating light gray rows, compact copy",
        color_palette: report_style_system.fetch(:color_palette),
        avoid: ["complex floating text boxes", "tiny text", "long walls of copy", "generic corporate blue", "internal notes", "appendices", "production specs", "low contrast text"]
      }
    end

    def word_docx_rules
      [
        "Use real DOCX styles: Title, Heading 1, Heading 2, Heading 3, Normal, Callout, Table Header, Table Body.",
        "Use page breaks so each page has one clear job and one major visual structure.",
        "Use shaded boxes, borders, red left bars, simple tables, and section bands instead of fragile floating text boxes.",
        "Cover title should be 42-56pt where possible; page titles 28-36pt; section headings 18-24pt; body 10.5-12pt.",
        "Tables should be compact with black headers, white header text, red dividers, and alternating light gray rows.",
        "Include logo placeholder if client logo is unavailable.",
        "Keep all text editable and Canva-import-friendly."
      ]
    end

    def manifest_schema
      {
        required_top_level_keys: ["worker_id", "generated_at", "provider", "model", "usage", "report_title", "source_artifact_id", "source_deal_id", "sections", "tables", "media", "quality"],
        section_item: { id: "required_sections.id", title: "string", word_count: "integer", present: "boolean" },
        table_item: { id: "required_tables.id", row_count: "integer", present: "boolean" },
        quality: { docx_byte_size: "integer", docx_signature: "PK", word_count: "integer", section_count: "integer", table_count: "integer", validation_passed: "boolean", validation_errors: "array", validation_warnings: "array" }
      }
    end

def preflight_rules(minimum_docx_bytes, audience: "client")
  base = [
    "Verify DOCX begins with PK before posting complete_endpoint.",
    "Verify byte size is at least #{minimum_docx_bytes} bytes.",
    "Verify every required section id appears in manifest.sections with present=true.",
    "Verify every required table id appears in manifest.tables with row_count >= minimum_rows."
  ]

  if audience.to_s == "am"
    base + [
      "Verify internal AM content does not include credentials, secrets, private personal data, or irrelevant raw property dumps.",
      "Verify the report includes a client-safe summary section.",
      "If preflight fails, rebuild once with cleaner AM-focused brief copy before failing the job."
    ]
  else
    base + [
      "Verify there is no internal-only content: no HubSpot IDs, no AM notes, no assumptions table, no technical metadata, no designer notes, no production notes, no source appendix, and no Canva handoff section in visible copy.",
      "Verify visible sections stop after Final Recommendation. Reject output that appends implementation notes, designer notes, production notes, source data appendix, HubSpot properties, asset lists, or approval gates.",
      "Verify the report uses the WIZWIKI Bold Market Report system: red/black hierarchy, large headings, callouts/cards/tables/timelines, and no long essay-style pages.",
      "Verify the manifest includes design_spec.theme = WIZWIKI Bold Market Report when the worker supports manifest design metadata.",
      "Reject output that begins with or contains model planning/prompt echo such as: We are creating, The payload specifies, Important, Assumptions, Let's structure, Now we write, or Note.",
      "Reject unsupported exact statistics, percentages, response goals, conversion goals, or performance benchmarks unless they appear in source data.",
      "Reject visible copy that uses internal workflow/status language such as abandoned, SAM, Ticket status, HubSpot ID, hs_* property names, checklist states, or AM-only labels.",
      "Reject visible copy with duplicate section headings, empty section headings, or generic fallback copy when specific client/account context is available.",
      "If preflight fails, rebuild once with cleaner client-facing report copy before failing the job."
    ]
  end
end

    def report_style_system
      {
        style_name: "WIZWIKI Bold Market Report",
        visual_mood: ["bold", "clean", "confident", "high contrast", "strategic", "practical", "sales-ready", "print-friendly"],
        color_palette: {
          wizwiki_red: "#E10600",
          black: "#0B0B0B",
          charcoal: "#1A1A1A",
          dark_gray: "#2B2B2B",
          light_gray: "#F2F2F2",
          white: "#FFFFFF",
          warning_orange: "#FFB000",
          success_green: "#22A06B",
          muted_red: "#B00000"
        },
        font_roles: {
          cover_title: "bold condensed sans serif, preferred Anton or Arial Black",
          page_title: "heavy modern sans serif, preferred Montserrat ExtraBold",
          section_heading: "bold modern sans serif, preferred Montserrat Bold",
          subheading: "semibold modern sans serif",
          body: "clean readable sans serif",
          table: "compact readable sans serif",
          callout: "bold sans serif",
          caption: "small clean sans serif"
        },
        docx_font_sizes: {
          cover_title: "42-56pt",
          cover_subtitle: "18-24pt",
          page_title: "28-36pt",
          section_heading: "18-24pt",
          subheading: "14-18pt",
          body: "10.5-12pt",
          callout_large: "16-22pt",
          table_header: "10-11pt bold",
          table_body: "9.5-10.5pt",
          footer: "8-9pt"
        },
        page_density_rules: [
          "One main headline per page.",
          "One short subheading per page.",
          "One major visual structure per page.",
          "Prefer cards, tables, bullets, timelines, callouts, and offer stacks over long prose.",
          "No paragraph longer than 4 lines.",
          "Use red accent bars to guide the eye."
        ],
        approved_components: [
          "COVER_DARK_HERO",
          "SECTION_HEADER_BAND",
          "BEST_OPPORTUNITY_CALLOUT",
          "BIG_STAT_CARD",
          "CAMPAIGN_RECOMMENDATION_CARD",
          "CHANNEL_COMPARISON_TABLE",
          "SEASONAL_TIMELINE",
          "OFFER_STACK",
          "NEXT_STEPS_BLOCK"
        ]
      }
    end

    def design_spec(audience = "client")
      return internal_design_spec if audience.to_s == "am"

      {
        theme: "WIZWIKI Bold Market Report",
        color_palette: {
          primary: "#E10600",
          black: "#0B0B0B",
          charcoal: "#1A1A1A",
          light_gray: "#F2F2F2",
          white: "#FFFFFF"
        },
        font_roles: {
          cover_title: "bold condensed sans serif",
          page_title: "heavy modern sans serif",
          section_heading: "bold modern sans serif",
          body: "clean readable sans serif",
          callout: "bold sans serif"
        },
        pages: [
          design_page(1, "cover", "COVER_DARK_HERO", "Market Strategy & Seasonality Report", "Prepared for the client", ["COVER_DARK_HERO"], ["Title", "Normal"]),
          design_page(2, "executive_summary", "BEST_OPPORTUNITY_CALLOUT", "The Best Play Is Clear", "What matters most and why now", ["SECTION_HEADER_BAND", "BEST_OPPORTUNITY_CALLOUT", "BIG_STAT_CARD"], ["Heading 1", "Callout", "Normal"]),
          design_page(3, "market_snapshot", "BIG_STAT_CARD", "Neighborhood Visibility Is the Advantage", "Customer mindset, triggers, and market fit", ["SECTION_HEADER_BAND", "BIG_STAT_CARD"], ["Heading 1", "Heading 2", "Normal"]),
          design_page(4, "seasonality_timeline", "SEASONAL_TIMELINE", "The Window Is Before Demand Peaks", "When to act and what to send", ["SECTION_HEADER_BAND", "SEASONAL_TIMELINE"], ["Heading 1", "Table Header", "Table Body"]),
          design_page(5, "recommended_campaign", "CAMPAIGN_RECOMMENDATION_CARD", "The Recommended Campaign", "Primary and backup campaign path", ["SECTION_HEADER_BAND", "CAMPAIGN_RECOMMENDATION_CARD", "BEST_OPPORTUNITY_CALLOUT"], ["Heading 1", "Heading 2", "Callout"]),
          design_page(6, "channel_strategy", "CHANNEL_COMPARISON_TABLE", "Print Works When Timing Is Clear", "Direct mail, signs, door hangers, and multi-touch", ["SECTION_HEADER_BAND", "CHANNEL_COMPARISON_TABLE"], ["Heading 1", "Table Header", "Table Body"]),
          design_page(7, "neighborhood_targeting", "BIG_STAT_CARD", "Target Where Trust Can Spread", "Where to market first", ["SECTION_HEADER_BAND", "BIG_STAT_CARD"], ["Heading 1", "Heading 2", "Normal"]),
          design_page(8, "offer_strategy", "OFFER_STACK", "Lead With the Offer", "Three campaign-ready offers", ["SECTION_HEADER_BAND", "OFFER_STACK"], ["Heading 1", "Heading 2", "Callout"]),
          design_page(9, "launch_plan", "NEXT_STEPS_BLOCK", "Repeat With Visibility", "Week-by-week launch rhythm", ["SECTION_HEADER_BAND", "SEASONAL_TIMELINE", "NEXT_STEPS_BLOCK"], ["Heading 1", "Table Header", "Table Body"]),
          design_page(10, "final_recommendation", "NEXT_STEPS_BLOCK", "Final Recommendation", "Clear approval path", ["SECTION_HEADER_BAND", "NEXT_STEPS_BLOCK"], ["Heading 1", "Callout", "Normal"])
        ]
      }
    end

    def internal_design_spec
      spec = design_spec("client")
      spec.merge(
        theme: "WIZWIKI Bold Market Report // AM Internal",
        pages: spec.fetch(:pages).first(6)
      )
    end

    def design_page(page_number, page_type, layout_component, headline, subheading, components, docx_styles)
      {
        page_number: page_number,
        page_type: page_type,
        layout_component: layout_component,
        headline: headline,
        subheading: subheading,
        components: components,
        color_roles: ["black", "charcoal", "wizwiki_red", "white", "light_gray"],
        font_roles: {
          headline: "page_title",
          subheading: "subheading",
          body: "body",
          callout: "callout"
        },
        canva_fields: ["client_name", "industry", "service_area", "campaign_window", "recommended_products", "primary_cta"],
        docx_styles: docx_styles
      }
    end

    def section(id, title, instructions, requires_table: nil)
      payload = { id: id, title: title, minimum_words: 40, instructions: instructions }
      payload[:requires_table] = requires_table if requires_table
      payload
    end

    def campaign_type_for(client)
      client[:campaign_type].presence || client[:preferred_campaign_types].to_s.split(/[;,]/).first.to_s.squish.presence || "Neighborhood Marketing Campaign"
    end

    def preferred_company_record(crm_record)
      return crm_record if crm_record&.record_type == "company"

      associated_records_for(crm_record).find { |record| record.record_type == "company" }
    rescue StandardError
      nil
    end

    def hubspot_properties_for(record)
      record&.properties.to_h.fetch("hubspot", {}).to_h.fetch("properties", {}).to_h
    end

    def hubspot_labeled_properties_for(record)
      record&.properties.to_h.fetch("hubspot", {}).to_h.fetch("labeled_properties", {}).to_h
    end

    def associated_service_area(company_record)
      properties = hubspot_properties_for(company_record)
      [
        properties["city"],
        properties["state"],
        properties["zip"],
        properties["postal_code"],
        properties["country"]
      ].compact_blank.join(", ").presence
    end

    def infer_industry(company_name, description = nil, company_record = nil)
      haystack = [
        company_name,
        description,
        company_record&.name,
        company_record&.domain,
        hubspot_properties_for(company_record).values_at("description", "about_us", "industry", "hs_industry_group")
      ].flatten.compact.join(" ").downcase

      case haystack
      when /mechanical|hvac|heating|cooling|air\s*conditioning|furnace|ventilation/
        "HVAC and mechanical services"
      when /plumb|drain|sewer|water\s*heater/
        "plumbing services"
      when /roof|gutter|siding|exterior/
        "roofing and exterior services"
      when /electric|electrical|solar/
        "electrical services"
      when /landscap|lawn|mow|tree|irrigation/
        "landscaping and lawn care services"
      when /pool|spa/
        "pool and spa services"
      when /clean|maid|janitorial|restoration|pressure\s*wash/
        "cleaning and restoration services"
      when /pest|termite/
        "pest control services"
      when /garage|door/
        "garage door services"
      when /dent|ortho|chiro|clinic|medical|health/
        "local healthcare services"
      when /restaurant|pizza|bar|grill|cafe|coffee/
        "local food and hospitality"
      when /auto|collision|tire|mechanic/
        "automotive services"
      else
        "local home and property services"
      end
    end

    def infer_main_services(industry)
      case industry.to_s.downcase
      when /hvac|mechanical/
        "HVAC maintenance, repair, replacement, and seasonal comfort services"
      when /plumbing/
        "plumbing repair, inspections, drain service, water heater support, and emergency response"
      when /roof/
        "roof inspections, repair, replacement, storm response, gutters, and exterior maintenance"
      when /electrical/
        "electrical repair, upgrades, inspections, and residential service calls"
      when /landscap|lawn/
        "lawn care, landscaping, seasonal maintenance, and neighborhood property services"
      when /pool/
        "pool cleaning, maintenance, repair, and seasonal service plans"
      when /clean|restoration/
        "cleaning, restoration, maintenance, and property care services"
      when /pest/
        "pest inspections, treatment plans, prevention, and recurring service"
      else
        "local service appointments, inspections, estimates, and seasonal campaign offers"
      end
    end

    def associated_context(crm_record, record_type, max: 3)
      records = associated_records_for(crm_record).select do |record|
        record&.record_type == record_type
      end
      return "not provided" if records.blank?

      records.first(max).map { |record| associated_record_summary(record) }.join(" | ")
    rescue StandardError
      "not provided"
    end

    def playbook_call_context(crm_record, max: 4)
      calls = PlaybookCall.for_crm_record_graph(crm_record).limit(max).to_a
      account_linked = calls.present?
      calls = crm_record.organization.playbook_calls.active.recent.limit(3).to_a if calls.blank?
      return "not provided" if calls.blank?

      prefix = account_linked ? "account-linked call" : "recent unlinked playbook training call"
      calls.map { |call| "#{prefix}: #{call.compact_context(max_chars: 600)}" }.join(" | ")
    rescue StandardError
      "not provided"
    end

    def associated_records_for(crm_record)
      records = []
      crm_record.outbound_associations.includes(:to_record).each { |association| records << association.to_record }
      crm_record.inbound_associations.includes(:from_record).each { |association| records << association.from_record }
      records.compact.uniq(&:id)
    end

    def associated_record_summary(record)
      hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
      properties = hubspot.fetch("properties", {}).to_h
      case record.record_type
      when "company"
        industry = properties["industry"].presence || infer_industry(record.name, nil, record)
        [
          record.name,
          record.domain,
          properties["website"],
          industry,
          [properties["city"], properties["state"], properties["country"]].compact_blank.join(", "),
          properties["lifecyclestage"]
        ].compact_blank.join("; ")
      when "contact"
        [record.name, properties["jobtitle"], properties["company"], properties["lifecyclestage"]].compact_blank.join("; ")
      when "deal"
        [record.name, record.stage, ("$#{record.amount.to_i}" if record.amount.present?), record.close_date&.iso8601].compact_blank.join("; ")
      else
        record.name
      end
    end

    def infer_service_area(description)
      return "your local service area" if description.blank?

      description[/\b(?:in|near|around|serving)\s+([A-Z][A-Za-z .,'-]{2,60})/, 1].presence || "your local service area"
    end

    def infer_target_customer(labeled, raw)
      [labeled["Agency Deal Type"], raw["deal_type"], raw["lifecyclestage"]].compact_blank.join(" / ").presence || "local customers who are most likely to need your services"
    end

    def infer_client_goal(crm_record, labeled, raw)
      labeled["Client Goal"].presence || raw["client_goal"].presence || crm_record.stage.presence || "more qualified leads and stronger neighborhood awareness"
    end
  end
end
