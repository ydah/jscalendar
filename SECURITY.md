# Security

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/ydah/jscalendar/security/advisories/new).
Include a minimal reproducer and the affected gem and Ruby versions.

Calendar data can include private locations and contact details. Applications control authentication, sharing, storage and logging.
Parsing never fetches calendar URIs, executes content, schedules invitations or sends alerts.
Input size, depth, collection sizes and recurrence work are bounded. Resource limits are hard failures even with `strict: false`.
Recurrence expansion requires an end time, caps its output and interrupts work after a configurable time budget.

Dependency changes must satisfy the MIT-only additional-dependency policy. The Ruby runtime and standard libraries are excepted. Consult the actual license files as well as package metadata; do not infer implementation provenance from packaging exclusions.
