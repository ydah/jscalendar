# frozen_string_literal: true

module Jscalendar
  class TimeZoneResolver
    def initialize(identifier, definitions = {})
      @identifier = identifier
      @custom = definitions[identifier]
      @iana = TZInfo::Timezone.get(identifier) unless @custom
      @transitions = {}
    rescue TZInfo::InvalidTimezoneIdentifier
      raise ValidationError, "unknown time zone #{identifier}"
    end

    def to_utc(local)
      wall = LocalDateTime.new(local).to_time
      return wall - custom_offset(wall) if @custom

      periods = @iana.periods_for_local(wall)
      return wall - periods.map(&:observed_utc_offset).max unless periods.empty?

      change = @iana.transitions_up_to(wall + (3 * 86_400), wall - (3 * 86_400)).find do |transition|
        instant = transition.at.to_time
        wall >= instant + transition.previous_offset.observed_utc_offset && wall < instant + transition.offset.observed_utc_offset
      end
      raise ConversionError, "unable to resolve time zone discontinuity" unless change

      wall - change.previous_offset.observed_utc_offset
    end

    def to_local(utc)
      return LocalDateTime.from_time(@iana.utc_to_local(utc.getutc)) unless @custom

      changes = transitions(utc.year + 1)
      offset = changes.first[1]
      changes.each do |instant, _before, after|
        break if instant > utc

        offset = after
      end
      LocalDateTime.from_time(utc.getutc + offset)
    end

    def wall_bounds(from, to)
      points = [to_local(from).to_time, to_local(to).to_time]
      changes = if @custom
                  transitions(to.year + 1).select { |instant, _before, _after| instant.between?(from, to) }
                else
                  @iana.transitions_up_to(to + 1, from).map do |transition|
                    [transition.at.to_time, transition.previous_offset.observed_utc_offset, transition.offset.observed_utc_offset]
                  end
                end
      changes.each { |instant, before, after| points.push(instant + before, instant + after) }
      points.minmax
    end

    private

    def custom_offset(wall)
      changes = transitions(wall.year + 1)
      offset = changes.first[1]
      changes.each do |instant, before, after|
        low, high = [instant + before, instant + after].minmax
        return before if wall >= low && wall < high
        break if wall < high

        offset = after
      end
      offset
    end

    def transitions(year)
      @transitions[year] ||= Timeout.timeout(2, LimitError, "custom time zone expansion exceeded time limit") do
        rules = @custom.fetch("standard", []) + @custom.fetch("daylight", [])
        changes = rules.flat_map do |rule|
          before = offset_seconds(rule.fetch("offsetFrom"))
          after = offset_seconds(rule.fetch("offsetTo"))
          initial = LocalDateTime.new(rule.fetch("start")).to_time
          dates = [initial] + rule.fetch("recurrenceOverrides", {}).keys.map { |date| LocalDateTime.new(date).to_time }
          rule.fetch("recurrenceRules", []).each do |recurrence|
            recurrence = Jscalendar.deep_copy(recurrence)
            # VTIMEZONE UNTIL denotes UTC, while the recurrence engine uses wall time.
            recurrence["until"] = LocalDateTime.from_time(LocalDateTime.new(recurrence["until"]).to_time + before).to_s if recurrence["until"]
            dates.concat(Recurrence.rule_times(recurrence, initial, initial, Time.utc(year + 1), limit: 10_001))
            raise LimitError, "custom time zone has too many transitions" if dates.size > 10_000
          end
          dates.uniq.map { |date| [date - before, before, after] }
        end
        raise ValidationError, "custom time zone needs a transition rule" if changes.empty?

        changes.sort_by(&:first)
      end
    end

    def offset_seconds(value)
      sign = value.start_with?("-") ? -1 : 1
      ((value[1, 2].to_i * 3600) + (value[3, 2].to_i * 60) + value[5, 2].to_i) * sign
    end
  end
end
