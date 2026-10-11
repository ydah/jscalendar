# frozen_string_literal: true

require "digest"
require "tempfile"
require "tmpdir"
require_relative "extract_examples"

module RFCFixtures
  ROOT = File.expand_path("../tmp/rfc", __dir__)
  DIRECTORY = File.join(ROOT, "fixtures")
  MANIFEST = JSON.parse(File.read(File.join(__dir__, "rfc_sources.json"))).freeze

  module_function

  def verify_source(path, checksum)
    raise "SHA-256 mismatch for #{path}; remove the cached file and retry" unless Digest::SHA256.file(path).hexdigest == checksum
  end

  def fetch(source, path)
    if File.file?(path)
      verify_source(path, source.fetch("sha256"))
      return
    end

    Tempfile.create(["download-", ".xml"], File.dirname(path)) do |file|
      success = system("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
                       "--retry", "3", "--connect-timeout", "10", "--max-time", "60", source.fetch("url"), "--output", file.path)
      raise "Download failed: #{source.fetch("url")}" unless success

      verify_source(file.path, source.fetch("sha256"))
      File.rename(file.path, path)
    end
  end

  def verify_fixtures(directory)
    count = JSON.parse(File.read(File.join(directory, "manifest.json"))).length
    raise "Fixture count mismatch" unless count == MANIFEST.fetch("example_count")

    entries = Dir.children(directory).sort.reject { |name| name == "LICENSE" }.map do |name|
      [name, Digest::SHA256.file(File.join(directory, name)).hexdigest]
    end
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(entries))
    raise "Fixture fingerprint mismatch; review the sources and extraction changes" unless fingerprint == MANIFEST.fetch("fixtures_sha256")
  end

  def prepare
    sources = File.join(ROOT, "sources")
    FileUtils.mkdir_p(sources)
    MANIFEST.fetch("sources").each do |number, source|
      fetch(source, File.join(sources, "rfc#{number}.#{source.fetch("format", "xml")}"))
    end
    Dir.mktmpdir("extract-", ROOT) do |temporary|
      directory = File.join(temporary, "fixtures")
      RFCExamples.extract(sources, directory)
      verify_fixtures(directory)
      # The short notification is permitted by IETF Trust Legal Provisions sections 4.e and 6.d.
      File.write(File.join(directory, "LICENSE"), <<~NOTICE)
        RFC Code Components used only for conformance tests.
        Copyright (c) 2009, 2021 IETF Trust and the persons
        identified as authors of the code. All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, is permitted pursuant to, and subject to the license terms
        contained in, the Revised BSD License set forth in Section 4.c of the
        IETF Trust's Legal Provisions Relating to IETF Documents
        (https://trustee.ietf.org/license-info).

        Source attribution and corrections: manifest.json and adjacent .original*.txt files.
        Full source documents, including author and copyright notices: ../sources/
        #{MANIFEST.fetch("sources").values.map { |source| source.fetch("url") }.join("\n")}
      NOTICE
      FileUtils.rm_rf(DIRECTORY)
      FileUtils.mv(directory, DIRECTORY)
    end
    puts "RFC fixtures ready in #{DIRECTORY}"
  end
end

RFCFixtures.prepare if $PROGRAM_NAME == __FILE__
