module Autos
  class EmbeddingSource
    CHUNK_CHARS = 1_500
    CRM_MAX_CHUNKS = 8
    CRM_SOURCE_SCHEMA_VERSION = 3
    CRM_RAW_HUBSPOT_KEYS = %w[
      hs_object_id firstname lastname name company company_name dealname
      email phone mobilephone website domain industry hs_industry_group
      amount closedate dealstage dealstage_label pipeline hs_pipeline
      hs_pipeline_stage hubspot_owner_id hubspot_owner_name hs_lead_name
      hs_lead_label hs_lead_stage hs_lead_quality hs_ticket_priority
      subject content lead_status lifecyclestage hs_analytics_source
      hs_latest_source hs_analytics_source_data_1 hs_analytics_source_data_2
      hs_latest_source_data_1 hs_latest_source_data_2
      b__shopify_eddm_order ip__shopify__orders_count shopify_amount_spent
      ip__shopify__shopify_created_at ip__shopify__tags
    ].freeze
    CRM_TOP_LEVEL_PROPERTY_KEYS = %w[
      lead_type package callback_channel payment_status industry business_type
      campaign_type product_interest product_interest_code contact_preference
      source notes city state postal_code zip
    ].freeze

    class << self
      def chunks_for(source)
        text = case source
        when PlaybookCall
          playbook_call_text(source)
        when TrainingDocument
          training_document_text(source)
        when CrmRecord
          crm_record_text(source)
        when CrmAddressRecord
          crm_address_record_text(source)
        when WeatherLeadSignal
          weather_lead_signal_text(source)
        when FathomCall
          fathom_call_text(source)
        when AutosQuestion
          autos_question_text(source)
        when CrmRecordArtifact
          crm_record_artifact_text(source)
        else
          generic_text(source)
        end

        pieces = chunk_text(clean(text))
        pieces = pieces.first(CRM_MAX_CHUNKS) if source.is_a?(CrmRecord)

        pieces.map.with_index do |content, index|
          {
            label: label_for(source, index),
            content: content,
            metadata: metadata_for(source)
          }
        end
      end

      private

      def playbook_call_text(call)
        associated = Autos::WorkerQueue.associated_records_for_call(call).map do |record|
          [
            "#{record.record_type}: #{record.name}",
            record.email.present? ? "email=#{record.email}" : nil,
            record.phone.present? ? "phone=#{record.phone}" : nil,
            record.domain.present? ? "domain=#{record.domain}" : nil,
            record.stage.present? ? "stage=#{record.stage}" : nil,
            record.status.present? ? "status=#{record.status}" : nil
          ].compact.join(" | ")
        end

        [
          "PLAYBOOK CALL",
          call.compact_context(max_chars: 4_000),
          call.analyzer_text.presence,
          "associated_records:",
          associated.join("\n").presence,
          call.playbook_data.present? ? "playbook_data=#{call.playbook_data.to_json}" : nil
        ].compact.join("\n")
      end

      def training_document_text(document)
        metadata = document.metadata.to_h
        [
          "TRAINING DOCUMENT",
          "title=#{document.title}",
          "source_type=#{document.source_type}",
          document.file_name.present? ? "file_name=#{document.file_name}" : nil,
          metadata["folder_path"].present? ? "folder_path=#{metadata["folder_path"]}" : nil,
          metadata["training_kind"].present? ? "training_kind=#{metadata["training_kind"]}" : nil,
          document.body
        ].compact.join("\n")
      end

      def crm_record_text(record)
        properties = record.properties.to_h
        hubspot = properties.fetch("hubspot", {}).to_h
        labeled = compact_embedding_hash(hubspot.fetch("labeled_properties", {}), max_entries: 40)
        raw = compact_embedding_hash(hubspot.fetch("properties", {}).to_h.slice(*CRM_RAW_HUBSPOT_KEYS), max_entries: 50)
        record_context = compact_embedding_hash(properties.slice(*CRM_TOP_LEVEL_PROPERTY_KEYS), max_entries: 30)
        weather = crm_weather_summary(properties.fetch("weather_lead", {}))

        [
          "CRM #{record.record_type.to_s.upcase}",
          "name=#{record.name}",
          record.email.present? ? "email=#{record.email}" : nil,
          record.phone.present? ? "phone=#{record.phone}" : nil,
          record.domain.present? ? "domain=#{record.domain}" : nil,
          record.stage.present? ? "stage=#{record.stage}" : nil,
          record.status.present? ? "status=#{record.status}" : nil,
          record.amount.present? ? "amount=#{record.amount}" : nil,
          record.close_date.present? ? "close_date=#{record.close_date}" : nil,
          labeled.present? ? "hubspot_labeled=#{labeled.to_json}" : nil,
          raw.present? ? "hubspot_properties=#{raw.to_json}" : nil,
          record_context.present? ? "record_context=#{record_context.to_json}" : nil,
          weather.present? ? "weather_lead=#{weather.to_json}" : nil
        ].compact.join("\n")
      end

      def crm_weather_summary(value)
        weather = value.to_h
        return {} if weather.blank?

        compact_embedding_hash(
          weather.slice("lead_source", "lookback_days", "signals_count", "matched_signals_count", "matched_postal_code_count"),
          max_entries: 5
        )
      end

      def compact_embedding_hash(value, max_entries:, max_value_chars: 320)
        value.to_h.first(max_entries).each_with_object({}) do |(key, raw_value), memo|
          normalized = case raw_value
          when Hash, Array
            raw_value.to_json.truncate(max_value_chars)
          else
            raw_value.to_s.squish.truncate(max_value_chars)
          end
          memo[key.to_s] = normalized if normalized.present?
        end
      end

      def crm_address_record_text(record)
        source = record.crm_record || record.playbook_call
        [
          "CRM ADDRESS",
          "address=#{record.display_address}",
          "kind=#{record.address_kind}",
          record.city.present? ? "city=#{record.city}" : nil,
          record.state.present? ? "state=#{record.state}" : nil,
          record.postal_code.present? ? "postal_code=#{record.postal_code}" : nil,
          record.country.present? ? "country=#{record.country}" : nil,
          record.record_type.present? ? "record_type=#{record.record_type}" : nil,
          source.respond_to?(:name) && source.name.present? ? "source_record=#{source.name}" : nil,
          source.respond_to?(:title) && source.title.present? ? "source_call=#{source.title}" : nil,
          record.association_context.present? ? "association_context=#{record.association_context.to_json}" : nil
        ].compact.join("\n")
      end

      def weather_lead_signal_text(signal)
        [
          "WEATHER LEAD SIGNAL",
          "event=#{signal.event}",
          signal.headline.present? ? "headline=#{signal.headline}" : nil,
          signal.severity.present? ? "severity=#{signal.severity}" : nil,
          signal.urgency.present? ? "urgency=#{signal.urgency}" : nil,
          signal.certainty.present? ? "certainty=#{signal.certainty}" : nil,
          signal.area_desc.present? ? "area=#{signal.area_desc}" : nil,
          signal.affected_states.present? ? "states=#{signal.affected_states.join(', ')}" : nil,
          signal.affected_postal_codes.present? ? "postal_codes=#{signal.affected_postal_codes.join(', ')}" : nil,
          signal.started_at.present? ? "started_at=#{signal.started_at.iso8601}" : nil,
          signal.expires_at.present? ? "expires_at=#{signal.expires_at.iso8601}" : nil,
          signal.description.present? ? "description=#{signal.description.truncate(1_000)}" : nil,
          signal.metadata.present? ? "metadata=#{signal.metadata.to_json}" : nil
        ].compact.join("\n")
      end

      def fathom_call_text(call)
        [
          "FATHOM BRAIN CALL",
          "title=#{call.title.presence || call.meeting_title}",
          call.recording_start_time.present? ? "recorded_at=#{call.recording_start_time.iso8601}" : nil,
          call.recorded_by_name.present? ? "recorded_by=#{call.recorded_by_name}" : nil,
          call.recorded_by_email.present? ? "recorded_by_email=#{call.recorded_by_email}" : nil,
          call.meeting_type.present? ? "meeting_type=#{call.meeting_type}" : nil,
          call.share_url.present? ? "fathom_link=#{call.share_url}" : nil,
          call.participant_label.present? ? "participants=#{call.participant_label}" : nil,
          call.crm_matches.present? ? "crm_matches=#{call.crm_matches.to_json}" : nil,
          call.summary.present? ? "summary=#{call.summary}" : nil,
          call.action_items_text.present? ? "action_items=#{call.action_items_text}" : nil,
          call.highlights_text.present? ? "highlights=#{call.highlights_text}" : nil,
          call.transcript.present? ? "transcript=#{call.transcript}" : nil
        ].compact.join("\n")
      end

      def autos_question_text(question)
        metadata = question.metadata.to_h
        return weather_analysis_text(question, metadata) if metadata["surface"].to_s == "weather_outcome_analysis"

        [
          "THUMPER CHAT MEMORY",
          "brain_type=wizwiki_ask",
          "surface=ask",
          "organization=#{question.organization&.name}",
          "user=#{question.user&.display_name}",
          "asked_at=#{question.created_at&.iso8601}",
          "answered_at=#{question.updated_at&.iso8601}",
          metadata.dig("local_worker", "model").present? ? "model=#{metadata.dig('local_worker', 'model')}" : nil,
          metadata.dig("local_worker", "provider").present? ? "provider=#{metadata.dig('local_worker', 'provider')}" : nil,
          "",
          "USER QUESTION:",
          question.question.to_s.squish.truncate(900),
          question.context.present? ? "USER ADDED CONTEXT:\n#{question.context.to_s.squish.truncate(500)}" : nil,
          "",
          "THUMPER ANSWER:",
          question.answer.to_s.squish.truncate(1_300)
        ].compact.join("\n")
      end

      def weather_analysis_text(question, metadata)
        parsed_answer = JSON.parse(question.answer.to_s)
        [
          "Thumper WEATHER CALIBRATION MEMORY",
          "brain_type=weather_calibration",
          "surface=weather_outcome_analysis",
          "schema_version=#{metadata['weather_schema_version']}",
          "knowledge_version=#{metadata['weather_knowledge_version']}",
          "batch_digest=#{metadata['weather_batch_digest']}",
          "independent_sample_size=#{metadata['weather_sample_size']}",
          "analyzed_at=#{question.updated_at&.iso8601}",
          "model=#{metadata.dig('local_worker', 'model')}",
          "validated_analysis=#{JSON.generate(parsed_answer)}"
        ].compact.join("\n")
      rescue JSON::ParserError
        ""
      end

      def crm_record_artifact_text(artifact)
        metadata = artifact.metadata.to_h
        return generic_text(artifact) unless artifact.artifact_type.to_s == "comm_staging"

        sms_thread = Array(metadata["sms_thread"]).last(12).map do |event|
          event = event.to_h
          [
            "#{event["created_at"]} SMS #{event["direction"]} #{event["status"]}",
            event["to"].present? ? "to=#{event["to"]}" : nil,
            event["body"].present? ? "body=#{event["body"]}" : nil,
            event["error"].present? ? "error=#{event["error"]}" : nil
          ].compact.join(" | ")
        end

        email_thread = Array(metadata["email_thread"]).last(8).map do |event|
          event = event.to_h
          [
            "#{event["created_at"]} EMAIL #{event["direction"]} #{event["status"]}",
            event["to"].present? ? "to=#{event["to"]}" : nil,
            event["subject"].present? ? "subject=#{event["subject"]}" : nil,
            event["body"].present? ? "body=#{event["body"].to_s.truncate(900)}" : nil,
            event["error"].present? ? "error=#{event["error"]}" : nil
          ].compact.join(" | ")
        end

        [
          "Thumper COMMS COMMAND MEMORY",
          "company=#{metadata["company_name"].presence || artifact.crm_record&.name}",
          "deal=#{metadata["deal_name"].presence || artifact.crm_record&.name}",
          "direction=#{metadata["comm_kit_direction_label"].presence || metadata["comm_kit_direction"]}",
          "status=#{artifact.status}",
          metadata["processing_code"].present? ? "processing_code=#{metadata["processing_code"]}" : nil,
          metadata["processing_label"].present? ? "processing_label=#{metadata["processing_label"]}" : nil,
          metadata["processing_next_step"].present? ? "processing_next_step=#{metadata["processing_next_step"]}" : nil,
          metadata["processing_summary"].present? ? "processing_summary=#{metadata["processing_summary"]}" : nil,
          "organization_context=Use only the organization facts supplied in this record and its approved source documents.",
          metadata["recipient_selection_summary"].present? ? "recipient_selection=#{metadata["recipient_selection_summary"]}" : nil,
          metadata["aircall_selected_contact"].present? ? "selected_contact=#{metadata["aircall_selected_contact"].to_json}" : nil,
          metadata["aircall_selected_phone"].present? ? "selected_phone=#{metadata["aircall_selected_phone"].to_json}" : nil,
          metadata["aircall_selected_recipient_email"].present? ? "selected_email=#{metadata["aircall_selected_recipient_email"].to_json}" : nil,
          metadata["aircall_composed_sms_body"].present? ? "approved_sms=#{metadata["aircall_composed_sms_body"]}" : nil,
          metadata["aircall_composed_email_subject"].present? ? "approved_email_subject=#{metadata["aircall_composed_email_subject"]}" : nil,
          metadata["aircall_composed_email_body"].present? ? "approved_email_body=#{metadata["aircall_composed_email_body"].to_s.truncate(1_200)}" : nil,
          sms_thread.present? ? "sms_thread:\n#{sms_thread.join("\n")}" : nil,
          email_thread.present? ? "email_thread:\n#{email_thread.join("\n")}" : nil
        ].compact.join("\n")
      end


      def generic_text(source)
        source.respond_to?(:attributes) ? source.attributes.to_json : source.to_s
      end

      def clean(text)
        text.to_s
          .gsub(/\r\n?/, "\n")
          .gsub(/[ \t]+/, " ")
          .gsub(/\n{4,}/, "\n\n\n")
          .strip
      end

      def chunk_text(text)
        return [] if text.blank?

        chunks = []
        current = +""
        text.split(/\n{2,}/).each do |paragraph|
          paragraph = paragraph.strip
          next if paragraph.blank?

          split_long_paragraph(paragraph).each do |piece|
            if current.length + piece.length + 2 > CHUNK_CHARS && current.present?
              chunks << current.strip
              current = +""
            end
            current << "\n\n" if current.present?
            current << piece
          end
        end
        chunks << current.strip if current.present?
        chunks.select { |chunk| chunk.length >= 120 }.presence || [text.first(CHUNK_CHARS)]
      end

      def split_long_paragraph(paragraph)
        return [paragraph] if paragraph.length <= CHUNK_CHARS

        pieces = []
        current = +""
        paragraph.split(/(?<=[.!?])\s+|\n+/).each do |sentence|
          sentence = sentence.strip
          next if sentence.blank?

          if sentence.length > CHUNK_CHARS
            pieces << current.strip if current.present?
            current = +""
            pieces.concat(split_by_words(sentence))
            next
          end

          if current.length + sentence.length + 1 > CHUNK_CHARS && current.present?
            pieces << current.strip
            current = +""
          end
          current << " " if current.present?
          current << sentence
        end
        pieces << current.strip if current.present?
        pieces
      end

      def split_by_words(text)
        pieces = []
        current = +""
        text.split(/\s+/).each do |word|
          if word.length > CHUNK_CHARS
            pieces << current.strip if current.present?
            current = +""
            word.scan(/.{1,#{CHUNK_CHARS}}/m).each { |part| pieces << part }
            next
          end

          if current.length + word.length + 1 > CHUNK_CHARS && current.present?
            pieces << current.strip
            current = +""
          end
          current << " " if current.present?
          current << word
        end
        pieces << current.strip if current.present?
        pieces
      end

      def label_for(source, index)
        base = if source.respond_to?(:title) && source.title.present?
          source.title
        elsif source.respond_to?(:name) && source.name.present?
          source.name
        else
          "#{source.class.name} #{source.try(:id)}"
        end

        index.zero? ? base : "#{base} ##{index + 1}"
      end

      def metadata_for(source)
        metadata = {
          source_type: source.class.name,
          source_id: source.try(:id),
          occurred_at: source.try(:occurred_at)&.iso8601,
          updated_at: source.try(:updated_at)&.iso8601
        }.compact

        if defined?(CrmRecord) && source.is_a?(CrmRecord)
          metadata["source_schema_version"] = CRM_SOURCE_SCHEMA_VERSION
        end

        if defined?(TrainingDocument) && source.is_a?(TrainingDocument) && defined?(Comms::TrainingMemoryPolicy)
          metadata.merge!(Comms::TrainingMemoryPolicy.embedding_metadata(source))
        end

        if defined?(AutosQuestion) && source.is_a?(AutosQuestion)
          question_metadata = source.metadata.to_h
          surface = question_metadata["surface"].to_s.presence || "ask"
          weather_analysis = surface == "weather_outcome_analysis"
          weather_valid = ActiveModel::Type::Boolean.new.cast(question_metadata.dig("weather_analysis_validation", "valid"))
          metadata.merge!(
            "surface" => surface,
            "brain_type" => weather_analysis ? "weather_calibration" : "wizwiki_ask",
            "weather_analysis_valid" => weather_valid,
            "weather_batch_digest" => question_metadata["weather_batch_digest"],
            "weather_schema_version" => question_metadata["weather_schema_version"],
            "retrieval_role" => weather_analysis ? "weather_calibration_memory" : "chat_memory",
            "composition_eligible" => !weather_analysis || weather_valid
          )
        end

        metadata
      end
    end
  end
end
