# frozen_string_literal: true

module Jscalendar
  # A typed view over a JSON object; nested views write into their owning model.
  class Model
    attr_reader :limits

    def initialize(data = nil, strict: false, time_zones: {}, **limits)
      @limits = DEFAULT_LIMITS.merge(limits).freeze
      validator = Validator.new(**limits)
      @time_zones = Jscalendar.deep_copy(time_zones)
      data ||= { "@type" => type_name }
      raise ValidationError, "expected a JSON object" unless data.is_a?(Hash)

      @data = Jscalendar.deep_copy(data, max_depth: @limits[:max_depth])
      violations = validator.validate(@data, type: type_name, time_zones: @time_zones)
      raise ValidationError, violations if strict && !violations.empty?
    end

    def self.wrap(data, limits, time_zones = {})
      value = allocate
      value.instance_variable_set(:@data, data)
      value.instance_variable_set(:@limits, limits)
      value.instance_variable_set(:@time_zones, time_zones)
      value
    end

    def [](name)
      name = name.to_s
      rule = SCHEMA.fetch(type_name).fetch("properties")[name]
      return @data[name] unless rule
      return wrap_value(Jscalendar.deep_copy(rule["default"]), rule.fetch("type")) if !@data.key?(name) && rule.key?("default")

      wrap_value(@data[name], rule.fetch("type"))
    end

    def []=(name, value)
      @data[name.to_s] = Jscalendar.deep_copy(value, max_depth: @limits[:max_depth])
    end

    def key?(name)
      @data.key?(name.to_s)
    end

    def delete(name)
      @data.delete(name.to_s)
    end

    def to_h
      Jscalendar.deep_copy(@data, max_depth: @limits[:max_depth])
    end

    def to_json(options = nil)
      validate!
      data = to_h
      data["@type"] ||= type_name
      Jscalendar.generate_json(data, options || { max_nesting: @limits[:max_depth] })
    end

    def errors
      Validator.new(**@limits).validate(@data, type: type_name, time_zones: @time_zones)
    end
    alias warnings errors

    def valid?
      errors.empty?
    end

    def validate!
      violations = errors
      raise ValidationError, violations unless violations.empty?

      self
    end

    def ==(other)
      other.is_a?(Model) && to_h == other.to_h
    end

    protected

    def type_name
      self.class.name.split("::").last
    end

    private

    def wrap_value(value, signature)
      return Jscalendar.const_get(signature).new(value) if value && %w[LocalDateTime Duration SignedDuration].include?(signature)
      return value unless value.is_a?(Hash) || value.is_a?(Array)

      zones = @time_zones.merge(@data["timeZones"].is_a?(Hash) ? @data["timeZones"] : {})
      if %w[Entry Trigger].include?(signature) && value.is_a?(Hash)
        type = value["@type"]
        return SCHEMA.key?(type) ? Jscalendar.const_get(type).wrap(value, @limits, zones) : value
      end

      if SCHEMA.key?(signature) && value.is_a?(Hash)
        Jscalendar.const_get(signature).wrap(value, @limits, zones)
      elsif (match = /\A(?:Id|String)\[(\w+)\]\z/.match(signature)) && SCHEMA.key?(match[1]) && value.is_a?(Hash)
        IdMap.new(value, type: match[1], limits: @limits,
                         validate_ids: signature.start_with?("Id["), time_zones: zones)
      elsif signature.end_with?("[]") && value.is_a?(Array)
        value.map { |item| wrap_value(item, signature.delete_suffix("[]")) }
      elsif signature.include?("|") && value.is_a?(Hash)
        type = value.fetch("@type", signature.split("|").first)
        SCHEMA.key?(type) ? Jscalendar.const_get(type).wrap(value, @limits, zones) : value
      else
        value
      end
    end
  end

  # A map preserving source identifiers and exposing typed member values.
  class IdMap
    include Enumerable

    def initialize(data = {}, type:, limits: DEFAULT_LIMITS, validate_ids: true, time_zones: {})
      @data = data
      @type = type
      @limits = limits
      @validate_ids = validate_ids
      @time_zones = time_zones
    end

    def [](id)
      value = @data[id.to_s]
      value.is_a?(Hash) ? Jscalendar.const_get(@type).wrap(value, @limits, @time_zones) : value
    end

    def []=(id, value)
      id = id.to_s
      raise ValidationError.new("invalid map Id", pointer: Jscalendar.pointer("", id)) if @validate_ids && !Types.id?(id)
      raise LimitError, "map exceeds max_map_size" if !@data.key?(id) && @data.size >= @limits[:max_map_size]

      @data[id] = Jscalendar.deep_copy(value, max_depth: @limits[:max_depth])
    end

    def each
      return enum_for(:each) unless block_given?

      @data.each_key { |id| yield id, self[id] }
      self
    end

    def keys
      @data.keys
    end

    def values
      map { |_id, value| value }
    end

    def size
      @data.size
    end
    alias length size

    def empty?
      @data.empty?
    end

    def key?(id)
      @data.key?(id.to_s)
    end

    def delete(id)
      value = self[id]
      @data.delete(id.to_s)
      value
    end

    def add(value, prefix: "id")
      counter = 1
      counter += 1 while @data.key?("#{prefix}#{counter}")
      id = "#{prefix}#{counter}"
      self[id] = value
      id
    end

    def to_h
      Jscalendar.deep_copy(@data, max_depth: @limits[:max_depth])
    end
  end

  SCHEMA.each do |name, definition|
    model = const_set(name, Class.new(Model))
    definition.fetch("properties").each_key do |property|
      next if property == "@type"

      model.define_method(property) { self[property] }
      model.define_method("#{property}=") { |value| self[property] = value }
      snake = property.gsub(/([A-Z])/, '_\\1').downcase
      next if snake == property

      model.alias_method(snake, property)
      model.alias_method("#{snake}=", "#{property}=")
    end
  end
end
