# frozen_string_literal: true

namespace :autos do
  desc "Build or refresh any URL-backed SMS RAG (PAGES_JSON is a JSON object; no embeddings by default)"
  task build_url_rag: :environment do
    organization = Organization.find_by(id: ENV["ORGANIZATION_ID"]) || Organization.order(:created_at).first
    user = organization&.users&.find_by(id: ENV["USER_ID"]) || organization&.users&.order(:created_at)&.first
    pages = JSON.parse(ENV.fetch("PAGES_JSON"))
    result = Autos::UrlRagBuilder.call(
      organization: organization,
      user: user,
      profile_key: ENV.fetch("RAG_KEY"),
      profile_label: ENV.fetch("RAG_LABEL"),
      profile_kind: ENV.fetch("RAG_KIND", "support"),
      description: ENV["RAG_DESCRIPTION"],
      pages: pages,
      enqueue_embeddings: ENV["EMBED"] == "1"
    )
    puts JSON.pretty_generate(result)
  end

  desc "List selectable SMS RAG profiles"
  task list_rags: :environment do
    organization = Organization.find_by(id: ENV["ORGANIZATION_ID"]) || Organization.order(:created_at).first
    puts JSON.pretty_generate(Comms::RagProfile.profiles_for(organization))
  end

  desc "Clean RAG embedding queue hygiene issues such as stale claimed chunks"
  task rag_hygiene: :environment do
    result = Autos::RagHygiene.call(**Autos::RagHygiene.env_options)

    puts "RAG hygiene #{result.fetch(:dry_run) ? 'dry run' : 'complete'}"
    puts "organization=#{result.fetch(:organization_id)} #{result.fetch(:organization_name)}"
    puts "scope=#{result.fetch(:scope)} embedding_model=#{result.fetch(:embedding_model)}"
    puts "before=#{result.fetch(:before).fetch(:counts_by_status).to_json}"

    reclaimed = result.fetch(:reclaimed_stale_claims)
    puts "reclaimed_stale_claims=#{reclaimed.fetch(:count)} by_source=#{reclaimed.fetch(:by_source).to_json}"

    pruned = result.fetch(:pruned_stale_chunks)
    puts "pruned_stale_chunks=#{pruned.fetch(:count)} by_source=#{pruned.fetch(:by_source).to_json}"
    puts "prune_note=#{pruned.fetch(:skipped)}" if pruned[:skipped].present?

    after = result.fetch(:after)
    puts "after=#{after.fetch(:counts_by_status).to_json}"
    puts "pending_by_source=#{after.fetch(:pending_by_source).to_json}" if after.fetch(:pending_by_source).present?
    puts "stale_claimed_by_source=#{after.fetch(:stale_claimed_by_source).to_json}" if after.fetch(:stale_claimed_by_source).present?
    result.fetch(:recommendations).each { |recommendation| puts "NEXT: #{recommendation}" }
  end

  namespace :rag_hygiene do
    desc "Alias for autos:rag_hygiene"
    task run: :environment do
      Rake::Task["autos:rag_hygiene"].invoke
    end
  end

  desc "Run recursive Thumper dojo sessions until the target average is met or the loop limit is reached"
  task dojo_thumper: :environment do
    target = ENV.fetch("TARGET", "96").to_f
    max_sessions = ENV.fetch("MAX_SESSIONS", "3").to_i.clamp(1, 20)
    poll_seconds = ENV.fetch("POLL_SECONDS", "20").to_i.clamp(5, 300)
    timeout_minutes = ENV.fetch("TIMEOUT_MINUTES", "90").to_i.clamp(5, 720)
    stage_id = ENV["STAGE_ID"].presence
    user_id = ENV["USER_ID"].presence
    organization_id = ENV["ORGANIZATION_ID"].presence
    writer_model = ENV.fetch("WRITER_MODEL", "qwen3:8b")
    guidance = ENV["GUIDANCE"].presence ||
      "Thumper validation loop: run live-style SMS dojo scenarios, publish scrolls, and stop when scorecard average reaches target."

    stage = if stage_id.present?
      CrmRecordArtifact.find(stage_id)
    else
      nil
    end

    organization = stage&.organization || (organization_id.present? ? Organization.find(organization_id) : Organization.order(:id).first)
    raise "organization not found" if organization.blank?

    user = if user_id.present?
      User.find(user_id)
    elsif stage&.user.present?
      stage.user
    elsif organization.respond_to?(:users)
      organization.users.order(:id).first
    elsif organization.respond_to?(:user_id) && organization.user_id.present?
      User.find_by(id: organization.user_id)
    else
      User.order(:id).first
    end
    raise "user not found" if user.blank?

    max_sessions.times do |index|
      payload = stage.present? ? { "stage_id" => stage.id } : {}
      result = Comms::AskAutopilotTest.start_recursive_dojo(
        payload,
        guidance: guidance,
        user: user,
        organization: organization,
        async: true,
        writer_model: writer_model
      )
      stage = organization.crm_record_artifacts.find(result.to_h["stage_id"].presence || stage&.id)
      generation = stage.metadata.to_h["recursive_dojo_generation"].to_s
      started_at = Time.current
      puts "dojo_thumper session=#{index + 1}/#{max_sessions} stage=#{stage.id} generation=#{generation} target=#{target}"

      loop do
        stage.reload
        metadata = stage.metadata.to_h
        scores = dojo_thumper_scores(metadata, generation)
        average = scores.any? ? (scores.sum / scores.length.to_f).round(1) : nil
        puts "status=#{metadata['recursive_dojo_status']} phase=#{metadata['ask_autopilot_pending_phase']} grades=#{scores.length} average=#{average || 'n/a'}"

        if metadata["recursive_dojo_status"].to_s == "complete"
          if average.to_f >= target
            puts "dojo_thumper complete: target met average=#{average}"
            exit 0
          end

          puts "dojo_thumper continuing: average=#{average || 'n/a'} below target=#{target}"
          break
        end

        if metadata["recursive_dojo_status"].to_s.in?(%w[failed canceled cancelled])
          puts "dojo_thumper stopped: dojo status=#{metadata['recursive_dojo_status']} error=#{metadata['recursive_dojo_error'] || metadata['comms_command_background_error']}"
          exit 2
        end

        if Time.current - started_at > timeout_minutes.minutes
          puts "dojo_thumper stopped: timeout after #{timeout_minutes} minutes"
          exit 3
        end

        sleep poll_seconds
      end
    end

    puts "dojo_thumper stopped: max sessions reached before target=#{target}"
    exit 1
  end

  def dojo_thumper_scores(metadata, generation)
    Array(metadata["sms_thread"]).filter_map do |event|
      event = event.to_h
      next unless event["role"].to_s == "dojo_conversation_grade"
      next if generation.present? && event["dojo_generation"].to_s != generation

      event.dig("dojo_grade", "score")&.to_f
    end
  end
end
