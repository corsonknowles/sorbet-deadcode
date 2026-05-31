# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Scans RABL view templates (`*.rabl`) for Ruby method and constant references.
    #
    # RABL exposes model methods as JSON via a Ruby DSL with no direct call site, e.g.
    #
    #   object @widget
    #   attributes :id, :display_name
    #   child(:parts) { attributes :sku }
    #   node(:status) { |w| w.current_status }
    #
    # Methods used only from `.rabl` are otherwise wrongly reported dead. A `.rabl` file is
    # itself Ruby, so we parse it once and run two passes over the AST:
    #
    #   A. the existing Prism ReferenceCollector — captures real method calls and constants
    #      (e.g. `w.current_status` inside a node/child block);
    #   B. a small DSL visitor — harvests the symbol arguments of `attributes`/`attribute`
    #      (model attributes) and `child`/`glue` (association source names), which pass 'A'
    #      does not see because they are symbols, not calls.
    #
    # `node(:key)` first arguments are output keys, not model methods, so they are not
    # harvested; the methods invoked inside the node block are captured by pass A.
    class RablScanner
      DEFAULT_GLOBS = ["**/*.rabl"].freeze
      DEFAULT_EXCLUDE_DIRS = %w[node_modules vendor tmp log coverage .git].freeze

      def initialize(project_root, globs: DEFAULT_GLOBS, exclude_dirs: DEFAULT_EXCLUDE_DIRS)
        @project_root = File.expand_path(project_root)
        @globs = globs
        @exclude_dirs = exclude_dirs
      end

      # @return [Array<Reference>]
      def references
        rabl_files.flat_map { |path| scan_file(path) }
      end

      private

      def rabl_files
        FileFinder.find(@project_root, @globs, exclude_dirs: @exclude_dirs)
      end

      def scan_file(path)
        result = Prism.parse(File.read(path))
        root = result.value

        calls = Collector::ReferenceCollector.new(path, type_resolver: nil)
        calls.visit(root)

        dsl = RablDslCollector.new(path)
        dsl.visit(root)

        calls.references + dsl.references
      rescue StandardError
        []
      end
    end

    # Prism visitor that harvests the symbol arguments of RABL attribute/association DSL
    # calls as name-only method references.
    class RablDslCollector < Prism::Visitor
      ATTRIBUTE_METHODS = %w[attributes attribute].freeze
      ASSOCIATION_METHODS = %w[child glue].freeze
      # Hash keys that are RABL options rather than model methods.
      OPTION_KEYS = %w[root if unless partial].freeze

      attr_reader :references

      def initialize(file_path)
        super()
        @file_path = file_path
        @references = []
      end

      def visit_call_node(node)
        name = node.name.to_s
        if ATTRIBUTE_METHODS.include?(name)
          symbol_args(node).each { |method_name| emit(method_name, node) }
        elsif ASSOCIATION_METHODS.include?(name)
          association_methods(node).each { |method_name| emit(method_name, node) }
        end

        super
      end

      private

      def emit(method_name, node)
        @references << Reference.new(
          name: method_name,
          location: "#{@file_path}:#{node.location.start_line}",
          kind: :method,
        )
      end

      # Every symbol argument is a model attribute, e.g. `attributes :id, :name`.
      def symbol_args(node)
        arguments(node).select { |arg| arg.is_a?(Prism::SymbolNode) }.map(&:unescaped)
      end

      # For `child`/`glue`: a leading symbol is the association method, and `key: :alias`
      # hash entries name the association via the key (excluding option keys).
      def association_methods(node)
        arguments(node).flat_map do |arg|
          case arg
          when Prism::SymbolNode
            [arg.unescaped]
          when Prism::KeywordHashNode, Prism::HashNode
            hash_key_methods(arg)
          else
            []
          end
        end
      end

      def hash_key_methods(hash_node)
        hash_node.elements.filter_map do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key = assoc.key
          next unless key.is_a?(Prism::SymbolNode)

          name = key.unescaped
          name unless OPTION_KEYS.include?(name)
        end
      end

      def arguments(node)
        node.arguments ? node.arguments.arguments : []
      end
    end
  end
end
