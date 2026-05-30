# frozen_string_literal: true

module SorbetDeadcode
  class Reference
    KINDS = %i[method constant].freeze

    attr_reader :name, :location, :kind, :receiver_type

    # receiver_type is the resolved type of the receiver, if known.
    # When nil, this is an unqualified reference (matches any owner).
    # When set, only definitions on that type are considered alive.
    def initialize(name:, location:, kind:, receiver_type: nil)
      raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)

      @name = name
      @location = location
      @kind = kind
      @receiver_type = receiver_type
    end

    def typed?
      !receiver_type.nil?
    end

    def ==(other)
      other.is_a?(Reference) &&
        name == other.name &&
        kind == other.kind &&
        receiver_type == other.receiver_type
    end

    alias_method :eql?, :==

    def hash
      [name, kind, receiver_type].hash
    end
  end
end
