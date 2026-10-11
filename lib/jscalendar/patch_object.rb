# frozen_string_literal: true

module Jscalendar
  class PatchObject
    RECURRENCE_IGNORED = %w[@type excludedRecurrenceRules method privacy prodId recurrenceId recurrenceIdTimeZone
                            recurrenceOverrides recurrenceRules relatedTo replyTo sentBy timeZones uid].freeze

    def self.recurrence(patches)
      patches.reject { |path, _| RECURRENCE_IGNORED.any? { |prefix| path.start_with?(prefix) } }
    end

    def self.localization(patches)
      patches.select { |path, _| !path.start_with?("recurrenceOverrides") && %w[title description name].any? { |suffix| path.end_with?(suffix) } }
    end

    def initialize(patches, max_patches: 1_000, **limits)
      raise ArgumentError, "max_patches must be a nonnegative integer" unless max_patches.is_a?(Integer) && max_patches >= 0
      raise ValidationError, "PatchObject must be an object" unless patches.is_a?(Hash)
      raise LimitError.new("Too many patches", pointer: "") if patches.size > max_patches

      @limits = limits.merge(max_patches: max_patches)
      @patches = Jscalendar.deep_copy(patches, max_depth: @limits.fetch(:max_depth, 32))
    end

    def to_h
      Jscalendar.deep_copy(@patches, max_depth: @limits.fetch(:max_depth, 32))
    end

    # RFC 8984 section 1.4.9: resolve every path before modifying the copy.
    def apply(data, validate: true)
      raise ValidationError, "Patch target must be an object" unless data.is_a?(Hash)

      result = Jscalendar.deep_copy(data, max_depth: @limits.fetch(:max_depth, 32))
      type = result["@type"]
      validator = Validator.new(**@limits, validate_patches: false)
      errors = validator.validate_json(result) + validator.validate_json(@patches)
      raise ValidationError, errors unless errors.empty?

      paths = @patches.keys.map { |path| [tokens(path), path] }.sort_by(&:first)
      paths.each_cons(2) do |(first, _), (second, path)|
        invalid(path, "Patch paths must not overlap") if second.first(first.size) == first
      end
      operations = paths.map do |parts, path|
        parent = parts[0...-1].reduce(result) { |value, token| member(value, token, path) }
        key = parts.last
        invalid(path, "Patch parent must be an object; arrays cannot be traversed") unless parent.is_a?(Hash)
        [parent, key, @patches[path]]
      end
      operations.each do |parent, key, value|
        if value.nil?
          parent.delete(key)
        else
          parent[key] = Jscalendar.deep_copy(value, max_depth: @limits.fetch(:max_depth, 32))
        end
      end
      errors = if validate && (type || result["@type"])
                 raise ValidationError.new("Unknown patch target type", pointer: "/@type") unless SCHEMA.key?(type || result["@type"])

                 validator.validate(result, type: type || result["@type"])
               else
                 validator.validate_json(result)
               end
      raise ValidationError, errors unless errors.empty?

      result
    end

    private

    def tokens(path)
      invalid(path, "Invalid JSON Pointer escape") if path.match?(/~(?:[^01]|\z)/)
      (path.empty? ? [""] : path.split("/", -1)).map { |token| token.gsub(/~[01]/) { |escape| escape == "~0" ? "~" : "/" } }
    end

    def member(parent, key, path)
      invalid(path, "Intermediate reference must be an existing object member") unless parent.is_a?(Hash) && parent.key?(key)
      parent[key]
    end

    def invalid(path, message)
      raise ValidationError.new(message, pointer: "/#{path.gsub("~", "~0").gsub("/", "~1")}")
    end
  end
end
