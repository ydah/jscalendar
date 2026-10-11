# Specification decisions

The implementation targets RFC 8984. As checked on 2026-10-11, JSCalendar 2.0 remains draft-ietf-calext-jscalendarbis-21.

- Verified erratum 6873 allows omission of `recurrenceIdTimeZone` for floating instances. The validator applies this correction.
- Verified erratum 6872 expands the private-sharing allowlist. Sharing-policy enforcement belongs to the calling application; serialization does not redact data.
- Verified erratum 8028 changes Group example `name` to `title`.
- The normative §4.7.2 UTC offset strings take precedence over the inconsistent §8.2.6 registry table, also identified by reported erratum 8461.
- Example §6.6 uses `rel` where the normative Location field is `relativeTo`. Example §6.9 uses Location `title` where the normative field is `name`. Extraction records these corrections. The written June 25 override date in §6.9 is retained; it is an additional occurrence even though the prose describes an exam at the last regular instance.
- Missing envelopes indicated by `...` are supplied only in temporary extracted fixtures. Original text is kept alongside each corrected fixture.
- Verified RFC 5545 erratum 3883 changes the hourly example's UNTIL to 21:00 UTC. Tests check the three occurrences printed in the RFC, without consulting another recurrence engine.
- The authored Gregorian engine builds date candidates within each frequency period, applies BY filters and indexed BYSETPOS selection, then applies start, COUNT and UNTIL bounds. It preserves fractional seconds and skips invalid calendar dates. Rules with no COUNT may jump to the first relevant period while retaining INTERVAL alignment.
- Custom TimeZoneRule UNTIL is interpreted in UTC as required by §4.7.2. The recurrence adapter converts it to the transition's wall-clock frame.

JSCalendar recurrence semantics take precedence where RFC 8984 differs from RFC 5545. A yearly ordinal BYDAY is measured within the year, including when BYMONTH is present. To express the last Sunday of a particular month in an annual custom zone rule, combine that month, byMonthDay values -7 through -1, and an unnumbered Sunday. For a yearly BYMONTHDAY rule without BYMONTH, BYWEEKNO or BYYEARDAY, the initial month is implicitly added as required by section 4.3.3.1. A lexical `to_rrule` serialization does not perform semantic iCalendar conversion; that conversion is outside this release.

The RFC result extractor handles numeric-list line continuations and expands arithmetic ellipses in printed result lists. Sources, expected dates, original excerpts and notices remain in ignored temporary files. See [provenance](provenance.md) for historical external implementation use.
