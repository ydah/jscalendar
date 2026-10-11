# frozen_string_literal: true

module Jscalendar
  DEFAULT_LIMITS = { max_input_size: 16 * 1024 * 1024, max_depth: 32, max_map_size: 10_000,
                     max_data_uri_size: 1024 * 1024, max_patches: 1000, max_occurrences: 10_000, max_rules: 100, max_occurrence_bytes: 32 * 1024 * 1024 }.freeze
  MAX_INTEGER = (2**53) - 1

  class << self
    def generate_json(value, options = nil)
      value = precise_json_floats(value) if RUBY_ENGINE == "truffleruby"
      JSON.generate(value, options)
    end

    # TruffleRuby Float#to_s can round away significant digits used by json's generator.
    def precise_json_floats(value)
      case value
      when Hash then value.transform_values { |item| precise_json_floats(item) }
      when Array then value.map { |item| precise_json_floats(item) }
      when Float
        raise JSON::GeneratorError, "#{value} not allowed in JSON" unless value.finite?

        number = format("%.17g", value)
        number += ".0" unless number.match?(/[.eE]/)
        JSON::Fragment.new(number)
      else value
      end
    end
    private :precise_json_floats

    # Copies JSON-compatible values without sharing mutable caller-owned containers.
    def deep_copy(value, max_depth: DEFAULT_LIMITS[:max_depth], depth: 0, ancestors: [], pointer: "")
      case value
      when Hash, Array
        raise LimitError.new("JSON nesting exceeds max_depth", pointer: pointer) if depth >= max_depth
        raise ValidationError.new("cyclic JSON data", pointer: pointer) if ancestors.include?(value.object_id)

        nested = ancestors + [value.object_id]
        if value.is_a?(Array)
          value.each_with_index.map do |item, index|
            deep_copy(item, max_depth: max_depth, depth: depth + 1, ancestors: nested, pointer: self.pointer(pointer, index))
          end
        else
          value.each_with_object({}) do |(key, item), result|
            raise ValidationError.new("JSON object keys must be strings", pointer: pointer) unless key.is_a?(String) || key.is_a?(Symbol)

            key = key.to_s
            unless key.valid_encoding? && (key.encoding == Encoding::UTF_8 || key.ascii_only?)
              raise ValidationError.new("invalid JSON object key encoding", pointer: pointer)
            end
            raise ValidationError.new("duplicate JSON object key #{key}", pointer: self.pointer(pointer, key)) if result.key?(key)

            result[key.dup] = deep_copy(item, max_depth: max_depth, depth: depth + 1, ancestors: nested,
                                              pointer: self.pointer(pointer, key))
          end
        end
      when LocalDateTime, Duration then value.to_s
      when String then value.dup
      when Integer, Float, TrueClass, FalseClass, NilClass then value
      when Model, IdMap then value.to_h
      else raise ValidationError.new("value is not JSON-compatible", pointer: pointer)
      end
    end

    def deep_freeze(value)
      if value.is_a?(Hash)
        value.each do |key, item|
          deep_freeze(key)
          deep_freeze(item)
        end
      end
      value.each { |item| deep_freeze(item) } if value.is_a?(Array)
      value.freeze
    end

    def pointer(parent, key)
      "#{parent}/#{key.to_s.gsub("~", "~0").gsub("/", "~1")}"
    end
  end

  SCHEMA = deep_freeze(YAML.safe_load_file(File.expand_path("../../data/types.yml", __dir__)))
  ENUMS = deep_freeze(YAML.safe_load_file(File.expand_path("../../data/enums.yml", __dir__)))

  module Types
    module_function

    def id?(value)
      value.is_a?(String) && value.bytesize.between?(1, 255) && value.match?(/\A[A-Za-z0-9_-]+\z/)
    end

    def integer?(value, minimum: -MAX_INTEGER, maximum: MAX_INTEGER)
      value.is_a?(Integer) && value.between?(minimum, maximum)
    end

    def vendor?(value)
      return false unless value.is_a?(String) && value.valid_encoding?

      prefix, name = value.split(":", 2)
      return false unless name && !prefix.empty? && !name.empty? && !name.match?(%r{[\x00-\x08\x0A-\x1F\x7F"/~]})

      prefix.split(".", -1).all? do |label|
        label.match?(/\A[A-Za-z0-9\u0080-\u{10ffff}](?:[A-Za-z0-9\u0080-\u{10ffff}-]*[A-Za-z0-9\u0080-\u{10ffff}])?\z/)
      end
    rescue ArgumentError, Encoding::CompatibilityError
      false
    end

    def uri?(value)
      value.is_a?(String) && value.ascii_only? && !value.match?(/%(?![0-9a-fA-F]{2})/) && !URI.parse(value).scheme.nil?
    rescue URI::InvalidURIError
      false
    end

    def utc_date_time?(value)
      return false unless value.is_a?(String)

      match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d*[1-9])?Z\z/.match(value)
      return false unless match

      year, month, day, hour, minute, second = match.captures.map(&:to_i)
      Date.valid_date?(year, month, day, Date::GREGORIAN) && hour < 24 && minute < 60 && second <= 60 &&
        (second < 60 || (hour == 23 && minute == 59 && [6, 12].include?(month) && day == Date.new(year, month, -1).day))
    end

    GRANDFATHERED_LANGUAGES = %w[art-lojban cel-gaulish en-gb-oed i-ami i-bnn i-default i-enochian i-hak i-klingon
                                 i-lux i-mingo i-navajo i-pwn i-tao i-tay i-tsu no-bok no-nyn sgn-be-fr sgn-be-nl
                                 sgn-ch-de zh-guoyu zh-hakka zh-min zh-min-nan zh-xiang].freeze

    def language_tag?(value)
      return false unless value.is_a?(String)
      return true if GRANDFATHERED_LANGUAGES.include?(value.downcase)
      return true if value.match?(/\Ax(?:-[A-Za-z0-9]{1,8})+\z/i)

      parts = value.split("-", -1)
      language = parts.shift
      return false unless language&.match?(/\A[A-Za-z]{2,8}\z/)

      3.times { parts.shift if parts.first&.match?(/\A[A-Za-z]{3}\z/) } if language.size <= 3
      parts.shift if parts.first&.match?(/\A[A-Za-z]{4}\z/)
      parts.shift if parts.first&.match?(/\A(?:[A-Za-z]{2}|[0-9]{3})\z/)
      variants = []
      while parts.first&.match?(/\A(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3})\z/)
        variant = parts.shift.downcase
        return false if variants.include?(variant)

        variants << variant
      end
      singletons = []
      until parts.empty?
        singleton = parts.shift.downcase
        return false unless singleton.match?(/\A[A-Za-z0-9]\z/) && !singletons.include?(singleton)
        return !parts.empty? && parts.all? { |part| part.match?(/\A[A-Za-z0-9]{1,8}\z/) } if singleton == "x"

        singletons << singleton
        count = 0
        while parts.first&.match?(/\A[A-Za-z0-9]{2,8}\z/)
          parts.shift
          count += 1
        end
        return false if count.zero?
      end
      true
    end

    def email?(value)
      return false unless value.is_a?(String) && value.ascii_only?

      value = value.gsub(/\r\n(?=[ \t])/, "")
      return false if value.match?(/[^\x09\x20-\x7E]/)

      value = without_email_comments(value)
      return false unless value

      atom = %q([A-Za-z0-9!#$%&'*+\-/=?^_`{|}~]+)
      quoted = '"(?:[^"\\\\\r\n]|\\\\[\\x20-\\x7E])*"'
      word = "(?:#{atom}|#{quoted})"
      local = "#{word}(?:[ \\t]*\\.[ \\t]*#{word})*"
      domain = "(?:#{atom}(?:[ \\t]*\\.[ \\t]*#{atom})*|\\[(?:[^\\[\\]\\\\\\r\\n]|\\\\[\\x20-\\x7E])*\\])"
      value.match?(/\A[ \t]*#{local}[ \t]*@[ \t]*#{domain}[ \t]*\z/)
    end

    def without_email_comments(value)
      result = +""
      depth = 0
      quoted = nil
      escaped = false
      value.each_char do |character|
        if escaped
          result << character if depth.zero?
          escaped = false
        elsif character == "\\" && (depth.positive? || quoted)
          escaped = true
          result << character if depth.zero?
        elsif depth.positive?
          depth += 1 if character == "("
          depth -= 1 if character == ")"
          result << " " if depth.zero?
        elsif quoted
          result << character
          quoted = nil if character == quoted
        elsif character == "("
          depth = 1
        else
          result << character
          quoted = character == "[" ? "]" : '"' if ['"', "["].include?(character)
        end
      end
      result if depth.zero? && !quoted && !escaped
    end
  end
end
