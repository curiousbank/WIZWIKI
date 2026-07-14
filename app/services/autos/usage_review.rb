module Autos
  class UsageReview
    TYPING_WPM = 40.0
    WORD_PATTERN = /[[:alnum:]][[:alnum:]'_-]*/.freeze

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(user:, organization:, relation:, all_relation:, label: "Thumper", now: Time.zone.now)
      @user = user
      @organization = organization
      @relation = relation
      @all_relation = all_relation
      @label = label
      @now = now
    end

    def call
      return empty_payload unless user.present?

      current_records = month_relation.to_a
      previous_records = previous_month_relation.to_a
      active_dates = active_dates_for(current_records)

      {
        label: label,
        month_label: now.strftime("%B %Y"),
        rank_label: rank_label,
        total_words: total_words(current_records),
        words_delta: total_words(current_records) - total_words(previous_records),
        prompt_words: current_records.sum { |record| word_count(record.question) },
        answer_words: current_records.sum { |record| word_count(record.answer) },
        voice_words: voice_words(current_records),
        sessions: current_records.size,
        sessions_delta: current_records.size - previous_records.size,
        active_days: active_dates.size,
        longest_streak: longest_streak(active_dates),
        avg_words_per_session: average(total_words(current_records), current_records.size),
        estimated_typing_minutes_saved: (total_words(current_records) / TYPING_WPM).round,
        peak_insight: peak_insight(current_records),
        calendar: calendar_for(current_records),
        embedding: embedding_payload(current_records)
      }
    end

    private

    attr_reader :user, :organization, :relation, :all_relation, :label, :now

    def empty_payload
      {
        label: label,
        month_label: now.strftime("%B %Y"),
        rank_label: "log in for personal review",
        total_words: 0,
        words_delta: 0,
        prompt_words: 0,
        answer_words: 0,
        voice_words: 0,
        sessions: 0,
        sessions_delta: 0,
        active_days: 0,
        longest_streak: 0,
        avg_words_per_session: 0,
        estimated_typing_minutes_saved: 0,
        peak_insight: "Ask Thumper or train a document to start building your review.",
        calendar: calendar_for([]),
        embedding: empty_embedding_payload
      }
    end

    def month_start
      now.beginning_of_month
    end

    def previous_month_start
      month_start.prev_month
    end

    def month_relation
      relation.where(created_at: month_start..now)
    end

    def previous_month_relation
      relation.where(created_at: previous_month_start...month_start)
    end

    def total_words(records)
      records.sum { |record| word_count(record.question) + word_count(record.answer) }
    end

    def voice_words(records)
      records.select { |record| record.metadata.to_h["input_mode"] == "voice" }
        .sum { |record| word_count(record.question) }
    end

    def word_count(text)
      text.to_s.scan(WORD_PATTERN).size
    end

    def average(total, count)
      return 0 if count.to_i <= 0

      (total.to_f / count).round
    end

    def active_dates_for(records)
      records.map { |record| record.created_at.in_time_zone.to_date }.uniq.sort
    end

    def longest_streak(dates)
      return 0 if dates.blank?

      streak = 1
      longest = 1
      dates.each_cons(2) do |previous, current|
        if current == previous + 1.day
          streak += 1
        else
          streak = 1
        end
        longest = [longest, streak].max
      end
      longest
    end

    def rank_label
      counts = all_relation
        .where(created_at: month_start..now)
        .where.not(user_id: nil)
        .group(:user_id)
        .count
      return "first month of data" if counts.blank?

      sorted = counts.sort_by { |_user_id, count| -count }
      rank = sorted.index { |user_id, _count| user_id.to_i == user.id.to_i }
      return "no #{label} sessions yet" unless rank

      position = rank + 1
      total = counts.size
      if total >= 10
        percentile = ((position.to_f / total) * 100).ceil
        "top #{percentile}% of active users"
      else
        "rank ##{position} of #{total} active users"
      end
    end

    def peak_insight(records)
      return "No active hour yet. Your next Thumper session starts the map." if records.blank?

      grouped = records.group_by { |record| [record.created_at.in_time_zone.wday, record.created_at.in_time_zone.hour] }
      (day, hour), count = grouped.max_by { |_key, values| values.size }
      day_name = Date::DAYNAMES[day]
      "#{day_name}s around #{hour_label(hour)} are your most active #{label} window this month (#{count} sessions)."
    end

    def hour_label(hour)
      time = Time.zone.local(2000, 1, 1, hour)
      time.strftime("%-l%P")
    end

    def calendar_for(records)
      by_day = records.group_by { |record| record.created_at.in_time_zone.to_date }
      last_day = month_start.end_of_month.day
      peak_count = by_day.values.map(&:size).max.to_i
      leading_blanks = month_start.to_date.wday

      Array.new(leading_blanks) { { day: nil, count: 0, intensity: 0 } } +
        (1..last_day).map do |day|
          date = month_start.to_date.change(day: day)
          count = by_day.fetch(date, []).size
          intensity = peak_count.positive? ? ((count.to_f / peak_count) * 4).ceil : 0
          { day: day, count: count, intensity: intensity }
        end
    end

    def embedding_payload(current_questions)
      question_ids = current_questions.map(&:id)
      training_documents = organization.training_documents.where(user: user, created_at: month_start..now)
      training_ids = training_documents.pluck(:id)
      chunks = AutosEmbeddingChunk.where(organization: organization).where(
        "(source_type = ? AND source_id IN (?)) OR (source_type = ? AND source_id IN (?))",
        "AutosQuestion", question_ids.presence || [0],
        "TrainingDocument", training_ids.presence || [0]
      )

      {
        training_documents: training_documents.count,
        training_words: training_documents.sum { |document| word_count(document.body) },
        chunks_total: chunks.count,
        chunks_embedded: chunks.where(status: "embedded").count,
        chunks_pending: chunks.where(status: ["pending", "claimed", "stale"]).count,
        chunks_failed: chunks.where(status: "failed").count,
        embedding_models: chunks.distinct.pluck(:embedding_model).compact.sort
      }
    rescue StandardError
      empty_embedding_payload
    end

    def empty_embedding_payload
      {
        training_documents: 0,
        training_words: 0,
        chunks_total: 0,
        chunks_embedded: 0,
        chunks_pending: 0,
        chunks_failed: 0,
        embedding_models: []
      }
    end
  end
end
