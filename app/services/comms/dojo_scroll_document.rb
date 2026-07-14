require "erb"

module Comms
  class DojoScrollDocument
    FOLDER_NAME = "Thumper dojo scrolls".freeze

    class << self
      def publish(organization:, date:, embedding_status: {}, session: nil, drive_client: GoogleWorkspace::DriveClient.new)
        new(
          organization: organization,
          date: date,
          embedding_status: embedding_status,
          session: session,
          drive_client: drive_client
        ).publish
      end
    end

    def initialize(organization:, date:, embedding_status:, session:, drive_client:)
      @organization = organization
      @date = parse_date(date)
      @embedding_status = embedding_status.to_h
      @session = session.to_h
      @drive_client = drive_client
    end

    def publish
      return skipped_result("no dojo scorecards for #{date.iso8601}") if scorecards.blank?

      folder = drive_client.find_or_create_folder(
        name: FOLDER_NAME,
        parent_id: ENV["THUMPER_DOJO_GOOGLE_DRIVE_PARENT_FOLDER_ID"].presence || ENV["GOOGLE_DRIVE_FOLDER_ID"].presence
      )
      share_file(folder["id"]) if folder["id"].present? && share_anyone_enabled?

      google_doc = drive_client.upsert_google_doc(
        name: document_name,
        html: html_document,
        folder_id: folder["id"].presence
      )
      share_file(google_doc["id"]) if google_doc["id"].present? && share_anyone_enabled?
      session_google_doc = publish_session_doc(folder)

      {
        ok: true,
        date: date.iso8601,
        scorecards: scorecards.length,
        pass_count: pass_count,
        review_count: review_count,
        average_score: average_score,
        folder: folder,
        google_doc: google_doc,
        session_google_doc: session_google_doc,
        session_scorecards: session_google_doc.present? ? session_scorecards.length : nil,
        embedding_status: embedding_status
      }.compact_blank
    end

    private

    attr_reader :organization, :date, :embedding_status, :session, :drive_client

    def document_name
      "Thumper DOJO Scroll - #{date.strftime('%Y-%m-%d')}"
    end

    def session_document_name
      generation = session_generation_label
      stage = session["stage_id"].presence || session[:stage_id].presence
      ["Thumper DOJO Session", date.strftime("%Y-%m-%d"), ("stage #{stage}" if stage.present?), ("gen #{generation}" if generation.present?)].compact.join(" - ")
    end

    def html_document(title: document_name, heading: "Thumper DOJO Scroll", readout_label: "Daily dojo readout:", subtitle_html: nil)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>#{h(title)}</title>
            <style>
              body { font-family: Arial, Helvetica, sans-serif; color: #151923; line-height: 1.5; font-size: 12px; }
              h1, h2, h3 { color: #11131b; margin-bottom: 8px; }
              h1 { border-bottom: 4px solid #10b981; padding-bottom: 8px; font-size: 26px; }
              h2 { margin-top: 26px; border-bottom: 1px solid #c8f1df; padding-bottom: 5px; font-size: 18px; }
              h3 { font-size: 15px; margin-top: 0; }
              table { border-collapse: collapse; width: 100%; margin: 10px 0 18px; }
              th, td { border: 1px solid #d8e3dc; padding: 8px; text-align: left; vertical-align: top; }
              th { background: #ecfdf5; width: 28%; }
              ol, ul { margin-top: 6px; padding-left: 22px; }
              li { margin: 3px 0; }
              .readout { background: #f0fdf4; border-left: 5px solid #10b981; padding: 12px 16px; margin: 16px 0; }
              .review { border-left: 5px solid #f59e0b; }
              .pass { border-left: 5px solid #10b981; }
              .card { page-break-inside: avoid; padding: 14px; margin: 14px 0; background: #fbfefc; border: 1px solid #d7f5e4; }
              .round-card { page-break-inside: avoid; padding: 12px 14px; margin: 10px 0; border: 1px solid #d8e3dc; background: #ffffff; }
              .score-pass { color: #047857; font-weight: 700; }
              .score-review { color: #b45309; font-weight: 700; }
              .meta { color: #53605a; font-size: 11px; }
              .pill { display: inline-block; padding: 2px 7px; border: 1px solid #b7dfcf; background: #ecfdf5; font-size: 10px; font-weight: 700; color: #075943; }
              .question-list { margin-bottom: 10px; }
              .transcript, .answer-summary { white-space: pre-wrap; }
              .empty { color: #6b7280; font-style: italic; }
            </style>
          </head>
          <body>
            <h1>#{h(heading)}</h1>
            <p><strong>Date:</strong> #{h(date.strftime('%B %-d, %Y'))}</p>
            #{subtitle_html}
            <div class="readout">
              <strong>#{h(readout_label)}</strong>
              #{scorecard_summary_sentence}
              #{pass_count} passed, #{review_count} needed review, average score #{average_score || 'n/a'}.
              #{owner_scenario_coverage_sentence}
              #{embedding_status_sentence}
              #{memory_retention_sentence}
            </div>

            <h2>Training Summary</h2>
            <table>
              <tr><th>Total scorecards</th><td>#{render_scorecards.length}</td></tr>
              <tr><th>Complete conversations</th><td>#{conversation_count}</td></tr>
              #{owner_scenario_coverage_row}
              #{missing_owner_scenario_row}
              <tr><th>PASS / REVIEW</th><td>#{pass_count} / #{review_count}</td></tr>
              <tr><th>Average score</th><td>#{average_score || 'n/a'}</td></tr>
              <tr><th>Judges</th><td>#{h(judge_summary.presence || 'not recorded')}</td></tr>
              <tr><th>Embedding status</th><td>#{h(embedding_status_sentence)}</td></tr>
              <tr><th>Memory retention</th><td>#{h(memory_retention_sentence)}</td></tr>
            </table>

            <h2>Training Rounds At A Glance</h2>
            #{round_overview_sections}

            <h2>Standing Training Rules Reinforced</h2>
            <ul>
              #{standing_rules.map { |rule| "<li>#{h(rule)}</li>" }.join}
            </ul>

            <h2>Boss Pass Criteria</h2>
            <div class="readout">
              <strong>Yard-sign lane first:</strong>
              The scroll should prove that Thumper answers yard-sign questions like a real WIZWIKI rep: price first, lane-specific,
              remembers quantity/logo/design facts, asks one natural next question, and sends the checkout link when the customer is ready.
            </div>
            <ul>
              #{boss_pass_criteria.map { |rule| "<li>#{h(rule)}</li>" }.join}
            </ul>

            <h2>Scorecards</h2>
            #{scorecard_sections}
          </body>
        </html>
      HTML
    end

    def session_html_document
      with_render_scorecards(session_scorecards) do
        html_document(
          title: session_document_name,
          heading: "Thumper DOJO Session Scroll",
          readout_label: "Session dojo readout:",
          subtitle_html: session_subtitle_html
        )
      end
    end

    def scorecard_sections
      render_scorecards.map.with_index(1) do |card, index|
        css = card[:verdict].to_s == "PASS" ? "pass" : "review"
        mode = card[:conversation] ? "Complete conversation" : "Single-turn scenario"
        scenario_label = card[:conversation] ? "Customer transcript" : "Customer scenario"
        answer_label = card[:conversation] ? "Thumper answer summary" : "Thumper answer"
        questions = card_questions(card)
        <<~HTML
          <div class="card #{css}">
            <h3>#{index}. <span class="#{score_class(card)}">#{h(card[:verdict])} #{h(card[:score])}/100</span></h3>
            <p class="meta">
              #{h(mode)}
              #{card[:conversation_title].present? ? " // #{h(card[:conversation_title])}" : ""}
              #{card[:language_label].present? ? " // #{h(card[:language_label])}" : ""}
              #{card[:route_code].present? ? " // route #{h(card[:route_code])}" : ""}
              #{card[:at_label].present? ? " // #{h(card[:at_label])}" : ""}
              #{card[:judge].present? ? " // #{h(card[:judge])}" : ""}
              #{card[:stage_id].present? ? " // stage #{h(card[:stage_id])}" : ""}
            </p>
            <table>
              #{card[:objective].present? ? "<tr><th>Training goal</th><td>#{h(card[:objective])}</td></tr>" : ""}
              #{questions.present? ? "<tr><th>Questions trained</th><td>#{question_list(questions)}</td></tr>" : ""}
              #{Array(card[:checks]).present? ? "<tr><th>Checks</th><td>#{list_or_empty(card[:checks])}</td></tr>" : ""}
              <tr><th>#{h(scenario_label)}</th><td class="transcript">#{h(card[:scenario].presence || 'not captured')}</td></tr>
              <tr><th>#{h(answer_label)}</th><td class="answer-summary">#{h(card[:answer].presence || 'not captured')}</td></tr>
              <tr><th>Findings</th><td>#{list_or_empty(card[:findings])}</td></tr>
              <tr><th>Rewrite</th><td>#{h(card[:rewrite].presence || 'not needed')}</td></tr>
              <tr><th>Embedding lesson</th><td>#{h(card[:embedding_lesson].presence || 'not captured')}</td></tr>
            </table>
          </div>
        HTML
      end.join("\n")
    end

    def round_overview_sections
      render_scorecards.map.with_index(1) do |card, index|
        questions = card_questions(card)
        <<~HTML
          <div class="round-card #{card[:verdict].to_s == 'PASS' ? 'pass' : 'review'}">
            <h3>#{index}. #{h(card_title(card, index))}</h3>
            <p class="meta">
              <span class="#{score_class(card)}">#{h(card[:verdict])} #{h(card[:score])}/100</span>
              #{card[:language_label].present? ? " // <span class=\"pill\">#{h(card[:language_label])}</span>" : ""}
              #{card[:route_code].present? ? " // <span class=\"pill\">#{h(card[:route_code])}</span>" : ""}
              #{card[:at_label].present? ? " // #{h(card[:at_label])}" : ""}
              #{card[:stage_id].present? ? " // stage #{h(card[:stage_id])}" : ""}
            </p>
            #{card[:objective].present? ? "<p><strong>Goal:</strong> #{h(card[:objective])}</p>" : ""}
            <p><strong>Questions trained:</strong></p>
            #{question_list(questions)}
          </div>
        HTML
      end.join("\n")
    end

    def card_title(card, index)
      card[:conversation_title].presence ||
        (card[:conversation] ? "Complete conversation #{index}" : "Single-turn scenario #{index}")
    end

    def score_class(card)
      card[:verdict].to_s == "PASS" ? "score-pass" : "score-review"
    end

    def card_questions(card)
      explicit = Array(card[:questions]).map { |question| clean(question, max: 500) }.compact_blank
      return explicit if explicit.present?

      return questions_from_transcript(card[:scenario]) if ActiveModel::Type::Boolean.new.cast(card[:conversation])

      [clean(card[:scenario], max: 500)].compact_blank
    end

    def question_list(items)
      values = Array(items).map { |item| clean(item, max: 500) }.compact_blank.first(12)
      return "<span class=\"empty\">No customer questions captured.</span>" if values.blank?

      "<ol class=\"question-list\">#{values.map { |item| "<li>#{h(item)}</li>" }.join}</ol>"
    end

    def dojo_turn_questions(event)
      explicit = Array(event["dojo_conversation_turns"]).map { |turn| clean(turn, max: 500) }.compact_blank
      return explicit if explicit.present?

      summarized = Array(event["dojo_turns"]).map { |turn| clean(turn.to_h["customer"], max: 500) }.compact_blank
      return summarized if summarized.present?

      questions_from_transcript(event["dojo_conversation_transcript"])
    end

    def questions_from_transcript(value)
      text = value.to_s
      return [] if text.blank?

      text.scan(/Customer:\s*(.+?)(?=\nTHUMPER:|\z)/m).flatten.map { |match| clean(match, max: 500) }.compact_blank
    end

    def standing_rules
      [
        "Answer the customer's latest question directly in sentence one.",
        "Lead source starts the lane; the customer's latest message controls the current lane.",
        "For yard-sign leads, do not push postcards, EDDM, bundles, or Neighborhood Blitz unless the customer brings them up.",
        "Give real prices, package names, links, or process detail when the customer asks for them.",
        "Remember practical facts from the thread: product, quantity, logo/artwork, direct-mail interest, handoff permission, and whether the checkout link was requested.",
        "Ask at most one next question, and only after the answer is complete.",
        "Never use prompt-style labels such as Quick practical check, One useful detail, Still worth asking, One clean next step, Small practical check, No rush one helpful detail, or Fresh start here.",
        "Do not repeat older questions, leak internal reasoning, or use a link as a shortcut.",
        "Use scorecard lessons as correction memory inside Thumper RAG, not as scripts to copy blindly."
      ]
    end

    def boss_pass_criteria
      [
        "Did the reply answer the customer's actual question first?",
        "Did it stay in the correct product lane?",
        "Did it use what the customer already said?",
        "Did it avoid re-asking answered questions?",
        "Did it avoid internal labels, route codes, reset language, and prompt-style prefixes?",
        "Did it ask only one natural next question?",
        "Would this sound normal if Thumper from WIZWIKI texted it?",
        "For direct mail side questions, did it ask permission before consultant handoff and preserve the original yard-sign sale?"
      ]
    end

    def scorecards
      @scorecards ||= load_scorecards
    end

    def render_scorecards
      @render_scorecards || scorecards
    end

    def with_render_scorecards(cards)
      previous = @render_scorecards
      @render_scorecards = Array(cards)
      yield
    ensure
      @render_scorecards = previous
    end

    def session_scorecards
      @session_scorecards ||= begin
        generation = session_generation
        if generation.blank?
          []
        else
          scorecards.select { |card| card[:generation].to_s == generation.to_s }
        end
      end
    end

    def publish_session_doc(folder)
      return unless session_scroll_requested?
      return if session_scorecards.blank?

      google_doc = drive_client.upsert_google_doc(
        name: session_document_name,
        html: session_html_document,
        folder_id: folder["id"].presence
      )
      share_file(google_doc["id"]) if google_doc["id"].present? && share_anyone_enabled?
      google_doc
    end

    def session_scroll_requested?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("THUMPER_DOJO_SESSION_SCROLLS_ENABLED", "true")) &&
        session_generation.present?
    end

    def session_generation
      session["generation"].presence || session[:generation].presence
    end

    def session_generation_label
      session_generation.to_s.first(8).presence
    end

    def session_subtitle_html
      stage = session["stage_id"].presence || session[:stage_id].presence
      guidance = clean(session["guidance"].presence || session[:guidance], max: 1_000)
      started = session["started_at"].presence || session[:started_at].presence
      completed = session["completed_at"].presence || session[:completed_at].presence
      rows = [
        ["Session generation", session_generation],
        ["Stage", stage],
        ["Started", started],
        ["Completed", completed],
        ["Guidance", guidance]
      ].select { |_label, value| value.present? }
      return "" if rows.blank?

      <<~HTML
        <h2>Session Details</h2>
        <table>
          #{rows.map { |label, value| "<tr><th>#{h(label)}</th><td>#{h(value)}</td></tr>" }.join}
        </table>
      HTML
    end

    def load_scorecards
      stages = organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where("updated_at >= ?", date.beginning_of_day)
        .order(updated_at: :desc)
        .limit(500)

      stages.flat_map { |stage| scorecards_for_stage(stage) }
        .select { |card| card[:at].present? && card[:at].to_date == date }
        .sort_by { |card| [card[:at], card[:stage_id].to_i, card[:cycle].to_i] }
    end

    def scorecards_for_stage(stage)
      events = Array(stage.metadata.to_h["sms_thread"]).map(&:to_h)
      event_cards = events.each_with_index.filter_map do |event, index|
        next unless event["role"].to_s == "dojo_grade" || event["dojo_grade"].present?

        grade = event["dojo_grade"].to_h
        next if grade.blank?

        at = parse_time(event["created_at"])
        conversation = ActiveModel::Type::Boolean.new.cast(event["dojo_conversation"]) || event["role"].to_s == "dojo_conversation_grade"
        if conversation
          judge = [grade["judge_provider"], grade["judge_model"]].compact_blank.join(" / ")
          lesson = event["embedding_lesson"].presence || grade["embedding_lesson"]
          next {
            at: at,
            at_label: at&.in_time_zone&.strftime("%b %-d, %-I:%M %p %Z"),
            stage_id: stage.id,
            cycle: event["dojo_cycle"],
            generation: event["dojo_generation"],
            conversation: true,
            conversation_id: event["dojo_conversation_id"].presence,
            conversation_title: clean(event["dojo_conversation_title"]),
            route_code: clean(event["dojo_route_code"], max: 80),
            language_code: clean(event["dojo_language_code"], max: 20),
            language_label: clean(event["dojo_language_label"], max: 80),
            objective: clean(event["dojo_conversation_objective"], max: 1_500),
            checks: Array(event["dojo_conversation_checks"]).map { |check| clean(check, max: 160) }.compact_blank,
            questions: dojo_turn_questions(event),
            score: grade["score"].to_i,
            verdict: grade["verdict"].to_s.presence || (grade["score"].to_i >= 85 ? "PASS" : "REVIEW"),
            judge: judge,
            scenario: clean(event["dojo_conversation_transcript"], max: 3_000),
            answer: clean(event["dojo_conversation_answer_summary"], max: 3_000),
            findings: Array(grade["findings"]).map { |finding| clean(finding) }.compact_blank.first(8),
            rewrite: clean(grade["rewrite"], max: 2_000),
            embedding_lesson: clean(lesson, max: 2_000)
          }.compact_blank
        end

        inbound = paired_event(events, index, direction: "inbound", cycle: event["dojo_cycle"], generation: event["dojo_generation"])
        answer = paired_event(events, index, direction: "outbound", role: "dojo_answer", cycle: event["dojo_cycle"], generation: event["dojo_generation"])
        judge = [grade["judge_provider"], grade["judge_model"]].compact_blank.join(" / ")

        {
          at: at,
          at_label: at&.in_time_zone&.strftime("%b %-d, %-I:%M %p %Z"),
          stage_id: stage.id,
          cycle: event["dojo_cycle"],
          generation: event["dojo_generation"],
          score: grade["score"].to_i,
          verdict: grade["verdict"].to_s.presence || (grade["score"].to_i >= 85 ? "PASS" : "REVIEW"),
          judge: judge,
          questions: Array(event["dojo_questions"]).map { |question| clean(question) }.compact_blank.presence || [clean(inbound.to_h["body"])].compact_blank,
          scenario: clean(inbound.to_h["body"]),
          answer: clean(answer.to_h["body"]),
          findings: Array(grade["findings"]).map { |finding| clean(finding) }.compact_blank.first(8),
          rewrite: clean(grade["rewrite"]),
          embedding_lesson: clean(event["embedding_lesson"].presence || grade["embedding_lesson"])
        }.compact_blank
      end

      (event_cards + summary_scorecards_for_stage(stage, events))
        .uniq { |card| [card[:stage_id], card[:generation].to_s, card[:conversation_id].presence || card[:cycle].to_s, card[:conversation]] }
    end

    def summary_scorecards_for_stage(stage, events)
      events.filter_map do |event|
        next unless event["role"].to_s == "dojo_summary"

        Array(event["dojo_cycles"]).filter_map do |cycle|
          cycle = cycle.to_h
          next unless ActiveModel::Type::Boolean.new.cast(cycle["conversation"])

          trajectory = cycle["trajectory"].to_h
          quality = trajectory["quality"].to_h
          score = (cycle["score"].presence || quality["score"]).to_i
          next if score <= 0

          generation = cycle["generation"].presence || trajectory["generation"].presence || event["dojo_generation"]
          answers = Array(trajectory.dig("output", "answers")).map(&:to_h)
          judge = [quality["judge_provider"], quality["judge_model"]].compact_blank.join(" / ")
          scenario_definition = dojo_conversation_definition(cycle["conversation_id"])
          at = parse_time(trajectory["created_at"].presence || event["created_at"])

          {
            at: at,
            at_label: at&.in_time_zone&.strftime("%b %-d, %-I:%M %p %Z"),
            stage_id: stage.id,
            cycle: cycle["cycle"],
            generation: generation,
            conversation: true,
            conversation_id: cycle["conversation_id"].presence,
            conversation_title: clean(cycle["title"].presence || trajectory["title"]),
            route_code: clean(trajectory.dig("state", "product_interest_code"), max: 80),
            objective: clean(scenario_definition.to_h[:objective], max: 1_500),
            checks: Array(scenario_definition.to_h[:checks]).map { |check| clean(check, max: 160) }.compact_blank,
            questions: Array(trajectory.dig("input", "customer_turns")).map { |turn| clean(turn, max: 500) }.compact_blank,
            score: score,
            verdict: cycle["verdict"].to_s.presence || quality["verdict"].to_s.presence || (score >= 85 ? "PASS" : "REVIEW"),
            judge: judge,
            scenario: clean(cycle["transcript"].presence || trajectory.dig("output", "transcript"), max: 3_000),
            answer: clean(answers.map { |answer| "Turn #{answer["turn"]}: #{answer["answer"]}" }.join(" "), max: 3_000),
            findings: Array(cycle["findings"].presence || quality["findings"]).map { |finding| clean(finding) }.compact_blank.first(8),
            rewrite: clean(quality["rewrite"], max: 2_000),
            embedding_lesson: clean(quality["embedding_lesson"], max: 2_000)
          }.compact_blank
        end
      end.flatten
    end

    def dojo_conversation_definition(id)
      return {} if id.blank? || !defined?(Comms::AskAutopilotTest)

      Comms::AskAutopilotTest.send(:dojo_conversation_by_id, id).to_h
    rescue StandardError
      {}
    end

    def paired_event(events, index, direction:, role: nil, cycle: nil, generation: nil)
      events[0...index].to_a.reverse.find do |event|
        event = event.to_h
        next false unless ActiveModel::Type::Boolean.new.cast(event["recursive_dojo"])
        next false unless event["direction"].to_s == direction.to_s
        next false if role.present? && event["role"].to_s != role.to_s
        next false if cycle.present? && event["dojo_cycle"].to_s != cycle.to_s
        next false if generation.present? && event["dojo_generation"].to_s != generation.to_s

        event["body"].to_s.squish.present?
      end
    end

    def pass_count
      render_scorecards.count { |card| card[:verdict].to_s == "PASS" }
    end

    def review_count
      render_scorecards.length - pass_count
    end

    def conversation_count
      render_scorecards.count { |card| ActiveModel::Type::Boolean.new.cast(card[:conversation]) }
    end

    def owner_scenario_coverage_sentence
      expected = expected_owner_conversation_titles
      return "" if expected.blank?

      missing = missing_owner_conversation_titles
      status = "Sample Owner scenario coverage: #{expected.length - missing.length}/#{expected.length}."
      missing.present? ? "#{status} Missing: #{missing.join('; ')}." : "#{status} All expected conversations scored."
    end

    def owner_scenario_coverage_row
      expected = expected_owner_conversation_titles
      return "" if expected.blank?

      missing = missing_owner_conversation_titles
      "<tr><th>Sample Owner scenario coverage</th><td>#{h(expected.length - missing.length)}/#{h(expected.length)}</td></tr>"
    end

    def missing_owner_scenario_row
      expected = expected_owner_conversation_titles
      return "" if expected.blank?

      missing = missing_owner_conversation_titles
      "<tr><th>Missing Sample Owner scenarios</th><td>#{missing.present? ? list_or_empty(missing) : 'none'}</td></tr>"
    end

    def expected_owner_conversation_titles
      @expected_owner_conversation_titles ||= begin
        if defined?(Comms::AskAutopilotTest)
          Comms::AskAutopilotTest
            .send(:owner_yard_sign_conversation_scenarios)
            .map { |scenario| clean(scenario.to_h[:title], max: 500) }
            .compact_blank
        else
          []
        end
      rescue StandardError
        []
      end
    end

    def missing_owner_conversation_titles
      expected = expected_owner_conversation_titles
      return [] if expected.blank?

      covered = render_scorecards
        .select { |card| ActiveModel::Type::Boolean.new.cast(card[:conversation]) }
        .map { |card| clean(card[:conversation_title], max: 500) }
        .compact_blank
        .uniq
      expected.reject { |title| covered.include?(title) }
    end

    def scorecard_summary_sentence
      single_turn_count = render_scorecards.length - conversation_count
      parts = []
      parts << "#{conversation_count} complete #{'conversation'.pluralize(conversation_count)}" if conversation_count.positive?
      parts << "#{single_turn_count} single-turn #{'scenario'.pluralize(single_turn_count)}" if single_turn_count.positive?
      "#{render_scorecards.length} scored training #{'scorecard'.pluralize(render_scorecards.length)}#{parts.present? ? " (#{parts.join(', ')})" : ""}."
    end

    def average_score
      scores = render_scorecards.map { |card| card[:score].to_i }.select(&:positive?)
      return if scores.blank?

      (scores.sum.to_f / scores.length).round(1)
    end

    def judge_summary
      render_scorecards.map { |card| card[:judge] }.compact_blank.tally.map { |judge, count| "#{judge}: #{count}" }.join(" | ")
    end

    def embedding_status_sentence
      status = embedding_status
      return "Embedding status not recorded." if status.blank?

      "#{status['embedded'].to_i}/#{status['chunk_count'].to_i} scorecard chunks embedded; #{status['pending'].to_i + status['claimed'].to_i} still waiting."
    end

    def memory_retention_sentence
      retention = embedding_status.to_h["memory_retention"].to_h
      return "Memory retention: no pruning needed." if retention.blank?

      archived = retention["memory_documents_archived"].to_i
      staled = retention["memory_embedding_sources_staled"].to_i
      "Memory retention: #{archived} old memory doc(s) archived; #{staled} embedding source(s) staled."
    end

    def list_or_empty(items)
      values = Array(items).compact_blank
      return "<span class=\"empty\">None recorded.</span>" if values.blank?

      "<ul>#{values.map { |item| "<li>#{h(item)}</li>" }.join}</ul>"
    end

    def share_file(file_id)
      drive_client.share_anyone(file_id: file_id, role: "reader")
    rescue StandardError => error
      Rails.logger.warn("[Comms::DojoScrollDocument] share failed file=#{file_id}: #{error.class}: #{error.message}")
      nil
    end

    def share_anyone_enabled?
      ENV.fetch("THUMPER_DOJO_SHARE_ANYONE_WITH_LINK", "true").to_s.match?(/\A(?:1|true|yes|on)\z/i)
    end

    def skipped_result(reason)
      {
        ok: true,
        skipped: true,
        reason: reason,
        date: date.iso8601,
        scorecards: 0,
        embedding_status: embedding_status
      }
    end

    def clean(value, max: 1_000)
      value.to_s.squish.truncate(max, omission: "...").presence
    end

    def parse_date(value)
      return Time.current.in_time_zone("Central Time (US & Canada)").yesterday.to_date if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.current.in_time_zone("Central Time (US & Canada)").yesterday.to_date
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def h(value)
      ERB::Util.html_escape(value.to_s)
    end
  end
end
