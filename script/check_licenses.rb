# frozen_string_literal: true

require "bundler"

module DependencyPolicy
  # Ruby default/bundled libraries are the explicitly approved platform exception.
  STANDARD_LIBRARIES = %w[
    base64 benchmark bigdecimal cgi csv date debug delegate did_you_mean digest drb
    erb error_highlight etc fcntl fiddle fileutils find forwardable getoptlong io-console
    io-nonblock io-wait ipaddr irb json logger mutex_m net-ftp net-http net-imap net-pop
    net-protocol net-smtp nkf observer open-uri open3 openssl optparse ostruct pathname
    power_assert pp prettyprint pstore psych racc rbs rdoc readline readline-ext reline
    resolv resolv-replace rexml rinda ripper rss ruby2_keywords securerandom set shellwords
    singleton socket stringio strscan syntax_suggest syslog tempfile test-unit time timeout
    tmpdir tsort typeprof un uri weakref webrick win32ole yaml zlib
  ].freeze
  # Their gem metadata says MIT, but their bundled Unicode data has separate terms.
  NON_MIT_DATA = %w[unicode-display_width unicode-emoji].freeze
  DIFF_LCS_ALTERNATIVES = %w[MIT Artistic-1.0-Perl GPL-2.0-or-later].freeze

  def self.license(spec)
    return nil if NON_MIT_DATA.include?(spec.name)
    return "Ruby standard library exception" if STANDARD_LIBRARIES.include?(spec.name)
    return "MIT" if spec.licenses == ["MIT"]

    # diff-lcs LICENSE.md explicitly offers these three licenses as alternatives.
    return "MIT" if spec.name == "diff-lcs" && spec.licenses.sort == DIFF_LCS_ALTERNATIVES.sort

    nil
  end

  def self.self_test
    spec = Struct.new(:name, :licenses)
    cases = [
      ["example", ["MIT"], true], ["example", ["Apache-2.0"], false],
      ["example", [], false], ["example", ["MIT AND BSD-2-Clause"], false],
      ["example", ["MIT", "BSD-2-Clause"], false],
      ["json", ["Ruby"], true], ["not-a-standard-library", ["Ruby"], false],
      ["diff-lcs", DIFF_LCS_ALTERNATIVES, true], ["diff-lcs", ["GPL-2.0-only"], false],
      ["unicode-emoji", ["MIT"], false]
    ]
    cases.each do |name, licenses, accepted|
      raise "Incorrect license decision for #{name}: #{licenses}" unless !!license(spec.new(name, licenses)) == accepted
    end
    puts "Dependency policy self-test passed"
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--self-test"]
    DependencyPolicy.self_test
  else
    abort "Usage: ruby script/check_licenses.rb [--self-test]" unless ARGV.empty?
    rejected = Bundler.load.specs.sort_by(&:name).reject do |spec|
      selection = DependencyPolicy.license(spec)
      puts "#{spec.name} #{spec.version}: #{selection || "REJECTED #{spec.licenses.inspect}"}"
      selection
    end
    abort "Dependency policy rejected: #{rejected.map(&:name).join(", ")}" unless rejected.empty?
  end
end
