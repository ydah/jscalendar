# frozen_string_literal: true

require "objspace"
require_relative "../lib/jscalendar"

item = JSCalendar::Event.build(start: "2026-01-01T00:00:00", time_zone: "UTC") { |event| event.add_recurrence_rule(frequency: "secondly") }
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = item.occurrences(from: Time.utc(2026), to: Time.utc(2026, 1, 2), limit: 1000, timeout: 10)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
raise "occurrence bound failed" unless result.to_a.size == 1000 && result.truncated?

GC.start
puts "1000 of an infinite secondly recurrence: #{elapsed.round(3)}s; Ruby heap #{ObjectSpace.memsize_of_all} bytes"
