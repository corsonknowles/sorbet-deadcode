# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead-code candidates (resolver methods) referenced only
    # from standalone GraphQL SDL (`*.graphql`) documents.
    #
    # Mirrors ErbRefiner. SDL fields/arguments name resolver methods that have no Ruby call
    # site; graphql-ruby maps a camelCase field to a snake_case method. Receivers are
    # unknown in SDL, so matching is name-only: any dead method whose name matches a scanned
    # field (literal or snake_cased) is kept alive.
    class GraphqlRefiner
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze

      def initialize(project_root, globs: Scanners::GraphqlScanner::DEFAULT_GLOBS)
        @project_root = File.expand_path(project_root)
        @globs = globs
      end

      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with SDL-referenced resolver methods removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        methods = scanned_method_names
        return dead_candidates if methods.empty?

        dead_candidates.reject { |defn| METHOD_KINDS.include?(defn.kind) && methods.include?(defn.name) }
      end

      private

      def scanned_method_names
        refs = Scanners::GraphqlScanner.new(@project_root, globs: @globs).references
        refs.each_with_object(Set.new) do |ref, set|
          set << ref.name if ref.kind == :method
        end
      end
    end
  end
end
