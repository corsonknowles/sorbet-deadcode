# frozen_string_literal: true

module SorbetDeadcode
  class Definition
    KINDS = %i[method class module constant attr_reader attr_writer].freeze

    attr_reader :name, :full_name, :kind, :location, :owner_name, :co_located_names, :superclass_name,
                :file, :line, :end_line, :inline_member

    # Optional metadata (not part of identity): set by a refiner in :report mode to record
    # that this candidate was kept alive only by a non-Ruby reference of the given source
    # (e.g. :graphql_sdl, :erb, :route). Surfaced by the Classifier as a low-confidence flag.
    attr_accessor :kept_by

    # Optional metadata (not part of identity): set by the analyzer when this dead accessor half
    # (:attr_reader/:attr_writer) has a LIVE sibling half on the same owner — i.e. an
    # `attr_accessor` where only one direction is dead. Surfaced by the Classifier as a
    # `partial_accessor` flag so the fix is "narrow the accessor", not "delete the line".
    attr_accessor :partial_accessor

    # Optional metadata (not part of identity): set by the analyzer's `--cascade` pass when this
    # definition became dead only AFTER other dead code was (transitively) removed. Surfaced by the
    # Classifier as a `cascaded` flag.
    attr_accessor :cascaded

    # co_located_names: names of other definitions whose source is nested inside
    # this definition (e.g. `PARENT = [CHILD = 1]`). Removing this definition would
    # also remove them, so it must not be reported dead while any of them is alive.
    # superclass_name: for a class definition, the (short) name of its direct superclass as
    # written (e.g. `class Foo < Base` => "Base"). Used to keep subclasses of a base that is
    # reflected over via `.descendants` / `.subclasses` alive.
    # inline_member: true when this constant is assigned inline inside another constant's
    # collection literal (`PARENT = [CHILD = 1]`). Such a constant can't be removed on its own
    # without also editing the enclosing literal, so it's surfaced for review, never safe_delete.
    def initialize(name:, full_name:, kind:, location:, owner_name: nil, co_located_names: [],
                   superclass_name: nil, inline_member: false, end_line: nil)
      raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)

      @name = name
      @full_name = full_name
      @kind = kind
      @location = location
      # Split into file + line once, here, instead of `location.split(":")` scattered across
      # consumers. rpartition splits on the LAST colon, so Windows drive-letter paths
      # (`C:/x.rb:12`) and any path containing a colon parse correctly.
      file, sep, line = location.to_s.rpartition(":")
      @file = sep.empty? ? location : file
      @line = sep.empty? || line.empty? ? nil : line.to_i
      @end_line = end_line
      @owner_name = owner_name
      @co_located_names = co_located_names
      @superclass_name = superclass_name
      @inline_member = inline_member
      @kept_by = nil
      @partial_accessor = nil
      @cascaded = nil
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
