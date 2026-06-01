# frozen_string_literal: true

module SorbetDeadcode
  class Definition
    KINDS = %i[method class module constant attr_reader attr_writer].freeze

    attr_reader :name, :full_name, :kind, :location, :owner_name, :co_located_names

    # co_located_names: names of other definitions whose source is nested inside
    # this definition (e.g. `PARENT = [CHILD = 1]`). Removing this definition would
    # also remove them, so it must not be reported dead while any of them is alive.
    def initialize(name:, full_name:, kind:, location:, owner_name: nil, co_located_names: [])
      raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)

      @name = name
      @full_name = full_name
      @kind = kind
      @location = location
      @owner_name = owner_name
      @co_located_names = co_located_names
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

    alias eql? ==

    def hash
      [name, full_name, kind].hash
    end
  end
end
