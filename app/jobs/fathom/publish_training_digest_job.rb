module Fathom
  class PublishTrainingDigestJob < ApplicationJob
    queue_as :default

    DEFAULT_MAX_WAIT = 20.minutes
    DEFAULT_POLL_INTERVAL = 60.seconds
    DEFAULT_DOJO_SCROLL_LOOKBACK_DAYS = 7
    MAX_DOJO_SCROLL_LOOKBACK_DAYS = 30

    def perform(organization_id:, date:, result:, started_at:, completed_at:, request_id: nil, queued_at: nil, automation_run_id: nil, publish_digest: nil)
      organization = Organization.find(organization_id)
      return if already_delivered?(organization, request_id)

      automation_run = automation_run_for(automation_run_id)
      sync_date = parse_date(date)
      unless publish_digest_enabled?(publish_digest, sync_date)
        automation_run&.mark_skipped!(
          step: "historical_digest_suppressed",
          data: {
            date: sync_date.iso8601,
            reason: "Historical Fathom catch-up digest email suppressed."
          }
        )
        Rails.logger.info("[Fathom::PublishTrainingDigestJob] organization=#{organization.id} date=#{sync_date} historical digest email suppressed")
        return
      end

      started_time = parse_time(started_at)
      completed_time = parse_time(completed_at) || Time.current
      first_queued_at = parse_time(queued_at) || Time.current
      result_hash = normalize_result(result)
      unless calls_for_day(organization, sync_date).exists?
        Fathom::DailyCallSyncStatus.mark_no_calls!(
          organization: organization,
          request_id: request_id,
          job_id: job_id
        )
        automation_run&.mark_skipped!(step: "no_fathom_calls", data: { date: sync_date.iso8601, reason: "no calls found; digest skipped" })
        Rails.logger.info("[Fathom::PublishTrainingDigestJob] organization=#{organization.id} date=#{sync_date} no Fathom calls found; digest skipped")
        return
      end
      embedding_status = embedding_status_for(organization: organization, date: sync_date)
      if refresh_fathom_embeddings?(embedding_status)
        embedding_refresh = refresh_fathom_embeddings(organization: organization, date: sync_date)
        embedding_status = embedding_status_for(organization: organization, date: sync_date)
          .merge("embedding_refresh" => embedding_refresh)
      end
      automation_run&.append_event!(step: "embedding_status_checked", data: embedding_status)

      if embedding_status["waiting"] && wait_for_embeddings?(embedding_status, first_queued_at)
        reschedule_for_embeddings(
          organization: organization,
          date: sync_date,
          result: result_hash,
          started_at: started_time,
          completed_at: completed_time,
          request_id: request_id,
          queued_at: first_queued_at,
          embedding_status: embedding_status,
          automation_run: automation_run
        )
        return
      end

      if embedding_status["waiting"]
        embedding_status = partial_embedding_status(embedding_status, first_queued_at)
        result_hash["operations_note"] = [result_hash["operations_note"].presence, embedding_status["note"]].compact.join(" ")
        automation_run&.append_event!(
          step: "embedding_timeout_digest_continuing",
          data: embedding_status.merge(message: "Embedding wait expired; sending the digest with the available call readout.")
        )
      end

      google_doc = publish_training_document(
        organization: organization,
        date: sync_date,
        result: result_hash,
        started_at: started_time,
        completed_at: Time.current,
        embedding_status: embedding_status
      )
      if google_doc_enabled? && GoogleWorkspace::OauthClient.configured? && google_doc.blank?
        embedding_status = google_doc_unavailable_status(embedding_status)
        result_hash["operations_note"] = [result_hash["operations_note"].presence, embedding_status["google_doc_note"]].compact.join(" ")
        automation_run&.append_event!(
          step: "google_doc_unavailable_digest_continuing",
          data: embedding_status.merge(message: "Google Doc creation failed or returned blank; sending the email digest without the doc.")
        )
      end
      automation_run&.append_event!(step: "google_doc_created", data: google_doc.to_h) if google_doc.present?

      dojo_scroll_runs = pending_dojo_scroll_runs(organization: organization, date: sync_date)
      dojo_scrolls = daily_dojo_scroll_payloads(
        dojo_scroll_runs,
        extra_payloads: same_day_dojo_scroll_event_payloads(organization: organization, date: sync_date)
      )
      automation_run&.append_event!(step: "thumper_dojo_scrolls_ready", data: { count: dojo_scrolls.length, scrolls: dojo_scrolls }) if dojo_scrolls.present?

      email_result = send_training_digest(
        organization: organization,
        date: sync_date,
        result: result_hash,
        started_at: started_time,
        completed_at: Time.current,
        google_doc: google_doc,
        embedding_status: embedding_status,
        dojo_scrolls: dojo_scrolls
      )
      if digest_email_enabled? && !email_result
        fail_without_digest!(
          organization: organization,
          request_id: request_id,
          embedding_status: embedding_status,
          automation_run: automation_run,
          message: "Fathom digest email delivery failed; digest was not marked sent"
        )
        return
      end
      automation_run&.append_event!(step: "postmark_email_sent", data: email_result.to_h) if email_result.present?
      mark_dojo_scrolls_shared!(dojo_scroll_runs, email_result: email_result, fathom_date: sync_date) if email_result.present?

      Fathom::DailyCallSyncStatus.mark_delivered!(
        organization: organization,
        request_id: request_id,
        job_id: nil,
        digest_job_id: job_id,
        google_doc: google_doc,
        embedding_status: embedding_status
      )
      automation_run&.mark_succeeded!(
        step: "digest_delivered",
        data: {
          google_doc: google_doc.to_h,
          email: email_result.to_h,
          embedding_status: embedding_status
        }
      )
    rescue Fathom::Error, ActiveRecord::ActiveRecordError => error
      Fathom::DailyCallSyncStatus.mark_failed!(organization: organization, error: error, request_id: request_id, job_id: job_id) if defined?(organization) && organization.present?
      automation_run&.mark_failed!(step: "digest_failed", error: error) if defined?(automation_run) && automation_run.present?
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] organization_id=#{organization_id} failed: #{error.class}: #{error.message}")
    end

    private

    def embedding_status_for(organization:, date:)
      return empty_embedding_status("vector storage is not ready") unless Autos::EmbeddingQueue.storage_ready?

      calls = calls_for_day(organization, date)
      call_ids = calls.pluck(:id)
      model = Autos::EmbeddingQueue.embedder_model
      chunks = AutosEmbeddingChunk.where(
        organization: organization,
        source_type: "FathomCall",
        source_id: call_ids,
        embedding_model: model
      )
      active_chunks = chunks.where.not(status: "stale")
      counts = chunks.group(:status).count
      sources_with_chunks = active_chunks.distinct.count(:source_id)
      missing = [call_ids.length - sources_with_chunks, 0].max
      incomplete_chunks = active_chunks.where.not(status: "embedded").count
      pending = incomplete_chunks + missing

      {
        "status" => pending.positive? ? "embedding_in_progress" : "embedding_complete",
        "complete" => pending.zero?,
        "waiting" => pending.positive?,
        "embedding_model" => model,
        "call_count" => call_ids.length,
        "chunk_count" => chunks.count,
        "active_chunk_count" => active_chunks.count,
        "missing_sources" => missing,
        "pending" => counts["pending"].to_i,
        "claimed" => counts["claimed"].to_i,
        "stale" => counts["stale"].to_i,
        "embedded" => counts["embedded"].to_i,
        "incomplete_chunks" => incomplete_chunks,
        "failed" => counts["failed"].to_i
      }
    end

    def empty_embedding_status(reason)
      {
        "status" => "embedding_skipped",
        "complete" => true,
        "waiting" => false,
        "reason" => reason,
        "call_count" => 0,
        "chunk_count" => 0,
        "pending" => 0,
        "claimed" => 0,
        "stale" => 0,
        "embedded" => 0,
        "failed" => 0
      }
    end

    def calls_for_day(organization, date)
      start_time = date.beginning_of_day
      end_time = date.tomorrow.beginning_of_day

      organization.fathom_calls
        .active
        .where(
          "(recording_start_time >= :start_time AND recording_start_time < :end_time) OR (fathom_created_at >= :start_time AND fathom_created_at < :end_time)",
          start_time: start_time,
          end_time: end_time
        )
    end

    def wait_for_embeddings?(embedding_status, queued_at)
      return false unless embedding_status["waiting"]

      Time.current < queued_at + max_wait
    end

    def partial_embedding_status(embedding_status, queued_at)
      embedding_status.to_h.merge(
        "status" => "embedding_partial_digest_sent",
        "complete" => false,
        "waiting" => false,
        "partial_digest" => true,
        "wait_expired_at" => (queued_at + max_wait).iso8601,
        "note" => "Digest sent with available Fathom call content because embeddings were still catching up."
      )
    end

    def google_doc_unavailable_status(embedding_status)
      embedding_status.to_h.merge(
        "google_doc_status" => "unavailable",
        "google_doc_note" => "Google Doc creation did not complete, so the email digest was sent without the Drive document."
      )
    end

    def refresh_fathom_embeddings?(embedding_status)
      embedding_status["waiting"] &&
        (embedding_status["missing_sources"].to_i.positive? || embedding_status["failed"].to_i.positive?)
    end

    def refresh_fathom_embeddings(organization:, date:)
      return { "skipped" => "vector storage is not ready" } unless Autos::EmbeddingQueue.storage_ready?

      result = {
        "call_count" => 0,
        "queued_sources" => 0,
        "failed_sources" => 0,
        "embedding_model" => Autos::EmbeddingQueue.embedder_model
      }

      calls_for_day(organization, date).find_each do |call_record|
        result["call_count"] += 1
        if Autos::EmbeddingQueue.enqueue_source!(call_record)
          result["queued_sources"] += 1
        else
          result["failed_sources"] += 1
        end
      rescue StandardError => error
        result["failed_sources"] += 1
        Rails.logger.warn("[Fathom::PublishTrainingDigestJob] embedding refresh failed call=#{call_record&.id}: #{error.class}: #{error.message}")
      end

      result
    end

    def reschedule_for_embeddings(organization:, date:, result:, started_at:, completed_at:, request_id:, queued_at:, embedding_status:, automation_run:)
      job = self.class.set(wait: poll_interval).perform_later(
        organization_id: organization.id,
        date: date.iso8601,
        result: result,
        started_at: started_at&.iso8601,
        completed_at: completed_at&.iso8601,
        request_id: request_id,
        queued_at: queued_at.iso8601,
        automation_run_id: automation_run&.id
      )
      automation_run&.mark_waiting!(step: "waiting_for_embeddings", data: embedding_status.merge(next_check_job_id: job.job_id))
      Fathom::DailyCallSyncStatus.mark_embedding!(
        organization: organization,
        request_id: request_id,
        job_id: nil,
        digest_job_id: job.job_id,
        embedding_status: embedding_status
      )
    end

    def fail_without_digest!(organization:, request_id:, embedding_status:, message:, automation_run: nil)
      error = Fathom::Error.new(message)
      Fathom::DailyCallSyncStatus.mark_failed!(
        organization: organization,
        error: error,
        request_id: request_id,
        job_id: job_id
      )
      automation_run&.mark_failed!(step: "digest_blocked", error: error, data: { embedding_status: embedding_status })
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] organization=#{organization.id} #{message} #{embedding_status.inspect}")
    end

    def publish_training_document(organization:, date:, result:, started_at:, completed_at:, embedding_status:)
      return unless google_doc_enabled?
      return unless GoogleWorkspace::OauthClient.configured?

      Fathom::TrainingDigestDocument.publish(
        organization: organization,
        date: date,
        result: result,
        started_at: started_at,
        completed_at: completed_at,
        embedding_status: embedding_status
      )
    rescue StandardError => error
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] Google Doc publish failed organization=#{organization.id}: #{error.class}: #{error.message}")
      nil
    end

    def send_training_digest(organization:, date:, result:, started_at:, completed_at:, google_doc:, embedding_status:, dojo_scrolls: [])
      return unless digest_email_enabled?

      mail = if google_doc.present?
        ThumperMailer.fathom_training_doc_ready(
          organization: organization,
          date: date,
          result: result,
          started_at: started_at,
          completed_at: completed_at,
          google_doc: google_doc,
          embedding_status: embedding_status,
          dojo_scrolls: dojo_scrolls
        )
      else
        ThumperMailer.fathom_training_digest(
          organization: organization,
          date: date,
          result: result,
          started_at: started_at,
          completed_at: completed_at,
          embedding_status: embedding_status,
          dojo_scrolls: dojo_scrolls
        )
      end
      deliver_digest_mail(mail)
    rescue StandardError => error
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] digest email failed organization=#{organization.id}: #{error.class}: #{error.message}")
      false
    end

    def pending_dojo_scroll_runs(organization:, date:)
      return [] unless defined?(Comms::DojoScrollJob)

      sync_date = parse_optional_date(date) || Time.zone.today
      start_date = sync_date - dojo_scroll_lookback_days

      organization.wizwiki_automation_runs
        .for_automation(Comms::DojoScrollJob::AUTOMATION_KEY)
        .where(status: "succeeded")
        .where(target_date: start_date..sync_date)
        .order(target_date: :asc, updated_at: :asc)
        .to_a
        .reject { |run| dojo_scroll_shared?(run) }
        .select { |run| dojo_scroll_payload(run).present? }
    rescue StandardError => error
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] Thumper DOJO scroll lookup failed organization=#{organization.id}: #{error.class}: #{error.message}")
      []
    end

    def daily_dojo_scroll_payloads(runs, extra_payloads: [])
      (Array(runs).filter_map { |run| dojo_scroll_payload(run) } + Array(extra_payloads))
        .group_by { |payload| [payload["date"], payload["doc_name"].presence || payload["url"]] }
        .values
        .map { |items| items.max_by { |payload| payload["run_id"].to_i } }
        .sort_by { |payload| [payload["date"].to_s, payload["run_id"].to_i] }
    end

    def same_day_dojo_scroll_event_payloads(organization:, date:)
      sync_date = parse_optional_date(date) || Time.zone.today
      start_time = sync_date.beginning_of_day
      end_time = sync_date.tomorrow.beginning_of_day

      organization.crm_record_artifacts
        .where(artifact_type: "comm_staging")
        .where(updated_at: start_time...end_time)
        .where("metadata @> ?", { sms_thread: [{ role: "dojo_scroll_summary" }] }.to_json)
        .order(updated_at: :desc)
        .limit(dojo_scroll_stage_scan_limit)
        .flat_map { |stage| dojo_scroll_event_payloads_for_stage(stage, sync_date) }
    rescue StandardError => error
      Rails.logger.warn("[Fathom::PublishTrainingDigestJob] Thumper DOJO thread-scroll lookup failed organization=#{organization.id}: #{error.class}: #{error.message}")
      []
    end

    def dojo_scroll_event_payloads_for_stage(stage, sync_date)
      Array(stage.metadata.to_h["sms_thread"]).each_with_index.filter_map do |event, index|
        event = event.to_h
        payload = event["dojo_scroll_published"].to_h
        next if payload.blank?

        event_time = parse_time(event["created_at"])
        payload_date = parse_optional_date(payload["date"])
        next unless event_time&.in_time_zone&.to_date == sync_date || payload_date == sync_date

        dojo_scroll_payload_from_hash(
          payload,
          run_id: 0,
          fallback_date: payload_date || sync_date,
          source: "sms_thread",
          stage_id: stage.id,
          event_index: index,
          event_at: event_time
        )
      end
    end

    def dojo_scroll_stage_scan_limit
      Integer(ENV.fetch("FATHOM_DOJO_SCROLL_STAGE_SCAN_LIMIT", "5000")).clamp(50, 5_000)
    rescue ArgumentError, TypeError
      5_000
    end

    def dojo_scroll_lookback_days
      Integer(ENV.fetch("FATHOM_DOJO_SCROLL_LOOKBACK_DAYS", DEFAULT_DOJO_SCROLL_LOOKBACK_DAYS.to_s)).clamp(0, MAX_DOJO_SCROLL_LOOKBACK_DAYS)
    rescue ArgumentError, TypeError
      DEFAULT_DOJO_SCROLL_LOOKBACK_DAYS
    end

    def dojo_scroll_shared?(run)
      run.result.to_h["fathom_digest_shared"].present?
    end

    def dojo_scroll_payload(run)
      dojo_scroll_payload_from_hash(
        run.result.to_h["dojo_scroll_published"],
        run_id: run.id,
        fallback_date: run.target_date,
        source: "automation_run"
      )
    end

    def dojo_scroll_payload_from_hash(raw_payload, run_id:, fallback_date:, source:, stage_id: nil, event_index: nil, event_at: nil)
      payload = raw_payload.to_h.with_indifferent_access
      doc = payload["google_doc"].to_h.with_indifferent_access
      session_doc = payload["session_google_doc"].to_h.with_indifferent_access
      return if doc["webViewLink"].blank?

      folder = payload["folder"].to_h.with_indifferent_access
      dojo_date = fallback_date || parse_optional_date(payload["date"])
      {
        "run_id" => run_id,
        "source" => source,
        "stage_id" => stage_id,
        "event_index" => event_index,
        "event_at" => event_at&.iso8601,
        "date" => dojo_date&.iso8601 || payload["date"],
        "date_label" => dojo_date&.strftime("%b %-d, %Y"),
        "scorecards" => payload["scorecards"].to_i,
        "pass_count" => payload["pass_count"].to_i,
        "review_count" => payload["review_count"].to_i,
        "average_score" => payload["average_score"],
        "doc_name" => doc["name"],
        "url" => doc["webViewLink"],
        "doc_url" => doc["webViewLink"],
        "full_day_title" => doc["name"],
        "full_day_url" => doc["webViewLink"],
        "session_doc_name" => session_doc["name"],
        "session_url" => session_doc["webViewLink"],
        "session_doc_url" => session_doc["webViewLink"],
        "folder_url" => folder["webViewLink"],
        "updated_existing" => doc["updatedExisting"],
        "duplicate_count" => doc["duplicateCount"]
      }.compact_blank
    end

    def parse_optional_date(value)
      return if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def mark_dojo_scrolls_shared!(runs, email_result:, fathom_date:)
      Array(runs).each do |run|
        run.append_event!(
          step: "fathom_digest_shared",
          data: {
            fathom_date: fathom_date.iso8601,
            shared_at: Time.current.iso8601,
            email: email_result.to_h.slice("provider", "message_id", "MessageID", "to")
          }.compact_blank
        )
      rescue StandardError => error
        Rails.logger.warn("[Fathom::PublishTrainingDigestJob] Thumper DOJO shared marker failed run=#{run&.id}: #{error.class}: #{error.message}")
      end
    end

    def deliver_digest_mail(mail)
      if Postmark::OutboundClient.configured?
        Postmark::OutboundClient.deliver_mail(mail, message_stream: ENV["POSTMARK_MESSAGE_STREAM"].presence || "outbound")
      else
        mail.deliver_now
        { "provider" => "smtp", "message_id" => mail.message_id, "to" => Array(mail.to).join(",") }
      end
    end

    def already_delivered?(organization, request_id)
      return false if request_id.blank?

      status = Fathom::DailyCallSyncStatus.for(organization)
      status[:request_id].to_s == request_id.to_s && status[:digest_sent_at].present?
    end

    def automation_run_for(id)
      return if id.blank?

      WizwikiAutomationRun.find_by(id: id)
    end

    def google_doc_enabled?
      value = ENV["FATHOM_DIGEST_GOOGLE_DOC_ENABLED"]
      value.blank? || ActiveModel::Type::Boolean.new.cast(value)
    end

    def digest_email_enabled?
      value = ENV["FATHOM_DIGEST_EMAIL_ENABLED"]
      value.blank? || ActiveModel::Type::Boolean.new.cast(value)
    end

    def publish_digest_enabled?(value, date)
      return ActiveModel::Type::Boolean.new.cast(value) unless value.nil?
      return true if date == Time.current.in_time_zone("Central Time (US & Canada)").to_date

      ActiveModel::Type::Boolean.new.cast(ENV["FATHOM_DIGEST_EMAIL_HISTORICAL_ENABLED"]) == true
    end

    def normalize_result(value)
      value.to_h.each_with_object({}) { |(key, result_value), memo| memo[key.to_s] = result_value }
    end

    def parse_date(value)
      return Time.zone.today if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Time.zone.parse(value.to_s).to_date
    rescue ArgumentError, TypeError
      Time.zone.today
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def max_wait
      ENV.fetch("FATHOM_BRAIN_EMBEDDING_MAX_WAIT_MINUTES", (DEFAULT_MAX_WAIT / 1.minute).to_i.to_s).to_i.clamp(1, 240).minutes
    end

    def poll_interval
      ENV.fetch("FATHOM_BRAIN_EMBEDDING_POLL_SECONDS", "60").to_i.clamp(30, 600).seconds
    end
  end
end
