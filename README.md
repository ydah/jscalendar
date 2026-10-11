# JSCalendar

Read, validate, build and expand calendar events and tasks using [RFC 8984](https://www.rfc-editor.org/rfc/rfc8984).

```ruby
require "jscalendar"

meeting = JSCalendar::Event.build do |event|
  event.title = "Weekly review"
  event.start = "2026-10-12T10:00:00"
  event.time_zone = "Asia/Tokyo"
  event.duration = "PT1H"
  event.add_recurrence_rule(frequency: "weekly", by_day: [{ day: "mo" }])
end

json = meeting.to_json
copy = JSCalendar.parse(json)
copy.start_time # => 2026-10-12 01:00:00 UTC

instances = copy.occurrences(from: Time.utc(2026, 10, 1), to: Time.utc(2026, 11, 1), limit: 100)
instances.each { |instance| puts [instance.recurrence_id, instance.start_time, instance.event.title] }
instances.truncated?
```

Install with `gem install jscalendar`. Ruby 3.3 or newer is required. CI checks maintained CRuby versions, Ruby head, JRuby and TruffleRuby on Linux and macOS, and json 2 and 3. Runtime dependencies are `json` and `tzinfo`. Gregorian recurrence generation is implemented by this library. Install `tzinfo-data` on systems without a zoneinfo database, including Windows. No other Gem from this format family is required.

## Scope

| Feature | Support |
| --- | --- |
| Event, Task, Group and every RFC 8984 object type | Parsing, validation, building, serialization and RBS |
| Unknown and vendor fields | Preserved; unknown Group entries and trigger types remain opaque |
| PatchObject | Atomic object patches, pointer escaping and overlap checks; array traversal is invalid in JSCalendar 1.0 |
| Localizations | Permitted text patches with locale selection |
| IANA and custom time zones | Floating time, Group inheritance and pre-transition offsets at gaps and folds |
| Gregorian recurrence | All frequencies and BY fields, union, exclusions, additions and overrides |
| Non-Gregorian calendars, `skip: backward/forward`, leap-second recurrence | Preserved and validated; expansion raises `UnsupportedError` |
| JSCalendar 2.0 | Awaiting a published RFC |
| iCalendar conversion, invitations, free/busy services and alert delivery | Outside this release |

`Jscalendar` is an alias of `JSCalendar`. Wire names are camelCase; Ruby accessors also accept snake_case. `Event.build` and `Task.build` generate `uid` and `updated`. Nested typed views update their owning object; `to_h` returns an independent copy. `Group#entries` contains typed Event/Task views and preserved unknown entries.

## Validation and patches

```ruby
calendar = JSCalendar.parse(json, strict: false)
calendar.warnings.each { |violation| warn "#{violation.pointer}: #{violation.message}" }
JSCalendar.validate(json) # array of violations
calendar.localize("ja")  # a localized copy; source stays unchanged

patch = JSCalendar::PatchObject.new("title" => "New title", "description" => nil)
patched = patch.apply(calendar.to_h)
```

Strict parsing raises `ValidationError` with `errors` and a JSON Pointer in `pointer`. Lenient parsing preserves invalid fields with diagnostics. Serialization always validates. Unknown root types and malformed JSON raise `ParseError`; resource bounds raise `LimitError`, including in lenient mode. Duplicate keys are rejected with both supported json major versions.

Recurrence overrides ignore the protected property prefixes specified by RFC 8984 §4.3.5. An `excluded: true` override can contain no other change. Localizations ignore disallowed paths. Patches never partially modify their target.

## Time and recurrence

`start` and `due` return `LocalDateTime` values; `duration` returns a `Duration`. `Duration#to_seconds` is the nominal elapsed time, while `add_to` and `Event#end_time` honor calendar days across DST. `SignedDuration` supports positive and negative offsets. JSON and typed values preserve fractional seconds. Conversion to Ruby `Time` raises `UnsupportedError` for leap seconds or precision the runtime cannot retain (for example, subnanosecond fractions on TruffleRuby). Rational seconds must have a finite decimal representation.

Floating date-times require an explicit zone for an instant: `event.start_time(time_zone: "Europe/London")`. Occurrence windows use `Time` values, include `from`, and exclude `to`. Without a zone, floating recurrence windows are interpreted as UTC-shaped wall times, and each occurrence still needs a reference zone for `start_time`.

An occurrence inherits the base object and applies its override. `recurrence_id` identifies its original wall time, even if an override moves its start. DTSTART is always an included first instance and consumes one COUNT, as specified by JSCalendar. Exclusion rules include DTSTART only when it matches the rule. The result reports `truncated?` when the output/candidate bound cuts off the requested expansion.

Time-zone results follow the installed TZInfo data. Its explicit future transition horizon can be shorter than other timezone databases (for example, the current Ruby data ends New York transitions in 2076); do not use the last known offset as a guarantee about distant-future civil time. Custom `timeZones` definitions can express application-owned transition rules.

## Resource bounds

| Option | Default |
| --- | --- |
| `max_input_size` | 16 MiB |
| `max_depth` | 32 |
| `max_map_size` | 10,000 members per collection |
| `max_data_uri_size` | 1 MiB decoded |
| `max_patches` | 1,000 |
| `max_occurrences` | 10,000 candidates per rule |
| `max_rules` | 100 combined inclusion/exclusion rules |
| `max_occurrence_bytes` | 32 MiB of expanded calendar data |

Pass these keyword options to `parse` or model constructors. `occurrences` additionally requires `to`, defaults to `limit: 1000`, and enforces `timeout: 2.0` seconds over the entire expansion. An exclusion set larger than the candidate budget fails instead of returning an incorrect partial subtraction. Impossible recurrence rules also time out. URIs are data and are never fetched.

## Development and references

```sh
bundle install
bundle exec rake test
COVERAGE=1 bundle exec rake test
bundle exec rbs -I sig validate
bundle exec ruby script/benchmark.rb
```

RFC source documents and 52 generated examples are fetched into ignored `tmp/` with pinned checksums and a generated-fixture fingerprint. Original text, correction notes and the applicable test-source license notice remain there. RFC material, IANA downloads, external implementations, tests and build artifacts are excluded from the Gem. Authored implementation and validation metadata are MIT licensed.

`script/update_registry.rb` checks property and enum identifiers against pinned IANA registries, CLDR calendar names and CSS Level 3 color names. Downloaded sources remain in ignored `tmp/registry/`; only identifiers needed for validation are present in the authored metadata. Updating a checksum requires reviewing the corresponding metadata differences. Source terms are available from [IANA](https://www.iana.org/help/licensing-terms), [Unicode](https://www.unicode.org/license.txt) and [W3C](https://www.w3.org/copyright/document-license/).

Every Ruby test job checks all 42 RFC 5545 recurrence examples against the results printed in the downloaded RFC. Finite examples also check for unexpected extra occurrences; infinite examples are checked through the last printed date. RFC 8984's ten examples all round trip. See [specification decisions](docs/specification.md) for errata and extraction corrections.

Additional dependencies must offer the MIT license, including development and comparison tools. The Ruby runtime and its standard libraries are exceptions to this policy. Reference documents and registry facts are test/specification inputs, not dependency implementations. See [implementation provenance](docs/provenance.md) for the scope and limits of the source audit.
