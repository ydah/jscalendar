# frozen_string_literal: true

RSpec.describe "Recurrence expansion" do
  def event(start: "2026-01-05T09:00:00", zone: "UTC", **rule)
    JSCalendar::Event.build(start: start, time_zone: zone) { |e| e.add_recurrence_rule(**rule) }
  end

  def expand(item, from: Time.utc(2026), to: Time.utc(2027), **options)
    item.occurrences(from: from, to: to, **options)
  end

  { secondly: 1, minutely: 60, hourly: 3600, daily: 86_400, weekly: 7 * 86_400 }.each do |frequency, interval|
    it "expands #{frequency} with count and interval" do
      item = event(frequency: frequency.to_s, interval: 2, count: 3)
      expect(expand(item).map(&:start_time)).to eq(Array.new(3) { |i| Time.utc(2026, 1, 5, 9) + (i * 2 * interval) })
    end
  end

  it "bounds secondly recurrences and rejects unbounded requests" do
    result = expand(event(frequency: "secondly"), from: Time.utc(2026, 1, 5, 9), to: Time.utc(2026, 1, 5, 10), limit: 10)
    expect(result.to_a.size).to eq(10)
    expect(result.truncated?).to be(true)
    expect(result.to_a.last.start_time).to eq(Time.utc(2026, 1, 5, 9, 0, 9))
    item = event(frequency: "secondly")
    [0, -1, 10_001].each { |limit| expect { expand(item, limit: limit) }.to raise_error(ArgumentError) }
    [0, Float::INFINITY, "2"].each { |timeout| expect { expand(item, timeout: timeout) }.to raise_error(ArgumentError) }
    expect { expand(item, from: Time.utc(2027), to: Time.utc(2026)) }.to raise_error(ArgumentError)
    expect { expand(item, from: "2026", to: Time.utc(2027)) }.to raise_error(ArgumentError)
  end

  it "interrupts impossible high-frequency rules" do
    item = event(frequency: "secondly", by_month: ["2"], by_month_day: [30])
    expect { expand(item, to: Time.utc(9998), timeout: 0.05) }.to raise_error(JSCalendar::LimitError, /time limit/)
  end

  it "bounds expanded payload size and respects exclusion of the base event" do
    item = event(frequency: "daily", count: 3)
    small = JSCalendar::Event.new(item.to_h, max_occurrence_bytes: 1)
    expect { expand(small) }.to raise_error(JSCalendar::LimitError, /max_occurrence_bytes/)
    item.excluded = true
    item.recurrence_overrides = { "2026-01-06T09:00:00" => { "excluded" => false } }
    expect(expand(item).map { |o| o.start_time.day }).to eq([6])
  end

  it "includes DTSTART even when it does not match and counts it" do
    item = event(frequency: "weekly", by_day: [{ day: "tu" }], count: 2)
    expect(expand(item).map { |o| o.recurrence_id.to_s }).to eq(%w[2026-01-05T09:00:00 2026-01-06T09:00:00])
  end

  it "uses inclusive UNTIL, exclusive query end, and fractional starts" do
    item = event(start: "2026-01-05T09:00:00.25", frequency: "daily", until: "2026-01-07T09:00:00.25")
    expect(expand(item).map { |o| o.recurrence_id.to_s }).to eq(%w[2026-01-05T09:00:00.25 2026-01-06T09:00:00.25 2026-01-07T09:00:00.25])
    expect(expand(item, to: Time.utc(2026, 1, 6, 9)).to_a.size).to eq(1)
  end

  it "honors clock filters at each high frequency before applying count" do
    hourly = event(start: "2026-01-05T09:00:00", frequency: "hourly", by_hour: [9, 12], count: 3)
    expect(expand(hourly).map { |o| o.start_time.strftime("%d %H:%M:%S") }).to eq(["05 09:00:00", "05 12:00:00", "06 09:00:00"])
    minutely = event(frequency: "minutely", by_minute: [0, 30], by_hour: [9], count: 3)
    expect(expand(minutely).map { |o| o.start_time.strftime("%d %H:%M:%S") }).to eq(["05 09:00:00", "05 09:30:00", "06 09:00:00"])
    secondly = event(frequency: "secondly", by_second: [0, 30], by_minute: [0, 1], count: 3)
    expect(expand(secondly).map { |o| o.start_time.strftime("%H:%M:%S") }).to eq(%w[09:00:00 09:00:30 09:01:00])
    fractional = event(start: "2026-01-05T09:00:00.9", frequency: "secondly", until: "2026-01-05T09:00:01.5")
    expect(expand(fractional).to_a.size).to eq(1)
  end

  it "merges rules, excludes matches and reinserts explicit override dates" do
    item = event(frequency: "daily", count: 4)
    item.add_recurrence_rule(frequency: "weekly", count: 2)
    item.excluded_recurrence_rules = [{ "@type" => "RecurrenceRule", "frequency" => "weekly", "byDay" => [{ "@type" => "NDay", "day" => "tu" }], "count" => 2 }]
    item.recurrence_overrides = { "2026-01-06T09:00:00" => {}, "2026-01-07T09:00:00" => { "excluded" => true },
                                  "2025-12-31T09:00:00" => { "start" => "2026-01-09T10:00:00", "uid" => "ignored" } }
    result = expand(item)
    expect(result.map { |o| o.start_time.day }).to eq([5, 6, 8, 9, 12])
    expect(result.map { |o| o.event.uid }.uniq).to eq([item.uid])
    expect(result.to_a.first.event.recurrence_id).to eq("2026-01-05T09:00:00")
    expect(result.truncated?).to be(false)
  end

  it "uses due for a Task without a start and preserves floating recurrences" do
    task = JSCalendar::Task.build(due: "2026-01-01T10:00:00") { |t| t.add_recurrence_rule(frequency: "daily", count: 2) }
    result = expand(task, from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 4))
    expect(result.map { |o| o.event.due.to_s }).to eq(%w[2026-01-01T10:00:00 2026-01-02T10:00:00])
    expect { result.to_a.first.start_time }.to raise_error(JSCalendar::UnsupportedError)
    expect(result.to_a.first.start_time(time_zone: "UTC")).to eq(Time.utc(2026, 1, 1, 10))
    expect { JSCalendar::Task.build(recurrence_rules: [{ "@type" => "RecurrenceRule", "frequency" => "daily" }]) }.to raise_error(JSCalendar::ValidationError)
  end

  it "keeps local wall time stable across DST" do
    item = event(start: "2026-03-07T09:00:00", zone: "America/New_York", frequency: "daily", count: 3)
    expect(expand(item).map { |o| o.start_time.hour }).to eq([14, 13, 13])
    expect(expand(item).map { |o| o.recurrence_id.to_s }).to eq(%w[2026-03-07T09:00:00 2026-03-08T09:00:00 2026-03-09T09:00:00])
  end

  it "selects the last weekday of each month using BYSETPOS" do
    item = event(start: "2026-01-30T09:00:00", frequency: "monthly", by_day: %w[mo tu we th fr].map { |day| { day: day } }, by_set_position: [-1], count: 3)
    expect(expand(item).map { |o| o.start_time.strftime("%m-%d") }).to eq(%w[01-30 02-27 03-31])
  end

  it "handles yearly BYWEEKNO and an explicit week start" do
    item = event(frequency: "yearly", by_week_no: [2], by_day: [{ day: "mo" }], first_day_of_week: "mo", count: 2)
    result = expand(item, to: Time.utc(2028))
    expect(result.map { |o| o.start_time.strftime("%Y-%m-%d") }).to eq(%w[2026-01-05 2027-01-11])
  end

  it "inherits the initial weekday for yearly week-number filters" do
    item = event(frequency: "yearly", by_week_no: [2], count: 3)
    result = expand(item, to: Time.utc(2029))
    expect(result.map { |o| o.recurrence_id.to_s }).to eq(%w[2026-01-05T09:00:00 2027-01-11T09:00:00 2028-01-10T09:00:00])
  end

  it "keeps fractional occurrences at query boundaries and in exclusion rules" do
    item = event(start: "2026-01-05T09:00:00.25", frequency: "daily")
    result = expand(item, from: Time.utc(2026, 1, 6, 9) + Rational(1, 10), to: Time.utc(2026, 1, 7))
    expect(result.map { |o| o.recurrence_id.to_s }).to eq(["2026-01-06T09:00:00.25"])
    item.excluded_recurrence_rules = [{ "@type" => "RecurrenceRule", "frequency" => "daily", "count" => 1 }]
    expect(expand(item, to: Time.utc(2026, 1, 7)).map { |o| o.recurrence_id.to_s }).to eq(["2026-01-06T09:00:00.25"])
  end

  it "skips invalid month days and selects negative year days" do
    item = event(start: "2026-01-31T09:00:00", frequency: "monthly", count: 3)
    expect(expand(item).map { |o| o.start_time.month }).to eq([1, 3, 5])
    yearly = event(start: "2026-12-31T09:00:00", frequency: "yearly", by_year_day: [-1], count: 2)
    expect(expand(yearly, to: Time.utc(2028)).map { |o| o.start_time.day }).to eq([31, 31])
  end

  it "rejects non-Gregorian, SKIP adjustments and leap-second expansion explicitly" do
    [{ rscale: "hebrew" }, { skip: "forward" }, { by_second: [60] }].each do |properties|
      item = event(frequency: "yearly", **properties)
      expect(JSON.parse(item.to_json)).to include("recurrenceRules")
      expect { expand(item) }.to raise_error(JSCalendar::UnsupportedError)
    end
  end

  [{ interval: 0 }, { count: 1, until: "2027-01-01T00:00:00" }, { by_month_day: [0] }, { by_month_day: [32] }, { by_month: ["13"] },
   { by_year_day: [367] }, { by_week_no: [54] }, { by_hour: [24] }, { by_minute: [60] }, { by_second: [61] }, { by_set_position: [0] },
   { by_day: [{ day: "mo", nth_of_period: 0 }] }, { by_day: [] }, { by_month: [] }].each do |properties|
    it("rejects invalid recurrence #{properties.keys.join(",")}") do
      expect { event(frequency: "yearly", **properties) }.to raise_error(JSCalendar::ValidationError)
    end
  end
end
