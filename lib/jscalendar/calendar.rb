# frozen_string_literal: true

module Jscalendar
  class Model
    def self.build(**properties)
      data = { "@type" => name.split("::").last }
      data.merge!("uid" => SecureRandom.uuid, "updated" => Time.now.utc.iso8601) if %w[Event Task Group].include?(data["@type"])
      data.merge!(camel_properties(properties))
      item = new(data)
      yield item if block_given?
      item.validate!
    end

    def self.camel_properties(value)
      case value
      when Hash
        value.to_h { |key, item| [key.is_a?(Symbol) ? key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase } : key, camel_properties(item)] }
      when Array then value.map { |item| camel_properties(item) }
      else value
      end
    end

    def localize(language)
      localizations = @data.fetch("localizations", {})
      key = localizations.keys.find { |tag| tag.casecmp?(language) }
      patch = localizations[key]
      return self.class.new(to_h, time_zones: @time_zones, **@limits) unless patch

      data = PatchObject.new(PatchObject.localization(patch), **@limits).apply(to_h, validate: false)
      data["locale"] = language
      self.class.new(data, strict: true, time_zones: @time_zones, **@limits)
    end
  end

  module RecurringCalendar
    def start_time(time_zone: nil)
      value = @data["start"] || @data["due"]
      raise ValidationError, "calendar has no start or due" unless value

      zone = @data["timeZone"] || time_zone
      raise UnsupportedError, "floating time requires time_zone" unless zone

      TimeZoneResolver.new(zone, effective_time_zones).to_utc(LocalDateTime.new(value))
    end

    def end_time(time_zone: nil)
      zone = @data["timeZone"] || time_zone
      raise UnsupportedError, "floating time requires time_zone" unless zone

      return TimeZoneResolver.new(zone, effective_time_zones).to_utc(LocalDateTime.new(@data["due"])) if is_a?(Task) && @data["due"]

      duration = Duration.new(@data.fetch("duration", "PT0S"))
      local = duration.add_to(@data.fetch("start"), time_zone: zone, time_zones: effective_time_zones)
      TimeZoneResolver.new(zone, effective_time_zones).to_utc(local)
    end

    def occurrences(from:, to:, limit: 1000, time_zone: nil, timeout: 2.0)
      validate!
      Occurrences.new(self, from: from, to: to, limit: limit, time_zone: time_zone, timeout: timeout)
    end

    def add_recurrence_rule(**properties)
      rule = Model.camel_properties(properties)
      rule["@type"] = "RecurrenceRule"
      rule.fetch("byDay", []).each { |day| day["@type"] ||= "NDay" }
      (@data["recurrenceRules"] ||= []) << rule
      self
    end

    def effective_time_zones
      @time_zones.merge(@data.fetch("timeZones", {}))
    end
  end

  Event.include(RecurringCalendar)
  Task.include(RecurringCalendar)
end
