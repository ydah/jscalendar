# frozen_string_literal: true

RSpec.describe "Gregorian candidate generation" do
  def times(start, rule, from: nil, to: nil, limit: 1000, include_initial: true)
    initial = JSCalendar::LocalDateTime.new(start).to_time
    rule = { "@type" => "RecurrenceRule" }.merge(rule)
    rule["byDay"]&.each { |day| day["@type"] = "NDay" }
    JSCalendar::Recurrence.rule_times(rule, initial, from || initial, to || Time.utc(initial.year + 4), limit: limit,
                                     include_initial: include_initial)
  end

  it "selects positions before removing dates preceding the initial occurrence" do
    result = times("2024-02-15T10:00:00", { "frequency" => "monthly", "byDay" => [{ "day" => "mo" }], "bySetPosition" => [1], "count" => 3 })
    expect(result.map { |time| time.strftime("%F") }).to eq(%w[2024-02-15 2024-03-04 2024-04-01])
  end

  it "selects a Cartesian position without materializing millions of seconds" do
    rule = { "frequency" => "yearly", "byYearDay" => (1..366).to_a, "byHour" => (0..23).to_a,
             "byMinute" => (0..59).to_a, "bySecond" => (0..59).to_a, "bySetPosition" => [-1], "count" => 3 }
    expect(times("2024-01-01T00:00:00", rule)).to eq([Time.utc(2024), Time.utc(2024, 12, 31, 23, 59, 59), Time.utc(2025, 12, 31, 23, 59, 59)])
  end

  it "sorts and deduplicates filters and set positions before counting" do
    rule = { "frequency" => "daily", "byHour" => [12, 9, 12], "byMinute" => [30, 0, 30], "bySecond" => [0, 0],
             "bySetPosition" => [-1, 1, 99, -99, 1], "count" => 4 }
    expect(times("2024-01-01T09:00:00", rule)).to eq([Time.utc(2024, 1, 1, 9), Time.utc(2024, 1, 1, 12, 30),
                                                    Time.utc(2024, 1, 2, 9), Time.utc(2024, 1, 2, 12, 30)])
  end

  it "uses Gregorian leap days, including dates before the historical reform" do
    rule = { "frequency" => "yearly", "count" => 3 }
    expect(times("1496-02-29T00:00:00", rule, to: Time.utc(1510)).map(&:year)).to eq([1496, 1504, 1508])
    expect(times("2000-02-29T00:00:00", rule, to: Time.utc(2010)).map(&:year)).to eq([2000, 2004, 2008])
  end

  it "filters ordinal weekdays within the year when no month is specified" do
    rule = { "frequency" => "yearly", "byDay" => [{ "day" => "fr", "nthOfPeriod" => -1 }], "count" => 3 }
    expect(times("2024-12-27T00:00:00", rule).map { |time| time.strftime("%F") }).to eq(%w[2024-12-27 2025-12-26 2026-12-25])
  end

  it "uses JSCalendar yearly month defaults rather than iCalendar expansion defaults" do
    rule = { "frequency" => "yearly", "byMonthDay" => [1], "count" => 4 }
    expect(times("2026-01-01T00:00:00", rule).map { |time| time.strftime("%F") }).to eq(%w[2026-01-01 2027-01-01 2028-01-01 2029-01-01])
    rule["byMonth"] = ["1", "2"]
    expect(times("2026-01-01T00:00:00", rule).map { |time| time.strftime("%F") }).to eq(%w[2026-01-01 2026-02-01 2027-01-01 2027-02-01])
  end

  it "measures yearly weekday ordinals within the year even with a month filter" do
    rule = { "frequency" => "yearly", "byMonth" => ["10"], "byDay" => [{ "day" => "su", "nthOfPeriod" => -1 }] }
    expect(times("2024-10-27T00:00:00", rule, include_initial: false)).to eq([])
    rule["byMonth"] = ["12"]
    expect(times("2024-10-27T00:00:00", rule, to: Time.utc(2026), include_initial: false).map { |time| time.strftime("%F") }).to eq(%w[2024-12-29 2025-12-28])
  end

  it "handles week numbers on both sides of a calendar-year boundary" do
    rule = { "frequency" => "daily", "byWeekNo" => [1], "firstDayOfWeek" => "mo" }
    result = times("2024-12-28T00:00:00", rule, to: Time.utc(2025, 1, 7), include_initial: false)
    expect(result.map { |time| time.strftime("%F") }).to eq(%w[2024-12-30 2024-12-31 2025-01-01 2025-01-02 2025-01-03 2025-01-04 2025-01-05])
    rule["byWeekNo"] = [-1]
    result = times("2020-12-30T00:00:00", rule, to: Time.utc(2021, 1, 5), include_initial: false)
    expect(result.map { |time| time.strftime("%F") }).to eq(%w[2020-12-30 2020-12-31 2021-01-01 2021-01-02 2021-01-03])
  end

  it "counts matching exclusions without forcing the initial occurrence" do
    rule = { "frequency" => "daily", "byDay" => [{ "day" => "fr" }], "count" => 2 }
    expect(times("2024-01-01T10:00:00", rule, include_initial: false)).to eq([Time.utc(2024, 1, 5, 10), Time.utc(2024, 1, 12, 10)])
    expect(times("2024-01-01T10:00:00", rule.merge("count" => 0))).to eq([])
  end

  it "jumps to distant windows without changing the interval phase" do
    rule = { "frequency" => "secondly", "interval" => 7 }
    from = Time.utc(2095, 7, 2, 3, 4, 5)
    values = times("2001-02-03T04:05:06.125", rule, from: from, to: from + 30)
    expect(values.size).to eq(5)
    expect(values).to all(be >= from)
    initial = Time.utc(2001, 2, 3, 4, 5, 6) + Rational(1, 8)
    expect(values.map { |value| (value - initial) % 7 }).to all(eq(0))
  end

  it "keeps nanosecond candidates just before a distant period boundary" do
    boundary = Time.utc(2096)
    from = boundary - Rational(2, 1_000_000_000)
    result = times("2024-01-01T23:59:59.999999999", { "frequency" => "daily" }, from: from, to: boundary)
    expect(result).to eq([boundary - Rational(1, 1_000_000_000)])
  end

  it "preserves results when randomized windows are split at arbitrary instants" do
    random = Random.new(4167)
    spans = { "secondly" => 1, "minutely" => 60, "hourly" => 3600, "daily" => 86_400, "weekly" => 604_800,
              "monthly" => 2_678_400, "yearly" => 31_622_400 }
    spans.each do |frequency, width|
      8.times do
        initial = Time.utc(2024, random.rand(1..12), random.rand(1..28), 7, 13, 19) + Rational(1, 4)
        start = JSCalendar::LocalDateTime.from_time(initial).to_s
        rule = { "frequency" => frequency, "interval" => random.rand(1..4) }
        rule["byDay"] = [{ "day" => %w[mo tu we th fr sa su].sample(random: random) }] if random.rand(2).zero?
        finish = initial + width * 30
        split = initial + width * random.rand(1..29) + Rational(1, 10)
        all = times(start, rule, to: finish)
        first = times(start, rule, to: split)
        last = times(start, rule, from: split, to: finish)
        expect(first + last).to eq(all), "#{rule} split at #{split}"
      end
    end
  end
end
