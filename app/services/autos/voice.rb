module Autos
  module Voice
    FRANKENSTEIN = Autos::Settings::FRANKENSTEIN


    def self.alice_voice
      Autos::Settings.alice_voice
    end

    def self.selected_voice(metadata)
      metadata = metadata.to_h
      Autos::Settings.normalize_tts_voice(
        metadata["autos_voice_preference"].presence ||
          metadata["autos_tts_voice"].presence ||
          metadata["alice_voice"].presence ||
          alice_voice
      )
    end

    def self.constrain_answer_length(answer, max_chars: nil, max_lines: nil)
      max_chars = max_chars ? max_chars.to_i.clamp(180, 4_000) : Autos::Settings.max_answer_chars
      max_lines = max_lines ? max_lines.to_i.clamp(1, 24) : Autos::Settings.max_answer_lines
      text = answer.to_s.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
      return text if text.blank?

      pieces = text.split(/(?<=[.!?])\s+|\n+/).map(&:strip).reject(&:blank?)
      pieces = [text] if pieces.blank?
      seen = {}
      kept = []

      pieces.each do |piece|
        normalized = piece.downcase.gsub(/[^[:alnum:]]+/, " ").strip
        next if normalized.present? && seen[normalized]

        seen[normalized] = true if normalized.present?
        kept << piece
        break if kept.length >= max_lines || kept.join(" ").length >= max_chars
      end

      result = kept.join("\n").strip
      if result.length > max_chars
        snippet = result[0, max_chars]
        boundary = [snippet.rindex("."), snippet.rindex("!"), snippet.rindex("?")].compact.max
        result = boundary && boundary > (max_chars / 2) ? snippet[0..boundary] : snippet.strip
        result = result.strip
        result += "..." unless result.end_with?(".", "!", "?", "...")
      end

      result
    end

    def self.customer_visible_answer(answer, question: nil, max_chars: nil, max_lines: nil)
      max_chars = max_chars ? max_chars.to_i.clamp(180, 4_000) : Autos::Settings.max_answer_chars
      max_lines = max_lines ? max_lines.to_i.clamp(1, 24) : Autos::Settings.max_answer_lines
      raw = answer.to_s
      candidate = extract_visible_answer_candidate(raw).presence || raw
      constrained = constrain_answer_length(candidate, max_chars: max_chars, max_lines: max_lines)
      return constrained unless internal_draft_leak?(constrained)

      constrain_answer_length(safe_visible_fallback(question), max_chars: max_chars, max_lines: max_lines)
    end

    def self.internal_draft_leak?(answer)
      text = answer.to_s.squish
      return false if text.blank?
      return true if defined?(Comms::SmsBodySafety) && Comms::SmsBodySafety.internal_leak?(text)
      return true if text.match?(/\A(?:STOP|THINKING|ANALYSIS|REASONING)\b/i)
      return true if text.match?(/\b(?:system prompt|developer prompt|operator_prompt|answer_contract|raw_prompt|metadata|latest_inbound_event|context_json|conversation_state|conversation\s+state|campaign_fit|missing\s+fit\s+signal)\b/i)
      return true if text.match?(/\A(?:to the question about|this answers|the next step is to (?:provide|ask|collect|route)|we are in the middle of)\b/i)
      return true if text.match?(/\b(?:we are given a user question|we must answer|we are to answer|we need to answer|we have to answer|the user is asking|first,\s*note the voice rules|looking at the context|let's look at the context|following the voice rules|we cannot invent details|do not invent details|must use the context provided|the conversation state shows|the latest inbound message was|household count question)\b/i)

      false
    end

    def self.extract_visible_answer_candidate(answer)
      text = answer.to_s.gsub(/\r\n?/, "\n").strip
      return "" if text.blank?

      markers = [
        /(?:\A|\n)\s*(?:FINAL\s+ANSWER|VISIBLE\s+ANSWER|CUSTOMER[-\s]?FACING\s+ANSWER|Thumper|THUMPER|ANSWER|RESPONSE)\s*:\s*/i,
        /(?:\A|\n)\s*A\s*:\s*/i
      ]
      positions = markers.flat_map do |pattern|
        text.enum_for(:scan, pattern).map { Regexp.last_match.end(0) }
      end.sort.reverse

      positions.each do |index|
        candidate = text[index..].to_s.strip
        candidate = candidate.sub(/\A```(?:text|markdown)?\s*/i, "").sub(/```\s*\z/, "").strip
        return candidate if candidate.present? && !internal_draft_leak?(candidate)
      end

      text
    end

    def self.safe_visible_fallback(question)
      prompt = [question&.question, question&.context].compact.join(" ").downcase

      if prompt.match?(/\bfathom\b/) && prompt.match?(/\bfavou?rite\b/)
        return "I do not have a personal favorite, but I can pick the most useful Fathom call by signal: clear customer need, Thumper's wording, objections, and next action. Want me to rank the recent calls that way?"
      end

      if prompt.match?(/\bfathom\b|\bcalls?\b/)
        return "I can help with the Fathom calls, but I should rank them from the actual call context instead of guessing. Want me to sort them by voice, customer signal, or follow-up opportunity?"
      end

      "I caught an internal draft before publishing a clean answer. Ask that one again and I will answer directly from the WIZWIKI context."
    end

    def self.generate_for_question(question)
      return unless question&.answer.present?

      metadata = question.metadata.to_h.deep_dup
      return if metadata["autos_voice_url"].present?

      metadata["autos_voice_status"] = "generating"
      question.update!(metadata: metadata)
      Autos::WorkerQueue.broadcast(question)

      spoken_text = question.answer.to_s
        .gsub(%r{https?://\S+}, " link ")
        .gsub(/[*_`#>]/, "")
        .squish
        .truncate(Autos::Settings.tts_max_spoken_chars)

      voice = selected_voice(metadata)
      url = TtsService.generate_url(
        text: spoken_text,
        voice: voice,
        ttl: Autos::Settings.tts_ttl_seconds.seconds
      )

      metadata = question.reload.metadata.to_h.deep_dup
      if url.present?
        metadata.merge!(
          "autos_voice_url" => url,
          "autos_voice" => voice,
          "alice_voice" => voice,
          "autos_voice_status" => "ready",
          "autos_voice_generated_at" => Time.current.iso8601
        )
      else
        metadata.merge!(
          "autos_voice_status" => "failed",
          "autos_voice_failed_at" => Time.current.iso8601
        )
      end

      question.update!(metadata: metadata)
      Autos::WorkerQueue.broadcast(question)
    rescue StandardError => error
      Rails.logger.warn("[WIZWIKI Autos::Voice] #{error.class}: #{error.message}")
      if question&.persisted?
        metadata = question.metadata.to_h.deep_dup
        metadata["autos_voice_status"] = "failed"
        metadata["autos_voice_error"] = error.message.to_s.truncate(240)
        question.update!(metadata: metadata)
        Autos::WorkerQueue.broadcast(question)
      end
      nil
    end
  end
end
