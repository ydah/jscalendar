# frozen_string_literal: true

module Jscalendar
  # Collects violations while treating configured resource limits as hard failures.
  class Validator
    KNOWN_NAMES = SCHEMA.values.flat_map { |definition| definition.fetch("properties").keys }.uniq.freeze

    def initialize(validate_patches: true, **limits)
      unknown = limits.keys - DEFAULT_LIMITS.keys
      raise ArgumentError, "unknown limits: #{unknown.join(", ")}" unless unknown.empty?

      @limits = DEFAULT_LIMITS.merge(limits)
      @limits.each do |name, value|
        raise ArgumentError, "#{name} must be a nonnegative Integer" unless value.is_a?(Integer) && value >= 0
      end
      raise ArgumentError, "max_depth must be positive" if @limits[:max_depth].zero?

      @validate_patches = validate_patches
      @errors = []
    end

    def validate(value, type: value.is_a?(Hash) && value["@type"], time_zones: {})
      @errors = []
      inspect_json(value, "", 0, [])
      return @errors unless @errors.empty?

      @zones = time_zones
      object(value, type, "")
      @errors
    end

    def validate_json(value, pointer: "")
      @errors = []
      inspect_json(value, pointer, 0, [])
      @errors
    end

    private

    def add(pointer, message)
      @errors << Violation.new(pointer: pointer, message: message)
    end

    def inspect_json(value, path, depth, ancestors)
      case value
      when Hash, Array
        raise LimitError.new("JSON nesting exceeds max_depth", pointer: path) if depth >= @limits[:max_depth]

        if ancestors.include?(value.object_id)
          add(path, "cyclic JSON data")
          return
        end
        raise LimitError.new("collection exceeds max_map_size", pointer: path) if value.size > @limits[:max_map_size]

        next_ancestors = ancestors + [value.object_id]
        if value.is_a?(Hash)
          value.each do |key, item|
            unless key.is_a?(String) && unicode?(key)
              add(path, "JSON member names must be valid Unicode strings")
              next
            end
            inspect_json(item, Jscalendar.pointer(path, key), depth + 1, next_ancestors)
          end
        else
          value.each_with_index { |item, index| inspect_json(item, Jscalendar.pointer(path, index), depth + 1, next_ancestors) }
        end
      when String
        add(path, "string is not valid I-JSON Unicode") unless unicode?(value)
        check_data_uri_limit(value, path)
      when Integer
        add(path, "integer is outside the exact I-JSON range") unless Types.integer?(value)
      when Float
        add(path, "number must be finite") unless value.finite?
      when TrueClass, FalseClass, NilClass
        nil
      else
        add(path, "value is not JSON-compatible")
      end
    end

    def unicode?(value)
      return false unless value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)

      value.each_codepoint.none? { |point| point.between?(0xD800, 0xDFFF) || point.between?(0xFDD0, 0xFDEF) || (point & 0xFFFF) >= 0xFFFE }
    end

    def check_data_uri_limit(value, path)
      return unless value.b.byteslice(0, 5)&.downcase == "data:"

      header, payload = value.b.split(",", 2)
      return unless payload

      payload = URI::DEFAULT_PARSER.unescape(payload)
      size = if header.downcase.end_with?(";base64")
               (payload.bytesize * 3 / 4) - [payload[/=+\z/].to_s.length, 2].min
             else
               payload.bytesize
             end
      raise LimitError.new("data URI exceeds max_data_uri_size", pointer: path) if size > @limits[:max_data_uri_size]
    end

    def object(value, type, path)
      unless value.is_a?(Hash) && SCHEMA.key?(type)
        add(path, "expected a known JSCalendar object")
        return
      end
      previous_zones = @zones
      @zones = @zones.merge(value["timeZones"].is_a?(Hash) ? value["timeZones"] : {})
      fields = SCHEMA.fetch(type).fetch("properties")
      add(Jscalendar.pointer(path, "@type"), "expected @type #{type}") unless value["@type"] == type
      fields.each do |name, rule|
        add(Jscalendar.pointer(path, name), "required property is missing") if rule["required"] && !value.key?(name)
      end
      value.each do |name, item|
        next unless name.is_a?(String) && unicode?(name)

        location = Jscalendar.pointer(path, name)
        if fields.key?(name)
          check(item, fields[name].fetch("type"), location) unless name == "@type"
        elsif KNOWN_NAMES.any? { |known| known.casecmp?(name) }
          add(location, "property is not allowed in #{type} or has incorrect case")
        elsif !Types.vendor?(name) && !name.match?(/\A[a-z][A-Za-z0-9]*\z/)
          add(location, "invalid property name")
        end
      end
      relationships(value, type, path)
    ensure
      @zones = previous_zones if defined?(previous_zones) && previous_zones
    end

    def check(value, signature, path)
      if signature.end_with?("|null")
        check(value, signature.delete_suffix("|null"), path) unless value.nil?
      elsif SCHEMA.key?(signature)
        object(value, signature, path)
      elsif signature.end_with?("[]")
        if value.is_a?(Array)
          value.each_with_index { |item, i| check(item, signature.delete_suffix("[]"), Jscalendar.pointer(path, i)) }
        else
          add(path, "expected an array")
        end
      elsif (match = /\A(\w+)\[(.+)\]\z/.match(signature))
        check_map(value, match[1], match[2], path)
      elsif signature.start_with?("Enum:", "Closed:")
        enum(value, signature.split(":", 2).last, path, extensible: signature.start_with?("Enum:"))
      elsif signature.start_with?("EnumMap:", "ClosedEnumMap:")
        check_map(value, "String", "True", path)
        if value.is_a?(Hash)
          value.each_key { |key| enum(key, signature.split(":", 2).last, Jscalendar.pointer(path, key), extensible: signature.start_with?("EnumMap:")) }
        end
      elsif signature == "PatchObject"
        if value.is_a?(Hash)
          raise LimitError.new("patch count exceeds max_patches", pointer: path) if value.size > @limits[:max_patches]
        else
          add(path, "expected PatchObject")
        end
      elsif %w[Entry Trigger].include?(signature)
        if !value.is_a?(Hash) || !value["@type"].is_a?(String)
          add(path, "expected typed #{signature}")
        elsif (signature == "Entry" ? %w[Event Task] : %w[OffsetTrigger AbsoluteTrigger]).include?(value["@type"])
          object(value, value["@type"], path)
        end
      else
        add(path, "invalid #{signature} value") unless scalar?(value, signature)
      end
    end

    def check_map(value, key_type, item_type, path)
      unless value.is_a?(Hash)
        add(path, "expected a map")
        return
      end
      value.each do |key, item|
        location = Jscalendar.pointer(path, key)
        add(location, "invalid #{key_type} map key") unless scalar?(key, key_type)
        check(item, item_type, location)
      end
    end

    def enum(value, name, path, extensible: true)
      valid = value.is_a?(String) && (ENUMS.fetch(name).include?(value) || (extensible && Types.vendor?(value)))
      add(path, "invalid #{name} value") unless valid
    end

    def scalar?(value, signature)
      case signature
      when "String" then value.is_a?(String)
      when "Boolean" then [true, false].include?(value)
      when "True" then value == true
      when "Int" then Types.integer?(value)
      when "UnsignedInt" then Types.integer?(value, minimum: 0)
      when "Id" then Types.id?(value)
      when "UTCDateTime" then Types.utc_date_time?(value)
      when "LocalDateTime" then value.is_a?(String) && Types.utc_date_time?("#{value}Z")
      when "Duration", "SignedDuration"
        value.is_a?(String) && Jscalendar.const_get(signature).new(value)
      when "TimeZoneId"
        value.is_a?(String) && (@zones.key?(value) || TZInfo::Timezone.get(value))
      when "LanguageTag" then Types.language_tag?(value)
      when "URI" then Types.uri?(value)
      when "Email" then Types.email?(value)
      when "UTCOffset"
        value.is_a?(String) && value.match?(/\A[+-](?:[01]\d|2[0-3])[0-5]\d(?:[0-5]\d)?\z/) && !%w[-0000 -000000].include?(value)
      else false
      end
    rescue ValidationError, TZInfo::InvalidTimezoneIdentifier
      false
    end

    def relationships(value, type, path)
      if value["color"].is_a?(String)
        valid = ENUMS.fetch("color").include?(value["color"].downcase) || value["color"].match?(/\A#(?:[0-9a-f]{3}|[0-9a-f]{6})\z/i)
        add("#{path}/color", "expected CSS Level 3 color name or hexadecimal RGB") unless valid
      end
      if value["method"].is_a?(String) && !%w[publish request reply add cancel refresh counter declinecounter].include?(value["method"])
        add("#{path}/method", "expected lowercase iTIP method")
      end
      %w[links delegatedTo delegatedFrom memberOf replyTo sendTo roles locationTypes].each do |name|
        add(Jscalendar.pointer(path, name), "must not be empty") if value[name].is_a?(Hash) && value[name].empty?
      end
      %w[percentComplete priority].each do |name|
        next unless value[name].is_a?(Integer)

        max = name == "priority" ? 9 : 100
        add(Jscalendar.pointer(path, name), "must be between 0 and #{max}") unless value[name].between?(0, max)
      end
      if value["descriptionContentType"].is_a?(String)
        media = value["descriptionContentType"]
        valid = media.match?(%r{\Atext/[A-Za-z0-9!\#$&^_.+-]+(?:\s*;[^\r\n]*)?\z}) &&
                (!media.match?(/charset\s*=/i) || media.match?(/charset\s*=\s*"?utf-8"?(?:\s*;|\z)/i))
        add(Jscalendar.pointer(path, "descriptionContentType"), "expected text media type with UTF-8 charset") unless valid
      end
      %w[replyTo sendTo].each do |name|
        next unless value[name].is_a?(Hash)

        value[name].each do |method, uri|
          location = Jscalendar.pointer(Jscalendar.pointer(path, name), method)
          add(location, "method must be ASCII alphanumeric") unless method.match?(/\A[A-Za-z0-9]+\z/)
          scheme = if method == "imip"
                     "mailto:"
                   else
                     (method == "web" && name == "replyTo" ? "https:" : nil)
                   end
          add(location, "expected #{scheme} URI") if scheme && uri.is_a?(String) && !uri.downcase.start_with?(scheme)
        end
      end
      case type
      when "Event", "Task", "Group" then calendar(value, type, path)
      when "RecurrenceRule" then recurrence(value, path)
      when "NDay"
        add(Jscalendar.pointer(path, "nthOfPeriod"), "must be nonzero") if value["nthOfPeriod"].is_a?(Integer) && value["nthOfPeriod"].zero?
      when "Link"
        add(Jscalendar.pointer(path, "rel"), "must be icon when display is set") if value.key?("display") && value["rel"] != "icon"
        if value["cid"].is_a?(String)
          cid = value["cid"]
          valid = !cid.match?(/%(?![0-9a-fA-F]{2})/) && Types.email?(URI::DEFAULT_PARSER.unescape(cid))
          add("#{path}/cid", "expected URL-encoded content-id") unless valid
        end
      when "Location"
        add(path, "location needs a property other than relativeTo") if (value.keys - %w[@type relativeTo]).empty?
        add(Jscalendar.pointer(path, "coordinates"), "expected geo URI") if value["coordinates"].is_a?(String) && !value["coordinates"].start_with?("geo:")
      when "Participant"
        if value.key?("progress") && value.fetch("participationStatus", "needs-action") != "accepted"
          add(Jscalendar.pointer(path, "progress"), "requires accepted participationStatus")
        end
        if value["scheduleStatus"].is_a?(Array)
          value["scheduleStatus"].each_with_index do |status, i|
            add("#{path}/scheduleStatus/#{i}", "invalid scheduling status") unless status.is_a?(String) && status.match?(/\A[1-5]\.\d+(?:\.\d+)?\z/)
          end
        end
      when "TimeZone" then zone(value, path)
      when "TimeZoneRule"
        add("#{path}/recurrenceRules", "at most one rule is allowed") if value["recurrenceRules"].is_a?(Array) && value["recurrenceRules"].size > 1
        if value["recurrenceOverrides"].is_a?(Hash)
          value.fetch("recurrenceOverrides", {}).each do |key, patch|
            add(Jscalendar.pointer("#{path}/recurrenceOverrides", key), "time zone override must be empty") unless patch == {}
          end
        end
      end
    end

    def calendar(value, type, path)
      if value.key?("recurrenceId")
        %w[recurrenceRules recurrenceOverrides].each { |name| add("#{path}/#{name}", "not allowed on recurrence instance") if value.key?(name) }
      elsif value.key?("recurrenceIdTimeZone")
        add("#{path}/recurrenceIdTimeZone", "requires recurrenceId")
      end
      if type == "Task" && value.key?("recurrenceRules") && !value.key?("start") && !value.key?("due")
        add("#{path}/recurrenceRules", "task recurrence needs start or due")
      end
      if value["participants"].is_a?(Hash)
        value["participants"].each do |id, person|
          next unless person.is_a?(Hash)

          if person.key?("sendTo") && (!value["replyTo"].is_a?(Hash) || value["replyTo"].empty?)
            add("#{path}/replyTo", "participants with sendTo require a reply method")
          end
          %w[progress progressUpdated percentComplete].each do |name|
            add(Jscalendar.pointer("#{path}/participants", id) + "/#{name}", "only allowed in a Task") if type != "Task" && person.key?(name)
          end
          %w[delegatedTo delegatedFrom memberOf].each do |name|
            next unless person[name].is_a?(Hash)

            person[name].each_key do |reference|
              add(Jscalendar.pointer("#{path}/participants/#{id}/#{name}", reference), "unknown participant") unless value["participants"].key?(reference)
            end
          end
        end
      end
      if value["timeZones"].is_a?(Hash)
        references = zone_references(value.except("timeZones"))
        value["timeZones"].each_key do |id|
          location = Jscalendar.pointer("#{path}/timeZones", id)
          add(location, "custom identifier must start with / and be paramtext") unless id.start_with?("/") && paramtext?(id)
          add(location, "unreferenced custom time zone") unless references.include?(id)
        end
      end
      validate_patches(value, path) if @validate_patches
    end

    def validate_patches(value, path)
      %w[recurrenceOverrides localizations].each do |name|
        next unless value[name].is_a?(Hash)

        value[name].each do |key, patch|
          next unless patch.is_a?(Hash)

          if name == "recurrenceOverrides" && patch["excluded"] == true
            add(Jscalendar.pointer("#{path}/#{name}", key), "excluded override cannot patch other properties") if patch.size != 1
            next
          end
          filtered = name == "recurrenceOverrides" ? PatchObject.recurrence(patch) : PatchObject.localization(patch)
          base = value.except("recurrenceOverrides", "localizations")
          begin
            result = PatchObject.new(filtered, **@limits).apply(base, validate: false)
            violations = Validator.new(validate_patches: false, **@limits).validate(result, time_zones: @zones)
            violations.each { |error| add(Jscalendar.pointer("#{path}/#{name}", key) + error.pointer, error.message) }
          rescue ValidationError => e
            add(Jscalendar.pointer("#{path}/#{name}", key), e.message)
          end
        end
      end
    end

    def recurrence(value, path)
      %w[byDay byMonthDay byMonth byYearDay byWeekNo byHour byMinute bySecond bySetPosition].each do |name|
        add("#{path}/#{name}", "must not be empty") if value[name].is_a?(Array) && value[name].empty?
      end
      add("#{path}/interval", "must be positive") if value["interval"].is_a?(Integer) && value["interval"].zero?
      add("#{path}/until", "count and until are mutually exclusive") if value.key?("count") && value.key?("until")
      ranges = { "byHour" => 0..23, "byMinute" => 0..59, "bySecond" => 0..60 }
      ranges.merge!("byMonthDay" => -31..31, "byYearDay" => -366..366, "byWeekNo" => -53..53) if value.fetch("rscale", "gregorian") == "gregorian"
      ranges.each do |name, range|
        next unless value[name].is_a?(Array)

        value[name].each_with_index do |number, i|
          valid = number.is_a?(Integer) && range.cover?(number) && !(range.begin.negative? && number.zero?)
          add("#{path}/#{name}/#{i}", "out of range") unless valid
        end
      end
      if value["bySetPosition"].is_a?(Array)
        value["bySetPosition"].each_with_index do |number, i|
          add("#{path}/bySetPosition/#{i}", "must be nonzero") if number.is_a?(Integer) && number.zero?
        end
      end
      return unless value["byMonth"].is_a?(Array)

      value["byMonth"].each_with_index do |month, i|
        valid = month.is_a?(String) && month.match?(/\A[1-9]\d*L?\z/)
        valid &&= month.match?(/\A(?:[1-9]|1[0-2])\z/) if value.fetch("rscale", "gregorian") == "gregorian"
        add("#{path}/byMonth/#{i}", "invalid calendar month") unless valid
      end
    end

    def zone(value, path)
      rules = %w[standard daylight].flat_map { |name| value[name].is_a?(Array) ? value[name] : [] }
      add(path, "time zone needs a transition rule") if rules.empty?
      add("#{path}/tzId", "invalid paramtext") if value["tzId"].is_a?(String) && !paramtext?(value["tzId"])
    end

    def paramtext?(value)
      !value.empty? && !value.match?(/[\x00-\x08\x0A-\x1F\x7F";:,]/)
    end

    def zone_references(value)
      case value
      when Hash
        value.flat_map do |key, item|
          if key == "timeZones"
            []
          else
            (%w[timeZone recurrenceIdTimeZone].include?(key) ? [item] : zone_references(item))
          end
        end
      when Array then value.flat_map { |item| zone_references(item) }
      else []
      end
    end
  end
end
