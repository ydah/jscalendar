# frozen_string_literal: true

require "json"
require "fileutils"
require "rexml/document"
require "rexml/xpath"
require_relative "extract_recurrences"

module RFCExamples
  module_function

  def extract(sources, directory)
    FileUtils.mkdir_p(directory)
    document = REXML::Document.new(File.read(File.join(sources, "rfc8984.xml")))
    entries = REXML::XPath.match(document, "//sourcecode[@type='json']").map do |element|
      section = element.attributes["pn"].sub("section-", "").sub(/-\d+\z/, "")
      original = element.texts.map(&:value).join
      data = JSON.parse(original)
      notes = []
      if data.delete("...")
        notes << "Supply omitted metadata and remove the presentation placeholder."
        data = { "@type" => section == "6.5" ? "Task" : "Event", "uid" => "example-#{section}",
                 "updated" => "2020-01-01T00:00:00Z" }.merge(data)
      end
      if section == "6.3"
        data["title"] = data.delete("name")
        notes << "Verified erratum 8028: Group name is title."
      end
      if section == "6.6"
        data.fetch("locations").each_value { |location| location["relativeTo"] = location.delete("rel") }
        notes << "Use the normative Location relativeTo property in place of example rel."
      end
      if section == "6.9"
        data.fetch("locations").each_value { |location| location["name"] = location.delete("title") }
        data.fetch("recurrenceOverrides").each_value do |patch|
          patch.fetch("locations", {}).each_value { |location| location["name"] = location.delete("title") }
        end
        notes << "Use the normative Location name property in place of example title; preserve the written June 25 override date."
      end
      name = "rfc8984_#{section}"
      File.write(File.join(directory, "#{name}.json"), "#{JSON.pretty_generate(data)}\n")
      File.write(File.join(directory, "#{name}.original.txt"), original)
      { "section" => section, "json" => "#{name}.json", "notes" => notes }
    end
    entries.concat(RFCRecurrences.extract(sources, directory))
    File.write(File.join(directory, "manifest.json"), "#{JSON.pretty_generate(entries)}\n")
    entries
  end
end

RFCExamples.extract(*ARGV) if $PROGRAM_NAME == __FILE__
