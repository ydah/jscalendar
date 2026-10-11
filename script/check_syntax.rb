# frozen_string_literal: true

require "open3"
require "rbconfig"

root = File.expand_path("..", __dir__)
files = Dir.glob("{lib,spec,script}/**/*.rb", base: root) + Dir.glob("*.{rb,gemspec}", base: root) + %w[Gemfile Rakefile]
failed = files.sort.reject do |file|
  output, error, status = Open3.capture3(RbConfig.ruby, "-c", File.join(root, file))
  warn "#{file}: #{output}#{error}" unless status.success?
  status.success?
end
abort "Ruby syntax check failed" unless failed.empty?
puts "Ruby syntax checked: #{files.length} files"
