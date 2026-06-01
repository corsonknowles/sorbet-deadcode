# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead-code candidates referenced only from ERB templates.
    #
    # Mirrors RouteRefiner: runs after the primary Prism analysis and can be applied to a
    # cached --index. ERB receivers are untyped (`<%= widget.display_name %>` — the type of
    # `widget` is unknown in the template), so method matching is necessarily name-only:
    # any dead method whose name is referenced from a template is kept alive. Constants
    # named in templates keep the corresponding class/module alive.
    class ErbRefiner
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze

      def initialize(project_root, globs: Scanners::ErbScanner::DEFAULT_GLOBS)
        @project_root = File.expand_path(project_root)
        @globs = globs
      end

      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with ERB-referenced methods and constants removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        referenced = build_referenced_set
        return dead_candidates if referenced[:methods].empty? && referenced[:constants].empty?

        dead_candidates.reject { |d| erb_referenced?(d, referenced) }
      end

      private

      def build_referenced_set
        refs = Scanners::ErbScanner.new(@project_root, globs: @globs).references

        methods = Set.new
        constants = Set.new
        refs.each do |ref|
          methods << ref.name if ref.kind == :method
          constants << ref.name if ref.kind == :constant
        end
        { methods: methods, constants: constants }
      end

      def erb_referenced?(defn, referenced)
        return referenced[:methods].include?(defn.name) if METHOD_KINDS.include?(defn.kind)

        referenced[:constants].include?(defn.name) ||
          referenced[:constants].include?(defn.full_name)
      end
    end
  end
end
