# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "time"
require "uri"
require "securerandom"
require "timeout"
require "tzinfo"
require_relative "jscalendar/version"
require_relative "jscalendar/errors"
require_relative "jscalendar/types"
require_relative "jscalendar/temporal"
require_relative "jscalendar/validator"
require_relative "jscalendar/model"
require_relative "jscalendar/patch_object"
require_relative "jscalendar/time_zone"
require_relative "jscalendar/recurrence"
require_relative "jscalendar/calendar"

JSCalendar = Jscalendar unless defined?(JSCalendar)

module Jscalendar
  class << self
    def parse(source, strict: true, **limits)
      raise ParseError, "JSON input must be a String" unless source.is_a?(String)

      Validator.new(**limits)
      options = DEFAULT_LIMITS.merge(limits)
      raise LimitError, "input exceeds max_input_size" if source.bytesize > options[:max_input_size]

      data = JSON.parse(source, allow_duplicate_key: false, max_nesting: options[:max_depth])
      raise ParseError, "expected Event, Task, or Group" unless data.is_a?(Hash) && %w[Event Task Group].include?(data["@type"])

      const_get(data["@type"]).new(data, strict: strict, **limits)
    rescue JSON::NestingError => e
      raise LimitError, e.message
    rescue JSON::ParserError, EncodingError => e
      raise ParseError, e.message
    end

    def validate(source, **limits)
      validator = Validator.new(**limits)
      data = if source.is_a?(String)
               parse(source, strict: false, **limits).to_h
             else
               deep_copy(source, max_depth: limits.fetch(:max_depth, DEFAULT_LIMITS[:max_depth]))
             end
      validator.validate(data)
    end
  end
end
