# frozen_string_literal: true

require "psych"

module RepositoryYAML
  def self.validate(source, filename)
    stream = Psych.parse_stream(source, filename: filename)
    unless stream.children.length == 1 && stream.children.first.root.is_a?(Psych::Nodes::Mapping)
      raise ArgumentError, "#{filename}: expected one YAML mapping document"
    end
    check_keys(stream, filename)
  end

  def self.check_keys(node, filename)
    if node.is_a?(Psych::Nodes::Mapping)
      keys = {}
      node.children.each_slice(2) do |key, _value|
        location = "#{filename}:#{key.start_line + 1}"
        raise ArgumentError, "#{location}: expected a scalar mapping key" unless key.is_a?(Psych::Nodes::Scalar)
        raise ArgumentError, "#{location}: duplicate key #{key.value.inspect}" if keys.key?(key.value)

        keys[key.value] = true
      end
    end
    (node.children || []).each { |child| check_keys(child, filename) }
  end

  def self.self_test
    cases = {
      "on:\n  push:\njobs:\n  test:\n    steps: [{run: 'true'}]\n" => true,
      "a: {run: first}\nb: {run: second}\n" => true,
      "jobs:\n  test:\n    steps: [{run: first, 'run': second}]\n" => false,
      "jobs: [\n" => false,
      "a: 1\n---\nb: 2\n" => false,
      "- not a mapping\n" => false,
      "? [complex, key]\n: value\n" => false,
      "" => false
    }
    cases.each do |source, expected|
      accepted = begin
        validate(source, "self-test.yml")
        true
      rescue Psych::SyntaxError, ArgumentError
        false
      end
      raise "Incorrect YAML validation for #{source.inspect}" unless accepted == expected
    end
    puts "Repository YAML self-test passed"
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--self-test"]
    RepositoryYAML.self_test
  else
    abort "Usage: ruby script/check_yaml.rb [--self-test]" unless ARGV.empty?
    root = File.expand_path("..", __dir__)
    files = Dir.glob(".github/**/*.{yml,yaml}", base: root).sort
    abort "No GitHub YAML configuration found" if files.empty?
    failed = files.reject do |file|
      RepositoryYAML.validate(File.read(File.join(root, file)), file)
      true
    rescue Psych::SyntaxError, ArgumentError => error
      warn error.message
      false
    end
    abort "Repository YAML check failed" unless failed.empty?
    puts "GitHub YAML checked: #{files.length} files"
  end
end
