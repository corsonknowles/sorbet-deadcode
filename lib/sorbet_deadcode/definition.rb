# frozen_string_literal: true

module SorbetDeadcode
  class Definition
    KINDS = %i[method class module constant attr_reader attr_writer].freeze

    attr_reader :name, :full_name, :kind, :location, :owner_name

    def initialize(name:, full_name:, kind:, location:, owner_name: nil)
      raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)

      @name = name
      @full_name = full_name
      @kind = kind
      @location = location
      @owner_name = owner_name
    end

    def qualified_name
      return full_name unless owner_name

      separator = kind == :method ? "#" : "::"
      "#{owner_name}#{separator}#{name}"
    end

    def ==(other)
      other.is_a?(Definition) &&
        name == other.name &&
        full_name == other.full_name &&
        kind == other.kind
    end

    alias_method :eql?, :==

    def hash
      [name, full_name, kind].hash
    end
  end
end
