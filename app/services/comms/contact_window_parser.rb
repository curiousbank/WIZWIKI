# frozen_string_literal: true

module Comms
  class ContactWindowParser
    CENTRAL_ZONE = "Central Time (US & Canada)"
    BUSINESS_START_HOUR = 9
    AFTER_HOURS_CUTOFF = 17
    DAY_NAMES = Date::DAYNAMES.map(&:downcase).freeze
    TIME_ZONE_NAMES = {
      "ct" => CENTRAL_ZONE,
      "cst" => CENTRAL_ZONE,
      "cdt" => CENTRAL_ZONE,
      "et" => "Eastern Time (US & Canada)",
      "est" => "Eastern Time (US & Canada)",
      "edt" => "Eastern Time (US & Canada)",
      "mt" => "Mountain Time (US & Canada)",
      "mst" => "Mountain Time (US & Canada)",
      "mdt" => "Mountain Time (US & Canada)",
      "pt" => "Pacific Time (US & Canada)",
      "pst" => "Pacific Time (US & Canada)",
      "pdt" => "Pacific Time (US & Canada)"
    }.freeze

    Result = Struct.new(
      :raw,
      :day,
      :time_zone,
      :not_before_at,
      :not_after_at,
      :scheduled_for,
      :after_hours_rollover,
      :effective_window,
      keyword_init: true
    ) do
      def present?
        raw.present?
      end

      def metadata
        {
          "sms_autopilot_handoff_contact_time" => raw,
          "sms_autopilot_handoff_contact_day" => day,
          "sms_autopilot_handoff_contact_timezone" => time_zone,
          "sms_autopilot_handoff_contact_not_before_at" => not_before_at&.iso8601,
          "sms_autopilot_handoff_contact_not_after_at" => not_after_at&.iso8601,
          "sms_autopilot_handoff_contact_scheduled_for" => scheduled_for&.iso8601,
          "sms_autopilot_handoff_contact_after_hours_rollover" => after_hours_rollover,
          "sms_autopilot_handoff_contact_effective_window" => effective_window
        }.compact
      end
    end

    class << self
      def parse(text, now: Time.current)
        new(text, now: now).parse
      end

      def extract(text)
        body = text.to_s.squish
        return if body.blank?

        day_match = body.match(/\b(?:(?:this|next)\s+)?(?:today|tomorrow|tonight|weekday|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b[^.!?]{0,80}/i)
        if day_match.present?
          earlier_time = body.match(/\b(?:not\s+before|not\s+until|after|before|by|at|around|near)\s+(?:\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|lunch)\b/i)
          if earlier_time.present? && earlier_time.begin(0) < day_match.begin(0)
            return body[earlier_time.begin(0)...day_match.end(0)].squish
          end

          return day_match[0].squish
        end

        range = body[/\b(?:between\s+|from\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)?\s*(?:-|to|and)\s*\d{1,2}(?::\d{2})?\s*(?:am|pm)?(?:\s+(?:ct|cst|cdt|et|est|edt|mt|mst|mdt|pt|pst|pdt))?\b/i]
        return range.squish if range.present?

        phrase = body[/\b(?:not\s+before|not\s+until|after|before|by|at|around|near)\s+(?:\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|lunch)(?:\s+(?:ct|cst|cdt|et|est|edt|mt|mst|mdt|pt|pst|pdt))?\b/i]
        return phrase.squish if phrase.present?

        body[/\b(?:early\s+)?(?:morning|afternoon|evening|after lunch|before lunch|lunch time|lunchtime|business hours|anytime|any time|whenever)\b/i]&.squish
      end
    end

    def initialize(text, now:)
      @text = text.to_s.squish
      @now = now
    end

    def parse
      raw = self.class.extract(text)
      return Result.new if raw.blank?

      zone = detected_time_zone
      local_now = now.in_time_zone(zone)
      date, explicit_future_day = requested_date(local_now)
      lower, upper, exact, qualifier = time_bounds(date, zone)
      rollover = rollover_required?(local_now, date, lower, upper, exact, qualifier, explicit_future_day)

      if weekend?(date)
        rollover = true
      end

      if rollover
        date = next_business_day([date, local_now.to_date].max)
        lower = zone.local(date.year, date.month, date.day, BUSINESS_START_HOUR)
        upper = nil
        exact = nil
      end

      Result.new(
        raw: raw,
        day: date.iso8601,
        time_zone: zone.name,
        not_before_at: lower,
        not_after_at: upper,
        scheduled_for: exact,
        after_hours_rollover: rollover,
        effective_window: effective_window(date, zone, lower, upper, exact, rollover)
      )
    end

    private

    attr_reader :text, :now

    def detected_time_zone
      abbreviation = text.downcase[/\b(?:ct|cst|cdt|et|est|edt|mt|mst|mdt|pt|pst|pdt)\b/]
      ActiveSupport::TimeZone[TIME_ZONE_NAMES[abbreviation] || CENTRAL_ZONE]
    end

    def requested_date(local_now)
      body = text.downcase
      return [local_now.to_date + 1, true] if body.match?(/\btomorrow\b/)
      return [next_business_day(local_now.to_date), true] if body.match?(/\b(?:next\s+)?weekday\b/)
      return [next_weekend_day(local_now.to_date), true] if body.match?(/\b(?:this\s+|next\s+)?weekend\b/)

      day_name = DAY_NAMES.find { |name| body.match?(/\b(?:this\s+|next\s+)?#{name}s?\b/) }
      return [local_now.to_date, false] if day_name.blank?

      target_wday = DAY_NAMES.index(day_name)
      days_ahead = (target_wday - local_now.to_date.wday) % 7
      recurring_day = body.match?(/\b#{day_name}s\b/)
      days_ahead = 7 if days_ahead.zero? && (recurring_day || body.match?(/\bnext\s+#{day_name}\b/))
      [local_now.to_date + days_ahead, days_ahead.positive?]
    end

    def time_bounds(date, zone)
      body = text.downcase
      if (match = body.match(/\b(?:between\s+|from\s+)?(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(?:-|to|and)\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\b/))
        lower = time_on(date, match[1], zone)
        upper = time_on(date, match[2], zone, meridiem_hint: meridiem_from(match[1]))
        return [lower, upper, nil, "range"]
      end

      if body.match?(/\b(?:morning|before lunch)\b/)
        return [zone.local(date.year, date.month, date.day, 9), zone.local(date.year, date.month, date.day, 12), nil, "range"]
      end
      if body.match?(/\b(?:afternoon|after lunch)\b/)
        return [zone.local(date.year, date.month, date.day, 12), zone.local(date.year, date.month, date.day, 17), nil, "range"]
      end
      if body.match?(/\b(?:evening|tonight)\b/)
        return [zone.local(date.year, date.month, date.day, 17), nil, nil, "after"]
      end
      if body.match?(/\b(?:business hours)\b/)
        return [zone.local(date.year, date.month, date.day, 9), zone.local(date.year, date.month, date.day, 17), nil, "range"]
      end

      match = body.match(/\b(not\s+before|not\s+until|after|before|by|at|around|near)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|lunch)\b/)
      return [nil, nil, nil, nil] if match.blank?

      clock = time_on(date, match[2], zone)
      case match[1]
      when "after", "not before", "not until"
        [clock, nil, nil, "after"]
      when "before", "by"
        [nil, clock, nil, "before"]
      else
        [nil, nil, clock, "exact"]
      end
    end

    def time_on(date, value, zone, meridiem_hint: nil)
      token = value.to_s.downcase.squish
      return zone.local(date.year, date.month, date.day, 12) if token.in?(%w[noon lunch])

      match = token.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/)
      return if match.blank?

      hour = match[1].to_i
      minute = match[2].to_i
      meridiem = match[3].presence || meridiem_hint.presence || inferred_meridiem(hour)
      hour = 0 if hour == 12 && meridiem == "am"
      hour += 12 if hour < 12 && meridiem == "pm"
      zone.local(date.year, date.month, date.day, hour, minute)
    end

    def inferred_meridiem(hour)
      hour.between?(1, 7) ? "pm" : "am"
    end

    def meridiem_from(value)
      value.to_s.downcase[/\b(?:am|pm)\b/]
    end

    def rollover_required?(local_now, date, lower, upper, exact, qualifier, explicit_future_day)
      central_now = local_now.in_time_zone(CENTRAL_ZONE)
      received_after_hours = !explicit_future_day && date <= local_now.to_date && central_now.hour >= AFTER_HOURS_CUTOFF
      boundary = lower || exact
      requested_after_hours = boundary.present? && at_or_after_cutoff?(boundary) && qualifier == "after"
      exact_after_hours = exact.present? && after_cutoff?(exact)
      range_after_hours = lower.present? && upper.present? && after_cutoff?(upper)
      received_after_hours || requested_after_hours || exact_after_hours || range_after_hours
    end

    def at_or_after_cutoff?(value)
      central = value.in_time_zone(CENTRAL_ZONE)
      central >= central.change(hour: AFTER_HOURS_CUTOFF, min: 0, sec: 0)
    end

    def after_cutoff?(value)
      central = value.in_time_zone(CENTRAL_ZONE)
      central > central.change(hour: AFTER_HOURS_CUTOFF, min: 0, sec: 0)
    end

    def effective_window(date, zone, lower, upper, exact, rollover)
      day_label = date.strftime("%A, %B %-d")
      zone_label = zone.name == CENTRAL_ZONE ? "Central" : zone.tzinfo.name
      return "#{day_label} after #{format_time(lower)} #{zone_label}" if rollover
      return "#{day_label} at #{format_time(exact)} #{zone_label}" if exact.present?
      return "#{day_label} between #{format_time(lower)} and #{format_time(upper)} #{zone_label}" if lower.present? && upper.present?
      return "#{day_label} after #{format_time(lower)} #{zone_label}" if lower.present?
      return "#{day_label} before #{format_time(upper)} #{zone_label}" if upper.present?

      day_label
    end

    def format_time(value)
      value.strftime("%-I:%M %p").sub(":00", "")
    end

    def weekend?(date)
      date.saturday? || date.sunday?
    end

    def next_business_day(date)
      candidate = date + 1
      candidate += 1 while weekend?(candidate)
      candidate
    end

    def next_weekend_day(date)
      candidate = date
      candidate += 1 until candidate.saturday?
      candidate
    end
  end
end
