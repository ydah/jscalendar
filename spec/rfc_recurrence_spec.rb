# frozen_string_literal: true

RSpec.describe "Downloaded RFC 5545 recurrence results" do
  directory = File.expand_path("../tmp/rfc/fixtures", __dir__)
  manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
  entries = manifest.select { |entry| entry["ical"] }

  it "covers every one of the 42 recurrence examples" do
    expect(entries.size).to eq(42)
    expect(entries).to all(include("expected"))
  end

  entries.each do |entry|
    it "matches the printed results for #{entry.fetch("json")}" do
      expected = JSON.parse(File.read(File.join(directory, entry.fetch("expected"))))
      item = JSCalendar.parse(File.read(File.join(directory, entry.fetch("json"))))
      rule = item.to_h.fetch("recurrenceRules").first
      # Finite examples also check there are no unexpected later instances.
      last = if rule.key?("count") || rule.key?("until")
               Time.utc(2050)
             else
               JSCalendar::TimeZoneResolver.new(item.time_zone).to_utc(JSCalendar::LocalDateTime.new(expected.last)) + 1
             end
      results = item.occurrences(from: item.start_time, to: last, limit: 1000, timeout: 10)
      expect(results.map { |value| value.recurrence_id.to_s }).to eq(expected)
      expect(results.truncated?).to be(false)
    end
  end
end
