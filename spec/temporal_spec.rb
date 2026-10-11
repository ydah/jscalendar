# frozen_string_literal: true

RSpec.describe "Calendar times" do
  def event(start, zone = nil, **extra)
    JSCalendar::Event.build(start: start, time_zone: zone, **extra)
  end

  it "validates canonical local date-times and arbitrary decimal precision" do
    ["2026-01-01T01:02:03", "0000-02-29T00:00:00", "2026-01-01T00:00:00.000000000123"].each do |text|
      value = JSCalendar::LocalDateTime.new(text)
      precise_time = (Time.utc(2026) + Rational(123, 10**12)).subsec == Rational(123, 10**12)
      if !precise_time && text.end_with?(".000000000123")
        expect { value.to_time }.to raise_error(JSCalendar::UnsupportedError, /precision/)
      else
        expect(JSCalendar::LocalDateTime.from_time(value.to_time).to_s).to eq(text)
      end
      expect(value).to eq(text)
    end
    ["2026-01-01", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00.0", "2026-02-29T00:00:00", "2026-01-01t00:00:00"].each do |text|
      expect { JSCalendar::LocalDateTime.new(text) }.to raise_error(JSCalendar::ValidationError)
    end
    expect(JSCalendar::LocalDateTime.new("2026-01-01T00:00:00")).to be < JSCalendar::LocalDateTime.new("2026-01-02T00:00:00")
    expect(JSCalendar::LocalDateTime.new("2026-01-01T00:00:00.0000000001")).to be < JSCalendar::LocalDateTime.new("2026-01-01T00:00:00.0000000002")
    expect { JSCalendar::LocalDateTime.new("2016-12-31T23:59:60").to_time }.to raise_error(JSCalendar::UnsupportedError)
  end

  it "converts durations and signed durations without floating point rounding" do
    { "PT0S" => 0, "P1W2DT3H4M5.25S" => Rational(78_864_525, 100), "P1D" => 86_400, "PT1M2S" => 62 }.each do |text, seconds|
      duration = JSCalendar::Duration.new(text)
      expect(duration.to_s).to eq(text)
      expect(duration.to_seconds).to eq(seconds)
    end
    expect(JSCalendar::Duration.from_seconds(1.25).to_s).to eq("PT1.25S")
    expect(JSCalendar::Duration.from_seconds(Rational(1, 8)).to_s).to eq("PT0.125S")
    expect { JSCalendar::Duration.from_seconds(Rational(1, 3)) }.to raise_error(ArgumentError, /finite decimal/)
    expect(JSCalendar::SignedDuration.from_seconds(-1.25).to_s).to eq("-PT1.25S")
    expect(JSCalendar::SignedDuration.new("+PT1H").to_seconds).to eq(3600)
    %w[P PT P1DT PT1.0S PT1H2S P1Y -P1D P1M].each { |text| expect { JSCalendar::Duration.new(text) }.to raise_error(JSCalendar::ValidationError) }
    [-1, Float::INFINITY, "1"].each { |value| expect { JSCalendar::Duration.from_seconds(value) }.to raise_error(ArgumentError) }
  end

  it "uses the offset before both a DST gap and a fold" do
    expect(event("2020-11-01T01:30:00", "America/Los_Angeles").start_time).to eq(Time.utc(2020, 11, 1, 8, 30))
    expect(event("2020-10-04T02:30:00", "Australia/Melbourne").start_time).to eq(Time.utc(2020, 10, 3, 16, 30))
  end

  it "distinguishes calendar days from elapsed hours across DST and handles subtraction" do
    one_day = event("2026-03-07T12:00:00", "America/New_York", duration: "P1D")
    hours = event("2026-03-07T12:00:00", "America/New_York", duration: "PT24H")
    expect(one_day.end_time - one_day.start_time).to eq(23 * 3600)
    expect(hours.end_time - hours.start_time).to eq(24 * 3600)
    expect(JSCalendar::SignedDuration.new("-P1DT1H").add_to("2026-03-08T12:00:00", time_zone: "America/New_York").to_s).to eq("2026-03-07T11:00:00")
    expect(JSCalendar::Duration.new("PT1H").add_to("2026-01-01T00:00:00").to_s).to eq("2026-01-01T01:00:00")
    expect(JSCalendar::SignedDuration.new("-P1D").add_to("2026-01-02T00:00:00").to_s).to eq("2026-01-01T00:00:00")
  end

  it "requires a reference zone for floating instants" do
    item = event("2026-01-01T10:00:00")
    expect { item.start_time }.to raise_error(JSCalendar::UnsupportedError)
    expect { item.end_time }.to raise_error(JSCalendar::UnsupportedError)
    expect(item.start_time(time_zone: "Asia/Tokyo")).to eq(Time.utc(2026, 1, 1, 1))
    task = JSCalendar::Task.build(due: "2026-01-01T10:00:00", time_zone: "UTC")
    expect(task.start_time).to eq(task.end_time)
    expect { JSCalendar::Task.build.start_time }.to raise_error(JSCalendar::ValidationError)
  end

  let(:custom) do
    { "@type" => "TimeZone", "tzId" => "Custom",
      "standard" => [{ "@type" => "TimeZoneRule", "start" => "2020-10-25T03:00:00", "offsetFrom" => "+0200", "offsetTo" => "+0100",
                       "recurrenceRules" => [{ "@type" => "RecurrenceRule", "frequency" => "yearly",
                                               "byMonth" => ["10"], "byMonthDay" => [-7, -6, -5, -4, -3, -2, -1],
                                               "byDay" => [{ "@type" => "NDay", "day" => "su" }] }] }],
      "daylight" => [{ "@type" => "TimeZoneRule", "start" => "2020-03-29T02:00:00", "offsetFrom" => "+0100", "offsetTo" => "+0200",
                       "recurrenceRules" => [{ "@type" => "RecurrenceRule", "frequency" => "yearly",
                                               "byMonth" => ["3"], "byMonthDay" => [-7, -6, -5, -4, -3, -2, -1],
                                               "byDay" => [{ "@type" => "NDay", "day" => "su" }] }] }] }
  end

  it "resolves independent custom zones and inherits them through Groups" do
    item = event("2026-07-01T12:00:00", "/custom", time_zones: { "/custom" => custom })
    expect(item.start_time).to eq(Time.utc(2026, 7, 1, 10))
    expect(event("2026-10-25T02:30:00", "/custom", time_zones: { "/custom" => custom }).start_time).to eq(Time.utc(2026, 10, 25, 0, 30))
    expect(event("2026-03-29T02:30:00", "/custom", time_zones: { "/custom" => custom }).start_time).to eq(Time.utc(2026, 3, 29, 1, 30))
    data = item.to_h
    data.delete("timeZones")
    group = JSCalendar::Group.build(time_zones: { "/custom" => custom }, entries: [data])
    expect(group.entries.first.start_time).to eq(item.start_time)
    expect(group.entries.first.to_json).to include('"/custom"')
    resolver = JSCalendar::TimeZoneResolver.new("/custom", { "/custom" => custom })
    expect(resolver.to_local(Time.utc(2026, 7, 1, 10)).to_s).to eq("2026-07-01T12:00:00")
    expect(resolver.to_local(Time.utc(2019, 7, 1, 10)).to_s).to eq("2019-07-01T11:00:00")
  end

  it "rejects malformed and unreferenced custom zones" do
    expect { event("2026-01-01T12:00:00", "UTC", time_zones: { "/custom" => custom }) }.to raise_error(JSCalendar::ValidationError, /unreferenced/)
    expect { event("2026-01-01T12:00:00", "/custom", time_zones: { "/custom" => { "@type" => "TimeZone", "tzId" => "Custom" } }) }.to raise_error(JSCalendar::ValidationError)
    expect { JSCalendar::TimeZoneResolver.new("invalid/zone") }.to raise_error(JSCalendar::ValidationError)
  end
end
