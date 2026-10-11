# frozen_string_literal: true

RSpec.describe JSCalendar do
  it "applies the requested validation depth to Hash and JSON input consistently" do
    data = { "@type" => "Event", "uid" => "deep", "updated" => "2026-01-01T00:00:00Z", "start" => "2026-01-01T00:00:00",
             "example.test:nested" => 35.times.reduce("value") { |item, _| [item] } }
    expect { JSCalendar.validate(data) }.to raise_error(JSCalendar::LimitError)
    expect(JSCalendar.validate(data, max_depth: 40)).to be_empty
    expect(JSCalendar.validate(JSON.generate(data), max_depth: 40)).to be_empty
  end

  def event(**extra)
    { "@type" => "Event", "uid" => "original", "updated" => "2026-10-11T00:00:00Z", "start" => "2026-10-12T10:00:00" }.merge(extra.transform_keys(&:to_s))
  end

  def parse(data, **options)
    described_class.parse(JSON.generate(data), **options)
  end

  it "round trips all downloaded RFC examples with recorded corrections" do
    require_relative "../script/prepare_rfc_fixtures"
    RFCFixtures.prepare unless File.file?(File.join(RFCFixtures::DIRECTORY, "manifest.json"))
    entries = JSON.parse(File.read(File.join(RFCFixtures::DIRECTORY, "manifest.json")))
    expect(entries.size).to eq(52)
    entries.each do |entry|
      source = File.read(File.join(RFCFixtures::DIRECTORY, entry.fetch("json")))
      expect(JSON.parse(described_class.parse(source).to_json)).to eq(JSON.parse(source))
    end
  end

  it "preserves unknown extensions, signed zero, and arbitrary exact binary64 values" do
    random = Random.new(8914)
    floats = [-0.0, Float::MAX, Float::MIN, 1.0e-320] + Array.new(100) { [random.bytes(8)].pack("a*").unpack1("G") }.select(&:finite?)
    floats.each do |number|
      value = parse(event("vendor.test:value": { "number" => number }))
      after = JSON.parse(value.to_json).dig("vendor.test:value", "number")
      expect([after].pack("G")).to eq([number].pack("G"))
    end
  end

  it "generates typed models and mutable map views without aliasing input or exports" do
    source = event(locations: { "room" => { "@type" => "Location", "name" => "Original" } })
    item = parse(source)
    item.locations["room"].name = "Changed"
    expect(item.to_h.dig("locations", "room", "name")).to eq("Changed")
    expect(source.dig("locations", "room", "name")).to eq("Original")
    copy = item.to_h
    copy["locations"].clear
    expect(item.locations.keys).to eq(["room"])
    expect(item.locations.values.first).to be_a(JSCalendar::Location)
    expect(item.locations.size).to eq(1)
    expect(item.locations).not_to be_empty
    expect(item.locations.key?(:room)).to be(true)
    id = item.locations.add({ "@type" => "Location", "name" => "Second" }, prefix: "l")
    expect(item.locations.delete(id).name).to eq("Second")
    expect(item.locations.to_h.keys).to eq(["room"])
    expect { item.locations["bad/id"] = {} }.to raise_error(JSCalendar::ValidationError)
    expect(item).to eq(parse(item.to_h))
    item["title"] = "A"
    expect(item.key?(:title)).to be(true)
    expect(item.delete(:title)).to eq("A")
  end

  it "builds an event, rules, and typed values with snake_case input" do
    item = JSCalendar::Event.build do |e|
      e.start = "2026-10-12T10:00:00"
      e.time_zone = "Asia/Tokyo"
      e.duration = JSCalendar::Duration.new("PT1H")
      e.add_recurrence_rule(frequency: "weekly", by_day: [{ day: "mo" }])
    end
    expect(item.uid).to match(/\A[0-9a-f-]{36}\z/)
    expect(item.recurrence_rules.first.by_day.first.day).to eq("mo")
    expect(item.recurrence_rules.first.to_rrule).to eq("FREQ=WEEKLY;BYDAY=MO")
    expect(item.end_time - item.start_time).to eq(3600)
    expect(JSCalendar::Link.build(href: "https://example.test").href).to eq("https://example.test")
  end

  it "retains and ignores unknown group entry and trigger types" do
    item = parse({ "@type" => "Group", "uid" => "g", "updated" => "2026-01-01T00:00:00Z",
                   "entries" => [event, { "@type" => "example.test:Other", "data" => [1] }] })
    expect(item.entries.first).to be_a(JSCalendar::Event)
    expect(item.entries.last["data"]).to eq([1])
    trigger = { "@type" => "example.test:Trigger", "thing" => true }
    expect(parse(event(alerts: { "a" => { "@type" => "Alert", "trigger" => trigger } })).alerts["a"].trigger).to eq(trigger)
  end

  it "reports lenient warnings but never emits invalid generated data" do
    item = parse(event(priority: 10), strict: false)
    expect(item.warnings.first.pointer).to eq("/priority")
    expect(item.valid?).to be(false)
    expect { item.to_json }.to raise_error(JSCalendar::ValidationError)
    expect(described_class.validate(event(percentComplete: 500)).map(&:pointer)).to include("/percentComplete")
  end

  it "rejects duplicate JSON keys, invalid roots, cycles, non-finite and non-I-JSON values" do
    expect { described_class.parse('{"@type":"Event","@type":"Task"}') }.to raise_error(JSCalendar::ParseError)
    [nil, 1, "null", "[]", '{"@type":"Future"}', "{"].each { |source| expect { described_class.parse(source) }.to raise_error(JSCalendar::ParseError) }
    [Float::INFINITY, 2**54, "\uFFFF"].each do |value|
      expect { JSCalendar::Event.new(event("vendor.test:value": value), strict: true) }.to raise_error(JSCalendar::ValidationError)
    end
    cycle = {}
    cycle["cycle"] = cycle
    expect { JSCalendar::Event.new(cycle) }.to raise_error(JSCalendar::ValidationError, /cyclic/)
    expect { JSCalendar::Event.new({ "uid" => "a", uid: "b" }) }.to raise_error(JSCalendar::ValidationError, /duplicate/)
    expect { JSCalendar::Event.new({ 1 => "bad" }) }.to raise_error(JSCalendar::ValidationError)
    expect { JSCalendar::Event.new(event(bad: Object.new)) }.to raise_error(JSCalendar::ValidationError)
  end

  it "reports invalid application string encodings before applying field syntax" do
    value = event(start: "\xff".dup.force_encoding("UTF-8"))
    expect(described_class.validate(value).map(&:pointer)).to include("/start")
    expect { JSCalendar::Event.new(value, strict: true) }.to raise_error(JSCalendar::ValidationError)
  end

  it "enforces input, depth, collection, patch, and data URI limits" do
    expect { parse(event, max_input_size: 10) }.to raise_error(JSCalendar::LimitError)
    expect { parse(event("vendor.test:nested": [[[[1]]]]), max_depth: 3) }.to raise_error(JSCalendar::LimitError)
    expect { parse(event, max_map_size: 2) }.to raise_error(JSCalendar::LimitError)
    expect { parse(event(links: { "a" => { "@type" => "Link", "href" => "data:text/plain,12345" } }), max_data_uri_size: 4) }.to raise_error(JSCalendar::LimitError)
    expect { JSCalendar::PatchObject.new({ "a" => 1 }, max_patches: 0) }.to raise_error(JSCalendar::LimitError)
    expect { parse(event, max_depth: -1) }.to raise_error(ArgumentError)
    expect { parse(event, max_depth: 0) }.to raise_error(ArgumentError)
    expect { described_class.validate(event, max_depth: 0) }.to raise_error(ArgumentError)
    expect { described_class.validate(event, max_depth: "2") }.to raise_error(ArgumentError)
    expect { parse(event, unknown: 1) }.to raise_error(ArgumentError)
  end

  {
    priority: -1, sequence: 1.5, timeZone: "Nowhere/Zone", start: "2026-02-30T01:00:00", updated: "2026-10-11T00:00:00.00Z",
    locations: [], descriptionContentType: "application/json", locale: "not_a_language", recurrenceIdTimeZone: nil,
    links: { "bad/id" => { "@type" => "Link", "href" => "relative" } }, privacy: "invalid", replyTo: {},
    categories: { "relative" => true }, keywords: { "anything" => false }, recurrenceRules: [{ "@type" => "RecurrenceRule", "frequency" => "sometimes" }]
  }.each do |name, value|
    it("rejects invalid #{name}") { expect { parse(event(**{ name => value })) }.to raise_error(JSCalendar::ValidationError) }
  end

  it "applies localizations atomically while ignoring prohibited patch paths" do
    item = parse(event(title: "English", localizations: { "de" => { "title" => "Deutsch", "uid" => "ignored" } }))
    expect(item.localize("de").title).to eq("Deutsch")
    expect(item.localize("de").uid).to eq("original")
    expect(item.localize("fr").title).to eq("English")
    expect(item.title).to eq("English")
    expect { parse(event(localizations: { "de" => { "missing/name" => "Name" } })) }.to raise_error(JSCalendar::ValidationError)
  end

  it "matches localization language tags without case sensitivity" do
    item = parse(event(title: "Original", localizations: { "en-US" => { "title" => "Translation" } }))
    localized = item.localize("EN-us")
    expect(localized.title).to eq("Translation")
    expect(localized.locale).to eq("EN-us")
    expect(item.title).to eq("Original")
    expect(item.to_h.fetch("localizations").keys).to eq(["en-US"])
  end
end

RSpec.describe JSCalendar::PatchObject do
  it "supports escaped object keys and deletion without modifying the source" do
    value = { "a/b" => { "~x" => 1 }, "old" => true }
    result = described_class.new({ "a~1b/~0x" => 2, "old" => nil, "absent" => nil }).apply(value)
    expect(result).to eq({ "a/b" => { "~x" => 2 } })
    expect(value["old"]).to be(true)
    expect(described_class.new({ "" => 2 }).apply({})).to eq({ "" => 2 })
  end

  [{ "a" => {}, "a/b" => 1 }, { "a~2b" => 1 }, { "missing/x" => 1 }, { "array/0" => 1 }].each do |patch|
    it("rejects invalid patch #{patch.keys.join(",")}") do
      expect { described_class.new(patch).apply({ "a" => {}, "array" => [1] }) }.to raise_error(JSCalendar::ValidationError)
    end
  end

  it "rejects invalid configuration and non-object patch/targets" do
    expect { described_class.new([], max_patches: 2) }.to raise_error(JSCalendar::ValidationError)
    expect { described_class.new({}, max_patches: -1) }.to raise_error(ArgumentError)
    expect { described_class.new({}).apply([]) }.to raise_error(JSCalendar::ValidationError)
    expect(described_class.new({ "a" => 1 }).to_h).to eq({ "a" => 1 })
  end
end
