# Implementation provenance

Additional runtime, development and comparison dependencies must offer the MIT license. Ruby itself and its standard libraries are exceptions. This record distinguishes protocol implementation from historical use of other implementations; it is not a legal opinion or a claim of independently isolated clean-room development.

## Recurrence implementation

`lib/jscalendar/recurrence.rb` contains the Gregorian recurrence generator authored for this project. Its design follows the frequency-period, candidate-filter and position-selection rules in RFC 8984 section 4.3.3.1 and RFC 5545 section 3.3.10. It uses Ruby calendar arithmetic and an indexed Cartesian product to avoid allocating an entire year's seconds. It preserves the library's occurrence, exclusion, override and resource-bound APIs. The serializer `RecurrenceRule#to_rrule` is an authored mapping of JSCalendar field names to iCalendar rule names; it does not load the `rrule` gem.

Previously the project depended on `rrule` 0.8.0, whose actual LICENSE.txt is Apache-2.0. During an earlier review, its `lib/rrule/rule.rb` was read to investigate count, fractional-second and filtering behavior. The adapter had project-authored workarounds. This is prior exposure, so this replacement is not described as a clean-room implementation. The replacement was designed from the standards and this project's API and tests; it does not translate or reuse the previous dependency's algorithm or code. The dependency and adapter calls have been removed.

All 42 RFC 5545 recurrence examples are checked against the date/time results printed in the downloaded RFC. `script/extract_recurrence_results.rb` is a separately authored parser of those result lists. Generated lists, source excerpts and notices stay in ignored `tmp/` and are excluded from the Gem. Handwritten boundary and randomized tests use synthetic data.

Earlier tests compared public input/output with Stalwart calcard 0.3.2 through a small project-authored Rust wrapper. calcard itself offers MIT or Apache-2.0; it was not removed for lacking an MIT option. The Cargo dependency graph included non-MIT terms, including BSD-3-Clause for sha1_smol and Unicode terms, so the wrapper, Cargo lockfile and external comparison job were removed. Other historical notes name python-dateutil as an examined implementation; this audit cannot reconstruct the extent of that inspection.

## Other implementation and metadata

The remaining `lib/`, `sig/` and `data/` files implement this project's public objects, validation, patches and temporal types. Metadata records protocol identifiers and constraints; source prose, schemas and implementation code are not included as metadata. The current audit does not reconstruct the complete original research history for every file, so it does not assert that no external implementation was ever inspected. No specific copied or translated third-party implementation was identified by this review. Absence from the package is not itself proof of independent authorship.

Runtime `tzinfo` and its `concurrent-ruby` dependency offer MIT licenses; `json` is covered by the Ruby-standard-library exception. The optional `tzinfo-data` Gem offers MIT and carries the public-domain timezone data. RuboCop was removed because its Unicode-data dependencies have additional non-MIT terms. Pinned RFC, IANA, CLDR and CSS documents are specification/test inputs; source-specific notices and downloaded content remain in ignored temporary directories. Review actual license texts and transitive dependencies for each dependency change.
