# frozen_string_literal: true

module Jscalendar
  module Recurrence
    PARTS = { "interval" => "INTERVAL", "firstDayOfWeek" => "WKST", "byMonthDay" => "BYMONTHDAY",
              "byMonth" => "BYMONTH", "byYearDay" => "BYYEARDAY", "byWeekNo" => "BYWEEKNO", "byHour" => "BYHOUR",
              "byMinute" => "BYMINUTE", "bySecond" => "BYSECOND", "bySetPosition" => "BYSETPOS", "count" => "COUNT" }.freeze

    module_function

    def to_rrule(rule)
      rule = rule.to_h if rule.is_a?(Model)
      errors = Validator.new.validate(rule, type: "RecurrenceRule")
      raise ValidationError, errors unless errors.empty?
      raise UnsupportedError, "only Gregorian recurrence expansion is supported" unless rule.fetch("rscale", "gregorian") == "gregorian"
      raise UnsupportedError, "recurrence expansion supports only skip=omit" unless rule.fetch("skip", "omit") == "omit"
      raise UnsupportedError, "recurrence expansion does not support leap seconds" if rule.fetch("bySecond", []).include?(60)

      parts = ["FREQ=#{rule.fetch("frequency").upcase}"]
      PARTS.each { |name, keyword| parts << "#{keyword}=#{Array(rule[name]).join(",").upcase}" if rule.key?(name) }
      parts << "BYDAY=#{rule["byDay"].map { |day| "#{day["nthOfPeriod"]}#{day.fetch("day").upcase}" }.join(",")}" if rule["byDay"]
      # The engine runs in UTC as a wall-clock calendar; zone conversion occurs afterwards.
      parts << "UNTIL=#{LocalDateTime.new(rule["until"]).to_time.strftime("%Y%m%dT%H%M%SZ")}" if rule["until"]
      parts.join(";")
    end

    def rule_times(rule, initial, from, to, limit:, include_initial: true)
      to_rrule(rule) # Validate before constructing candidates.
      GregorianRecurrence.new(rule, initial).between(from, to, limit: limit, include_initial: include_initial)
    end
  end

  # Authored from the candidate/filter rules in RFC 8984 section 4.3.3.1
  # and RFC 5545 section 3.3.10. Dates are wall-clock UTC until zone conversion.
  class GregorianRecurrence
    DAYS = %w[su mo tu we th fr sa].freeze
    SECONDS = { "weekly" => 604_800, "daily" => 86_400, "hourly" => 3600, "minutely" => 60, "secondly" => 1 }.freeze
    CLOCK = [["byHour", 3600, 24], ["byMinute", 60, 60], ["bySecond", 1, 60]].freeze

    def initialize(rule, initial)
      @rule = Jscalendar.deep_copy(rule)
      @initial = initial
      @frequency = @rule.fetch("frequency")
      @interval = @rule.fetch("interval", 1)
      @week_start = DAYS.index(@rule.fetch("firstDayOfWeek", "mo"))
      @until = LocalDateTime.new(@rule["until"]).to_time if @rule["until"]
      add_defaults
    end

    def between(from, to, limit:, include_initial:)
      count = @rule["count"]
      return [] if count == 0

      result = []
      generated = include_initial ? 1 : 0
      result << @initial if include_initial && @initial >= from && @initial < to
      return result if (count && generated >= count) || result.size >= limit

      index = count ? 0 : first_period(from)
      loop do
        start = period(index)
        break if start >= to || (@until && start > @until)

        each_candidate(start) do |candidate|
          next if candidate < @initial || (include_initial && candidate == @initial)
          return result if candidate >= to || (@until && candidate > @until)

          generated += 1
          result << candidate if candidate >= from
          return result if (count && generated >= count) || result.size >= limit
        end
        index += 1
      end
      result
    end

    private

    def add_defaults
      width = SECONDS.fetch(@frequency, 86_400)
      CLOCK.each do |name, seconds, _size|
        @rule[name] ||= [(@initial.hour * 3600 + @initial.min * 60 + @initial.sec) / seconds % (name == "byHour" ? 24 : 60)] if width > seconds
      end
      weekday = [{ "day" => DAYS[@initial.wday] }]
      @rule["byDay"] ||= weekday if @frequency == "weekly"
      if @frequency == "monthly" && !@rule.key?("byDay")
        @rule["byMonthDay"] ||= [@initial.day]
      end
      return unless @frequency == "yearly" && !@rule.key?("byYearDay")

      if !@rule.key?("byMonth") && !@rule.key?("byWeekNo") && (@rule.key?("byMonthDay") || !@rule.key?("byDay"))
        @rule["byMonth"] = [@initial.month.to_s]
      end
      return if @rule.key?("byMonthDay") || @rule.key?("byDay")

      @rule[@rule.key?("byWeekNo") ? "byDay" : "byMonthDay"] = @rule.key?("byWeekNo") ? weekday : [@initial.day]
    end

    def date(year, month = 1, day = 1)
      Date.new(year, month, day, Date::GREGORIAN)
    end

    def midnight(value)
      Time.utc(value.year, value.month, value.day)
    end

    def period(index)
      steps = index * @interval
      case @frequency
      when "yearly" then Time.utc(@initial.year + steps)
      when "monthly" then midnight(date(@initial.year, @initial.month) >> steps)
      when "weekly"
        first = date(@initial.year, @initial.month, @initial.day)
        midnight(first - ((first.wday - @week_start) % 7)) + steps * 604_800
      else
        width = SECONDS.fetch(@frequency)
        Time.at(@initial.to_i.div(width) * width + steps * width).utc
      end
    end

    # Jump whole periods only when COUNT does not require counting earlier matches.
    def first_period(from)
      delta = case @frequency
              when "yearly" then from.year - @initial.year
              when "monthly" then (from.year - @initial.year) * 12 + from.month - @initial.month
              else ((from.to_r - period(0).to_r) / SECONDS.fetch(@frequency)).floor
              end
      [delta.div(@interval), 0].max
    end

    def dates_in(start)
      first = date(start.year, start.month, start.day)
      last = case @frequency
             when "yearly" then date(start.year + 1) - 1
             when "monthly" then (first >> 1) - 1
             when "weekly" then first + 6
             else first
             end
      (first..last).select { |value| date_matches?(value) }
    end

    def signed_member?(values, number, length)
      values.include?(number) || values.include?(number - length - 1)
    end

    def week_one(year)
      january_fourth = date(year, 1, 4)
      january_fourth - ((january_fourth.wday - @week_start) % 7)
    end

    def week_matches?(value)
      year = value.year
      first = week_one(year)
      if value < first
        year -= 1
        first = week_one(year)
      elsif value >= week_one(year + 1)
        year += 1
        first = week_one(year)
      end
      number = ((value - first).to_i / 7) + 1
      signed_member?(@rule["byWeekNo"], number, (week_one(year + 1) - first).to_i / 7)
    end

    def date_matches?(value)
      return false if @rule.key?("byMonth") && !@rule["byMonth"].include?(value.month.to_s)
      return false if @rule.key?("byWeekNo") && !week_matches?(value)
      return false if @rule.key?("byYearDay") && !signed_member?(@rule["byYearDay"], value.yday, date(value.year, 12, 31).yday)
      return false if @rule.key?("byMonthDay") && !signed_member?(@rule["byMonthDay"], value.day, date(value.year, value.month, -1).day)

      !@rule.key?("byDay") || @rule["byDay"].any? { |day| day_matches?(value, day) }
    end

    def day_matches?(value, day)
      return false unless DAYS[value.wday] == day["day"]
      return true unless day.key?("nthOfPeriod")

      # RFC 8984 uses the frequency period even when BYMONTH is present.
      if @frequency == "monthly"
        first = date(value.year, value.month)
        last = date(value.year, value.month, -1)
      elsif @frequency == "yearly"
        first = date(value.year)
        last = date(value.year, 12, 31)
      else
        return [1, -1].include?(day["nthOfPeriod"])
      end
      signed_member?([day["nthOfPeriod"]], (value - first).to_i / 7 + 1,
                     (value - first).to_i / 7 + 1 + (last - value).to_i / 7)
    end

    def clock_values(start)
      width = SECONDS.fetch(@frequency, 86_400)
      CLOCK.map do |name, seconds, size|
        values = @rule.fetch(name, (0...size).to_a).uniq.sort
        values &= [(start.hour * 3600 + start.min * 60 + start.sec) / seconds % size] if width <= seconds
        values
      end
    end

    def each_candidate(start)
      dates = dates_in(start)
      hours, minutes, seconds = clock_values(start)
      per_day = hours.size * minutes.size * seconds.size
      size = dates.size * per_day
      return if size.zero?

      # Index the Cartesian product instead of allocating up to 31 million
      # Time objects for a yearly period with all clock values and BYSETPOS.
      positions = if @rule.key?("bySetPosition")
                    @rule["bySetPosition"].map { |n| n.positive? ? n - 1 : size + n }.select { |n| n >= 0 && n < size }.uniq.sort
                  else
                    0...size
                  end
      positions.each do |position|
        day_index, remainder = position.divmod(per_day)
        hour_index, remainder = remainder.divmod(minutes.size * seconds.size)
        minute_index, second_index = remainder.divmod(seconds.size)
        value = dates[day_index]
        yield Time.utc(value.year, value.month, value.day, hours[hour_index], minutes[minute_index], seconds[second_index]) + @initial.subsec
      end
    end
  end

  class RecurrenceRule
    def to_rrule
      Recurrence.to_rrule(to_h)
    end
  end

  class Occurrence
    attr_reader :recurrence_id, :event
    alias calendar event

    def initialize(id, event, time_zone)
      @recurrence_id = LocalDateTime.new(id)
      @event = event
      @time_zone = time_zone
    end

    def start_time(time_zone: @time_zone)
      @event.start_time(time_zone: time_zone)
    end
  end

  class Occurrences
    include Enumerable

    def initialize(calendar, from:, to:, limit:, time_zone:, timeout:)
      raise ArgumentError, "from and to must be Times with from < to" unless from.is_a?(Time) && to.is_a?(Time) && from < to
      unless limit.is_a?(Integer) && limit.positive? && limit <= calendar.limits[:max_occurrences]
        raise ArgumentError, "limit must be positive and <= max_occurrences"
      end
      raise ArgumentError, "timeout must be positive and finite" unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?

      @truncated = false
      @items = Timeout.timeout(timeout, LimitError, "recurrence expansion exceeded time limit") do
        expand(calendar, from, to, limit, time_zone)
      end
    end

    def each(&block)
      return enum_for(:each) unless block

      @items.each(&block)
      self
    end

    def truncated?
      @truncated
    end

    private

    def expand(calendar, from, to, limit, time_zone)
      data = calendar.to_h
      initial_text = data["start"] || data["due"]
      raise ValidationError, "calendar has no start or due" unless initial_text

      initial = LocalDateTime.new(initial_text).to_time
      zone = data["timeZone"] || time_zone
      resolver = zone && TimeZoneResolver.new(zone, calendar.effective_time_zones)
      lower, upper = resolver ? resolver.wall_bounds(from, to) : [from.getutc, to.getutc]
      maximum = calendar.limits[:max_occurrences]
      rules = data.fetch("recurrenceRules", [])
      exclusions = data.fetch("excludedRecurrenceRules", [])
      overrides = data.fetch("recurrenceOverrides", {})
      raise LimitError, "too many recurrence rules" if rules.size + exclusions.size > calendar.limits[:max_rules]

      # Without removals, moved instances, or offset changes, each rule's first
      # limit+1 dates suffice to determine the first limit results and truncation.
      simple = exclusions.empty? && overrides.empty? && [nil, "UTC"].include?(zone)
      generation_limit = simple ? limit + 1 : maximum + 1
      candidates = [initial]
      rules.each do |rule|
        dates = Recurrence.rule_times(rule, initial, lower, upper, limit: generation_limit)
        @truncated ||= dates.size > maximum
        candidates.concat(dates.first(maximum))
      end
      exclusions.each do |rule|
        dates = Recurrence.rule_times(rule, initial, lower, upper, limit: maximum + 1, include_initial: false)
        raise LimitError, "excluded recurrence set exceeds max_occurrences" if dates.size > maximum

        candidates -= dates
      end
      candidates.concat(overrides.keys.map { |date| LocalDateTime.new(date).to_time })
      property = data.key?("start") ? "start" : "due"
      resolvers = {}
      items = candidates.uniq.filter_map do |date|
        id = LocalDateTime.from_time(date).to_s
        patch = overrides.fetch(id, {})
        next if patch.fetch("excluded", data.fetch("excluded", false)) == true

        fields = { "start" => data["start"], "due" => data["due"], "timeZone" => data["timeZone"] }
        fields[property] = id
        fields.merge!(patch.slice("start", "due", "timeZone"))
        local = LocalDateTime.new(fields["start"] || fields["due"])
        actual_zone = fields["timeZone"] || time_zone
        instant = if actual_zone
                    resolvers[actual_zone] ||= TimeZoneResolver.new(actual_zone, calendar.effective_time_zones)
                    resolvers[actual_zone].to_utc(local)
                  else
                    local.to_time
                  end
        next unless instant >= from && instant < to

        [instant, id, patch]
      end
      items.sort_by!(&:first)
      @truncated ||= items.size > limit
      bytes = 0
      items.first(limit).map do |_instant, id, patch|
        occurrence_data = data.except("recurrenceRules", "excludedRecurrenceRules", "recurrenceOverrides")
        occurrence_data[property] = id
        occurrence_data["recurrenceId"] = id
        occurrence_data["recurrenceIdTimeZone"] = data["timeZone"]
        occurrence_data = PatchObject.new(PatchObject.recurrence(patch), **calendar.limits).apply(occurrence_data, validate: false) unless patch.empty?
        bytes += Jscalendar.generate_json(occurrence_data).bytesize
        raise LimitError, "expanded data exceeds max_occurrence_bytes" if bytes > calendar.limits[:max_occurrence_bytes]

        occurrence = calendar.class.new(occurrence_data, time_zones: calendar.effective_time_zones, **calendar.limits)
        Occurrence.new(id, occurrence, time_zone)
      end
    end
  end
end
