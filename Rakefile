# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
desc "Fetch pinned references and prepare temporary RFC examples"
task :fixtures do
  require_relative "script/update_registry"
  RFCFixtures.prepare
  CalendarRegistry.prepare
end
task spec: :fixtures
task test: :spec
task default: :spec
