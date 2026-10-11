# frozen_string_literal: true

RSpec.describe "Object constraints" do
  def valid_event
    { "@type" => "Event", "uid" => "u", "updated" => "2026-01-01T00:00:00Z", "start" => "2026-01-01T12:00:00" }
  end

  def validate(data)
    JSCalendar.validate(data)
  end

  it "validates registered color, link, location, calendar and scheduling values" do
    valid = { "color" => "AliceBlue", "method" => "request",
              "links" => { "l" => { "@type" => "Link", "href" => "https://example.test", "rel" => "enclosure", "cid" => "part@example.test" } },
              "locations" => { "l" => { "@type" => "Location", "locationTypes" => { "office" => true } } },
              "recurrenceRules" => [{ "@type" => "RecurrenceRule", "frequency" => "yearly", "rscale" => "hebrew" }] }
    expect(validate(valid_event.merge(valid))).to be_empty
    ["#abc", "#A0b1C2", "yellowgreen"].each { |color| expect(validate(valid_event.merge("color" => color))).to be_empty }
    ["rebeccapurple", "#abcd", "rgb(0,0,0)", "invalid"].each { |color| expect(validate(valid_event.merge("color" => color))).not_to be_empty }
    expect(validate(valid_event.merge("method" => "REQUEST"))).not_to be_empty
    expect(validate(valid_event.merge("recurrenceRules" => [{ "@type" => "RecurrenceRule", "frequency" => "yearly", "rscale" => "invalid" }]))).not_to be_empty
    expect(JSCalendar::Link.new({ "@type" => "Link", "href" => "https://example.test", "rel" => "invalid", "cid" => "invalid" }).errors.map(&:pointer))
      .to contain_exactly("/rel", "/cid")
    expect(JSCalendar::Location.new({ "@type" => "Location", "locationTypes" => { "invalid" => true } }).valid?).to be(false)
  end

  it "reports violations rather than crashing on wrong types for every property" do
    JSCalendar::SCHEMA.each do |type, definition|
      definition.fetch("properties").each_key do |property|
        next if property == "@type"

        [nil, false, 0, "bad", [], {}, ["bad"], { "bad" => "bad" }].each do |value|
          data = { "@type" => type, property => value }
          expect { JSCalendar.validate(data) }.not_to raise_error, "#{type}.#{property}=#{value.inspect}"
        end
      end
    end
  end

  it "accepts complete scheduling participants, links, alerts, and localized metadata" do
    participant = {
      "@type" => "Participant", "name" => "Reader", "email" => '"quoted name"(comment)@example.test',
      "roles" => { "attendee" => true, "example.test:reviewer" => true }, "sendTo" => { "imip" => "mailto:a@example.test" },
      "language" => "en-Latn-US-variant-u-ca-gregory-x-private", "kind" => "individual", "participationStatus" => "accepted",
      "scheduleAgent" => "server", "scheduleForceSend" => false, "scheduleSequence" => 1, "scheduleStatus" => ["2.0", "3.1.2"],
      "scheduleUpdated" => "2026-01-01T00:00:00Z", "delegatedTo" => { "p2" => true }, "delegatedFrom" => { "p2" => true }, "memberOf" => { "p2" => true }
    }
    data = valid_event.merge(
      "participants" => { "p1" => participant, "p2" => { "@type" => "Participant", "roles" => { "owner" => true } } },
      "replyTo" => { "web" => "https://example.test/reply", "imip" => "mailto:organizer@example.test", "future" => "urn:example:reply" },
      "links" => { "icon" => { "@type" => "Link", "href" => "data:image/png;base64,AAAA", "rel" => "icon", "display" => "badge", "size" => 3 } },
      "alerts" => { "a" => { "@type" => "Alert", "trigger" => { "@type" => "OffsetTrigger", "offset" => "-PT5M", "relativeTo" => "end" },
                             "action" => "display" },
                    "b" => { "@type" => "Alert", "trigger" => { "@type" => "AbsoluteTrigger", "when" => "2026-01-01T00:00:00Z" } } },
      "descriptionContentType" => 'text/html;charset="utf-8"', "relatedTo" => { "another UID" => { "@type" => "Relation", "relation" => { "parent" => true } } }
    )
    expect(validate(data)).to be_empty
    model = JSCalendar.parse(JSON.generate(data))
    expect(model.alerts["a"].trigger.offset.to_seconds).to eq(-300)
    expect(model.related_to["another UID"].relation).to eq({ "parent" => true })
  end

  it "supports participants' task progress only when accepted" do
    task = valid_event.merge("@type" => "Task", "participants" => { "p" => { "@type" => "Participant", "roles" => { "attendee" => true },
                                                                             "progress" => "completed", "participationStatus" => "accepted",
                                                                             "percentComplete" => 100 } })
    expect(validate(task)).to be_empty
    task["participants"]["p"]["participationStatus"] = "declined"
    expect(validate(task).map(&:pointer)).to include("/participants/p/progress")
    task["@type"] = "Event"
    expect(validate(task).map(&:pointer)).to include("/participants/p/percentComplete")
  end

  [
    { "replyTo" => { "bad-method" => "https://example.test" } },
    { "replyTo" => { "web" => "http://example.test" } },
    { "replyTo" => { "imip" => "https://example.test" } },
    { "descriptionContentType" => "text/plain; charset=ascii" },
    { "participants" => { "p" => { "@type" => "Participant", "roles" => { "attendee" => true }, "sendTo" => { "imip" => "mailto:a@example.test" } } } },
    { "participants" => { "p" => { "@type" => "Participant", "roles" => { "attendee" => true }, "memberOf" => { "missing" => true } } } },
    { "participants" => { "p" => { "@type" => "Participant", "roles" => { "attendee" => true }, "scheduleStatus" => ["9.0"] } } },
    { "locations" => { "l" => { "@type" => "Location", "relativeTo" => "end" } } },
    { "locations" => { "l" => { "@type" => "Location", "coordinates" => "https://example.test" } } },
    { "links" => { "l" => { "@type" => "Link", "href" => "https://example.test", "display" => "badge" } } },
    { "recurrenceId" => "2026-01-01T12:00:00", "recurrenceRules" => [] },
    { "recurrenceOverrides" => { "2026-01-01T12:00:00" => { "excluded" => true, "title" => "invalid" } } },
    { "recurrenceOverrides" => { "2026-01-01T12:00:00" => { "priority" => 100 } } },
    { "recurrenceOverrides" => { "2026-01-01T12:00:00" => [] } },
    { "virtualLocations" => { "v" => { "@type" => "VirtualLocation", "uri" => "relative" } } },
    { "alerts" => { "a" => { "@type" => "Alert", "trigger" => {} } } }
  ].each_with_index do |fields, index|
    it("rejects cross-property violation #{index + 1}") { expect(validate(valid_event.merge(fields))).not_to be_empty }
  end

  it "enforces offset syntax and time zone rule restrictions" do
    base = { "@type" => "TimeZoneRule", "start" => "2026-01-01T00:00:00", "offsetFrom" => "+0100", "offsetTo" => "+020030" }
    expect(JSCalendar::TimeZoneRule.new(base).valid?).to be(true)
    %w[-0000 +2400 +0060 0100 +01:00].each do |offset|
      expect(JSCalendar::TimeZoneRule.new(base.merge("offsetFrom" => offset)).valid?).to be(false)
    end
    rule = { "@type" => "RecurrenceRule", "frequency" => "yearly" }
    expect(JSCalendar::TimeZoneRule.new(base.merge("recurrenceRules" => [rule, rule])).valid?).to be(false)
    expect(JSCalendar::TimeZoneRule.new(base.merge("recurrenceOverrides" => { "2026-02-01T00:00:00" => { "title" => "invalid" } })).valid?).to be(false)
  end

  it "validates escaped email comments, quoted strings, and language subtags" do
    %w[en ja JP-x-a i-klingon zh-Hant-TW x-private en-US-u-ca-gregory].each { |tag| expect(JSCalendar::Types.language_tag?(tag)).to be(true) }
    %w[en-u en-a-aa-a-bb en-abcde-abcde en-US-! en-x].each { |tag| expect(JSCalendar::Types.language_tag?(tag)).to be(false) }
    ["a@example.test", "a(comment)@example.test", '"a\\"b"@example.test', "a@[127.0.0.1]"].each { |email| expect(JSCalendar::Types.email?(email)).to be(true) }
    ["a(unclosed@example.test", '"unclosed@example.test', "a@example.test)", "a\nb@example.test"].each { |email| expect(JSCalendar::Types.email?(email)).to be(false) }
  end
end
