require "digest"

module Autos
  class ContextBuilder
    SNIPPET_LIMIT = 900
    TERM_LIMIT = 18
    STOPWORDS = %w[
      able about athumperrtising after again all also an and answer any are around ask asking build
      audience campaign can copy create data does dont fresh from have include information into its let's like look
      need our pertinent please proceed provide should some specific target their them then
      there they this using want website with would you your we to for if in up see it the
      codes let lets service services u0027s us provide provided hit using zip zipcode
    ].freeze

    def self.call(record)
      if cacheable_record?(record)
        Autos::ContextCache.fetch(context_cache_key(record), expires_in: Autos::ContextCache.short_ttl) do
          new(record).call
        end
      else
        new(record).call
      end
    end

    def self.cacheable_record?(record)
      defined?(Autos::ContextCache) && record.is_a?(AutosQuestion) && record.organization_id.present?
    end

    def self.context_cache_key(record)
      digest = Digest::SHA256.hexdigest([
        record.question.to_s,
        record.context.to_s,
        record.metadata.to_h.slice("surface", "full_talk", "answer_style").to_json,
        record.user_id
      ].join("\n"))
      ["autos_context_builder", record.organization_id, record.id || "warmup", digest]
    end

    def initialize(record)
      @record = record
      @organization = record.organization
    end

    def call
      sections = []
      fathom_context = fathom_call_context
      sections << fathom_context if fathom_prompt?
      sections << crm_context
      sections << design_order_context
      sections << employee_profile_context
      sections << fine_training_voice_context
      sections << training_context
      sections << playbook_account_candidate_context
      sections << playbook_call_context
      sections << fathom_context unless fathom_prompt?
      sections << current_chat_memory_context
      sections << prior_question_context
      sections << build_context

      context = sections.compact.join("\n\n")
      context = context.first(WizwikiSettings.openai_max_context_chars)

      {
        text: context.presence || "No local Thumper context was found for this organization.",
        counts: @counts || {}
      }
    end

    private

    attr_reader :record, :organization

    def crm_context
      records = relevant_crm_records
      count(:crm_records, records.length)
      return if records.blank?

      lines = records.map do |crm_record|
        properties = crm_record.properties.to_h.slice("lead_type", "package", "callback_channel", "payment_status", "stage")
        [
          "- #{crm_record.record_type.upcase}: #{crm_record.name}",
          crm_record.email.present? ? "email=#{crm_record.email}" : nil,
          crm_record.phone.present? ? "phone=#{crm_record.phone}" : nil,
          crm_record.domain.present? ? "domain=#{crm_record.domain}" : nil,
          crm_record.stage.present? ? "stage=#{crm_record.stage}" : nil,
          crm_record.status.present? ? "status=#{crm_record.status}" : nil,
          properties.present? ? "properties=#{properties.to_json}" : nil,
          crm_record.amount.present? ? "amount=#{crm_record.amount}" : nil,
          crm_record.close_date.present? ? "close_date=#{crm_record.close_date}" : nil
        ].compact.join(" | ")
      end

      "CRM RECORDS\n#{lines.join("\n")}"
    end

    def design_order_context
      total_count = organization.design_orders.count
      queue_count = organization.design_orders.queued.count
      complete_count = organization.design_orders.complete.count
      orders = relevant_design_orders
      count(:design_orders_total, total_count)
      count(:design_orders_queue, queue_count)
      count(:design_orders_complete, complete_count)
      count(:design_orders_sample, orders.length)

header = [
  "DESIGN ORDERS",
  "total=#{total_count} | queue=#{queue_count} | complete=#{complete_count} | showing=#{orders.length}",
  design_workload_lines.presence,
  design_capacity_lines.presence,
  oldest_design_order_lines.presence
].compact.join("\n")
return header if orders.blank?

      lines = orders.map do |order|
        [
          "- DESIGN ORDER: #{order.item_name}",
          order.order_number.present? ? "order=#{order.order_number}" : nil,
          order.customer_email.present? ? "customer_email=#{order.customer_email}" : nil,
          order.product_name.present? ? "product=#{order.product_name}" : nil,
          order.designer_name.present? ? "designer=#{order.designer_name}" : nil,
          order.start_date.present? ? "start_date=#{order.start_date}" : nil,
          order.biz_days_overall.present? ? "biz_days_overall=#{order.biz_days_overall}" : nil,
          order.revisions.present? ? "revisions=#{order.revisions}" : nil,
          "status=#{order.queue_status_label}"
        ].compact.join(" | ")
      end

      "#{header}\n#{lines.join("\n")}"
    end

    def fine_training_voice_context
      return uncached_fine_training_voice_context unless defined?(Autos::ContextCache)

      Autos::ContextCache.fetch(["ask_fine_training_voice_context", organization.id], expires_in: Autos::ContextCache.medium_ttl) do
        uncached_fine_training_voice_context
      end
    end

    def uncached_fine_training_voice_context
      scope = organization.training_documents.where.not(status: "archived")
      return if scope.none?

      total = scope.count
      status_counts = scope.group(:status).count
      chunk_counts = fine_training_chunk_counts(scope)
      count(:fine_training_documents_total, total)
      count(:fine_training_documents_indexed, status_counts["indexed"].to_i)
      count(:fine_training_chunks_embedded, chunk_counts["embedded"].to_i)

      titles = scope.order(:title).limit(250).pluck(:title).compact_blank
      lines = [
        "Thumper FINE TRAINING VOICE MEMORY",
        "Use organization-owned documents marked training_priority=paramount as the governing Thumper guidance. Treat them as style and process guidance, not independent factual authority.",
        Thumper::VoiceGuide.system,
        "Vector retrieval policy: retrieve organization-owned TrainingDocument chunks from the configured WIZWIKI scope with #{Autos::WorkerQueue.embedder_model} before drafting copy. Treat matched chunks as operator-supplied guidance, never as unverified facts.",
        "Document inventory: total=#{total} | indexed=#{status_counts["indexed"].to_i} | processing=#{status_counts["processing"].to_i} | new=#{status_counts["ingested"].to_i}",
        chunk_counts.present? ? "Vector chunks: #{chunk_counts.sort.map { |status, amount| "#{status}=#{amount}" }.join(" | ")}" : nil,
        "Do not dump file names into client-facing copy. Use the corpus to shape tone, confidence, clarity, and sales rhythm.",
        titles.present? ? "Inventory titles: #{titles.join(" | ")}" : nil
      ].compact
      lines.join("\n")
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def training_context
      documents = relevant_training_documents
      count(:training_documents, documents.length)
      return if documents.blank?

      lines = documents.map do |document|
        body = clean(document.body).truncate(SNIPPET_LIMIT, omission: "...")
        "- #{document.title} (#{document.source_type}, #{document.created_at.to_date}): #{body}"
      end

      "TRAINING DOCUMENT SAMPLES\n#{lines.join("\n")}"
    end

    def playbook_account_candidate_context
      return unless account_analysis_prompt?

      calls = organization.playbook_calls.active.recent.limit(40).to_a
      grouped = {}

      calls.each do |call|
        records = Autos::WorkerQueue.associated_records_for_call(call)
        account_record = records.find { |item| item.record_type == "company" } ||
          records.find { |item| %w[deal ticket].include?(item.record_type) } ||
          records.find { |item| item.record_type == "contact" }
        contact_record = records.find { |item| item.record_type == "contact" }
        key = account_record.present? ? "crm:#{account_record.id}" : "call:#{call_title_contact(call).presence || call.id}"
        candidate = grouped[key] ||= {
          account: account_label_for(account_record, call),
          contact: contact_label_for(contact_record, account_record, call),
          preferred_contact: preferred_contact_for(contact_record, account_record),
          link: record_link_for(account_record),
          calls: 0,
          last_call_at: nil,
          outcomes: [],
          owners: [],
          titles: [],
          next_actions: []
        }
        candidate[:calls] += 1
        candidate[:last_call_at] = [candidate[:last_call_at], call.occurred_at].compact.max
        candidate[:outcomes] << call.call_disposition if call.call_disposition.present?
        candidate[:owners] << call.owner_name if call.owner_name.present?
        candidate[:titles] << call.title if call.title.present?
        candidate[:next_actions] << call.suggested_next_actions if call.suggested_next_actions.present?
      end

      candidates = grouped.values.sort_by do |candidate|
        [
          -candidate[:calls].to_i,
          candidate[:last_call_at].present? ? -candidate[:last_call_at].to_i : 0,
          candidate[:account].to_s.downcase
        ]
      end.first(10)
      count(:playbook_account_candidates, candidates.length)
      return if candidates.blank?

      lines = candidates.map do |candidate|
        [
          "- ACCOUNT CANDIDATE: #{candidate[:account]}",
          "contact=#{candidate[:contact]}",
          "preferred_contact=#{candidate[:preferred_contact]}",
          "calls=#{candidate[:calls]}",
          candidate[:last_call_at].present? ? "last_call=#{candidate[:last_call_at].iso8601}" : nil,
          candidate[:outcomes].present? ? "outcomes=#{candidate[:outcomes].uniq.first(3).join(', ')}" : nil,
          candidate[:owners].present? ? "owners=#{candidate[:owners].uniq.first(3).join(', ')}" : nil,
          candidate[:link].present? ? "link=#{candidate[:link]}" : nil,
          "why_now=#{candidate_why_now(candidate)}",
          "next_action=#{candidate_next_action(candidate)}",
          candidate[:titles].present? ? "evidence=#{candidate[:titles].uniq.first(3).join(' / ')}" : nil
        ].compact.join(" | ")
      end

      "PLAYBOOK ACCOUNT CANDIDATES\n#{lines.join("\n")}"
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def playbook_call_context
      calls = relevant_playbook_calls
      count(:playbook_calls, calls.length)
      return if calls.blank?

      lines = calls.map do |call|
        "- #{clean(call.compact_context(max_chars: SNIPPET_LIMIT))}"
      end

      "PLAYBOOK CALL ANALYZER\n#{lines.join("\n")}"
    end

    def fathom_call_context
      return unless organization.respond_to?(:fathom_calls)

      total_count = organization.fathom_calls.active.count
      calls = relevant_fathom_calls
      count(:fathom_calls_total, total_count)
      count(:fathom_calls_sample, calls.length)

      chunk_counts = fathom_chunk_counts
      header = [
        "FATHOM BRAIN CALLS",
        "Thumper has access to synced Fathom meeting data stored for this WIZWIKI organization.",
        "Use Fathom calls for recent client conversations, meeting summaries, action items, participants, recording links, CRM matches, and transcript-backed context.",
        "Inventory: total=#{total_count} | showing=#{calls.length}",
        chunk_counts.present? ? "Vector chunks: #{chunk_counts.sort.map { |status, amount| "#{status}=#{amount}" }.join(" | ")}" : nil,
        "If asked whether Fathom calls are available, answer yes when total is above zero and describe the newest synced calls."
      ].compact

      return header.join("\n") if calls.blank?

      lines = calls.map do |call|
        [
          "- #{clean(call.compact_context(max_chars: SNIPPET_LIMIT))}",
          call.share_url.present? ? "link=#{call.share_url}" : nil,
          call.crm_matches.present? ? "crm_matches=#{call.crm_matches.to_json.truncate(320)}" : nil
        ].compact.join(" | ")
      end

      "#{header.join("\n")}\n#{lines.join("\n")}"
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def prior_question_context
      scope = organization.autos_questions.where(status: "answered")
      scope = scope.where.not(id: record.id) if record.is_a?(AutosQuestion)
      questions = useful_prior_questions(scope.recent.limit(20).to_a).first(6)
      count(:prior_questions, questions.length)
      return if questions.blank?

      lines = questions.map do |item|
        "- Q: #{clean(item.question).truncate(240)} | A: #{clean(item.answer).truncate(360)}"
      end

      "RECENT ANSWERED Thumper QUESTIONS\n#{lines.join("\n")}"
    end

    def current_chat_memory_context
      return unless record.is_a?(AutosQuestion)

      questions = organization.autos_questions
        .where(user_id: record.user_id, status: "answered")
        .where.not(id: record.id)
        .where("created_at >= ?", 6.hours.ago)
        .recent
        .limit(20)
        .to_a
      questions = useful_prior_questions(questions).first(10)
      count(:current_chat_memory, questions.length)
      return if questions.blank?

      lines = questions.reverse.map.with_index(1) do |item, index|
        [
          "#{index}. employee asked=#{clean(item.question).truncate(360)}",
          "Thumper answered=#{clean(item.answer).truncate(460)}"
        ].join(" | ")
      end

      "CURRENT USER CHAT MEMORY (LAST 6 HOURS)\n#{lines.join("\n")}"
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def build_context
      scope = organization.build_requests.recent
      scope = scope.where.not(id: record.id) if record.is_a?(BuildRequest)
      requests = scope.limit(6).to_a
      count(:build_requests, requests.length)
      return if requests.blank?

      lines = requests.map do |request|
        answer = request.metadata.to_h.dig("autos_build", "answer")
        [
          "- #{request.title}",
          "area=#{request.target_area}",
          "status=#{request.status}",
          "prompt=#{clean(request.prompt).truncate(420)}",
          answer.present? ? "THUMPER_build=#{clean(answer).truncate(420)}" : nil
        ].compact.join(" | ")
      end

      "BUILD REQUESTS\n#{lines.join("\n")}"
    end

def design_workload_lines
  rows = organization.design_orders.queued.group(:designer_name).pluck(
    :designer_name,
    Arel.sql("COUNT(*)"),
    Arel.sql("MAX(COALESCE(biz_days_overall, 0))"),
    Arel.sql("ROUND(AVG(COALESCE(biz_days_overall, 0))::numeric, 1)"),
    Arel.sql("SUM(COALESCE(revisions, 0))")
  )
  return if rows.blank?

  lines = rows.sort_by { |(_designer, count, max_days, avg_days, revisions)| [-count.to_i, -max_days.to_i, -avg_days.to_f, -revisions.to_i] }.map do |designer, count, max_days, avg_days, revisions|
    "- DESIGNER LOAD: #{designer.presence || 'unassigned'} | queue=#{count} | oldest_days=#{max_days} | avg_days=#{avg_days} | revisions=#{revisions}"
  end

  "DESIGNER WORKLOAD\n#{lines.join("\n")}"
rescue ActiveRecord::StatementInvalid
  nil
end

def design_capacity_lines
  rows = organization.design_orders.queued.where.not(designer_name: [nil, ""]).group(:designer_name).pluck(
    :designer_name,
    Arel.sql("COUNT(*)"),
    Arel.sql("MAX(COALESCE(biz_days_overall, 0))"),
    Arel.sql("ROUND(AVG(COALESCE(biz_days_overall, 0))::numeric, 1)"),
    Arel.sql("SUM(COALESCE(revisions, 0))")
  )
  return if rows.blank?

  lines = rows.sort_by { |(_designer, count, max_days, avg_days, revisions)| [count.to_i, max_days.to_i, avg_days.to_f, revisions.to_i] }.first(8).map.with_index(1) do |(designer, count, max_days, avg_days, revisions), index|
    "- EXTRA ASSIGNMENT CANDIDATE ##{index}: #{designer} | current_queue=#{count} | oldest_days=#{max_days} | avg_days=#{avg_days} | revisions=#{revisions}"
  end

  "DESIGNER CAPACITY FOR EXTRA ASSIGNMENTS\n#{lines.join("\n")}"
rescue ActiveRecord::StatementInvalid
  nil
end

def oldest_design_order_lines
  orders = organization.design_orders.queued
    .order(Arel.sql("COALESCE(biz_days_overall, 0) DESC"), :start_date)
    .limit(5)
  return if orders.blank?

  lines = orders.map do |order|
    [
      "- OLDEST DESIGN: #{order.item_name}",
      order.designer_name.present? ? "designer=#{order.designer_name}" : nil,
      order.product_name.present? ? "product=#{order.product_name}" : nil,
      order.order_number.present? ? "order=#{order.order_number}" : nil,
      order.biz_days_overall.present? ? "days=#{order.biz_days_overall}" : nil,
      order.revisions.present? ? "revisions=#{order.revisions}" : nil
    ].compact.join(" | ")
  end

  "OLDEST QUEUE\n#{lines.join("\n")}"
rescue ActiveRecord::StatementInvalid
  nil
end

def employee_profile_context
  total_count = organization.employee_profiles.count
  active_count = organization.employee_profiles.activeish.count
  invite_ready_count = organization.employee_profiles.select(&:invite_ready?).count
  executive_count = organization.employee_profiles.executives.count
  profiles = relevant_employee_profiles
  count(:employee_profiles_total, total_count)
  count(:employee_profiles_activeish, active_count)
  count(:employee_profiles_invite_ready, invite_ready_count)
  count(:employee_profiles_executives, executive_count)
  count(:employee_profiles_sample, profiles.length)

  header = [
    "TEAM + CLIFTON STRENGTHS",
    "profiles=#{total_count} | activeish=#{active_count} | invite_ready=#{invite_ready_count} | exec_or_leader=#{executive_count}",
    clifton_domain_summary.presence,
    clifton_trait_summary.presence
  ].compact.join("\n")
  return header if profiles.blank?

  lines = profiles.map do |profile|
    strengths = profile.top_strengths(5)
    domains = profile.clifton_domains(5).map { |domain| EmployeeProfile.clifton_domain_label(domain) }
    [
      "- TEAMMATE: #{profile.display_name}",
      profile.role_title.present? ? "role=#{profile.role_title}" : nil,
      profile.team_name.present? ? "team=#{profile.team_name}" : nil,
      profile.department.present? ? "department=#{profile.department}" : nil,
      profile.recommended_role.present? ? "recommended_role=#{profile.recommended_role}" : nil,
      profile.executive_profile? ? "exec_or_leader=yes" : nil,
      "admin_level=#{profile.admin_level}",
      strengths.present? ? "strengths=#{strengths.join(', ')}" : nil,
      domains.present? ? "domains=#{domains.join(', ')}" : nil,
      profile.status_label.present? ? "profile_status=#{profile.status_label}" : nil
    ].compact.join(" | ")
  end

  "#{header}\n#{lines.join("\n")}"
rescue ActiveRecord::StatementInvalid
  nil
end

def clifton_domain_summary
  rows = organization.employee_profiles.with_top_strengths.to_a.flat_map { |profile| profile.clifton_domains(5) }.tally
  return if rows.blank?

  "CLIFTON DOMAIN COUNTS: " + rows.sort_by { |_domain, total| -total }.map { |domain, total| "#{EmployeeProfile.clifton_domain_label(domain)}=#{total}" }.join(" | ")
end

def clifton_trait_summary
  traits = organization.employee_profiles.with_top_strengths.pluck(:strength_1, :strength_2, :strength_3).flatten.compact_blank.tally
  return if traits.blank?

  "TOP SHARED TRAITS: " + traits.sort_by { |trait, total| [-total, trait] }.first(12).map { |trait, total| "#{trait}=#{total}" }.join(" | ")
end

def relevant_employee_profiles
  scoped = organization.employee_profiles.ordered_by_name
  matched = records_matching(scoped, [
    "first_name", "last_name", "email", "team_name", "department", "role_title", "recommended_role",
    "strength_1", "strength_2", "strength_3", "strength_4", "strength_5", "raw_payload::text"
  ])
  (matched.presence || scoped.limit(12)).to_a.first(12)
rescue ActiveRecord::StatementInvalid
  []
end

    def relevant_crm_records
      scoped = organization.crm_records.order(updated_at: :desc)
      matched = records_matching(scoped, ["name", "email", "phone", "domain", "source", "stage", "status", "properties::text"])
      (matched.presence || scoped.limit(10)).to_a.first(10)
    end

    def relevant_design_orders
      scoped = organization.design_orders.queued.order(updated_at: :desc)
      matched = records_matching(scoped, ["item_name", "customer_email", "order_number", "designer_name", "product_name", "monday_url", "raw_payload::text"])
      (matched.presence || scoped.limit(10)).to_a.first(10)
    rescue ActiveRecord::StatementInvalid
      []
    end

    def relevant_training_documents
      scoped = organization.training_documents.where(status: TrainingDocument::STATUSES - ["archived"]).order(updated_at: :desc)
      priority = scoped.where(
        "metadata ->> 'training_priority' = :priority OR metadata ->> 'priority' = :priority OR metadata ->> 'retrieval_priority' = :priority",
        priority: "paramount"
      ).limit(4).to_a
      matched = records_matching(scoped, ["title", "source_type", "body"])
      (priority + (matched.presence || scoped.limit(12)).to_a).uniq.first(12)
    end

    def fine_training_chunk_counts(scope)
      return {} unless defined?(AutosEmbeddingChunk) && Autos::EmbeddingQueue.storage_ready?

      if defined?(Autos::ContextCache)
        Autos::ContextCache.fetch(["ask_fine_training_chunk_counts", organization.id, Autos::WorkerQueue.embedder_model], expires_in: Autos::ContextCache.medium_ttl) do
          fine_training_chunk_counts_uncached(scope)
        end
      else
        fine_training_chunk_counts_uncached(scope)
      end
    rescue StandardError
      {}
    end

    def fine_training_chunk_counts_uncached(scope)
      AutosEmbeddingChunk.where(
        organization: organization,
        source_type: "TrainingDocument",
        source_id: scope.select(:id),
        embedding_model: Autos::WorkerQueue.embedder_model
      ).group(:status).count
    end

    def relevant_playbook_calls
      scoped = if record.respond_to?(:crm_record) && record.crm_record.present?
        PlaybookCall.for_crm_record_graph(record.crm_record)
      elsif record.is_a?(AutosQuestion)
        organization.playbook_calls.active.recent
      else
        organization.playbook_calls.active.recent
      end

      matched = records_matching(scoped, ["title", "summary", "notes", "suggested_next_actions", "analyzer_text", "playbook_data::text"])
      limit = playbook_call_limit
      (matched.presence || scoped.limit(limit)).to_a.first(limit)
    rescue ActiveRecord::StatementInvalid
      []
    end

    def account_analysis_prompt?
      return false unless record.is_a?(AutosQuestion)

      searchable_text.downcase.match?(/\b(playbook|calls?|accounts?|companies?|connect with|call today|who should|prospects?|leads?|preferred method|contact name)\b/)
    end

    def playbook_call_limit
      account_analysis_prompt? ? 24 : 6
    end

    def relevant_fathom_calls
      return [] unless organization.respond_to?(:fathom_calls)

      scoped = organization.fathom_calls.active.recent
      matched = records_matching(scoped, [
        "title", "meeting_title", "recorded_by_name", "recorded_by_email", "meeting_type",
        "summary", "action_items_text", "highlights_text", "transcript", "crm_matches::text", "raw_payload::text"
      ])
      limit = fathom_call_limit
      (matched.presence || scoped.limit(limit)).to_a.first(limit)
    rescue ActiveRecord::StatementInvalid
      []
    end

    def fathom_call_limit
      return 12 if fathom_prompt?

      6
    end

    def fathom_prompt?
      searchable_text.downcase.match?(/\bfathom|meeting recorder|recordings?|transcripts?|call summaries?|meeting summaries?\b/)
    end

    def fathom_chunk_counts
      return {} unless defined?(AutosEmbeddingChunk) && Autos::EmbeddingQueue.storage_ready?
      return {} unless organization.respond_to?(:fathom_calls)

      if defined?(Autos::ContextCache)
        Autos::ContextCache.fetch(["ask_fathom_chunk_counts", organization.id, Autos::WorkerQueue.embedder_model], expires_in: Autos::ContextCache.medium_ttl) do
          fathom_chunk_counts_uncached
        end
      else
        fathom_chunk_counts_uncached
      end
    rescue StandardError
      {}
    end

    def fathom_chunk_counts_uncached
      AutosEmbeddingChunk.where(
        organization: organization,
        source_type: "FathomCall",
        source_id: organization.fathom_calls.active.select(:id),
        embedding_model: Autos::WorkerQueue.embedder_model
      ).group(:status).count
    end

    def account_label_for(account_record, call)
      account_record&.name.presence || call_title_contact(call).presence || call.title.presence || "Playbook call #{call.hubspot_call_id}"
    end

    def contact_label_for(contact_record, account_record, call)
      contact_record&.name.presence || (account_record&.record_type == "contact" ? account_record.name : nil).presence || call_title_contact(call).presence || "not found"
    end

    def preferred_contact_for(contact_record, account_record)
      records = [contact_record, account_record].compact
      phone = records.map(&:phone).find(&:present?)
      email = records.map(&:email).find(&:present?)
      return "phone #{phone}; email #{email}" if phone.present? && email.present?
      return "phone #{phone}" if phone.present?
      return "email #{email}" if email.present?

      "not found"
    end

    def record_link_for(crm_record)
      return if crm_record.blank?

      Rails.application.routes.url_helpers.crm_record_path(crm_record)
    rescue StandardError
      nil
    end

    def candidate_why_now(candidate)
      outcomes = candidate[:outcomes].join(" ").downcase
      return "multiple recent playbook touches need follow-up" if candidate[:calls].to_i > 1
      return "recent missed or unanswered call needs recovery" if outcomes.match?(/no answer|voicemail|left message|missed/)
      return "recent answered call has follow-up potential" if outcomes.match?(/answered|connected/)

      "recent playbook activity indicates timely outreach"
    end

    def candidate_next_action(candidate)
      candidate[:next_actions].compact_blank.first.to_s.truncate(180).presence || "review the call notes and contact this account today"
    end

    def call_title_contact(call)
      call.title.to_s.sub(/\ACall with\s+/i, "").strip.presence
    end

    def records_matching(scope, columns)
      return scope.none if query_terms.blank?

      relation = query_terms.reduce(scope.none) do |memo, term|
        searchable_columns = query_columns_for(term, columns)
        next memo if searchable_columns.blank?

        if short_code_query_term?(term)
          pattern = "(^|[^[:alnum:]])#{Regexp.escape(term)}([^[:alnum:]]|$)"
          clause = searchable_columns.map { |column| "#{column} ~* :pattern" }.join(" OR ")
          memo.or(scope.where(clause, pattern: pattern))
        else
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
          clause = searchable_columns.map { |column| "#{column} ILIKE :pattern" }.join(" OR ")
          memo.or(scope.where(clause, pattern: pattern))
        end
      end

      relation.limit(80).to_a
        .sort_by { |item| [-record_match_score(item), -(item.try(:updated_at)&.to_i || 0)] }
        .first(12)
    rescue ActiveRecord::StatementInvalid
      scope.none
    end

    def query_terms
      @query_terms ||= begin
        normalized_text = searchable_text.downcase
        raw_tokens = normalized_text.scan(/[a-z0-9@._+-]{2,}/).map { |token| normalize_query_token(token) }.reject(&:blank?)
        tokens = raw_tokens.reject { |token| STOPWORDS.include?(token) }
        important = tokens.select { |token| important_query_term?(token) }
        business_pairs = raw_tokens.each_cons(2)
          .select { |left, right| !STOPWORDS.include?(left) && !STOPWORDS.include?(right) }
          .select { |left, right| important_query_term?(left) && important_query_term?(right) }
          .map { |left, right| "#{left} #{right}" }
        (business_pairs + important + tokens).uniq.first(TERM_LIMIT)
      end
    end

    def normalize_query_token(token)
      token.to_s.downcase.gsub(/\A[^a-z0-9]+|[^a-z0-9]+\z/, "")
    end

    def important_query_term?(term)
      term.match?(/\A[a-z]+\d+\z|\A\d+[a-z]+\z|\A[a-z]\d+\z|\A[a-z]{1,2}\d{1,3}\z/) ||
        term.match?(/plumb|roof|hvac|dental|pool|pest|lawn|landscap|window|garage|paint|remodel|exterior|comfort|sunshine|aspin|a1/)
    end

    def record_match_score(item)
      text = item.attributes.to_json.downcase
      query_terms.sum do |term|
        if term.include?(" ") && record_text_includes_term?(text, term)
          80
        elsif important_query_term?(term) && record_text_includes_term?(text, term)
          25
        elsif record_text_includes_term?(text, term)
          3
        else
          0
        end
      end
    end

    def query_columns_for(term, columns)
      return columns unless short_code_query_term?(term)

      columns.reject do |column|
        column.include?("::text") ||
          column.include?("raw_payload") ||
          column.include?("properties") ||
          column.include?("playbook_data") ||
          column.include?("analyzer_text")
      end
    end

    def short_code_query_term?(term)
      term.match?(/\A[a-z]{1,2}\d{1,3}\z|\A\d{1,3}[a-z]{1,2}\z/)
    end

    def record_text_includes_term?(text, term)
      return text.include?(term) unless short_code_query_term?(term)

      text.match?(/(^|[^a-z0-9])#{Regexp.escape(term)}([^a-z0-9]|$)/)
    end

    def useful_prior_questions(questions)
      questions.reject { |item| context_miss_answer?(item.answer) }
    end

    def context_miss_answer?(answer)
      text = answer.to_s.downcase
      text.include?("provided context does not include") ||
        text.include?("does not include specific data") ||
        text.include?("would need to first confirm") ||
        text.include?("need to first confirm if") ||
        text.include?("no local thumper context")
    end

    def searchable_text
      case record
      when AutosQuestion
        [question_text_for_search(record.question), record.context].join(" ")
      when BuildRequest
        [record.title, record.target_area, record.prompt].join(" ")
      when DesignOrder
        [record.item_name, record.order_number, record.customer_email, record.designer_name, record.product_name].join(" ")
      else
        record.to_s
      end
    end

    def question_text_for_search(value)
      text = value.to_s
      text = text.split(/\n\s*(?:THUMPER|AUTOS|WIZWIKI)\s*\/\/\s*answer stream/i).first || text
      text = text.lines.reject do |line|
        line.match?(/\A\s*(answered\s*\/\/|local_cc\s*\/\/|openai\s*\/\/|YOU\s*\z|STOP\s*\z|THUMPER\s*\/\/|AUTOS\s*\/\/|WIZWIKI\s*\/\/)/i)
      end.join
      text.squish
    end

    def clean(value)
      value.to_s.squish
    end

    def count(key, value)
      @counts ||= {}
      @counts[key] = value
    end
  end
end
