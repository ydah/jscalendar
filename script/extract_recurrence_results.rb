# frozen_string_literal: true

# Parse the printed results in the downloaded RFC, independently of the rule
# engine. Neither the source text nor the resulting date lists are committed.
module RFCRecurrenceResults
  MONTHS = Date::MONTHNAMES.compact.join("|")
  module_function

  def extract(lines, index, start)
    index += 1 until index == lines.size || lines[index].start_with?("==>")
    raise "Missing RFC recurrence result" if index == lines.size

    printed = []
    while index < lines.size && lines[index].match?(/\A(?:==>|\(|#{MONTHS}|\d|\.\.\.)/)
      printed << lines[index].delete_prefix("==>").strip
      index += 1
    end
    result = []
    printed.join(" ").scan(/\(([^)]+)\)\s*([^()]*)/).each do |header, body|
      if header.match?(/\A\d{4}/)
        year = header.to_i
        body.scan(/(#{MONTHS})\s+([^A-Za-z]*)/).each do |month, list|
          days, finished = numbers(list)
          days.each { |day| result << format("%04d-%02d-%02dT%s", year, Date::MONTHNAMES.index(month), day, start.split("T").last) }
          return result if finished
        end
      else
        month, day, year = header.match(/\A(#{MONTHS}) (\d+), (\d{4})/).captures
        times, finished = numbers(body, clock: true)
        times.each { |time| result << format("%04d-%02d-%02dT%02d:%02d:00", year.to_i, Date::MONTHNAMES.index(month), day.to_i, time / 60, time % 60) }
        return result if finished
      end
    end
    raise "Empty RFC recurrence result" if result.empty?

    result
  end

  def numbers(text, clock: false)
    tokens = text.scan(/\d+:\d+|\d+-\d+|\d+|\.\.\./)
    values = []
    tokens.each_with_index do |token, index|
      if token == "..."
        return [values, true] unless tokens[index + 1] && values.size >= 2

        last = number(tokens[index + 1], clock)
        step = values[-1] - values[-2]
        raise "Ambiguous RFC result ellipsis" unless step.positive? && last > values.last && ((last - values.last) % step).zero?

        values.concat(((values.last + step)...last).step(step).to_a)
      elsif token.include?("-")
        first, last = token.split("-").map(&:to_i)
        values.concat((first..last).to_a)
      else
        values << number(token, clock)
      end
    end
    [values, false]
  end

  def number(token, clock)
    return token.to_i unless clock

    hour, minute = token.split(":").map(&:to_i)
    hour * 60 + minute
  end
end
