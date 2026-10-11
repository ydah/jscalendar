# frozen_string_literal: true

RSpec.describe "JSCalendar" do
  let(:event) { { "@type" => "Event", "uid" => "meeting", "updated" => "2026-10-11T00:00:00Z", "start" => "2026-10-12T10:00:00" } }

  it "round trips and exposes calendar value types" do
    item = JSCalendar.parse(JSON.generate(event))
    expect(item).to be_a(JSCalendar::Event)
    expect(item.start).to be_a(JSCalendar::LocalDateTime)
    expect(item.duration.to_seconds).to eq(0)
    expect(JSON.parse(item.to_json)).to eq(event)
  end

  it "reports missing required fields" do
    expect { JSCalendar.parse(JSON.generate(event.except("uid"))) }.to raise_error(JSCalendar::ValidationError) { |error| expect(error.pointer).to eq("/uid") }
  end

  it "expands with exclusions and overrides" do
    data = event.merge("timeZone" => "Asia/Tokyo", "recurrenceRules" => [{ "@type" => "RecurrenceRule", "frequency" => "daily", "count" => 3 }],
                       "recurrenceOverrides" => { "2026-10-13T10:00:00" => { "excluded" => true }, "2026-10-14T10:00:00" => { "title" => "Special" } })
    result = JSCalendar.parse(JSON.generate(data)).occurrences(from: Time.utc(2026, 10, 11), to: Time.utc(2026, 10, 16))
    expect(result.map { |o| o.start_time.utc.iso8601 }).to eq(["2026-10-12T01:00:00Z", "2026-10-14T01:00:00Z"])
    expect(result.to_a.last.event.title).to eq("Special")
  end
end
