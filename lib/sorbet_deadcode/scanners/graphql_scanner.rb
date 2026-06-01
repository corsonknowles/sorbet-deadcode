# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Scans standalone GraphQL SDL schema documents (`*.graphql` / `*.graphqls`) for field
    # and argument names, mapping them to candidate Ruby resolver method names.
    #
    # A field declared only in an SDL document is backed by a Ruby resolver method
    # (graphql-ruby maps a camelCase field to a snake_case method) that has no Ruby call
    # site and would otherwise be reported dead.
    #
    # NOTE: the graphql-ruby DSL written *in Ruby* (`field`/`argument`/`builds`/`prepare:`/
    # `loads:`) is already handled by the ReferenceCollector. This scanner is *only* for
    # standalone `.graphql` SDL files (e.g. checked-in federation/subgraph schemas).
    #
    # Receivers are unknown in SDL, so references are name-only. Conservatively emits both
    # the literal field name and its snake_cased form so either resolver spelling stays
    # alive.
    class GraphqlScanner
      DEFAULT_GLOBS = ["**/*.graphql", "**/*.graphqls"].freeze
      DEFAULT_EXCLUDE_DIRS = %w[node_modules vendor tmp log coverage .git].freeze

      # A field whose name is immediately followed by an argument list: `field(arg: Int): T`.
      # The lookbehind avoids directive names (`@include(...)`) and variables (`$foo`).
      FIELD_WITH_ARGS = /(?<![@$\w])([A-Za-z_][A-Za-z0-9_]*)\s*\(/
      # A field / argument / input field whose name is followed by its type: `name: T`.
      NAME_WITH_TYPE = /(?<![@$\w])([A-Za-z_][A-Za-z0-9_]*)\s*:/

      # SDL block descriptions, inline strings, and comments — stripped before scanning so
      # their contents aren't mistaken for declarations.
      BLOCK_STRING = /"""[\s\S]*?"""/
      INLINE_STRING = /"(?:\\.|[^"\\])*"/
      LINE_COMMENT = /#[^\n]*/

      def initialize(project_root, globs: DEFAULT_GLOBS, exclude_dirs: DEFAULT_EXCLUDE_DIRS)
        @project_root = File.expand_path(project_root)
        @globs = globs
        @exclude_dirs = exclude_dirs
      end

      # @return [Array<Reference>]
      def references
        graphql_files.flat_map { |path| scan_file(path) }
      end

      private

      def graphql_files
        FileFinder.find(@project_root, @globs, exclude_dirs: @exclude_dirs)
      end

      def scan_file(path)
        text = strip_noise(File.read(path))
        names = text.scan(FIELD_WITH_ARGS).flatten + text.scan(NAME_WITH_TYPE).flatten
        names.uniq.flat_map { |name| emit(name, path) }
      rescue StandardError
        []
      end

      def strip_noise(text)
        text.gsub(BLOCK_STRING, " ").gsub(INLINE_STRING, " ").gsub(LINE_COMMENT, "")
      end

      def emit(graphql_name, path)
        [graphql_name, underscore(graphql_name)].uniq.map do |name|
          Reference.new(name: name, location: path, kind: :method)
        end
      end

      # camelCase / PascalCase → snake_case (fullName → full_name, parseHTMLBody → parse_html_body).
      def underscore(name)
        name.gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .downcase
      end
    end
  end
end
