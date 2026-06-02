# frozen_string_literal: true

module SorbetDeadcode
  module Spoom
    # Pure conversion of spoom dead-code candidates (as plain rows) into a SorbetDeadcode::Index,
    # so the two tools' dead sets can be intersected (`--spoom`). Deliberately decoupled from
    # spoom's runtime API (which lives in Spoom::Runner) so the mapping is unit-testable without
    # installing/booting spoom.
    #
    # spoom reports a definition's `kind` using the same vocabulary as
    # Definition::KINDS (class/module/method/constant/attr_reader/attr_writer) and a `full_name`
    # in the same `Owner#method` / `A::B::C` shape, so the intersection stays owner-precise.
    module Converter
      module_function

      # Kinds whose owner is joined with `#` in our Definition#full_name (spoom uses `::`).
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze

      # @param rows [Array<Hash>] each with :full_name, :kind (String), :file, :line
      # @param paths [Array<String>] the analyzed paths (recorded on the Index)
      # @return [SorbetDeadcode::Index]
      def index_from_rows(rows, paths:)
        definitions = rows.map do |row|
          kind = normalize_kind(row[:kind])
          full_name = normalize_full_name(row.fetch(:full_name), kind)
          Definition.new(
            name: demodulize(full_name),
            full_name: full_name,
            kind: kind,
            location: "#{row[:file]}:#{row[:line]}",
          )
        end
        Index.new(dead_definitions: definitions, paths: Array(paths))
      end

      # spoom joins a method's owner with `::` (`Foo::bar`), but our Definition#full_name uses `#`
      # (`Foo#bar`) for methods/attrs — so the `[full_name, kind]` intersection matches. Rewrite
      # the last `::` to `#` for method-like kinds; other kinds (class/module/constant) already
      # share the `A::B::C` shape.
      def normalize_full_name(full_name, kind)
        return full_name unless METHOD_KINDS.include?(kind)

        idx = full_name.rindex("::")
        idx ? "#{full_name[0...idx]}##{full_name[(idx + 2)..]}" : full_name
      end

      # Demodulized leaf of a spoom full_name:
      #   "A::B::C" => "C", "Foo#bar" => "bar", "Foo.baz" => "baz".
      def demodulize(full_name)
        full_name.split(/::|#|\./).reject(&:empty?).last || full_name
      end

      # spoom's Kind.serialize strings line up with Definition::KINDS; anything unexpected falls
      # back to :method (conservative — keeps the row in the intersection rather than dropping it).
      def normalize_kind(kind)
        sym = kind.to_s.to_sym
        Definition::KINDS.include?(sym) ? sym : :method
      end
    end
  end
end
