# frozen_string_literal: true

require_relative "../lib/jscalendar"
require_relative "extract_recurrence_results"

module RFCRecurrences
  module_function

  def extract(sources, directory)
    text = File.read(File.join(sources, "rfc5545.txt")).split("\n3.8.5.3.  Recurrence Rule").last.split("\n3.8.6.").first
    lines = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("Desruisseaux", "RFC 5545") }
    start = nil
    excluded = []
    entries = []
    lines.each_with_index do |line, index|
      if line.start_with?("DTSTART")
        start = line
        excluded = []
      elsif line.start_with?("EXDATE")
        excluded << line
      elsif line.start_with?("RRULE:")
        rule = line.dup
        cursor = index
        while (rule.end_with?(";") && lines[cursor + 1]&.match?(/\A[A-Z]+=/)) ||
              (rule.end_with?(",") && lines[cursor + 1]&.match?(/\A\d/))
          cursor += 1
          rule << lines[cursor]
        end
        raise "Missing DTSTART for RFC recurrence example" unless start

        identifier = "rfc5545_3.8.5.3_#{entries.size + 1}"
        original = "#{([start, rule] + excluded).join("\n")}\n"
        notes = ["Map the recurrence to JSCalendar and supply envelope fields."]
        if rule.include?("FREQ=HOURLY;INTERVAL=3;UNTIL=19970902T170000Z")
          rule = rule.sub("19970902T170000Z", "19970902T210000Z")
          notes << "Verified erratum 3883: use 21:00 UTC for the 17:00 New York upper bound."
        end
        corrected = "#{([start, rule] + excluded).join("\n")}\n"
        ical = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:#{identifier}\n#{corrected}END:VEVENT\nEND:VCALENDAR\n"
        data = calendar(start, rule, excluded, identifier)
        expected = RFCRecurrenceResults.extract(lines, cursor, data.fetch("start"))
        File.write(File.join(directory, "#{identifier}.expected.json"), "#{JSON.pretty_generate(expected)}\n")
        File.write(File.join(directory, "#{identifier}.ics"), ical.gsub("\n", "\r\n"))
        File.write(File.join(directory, "#{identifier}.original.txt"), original)
        File.write(File.join(directory, "#{identifier}.json"), "#{JSON.pretty_generate(data)}\n")
        entries << { "section" => "3.8.5.3", "json" => "#{identifier}.json", "ical" => "#{identifier}.ics", "expected" => "#{identifier}.expected.json", "notes" => notes }
      end
    end
    entries
  end

  def local_date(value, zone)
    time = Time.strptime("#{value.delete_suffix("Z")}+0000", "%Y%m%dT%H%M%S%z").getutc
    time = TZInfo::Timezone.get(zone).utc_to_local(time) if value.end_with?("Z") && zone != "UTC"
    time.strftime("%Y-%m-%dT%H:%M:%S")
  end

  def calendar(start, text, excluded, identifier)
    head, value = start.split(":", 2)
    zone = head[/TZID=([^;]+)/, 1] || "UTC"
    rule = { "@type" => "RecurrenceRule" }
    names = Jscalendar::Recurrence::PARTS.invert
    text.delete_prefix("RRULE:").split(";").each do |part|
      key, value = part.split("=", 2)
      case key
      when "FREQ" then rule["frequency"] = value.downcase
      when "UNTIL" then rule["until"] = local_date(value, zone)
      when "BYDAY"
        rule["byDay"] = value.split(",").map do |day|
          ordinal, weekday = day.match(/\A([+-]?\d+)?([A-Z]{2})\z/).captures
          result = { "@type" => "NDay", "day" => weekday.downcase }
          result["nthOfPeriod"] = ordinal.to_i if ordinal
          result
        end
      when "WKST" then rule["firstDayOfWeek"] = value.downcase
      when "COUNT", "INTERVAL" then rule[names.fetch(key)] = value.to_i
      when "BYMONTH" then rule["byMonth"] = value.split(",")
      else rule[names.fetch(key)] = value.split(",").map(&:to_i)
      end
    end
    data = { "@type" => "Event", "uid" => identifier, "updated" => "2009-01-01T00:00:00Z", "timeZone" => zone,
             "start" => local_date(start.split(":", 2).last, zone), "recurrenceRules" => [rule] }
    unless excluded.empty?
      data["recurrenceOverrides"] = excluded.flat_map { |line| line.split(":", 2).last.split(",") }.to_h do |date|
        [local_date(date, zone), { "excluded" => true }]
      end
    end
    data
  end
end
