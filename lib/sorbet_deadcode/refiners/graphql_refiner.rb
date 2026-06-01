# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead-code candidates (resolver methods) referenced only
    # from standalone GraphQL SDL (`*.graphql`) documents.
    #
    # SDL fields/arguments name resolver methods that have no Ruby call site; graphql-ruby
    # maps a camelCase field to a snake_case method. Receivers are unknown in SDL, so
    # matching is name-only — but each document's field names are scoped to the directory
    # subtree that contains it (its subgraph root). A method is kept alive only when a
    # same-named field is declared by an SDL document living at or above the method's
    # definition. This prevents a generic field name (`id`, `name`, `status`, `nodes`) in
    # one subgraph from masking a same-named method in an unrelated directory.
    class GraphqlRefiner
      include Reportable
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze
      REASON = :graphql_sdl

      def initialize(project_root, globs: Scanners::GraphqlScanner::DEFAULT_GLOBS, mode: :exclude)
        @project_root = File.expand_path(project_root)
        @globs = globs
        @mode = mode
      end

      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with SDL-referenced resolver methods removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        scoped = scoped_names_by_dir
        return dead_candidates if scoped.empty?

        resolve(dead_candidates) { |defn| sdl_referenced?(defn, scoped) }
      end

      private

      # @return [Array<Array(String, Set<String>)>] [schema directory, field names] pairs.
      def scoped_names_by_dir
        refs = Scanners::GraphqlScanner.new(@project_root, globs: @globs).references
        by_dir = Hash.new { |h, k| h[k] = Set.new }
        refs.each do |ref|
          by_dir[File.dirname(ref.location)] << ref.name if ref.kind == :method
        end
        by_dir.to_a
      end

      def sdl_referenced?(defn, scoped)
        return false unless METHOD_KINDS.include?(defn.kind)

        def_path = File.expand_path(defn.location.to_s.split(":").first.to_s)
        scoped.any? { |dir, names| names.include?(defn.name) && within?(def_path, dir) }
      end

      # True if path is dir itself or lives under it.
      def within?(path, dir)
        path == dir || path.start_with?("#{dir}/")
      end
    end
  end
end
