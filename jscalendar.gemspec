# frozen_string_literal: true

require_relative "lib/jscalendar/version"

Gem::Specification.new do |spec|
  spec.name = "jscalendar"
  spec.version = Jscalendar::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Read, validate, and expand JSCalendar events and tasks"
  spec.description = "RFC 8984 calendar models, time zones, atomic patches, and bounded recurrence expansion."
  spec.homepage = "https://github.com/ydah/jscalendar"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "sig/**/*.rbs", "data/*.yml", "README.md", "LICENSE.txt", "CHANGELOG.md", "SECURITY.md"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "json", ">= 2.19.4", "< 4"
  spec.add_dependency "tzinfo", ">= 2.0", "< 3"
end
