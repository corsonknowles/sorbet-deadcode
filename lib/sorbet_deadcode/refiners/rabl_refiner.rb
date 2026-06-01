# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead-code candidates referenced only from RABL templates.
    #
    # Mirrors RouteRefiner/ErbRefiner: runs after the primary Prism analysis and can be
    # applied to a cached --index. RABL receivers (the serialized model) are untyped, so
    # method matching is name-only: any dead method whose name is exposed by a template is
    # kept alive. Constants named in templates keep the corresponding class/module alive.
    class RablRefiner
      include Reportable
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze
      REASON = :rabl

      def initialize(project_root, globs: Scanners::RablScanner::DEFAULT_GLOBS, mode: :exclude)
        @project_root = File.expand_path(project_root)
        @globs = globs
        @mode = mode
      end

      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with RABL-referenced methods and constants removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        referenced = build_referenced_set
        return dead_candidates if referenced[:methods].empty? && referenced[:constants].empty?

        resolve(dead_candidates) { |d| rabl_referenced?(d, referenced) }
      end

      private

      def build_referenced_set
        refs = Scanners::RablScanner.new(@project_root, globs: @globs).references

        methods = Set.new
        constants = Set.new
        refs.each do |ref|
          methods << ref.name if ref.kind == :method
          constants << ref.name if ref.kind == :constant
        end
        { methods: methods, constants: constants }
      end

      def rabl_referenced?(defn, referenced)
        return referenced[:methods].include?(defn.name) if METHOD_KINDS.include?(defn.kind)

        referenced[:constants].include?(defn.name) ||
          referenced[:constants].include?(defn.full_name)
      end
    end
  end
end
