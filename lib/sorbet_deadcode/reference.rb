# frozen_string_literal: true

module SorbetDeadcode
  class Reference
    # method_prefix: dynamic dispatch on an interpolated name with a known literal
    #   prefix, e.g. public_send("dump_#{x}") => prefix "dump_".
    # method_suffix: dynamic dispatch on an interpolated name with a known literal
    #   suffix, e.g. public_send("#{x}_start_time") => suffix "_start_time".
    # dynamic_namespace: dynamic dispatch on a non-literal target (variable/call) inside
    #   a namespace, e.g. __send__(method_name) inside MemberSerializer => the whole
    #   namespace's methods may be reached.
    KINDS = %i[method constant method_prefix method_suffix dynamic_namespace].freeze

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

    alias eql? ==

    def hash
      [name, kind, receiver_type].hash
    end
  end
end
