# frozen_string_literal: true

module Jscalendar
  class UnsupportedError < Error; end

  def self.decimal_seconds(number)
    value = number.is_a?(Float) ? Rational(number.to_s) : number.to_r
    denominator = value.denominator
    powers = [2, 5].map do |factor|
      count = 0
      while (denominator % factor).zero?
        denominator /= factor
        count += 1
      end
      count
    end
    raise ArgumentError, "seconds must have a finite decimal representation" unless denominator == 1

    digits = powers.max
    return value.numerator.to_s if digits.zero?

    text = (value.abs * (10**digits)).to_i.to_s.rjust(digits + 1, "0")
    text.insert(-digits - 1, ".")
    "#{"-" if value.negative?}#{text.sub(/0+\z/, "")}"
  end

  class LocalDateTime
    include Comparable

    def initialize(value)
      value = value.to_s
      raise ValidationError, "invalid LocalDateTime" unless Types.utc_date_time?("#{value}Z")

      @value = value.dup.freeze
    end

    def self.from_time(time)
      fraction = if time.subsec.zero?
                   ""
                 else
                   Jscalendar.decimal_seconds(time.subsec).delete_prefix("0")
                 end
      new(time.strftime("%Y-%m-%dT%H:%M:%S") + fraction)
    end

    def to_s
      @value
    end

    def to_time
      raise UnsupportedError, "Ruby Time cannot represent leap seconds" if @value[17, 2] == "60"

      fraction = Rational("0#{@value[19..]}")
      time = Time.utc(*@value[0, 19].scan(/\d+/).map(&:to_i)) + fraction
      raise UnsupportedError, "Ruby Time cannot preserve this fractional precision" unless time.subsec == fraction

      time
    end

    def <=>(other)
      other = LocalDateTime.new(other).to_s
      [@value[0, 19], Rational("0#{@value[19..]}")] <=> [other[0, 19], Rational("0#{other[19..]}")]
    end

    def ==(other)
      other.respond_to?(:to_s) && @value == other.to_s
    end
  end

  class Duration
    attr_reader :days, :seconds

    def initialize(value)
      @value = value.to_s.dup.freeze
      sign = is_a?(SignedDuration) ? "[+-]?" : ""
      match = /\A(#{sign})P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d*[1-9])?)S)?)?\z/.match(@value)
      unless match && match.captures[1..].any? && !@value.end_with?("T") && !(match[4] && match[6] && !match[5])
        raise ValidationError, "invalid #{self.class.name.split("::").last}"
      end

      factor = match[1] == "-" ? -1 : 1
      @days = ((match[2].to_i * 7) + match[3].to_i) * factor
      @seconds = ((match[4].to_i * 3600) + (match[5].to_i * 60) + Rational(match[6] || "0")) * factor
    end

    def self.from_seconds(seconds)
      raise ArgumentError, "seconds must be a finite number" unless seconds.is_a?(Numeric) && seconds.finite?
      raise ArgumentError, "negative Duration" if self == Duration && seconds.negative?

      number = Jscalendar.decimal_seconds(seconds.abs)
      new("#{"-" if seconds.negative?}PT#{number}S")
    end

    def to_s
      @value
    end

    # Nominal seconds; calendar days can differ from 24 hours across a DST change.
    def to_seconds
      (@days * 86_400) + @seconds
    end

    def add_to(local, time_zone: nil, time_zones: {})
      local = LocalDateTime.new(local)
      resolver = time_zone && TimeZoneResolver.new(time_zone, time_zones)
      if @days.negative? || @seconds.negative?
        wall = resolver ? resolver.to_local(resolver.to_utc(local) + @seconds).to_time : local.to_time + @seconds
        shifted = LocalDateTime.from_time(wall + (@days * 86_400))
        resolver ? resolver.to_local(resolver.to_utc(shifted)) : shifted
      else
        shifted = LocalDateTime.from_time(local.to_time + (@days * 86_400))
        resolver ? resolver.to_local(resolver.to_utc(shifted) + @seconds) : LocalDateTime.from_time(shifted.to_time + @seconds)
      end
    end
  end

  class SignedDuration < Duration; end
end
