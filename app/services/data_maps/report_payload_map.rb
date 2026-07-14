module DataMaps
  class ReportPayloadMap
    SAMPLE_LIMIT = 500

    REPORT_INPUT_SOURCES = [
      ["Business name", "report_contract.client.business_name", "Company Name label, company_name raw, ticket name"],
      ["Industry", "report_contract.client.industry", "Industry label, industry raw, local service fallback"],
      ["Website", "report_contract.client.website", "Website URL label, website raw"],
      ["Logo / brand colors", "assets.logo_url, assets.logo_endpoint, assets.uploaded_media", "Free Postcard Logo label, uploaded media logo candidate"],
      ["Service area", "report_contract.client.service_area", "Service Area label, service_area raw, inferred from description"],
      ["Target customer", "report_contract.client.target_customer", "Target Customer label, target_customer raw, industry inference"],
      ["Main services/products", "report_contract.client.main_services", "Main Services label, main_services raw, ticket description"],
      ["Average ticket value", "report_contract.client.average_ticket_value", "CRM amount, Average Ticket Value label/raw"],
      ["Busy season", "report_contract.client.busy_season", "Busy Season label/raw, seasonal fallback"],
      ["Slow season", "report_contract.client.slow_season", "Slow Season label/raw, seasonal fallback"],
      ["Current marketing channels", "report_contract.client.current_marketing_channels", "Current Marketing Channels label/raw"],
      ["Current offers/promotions", "report_contract.client.current_offers", "Current Offers label/raw"],
      ["Competitors", "report_contract.client.competitors", "Competitors label/raw"],
      ["Client goal", "report_contract.client.client_goal", "Client Goal label/raw, inferred from ticket status"],
      ["Preferred campaign types", "report_contract.client.preferred_campaign_types", "Preferred Campaign Types label/raw, WIZWIKI default campaign set"],
      ["Special sales notes", "report_contract.client.sales_notes", "Sales Notes label/raw, ticket description"],
      ["Pipeline/status", "report_contract.client.pipeline_status", "Ticket Status, Deal Stage, CRM stage"],
      ["Lead source", "report_contract.client.lead_source", "Latest Traffic Source, analytics source, source_type"],
      ["Company status", "report_contract.client.company_status", "Company Status label, company status raw"],
      ["New/repeat business", "report_contract.client.new_or_repeat", "New Company label, new_or_repeat_business raw"],
      ["CRM used", "report_contract.client.crm_used", "CRM Used label/raw"],
      ["Last contacted", "report_contract.client.last_contacted", "Last Contacted label, notes_last_contacted raw, hs_lastcontacted raw"],
      ["Ticket priority", "report_contract.client.ticket_priority", "Ticket Priority label, hs_ticket_priority raw"],
      ["Ticket category", "report_contract.client.ticket_category", "Ticket Category label, hs_ticket_category raw"],
      ["Ticket source", "report_contract.client.ticket_source", "Ticket Source label, source_type raw"],
      ["Associated company", "account_graph.companies, report_contract.client.associated_company_context", "HubSpot company association"],
      ["Associated contacts", "account_graph.contacts, report_contract.client.associated_contact_context", "HubSpot contact associations"],
      ["Associated deals", "account_graph.deals, report_contract.client.associated_deal_context", "HubSpot deal associations"],
      ["Playbook / Zoom call insights", "playbook_context.calls", "HubSpot calls associated with synced tickets and their account graph"]
    ].freeze

    PAYLOAD_SECTIONS = [
      ["metadata", "Queue request", "Report number, audience, selected multipass lane, writer model, embedder, queued user, selected output mode."],
      ["deal", "Ticket/deal identity", "Local CRM id, HubSpot id, name, company name, stage, status, amount, close date, source timestamps."],
      ["company", "Company snapshot", "Company status, website, industry, CRM used, latest source, last contacted, owner context."],
      ["commerce", "Commerce links", "Amount, quote purchase link, Shopify payment link, Shopify order, Monday order number."],
      ["ai_runtime", "Writer runtime", "Provider, selected local model, qwen-only rule, OpenAI allowance/forbidden-provider policy."],
      ["embedding_runtime", "Embedder runtime", "Selected local embedder and fallback rule for ranking long HubSpot/media/context chunks."],
      ["generation_prompt", "Primary prompt", "The direct instruction block Alice/Qwen uses to create the DOCX report."],
      ["campaign_context", "Campaign context", "Campaign type, logo value, agency deal type, and requested output reminder."],
      ["account_graph", "Associated records", "Companies, contacts, and related deals connected to the ticket through HubSpot associations."],
      ["playbook_context", "Playbook call analyzer", "HubSpot/Zoom playbook call summaries, notes, next actions, and discovery-call insights connected to the ticket/account graph."],
      ["hubspot_context", "HubSpot property cache", "Labeled ticket fields, raw ticket properties, label map, missing core fields, raw property count."],
      ["report_contract", "Report contract", "Required sections, tables, design spec, writing rules, quality gates, manifest schema."],
      ["assets", "Report assets", "Agency logo endpoint, client logo endpoint, uploaded media filenames, content types, sizes, and endpoints."],
      ["output", "Worker endpoints", "DOCX content type, minimum byte gate, heartbeat endpoint, complete endpoint, fail endpoint."]
    ].freeze

    def initialize(organization)
      @organization = organization
    end

    def call
      sampled_tickets = ticket_scope.order(updated_at: :desc).limit(SAMPLE_LIMIT).to_a
      latest_artifact = artifact_scope.includes(:crm_record, :user).order(created_at: :desc).first
      sample_ticket = latest_artifact&.crm_record || sampled_tickets.first
      sample_payload = latest_artifact.present? ? safe_worker_payload(latest_artifact) : nil

      {
        generated_at: Time.current,
        sample_limit: SAMPLE_LIMIT,
        stats: stats,
        sync_status: Hubspot::TicketSyncStatus.for(organization),
        payload_sections: payload_sections(sample_payload),
        report_input_sources: report_input_sources,
        ticket_field_coverage: ticket_field_coverage(sampled_tickets),
        raw_property_names: raw_property_names(sampled_tickets),
        crm_hygiene: crm_hygiene,
        associated_objects: associated_objects,
        report_contract: report_contract_summary,
        sample_ticket: sample_ticket_summary(sample_ticket, sample_payload),
        optimization_notes: optimization_notes
      }
    end

    private

    attr_reader :organization

    def ticket_scope
      organization.crm_records.where(record_type: "ticket", source: "hubspot_ticket")
    end

    def artifact_scope
      organization.crm_record_artifacts.where(artifact_type: "market_report")
    end

    def stats
      {
        tickets: ticket_scope.count,
        tickets_with_labeled_properties: ticket_scope.where("properties -> 'hubspot' -> 'labeled_properties' IS NOT NULL").count,
        tickets_with_raw_properties: ticket_scope.where("properties -> 'hubspot' -> 'properties' IS NOT NULL").count,
        tickets_with_company: association_count("primary_company"),
        tickets_with_contacts: association_count("requester"),
        tickets_with_related_deals: association_count("related_deal"),
        tickets_with_playbook_calls: ticket_scope.joins(:playbook_calls).distinct.count,
        playbook_calls: organization.playbook_calls.count,
        tickets_with_media: ticket_scope.joins(:deal_media_attachments).distinct.count,
        tickets_with_reports: ticket_scope.joins(:crm_record_artifacts).where(crm_record_artifacts: { artifact_type: "market_report" }).distinct.count,
        report_artifacts: artifact_scope.count,
        queued_reports: artifact_scope.where(status: %w[queued generating report_ready]).count,
        completed_reports: DealReports::WorkerQueue.final_scope(artifact_scope).count,
        failed_reports: artifact_scope.where(status: "failed").count
      }
    end

    def association_count(association_type)
      ticket_scope
        .joins(:outbound_associations)
        .where(crm_associations: { association_type: association_type })
        .distinct
        .count
    end

    def safe_worker_payload(artifact)
      DealReports::WorkerQueue.payload_for(artifact)
    rescue StandardError => error
      { "_error" => "#{error.class}: #{error.message}" }
    end

    def payload_sections(sample_payload)
      counts = sample_payload_counts(sample_payload)
      PAYLOAD_SECTIONS.map do |key, title, description|
        {
          key: key,
          title: title,
          description: description,
          sample: counts[key] || "available when a report job exists"
        }
      end
    end

    def sample_payload_counts(payload)
      return {} if payload.blank? || payload["_error"].present?

      account_graph = payload.fetch(:account_graph, payload.fetch("account_graph", {})).to_h
      playbook_context = payload.fetch(:playbook_context, payload.fetch("playbook_context", {})).to_h
      hubspot_context = payload.fetch(:hubspot_context, payload.fetch("hubspot_context", {})).to_h
      assets = payload.fetch(:assets, payload.fetch("assets", {})).to_h
      report_contract = payload.fetch(:report_contract, payload.fetch("report_contract", {})).to_h

      {
        "metadata" => "#{payload.fetch(:metadata, {}).to_h.size} queue keys",
        "deal" => "#{payload.fetch(:deal, {}).to_h.compact.size} fields",
        "company" => "#{payload.fetch(:company, {}).to_h.compact.size} fields",
        "commerce" => "#{payload.fetch(:commerce, {}).to_h.compact.size} fields",
        "ai_runtime" => "#{payload.fetch(:ai_runtime, {}).to_h.compact.size} runtime rules",
        "embedding_runtime" => "#{payload.fetch(:embedding_runtime, {}).to_h.compact.size} embedder rules",
        "generation_prompt" => "#{payload.fetch(:generation_prompt, '').to_s.length} characters",
        "campaign_context" => "#{payload.fetch(:campaign_context, {}).to_h.compact.size} fields",
        "account_graph" => "#{account_graph.fetch(:association_count, account_graph.fetch('association_count', 0))} associated records",
        "playbook_context" => "#{playbook_context.fetch(:included_count, playbook_context.fetch('included_count', 0))} playbook calls",
        "hubspot_context" => "#{hubspot_context.fetch(:property_count, hubspot_context.fetch('property_count', 0))} raw properties",
        "report_contract" => "#{Array(report_contract.fetch(:required_sections, report_contract.fetch('required_sections', []))).size} required sections",
        "assets" => "#{Array(assets.fetch(:uploaded_media, assets.fetch('uploaded_media', []))).size} uploaded files",
        "output" => "#{payload.fetch(:output, {}).to_h.compact.size} endpoint rules"
      }
    end

    def report_input_sources
      REPORT_INPUT_SOURCES.map do |input, payload_key, source|
        {
          input: input,
          payload_key: payload_key,
          source: source
        }
      end
    end

    def ticket_field_coverage(records)
      labels = (Hubspot::TicketSync::REPORT_PROPERTY_LABELS + ["Ticket Status", "Ticket Pipeline", "Ticket owner"]).uniq
      label_map = merged_label_map(records)
      total = records.size

      labels.map do |label|
        present_count = records.count { |record| labeled_properties(record)[label].present? }
        {
          label: label,
          source_property: label_map[label],
          present_count: present_count,
          sample_count: total,
          coverage_percent: total.positive? ? ((present_count.to_f / total) * 100).round : 0
        }
      end
    end

    def merged_label_map(records)
      records.each_with_object({}) do |record, memo|
        label_property_names(record).each do |label, property_name|
          memo[label] ||= property_name
        end
      end
    end

    def raw_property_names(records)
      records.flat_map { |record| raw_properties(record).keys }.map(&:to_s).uniq.sort
    end

    def associated_objects
      Hubspot::AssociatedRecordSync::ASSOCIATION_CONFIG.map do |object_type, config|
        {
          object_type: object_type,
          local_record_type: config.fetch(:record_type),
          source: config.fetch(:source),
          association_type: config.fetch(:association_type),
          properties: config.fetch(:properties)
        }
      end
    end

    def crm_hygiene
      associated_record_ids = organization.crm_associations.pluck(:from_record_id, :to_record_id).flatten.compact.uniq
      unassociated_counts = organization.crm_records
        .where.not(id: associated_record_ids)
        .group(:record_type)
        .count

      {
        summary: {
          total_crm_records: organization.crm_records.count,
          records_by_type: organization.crm_records.group(:record_type).count,
          records_by_status: organization.crm_records.group(:status).count,
          direct_association_edges: organization.crm_associations.count,
          tickets_with_direct_deals: association_count("related_deal"),
          unassociated_records_by_type: unassociated_counts,
          playbook_calls_unlinked: organization.playbook_calls.where(crm_record_id: nil).count,
          failed_report_artifacts: artifact_scope.where(status: "failed").count,
          fileless_artifacts: organization.crm_record_artifacts.where("byte_size IS NULL OR byte_size = 0 OR storage_key IS NULL").count,
          archived_crm_chunks: archived_crm_embedding_count
        },
        duplicate_identity_groups: duplicate_identity_groups,
        unused_record_groups: unused_record_groups(unassociated_counts),
        association_gaps: association_gaps,
        artifact_noise: artifact_noise,
        vector_memory_notes: vector_memory_notes,
        recommendations: crm_hygiene_recommendations(unassociated_counts)
      }
    end

    def duplicate_identity_groups
      [
        duplicate_group("company", "domain", "Company domain duplicates"),
        duplicate_group("contact", "email", "Contact email duplicates"),
        duplicate_group(nil, "phone", "Phone duplicates across CRM records")
      ].compact
    end

    def duplicate_group(record_type, column, title)
      scope = organization.crm_records.where.not(column => [nil, ""])
      scope = scope.where(record_type: record_type) if record_type.present?
      groups = scope
        .group(column)
        .having("count(*) > 1")
        .order(Arel.sql("count_all DESC"))
        .limit(6)
        .count
      return if groups.blank?

      {
        title: title,
        key: column,
        count: groups.size,
        examples: groups.map do |value, count|
          {
            value: value,
            count: count,
            records: scope.where(column => value).order(:id).limit(4).map do |record|
              {
                id: record.id,
                type: record.record_type,
                name: record.name,
                status: record.status
              }
            end
          }
        end
      }
    end

    def unused_record_groups(unassociated_counts)
      sample = organization.crm_records
        .where(record_type: "deal")
        .where.not(id: organization.crm_associations.select(:from_record_id))
        .where.not(id: organization.crm_associations.select(:to_record_id))
        .order(updated_at: :asc)
        .limit(8)
        .map do |record|
          {
            id: record.id,
            name: record.name,
            status: record.status,
            stage: record.stage,
            amount: record.amount&.to_s,
            updated_at: record.updated_at
          }
        end

      [
        {
          title: "Unassociated HubSpot deals",
          count: unassociated_counts.fetch("deal", 0),
          recommendation: "Do not delete. Link these through ticket company/contact second-hop associations, or exclude unlinked deals from default Thumper memory so they do not add unrelated sales noise.",
          examples: sample
        },
        {
          title: "Unassociated companies/contacts",
          count: unassociated_counts.fetch("company", 0).to_i + unassociated_counts.fetch("contact", 0).to_i,
          recommendation: "Review identity merges first. These may be legitimate standalone CRM records, but duplicates should be merged in HubSpot before WIZWIKI treats them as durable training data.",
          examples: []
        }
      ]
    end

    def association_gaps
      active_tickets = ticket_scope.where.not(status: "archived")
      {
        active_tickets: active_tickets.count,
        active_tickets_with_company: active_tickets.joins(:outbound_associations).where(crm_associations: { association_type: "primary_company" }).distinct.count,
        active_tickets_with_contacts: active_tickets.joins(:outbound_associations).where(crm_associations: { association_type: "requester" }).distinct.count,
        active_tickets_with_deals: active_tickets.joins(:outbound_associations).where(crm_associations: { association_type: "related_deal" }).distinct.count,
        note: "HubSpot tickets often have no direct deal edge. WIZWIKI now checks ticket company/contact records for related deals and writes direct related_deal edges back to the ticket graph."
      }
    end

    def artifact_noise
      {
        failed_older_24h: artifact_scope.where(status: "failed").where("updated_at < ?", 24.hours.ago).count,
        generating_older_30m: artifact_scope.where(status: "generating").where("updated_at < ?", 30.minutes.ago).count,
        repeated_report_records: artifact_scope.group(:crm_record_id).having("count(*) > 10").count.map do |record_id, count|
          record = organization.crm_records.find_by(id: record_id)
          {
            record_id: record_id,
            name: record&.name,
            count: count,
            statuses: artifact_scope.where(crm_record_id: record_id).group(:status).count
          }
        end
      }
    end

    def vector_memory_notes
      return { storage_ready: false } unless defined?(AutosEmbeddingChunk) && ActiveRecord::Base.connection.table_exists?(:autos_embedding_chunks)

      scope = AutosEmbeddingChunk.where(organization_id: organization.id)
      {
        storage_ready: true,
        total_chunks: scope.count,
        by_source_type: scope.group(:source_type).count,
        by_model: scope.group(:embedding_model).count,
        by_status: scope.group(:status).count,
        archived_crm_chunks: archived_crm_embedding_count,
        recommendation: "Keep CRM vectors source-backed. Remove or mark stale chunks when a CRM record is archived; do not let old failed report attempts become training truth."
      }
    end

    def archived_crm_embedding_count
      return 0 unless defined?(AutosEmbeddingChunk) && ActiveRecord::Base.connection.table_exists?(:autos_embedding_chunks)

      AutosEmbeddingChunk
        .where(organization_id: organization.id, source_type: "CrmRecord")
        .joins("JOIN crm_records ON crm_records.id = autos_embedding_chunks.source_id")
        .where(crm_records: { status: "archived" })
        .count
    rescue StandardError
      0
    end

    def crm_hygiene_recommendations(unassociated_counts)
      [
        {
          status: "missing-link",
          title: "Pull related deals through company/contact associations",
          body: "The direct ticket->deal edge is usually empty in HubSpot, but associated companies and contacts often have related deals. Syncing those second-hop deals gives reports and /ask more sales context without inventing relationships."
        },
        {
          status: "review",
          title: "Review duplicate identity groups before training",
          body: "Duplicate domains, emails, phones, and normalized addresses should be presented as merge candidates. Keep local records intact until HubSpot is cleaned upstream."
        },
        {
          status: "noise",
          title: "Treat failed report artifacts as cache, not source truth",
          body: "Failed artifacts can remain in the database for debugging and export history, but should not rank ahead of CRM and call facts."
        },
        {
          status: "scope",
          title: "Exclude unlinked deals unless they connect to a ticket graph",
          body: "#{unassociated_counts.fetch('deal', 0)} deal records are currently standalone. They are useful inventory, but weak training context until attached to tickets, companies, or contacts."
        }
      ]
    end

    def report_contract_summary
      min_bytes = DealReports::WorkerQueue::MINIMUM_DOCX_BYTES
      {
        version: DealReports::MarketStrategyContract::VERSION,
        input_schema: DealReports::MarketStrategyContract.input_schema,
        client_sections: DealReports::MarketStrategyContract.required_sections("client").map { |section| section.fetch(:title, section["title"]) },
        am_sections: DealReports::MarketStrategyContract.required_sections("am").map { |section| section.fetch(:title, section["title"]) },
        client_tables: DealReports::MarketStrategyContract.required_tables("client").map { |table| table.fetch(:title, table["title"]) },
        am_tables: DealReports::MarketStrategyContract.required_tables("am").map { |table| table.fetch(:title, table["title"]) },
        client_quality_gate: DealReports::MarketStrategyContract.quality_gate(min_bytes, audience: "client"),
        am_quality_gate: DealReports::MarketStrategyContract.quality_gate(min_bytes, audience: "am")
      }
    end

    def sample_ticket_summary(record, payload)
      return unless record

      graph = payload.to_h.fetch(:account_graph, payload.to_h.fetch("account_graph", {})).to_h
      context = payload.to_h.fetch(:hubspot_context, payload.to_h.fetch("hubspot_context", {})).to_h
      assets = payload.to_h.fetch(:assets, payload.to_h.fetch("assets", {})).to_h
      latest_artifact = record.crm_record_artifacts.where(artifact_type: "market_report").order(created_at: :desc).first

      {
        id: record.id,
        hubspot_id: record.source_uid,
        name: record.name,
        stage: record.stage,
        status: record.status,
        raw_property_count: raw_properties(record).size,
        labeled_property_count: labeled_properties(record).size,
        missing_core_fields: Array(context.fetch(:missing_core_fields, context.fetch("missing_core_fields", []))),
        associations: {
          companies: Array(graph.fetch(:companies, graph.fetch("companies", []))).size,
          contacts: Array(graph.fetch(:contacts, graph.fetch("contacts", []))).size,
          deals: Array(graph.fetch(:deals, graph.fetch("deals", []))).size
        },
        media_count: Array(assets.fetch(:uploaded_media, assets.fetch("uploaded_media", []))).size,
        latest_report: latest_artifact && {
          id: latest_artifact.id,
          title: latest_artifact.title,
          status: latest_artifact.status,
          audience: latest_artifact.metadata.to_h["report_audience"].presence || "client",
          model: latest_artifact.metadata.to_h.dig("manifest", "model").presence || latest_artifact.metadata.to_h["report_local_model"],
          embedder: latest_artifact.metadata.to_h.dig("manifest", "embedder_model").presence || latest_artifact.metadata.to_h["report_embedder_model"]
        }
      }
    end

    def labeled_properties(record)
      record.properties.to_h.dig("hubspot", "labeled_properties").to_h
    end

    def label_property_names(record)
      record.properties.to_h.dig("hubspot", "label_property_names").to_h
    end

    def raw_properties(record)
      record.properties.to_h.dig("hubspot", "properties").to_h
    end

    def optimization_notes
      [
        {
          status: "strong",
          title: "Ticket payload is being used",
          body: "The report worker sends both labeled HubSpot ticket fields and raw ticket properties to Alice/Qwen, plus a missing-core-fields list."
        },
        {
          status: "strong",
          title: "Associations are reaching the worker",
          body: "Company, contact, and related deal associations are synced into account_graph and sent with their compact raw HubSpot properties."
        },
        {
          status: "watch",
          title: "Associated records are raw-key heavy",
          body: "Associated company/contact/deal records do not currently carry labeled_properties. Reports still receive the data, but labels would help local LLMs reason faster and write cleaner."
        },
        {
          status: "watch",
          title: "Two mapping names should be tightened",
          body: "campaign_context should fall back to Ticket Description, and company owner context should use Ticket owner when Deal owner is blank."
        },
        {
          status: "next",
          title: "Best next optimization",
          body: "Add selected labeled fields for associated companies, contacts, and deals, then call those fields out in report_contract.client so Qwen sees service area, domain, industry, owner, amount, and stage without decoding raw keys."
        }
      ]
    end
  end
end
