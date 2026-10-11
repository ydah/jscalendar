# frozen_string_literal: true

require_relative "prepare_rfc_fixtures"

module CalendarRegistry
  module_function

  def prepare
    pins = JSON.parse(File.read(File.join(__dir__, "registry_sources.json")))
    directory = File.expand_path("../tmp/registry/sources", __dir__)
    FileUtils.mkdir_p(directory)
    pins.each do |name, pin|
      path = File.join(directory, pin.fetch("filename", "#{name}.xml"))
      RFCFixtures.fetch(pin, path)
      next if name == "jscalendar"

      source = File.read(path)
      values = if name == "color"
                 source.scan(%r{<td><dfn id=[^>]+>([a-z]+)</dfn>}).flatten.uniq - %w[color opacity]
               elsif name == "rscale"
                 REXML::XPath.match(REXML::Document.new(source), "//key[@name='ca']/type").flat_map do |node|
                   [node.attributes["name"], *node.attributes["alias"].to_s.split]
                 end.uniq
               else
                 tag = name == "rel" ? "value" : "token"
                 REXML::XPath.match(REXML::Document.new(source), "//record/#{tag}").map { |node| node.text.strip }.uniq
               end
      raise "registry changed for #{name}; review metadata before updating the pin" unless values.sort == Jscalendar::ENUMS.fetch(name).sort
    end
    path = File.join(directory, "jscalendar.xml")
    document = REXML::Document.new(File.read(path))
    properties = REXML::XPath.match(document, "//registry[@id='jscalendar-properties']/record")
    raise "missing property registry" if properties.empty?

    properties.each do |record|
      next unless REXML::XPath.match(record, ".//xref[@data='rfc8984']").any?

      name = record.elements["type"].text.strip
      record.elements["context"].text.split(",").map(&:strip).each do |context|
        raise "missing #{context}.#{name}" unless Jscalendar::SCHEMA.dig(context, "properties", name)
      end
    end
    REXML::XPath.match(document, "//registry").each do |registry|
      title = registry.elements["title"]&.text.to_s
      name = title[/JSCalendar Enum Values for (\w+)/, 1]
      next unless name

      name = { "features" => "feature", "roles" => "role" }.fetch(name, name)
      registered = registry.get_elements("record/value").map { |value| value.text.strip }.sort
      raise "enum registry changed for #{name}; review metadata before updating the pin" unless registered == Jscalendar::ENUMS.fetch(name).sort
    end
    puts "IANA JSCalendar property and enum identifiers match the implementation."
  end
end

CalendarRegistry.prepare if $PROGRAM_NAME == __FILE__
