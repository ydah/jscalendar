# frozen_string_literal: true

module Jscalendar
  Violation = Struct.new(:pointer, :message, keyword_init: true)

  class Error < StandardError
    attr_reader :pointer

    def initialize(message = nil, pointer: nil)
      @pointer = pointer
      super(message)
    end
  end

  class ParseError < Error; end
  class ConversionError < Error; end
  class LimitError < Error; end

  class ValidationError < Error
    attr_reader :errors

    def initialize(errors, pointer: nil)
      @errors = errors.is_a?(Array) ? errors : [Violation.new(pointer: pointer || "", message: errors)]
      super(@errors.map { |error| "#{error.pointer}: #{error.message}" }.join("; "), pointer: pointer || @errors.first&.pointer)
    end
  end
end
