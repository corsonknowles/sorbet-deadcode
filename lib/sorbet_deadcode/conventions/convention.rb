# frozen_string_literal: true

module SorbetDeadcode
  module Conventions
    # A base-class-scoped framework convention: "for classes matching X, keep methods/prefixes Y
    # alive (they're invoked by the framework by name, with no explicit Ruby call site)".
    #
    # Matching is deliberately SCOPED so generic names (`on_send`, `perform`, `resolve`) are only
    # kept alive inside the framework classes that use them — a same-named method on an unrelated
    # class is still subject to dead-code analysis. A class matches if ANY signal matches:
    #   * superclass  — Regexp tested against the (sliced) superclass name (`< RuboCop::Cop::Base`)
    #   * includes    — module name(s); matches if the class `include`s any (`include Sidekiq::Job`)
    #   * name_suffix — class short-name suffix (`FooTest`), optionally gated by path_includes
    #
    # The kept-alive set is one or more of:
    #   * keep_methods    — exact method names, kept OWNER-SCOPED to the matching class
    #   * keep_prefixes   — method-name prefixes kept alive (e.g. `on_`, `visit_`, `test_`)
    #   * keep_constants  — constant names read by the framework (e.g. a cop's `MSG`), kept
    #                       OWNER-SCOPED to the matching class
    #   * keep_namespace  — keep the whole class alive (every method), for reflection-driven classes
    #
    # Convention is a pure value object (no Prism/IO), so it is unit-tested in isolation; the
    # ReferenceCollector extracts the signals from the AST and turns matches into References.
    class Convention
      attr_reader :name, :keep_methods, :keep_prefixes, :keep_constants

      def initialize(name:, superclass: nil, includes: nil, name_suffix: nil, path_includes: nil,
                     keep_methods: [], keep_prefixes: [], keep_constants: [], keep_namespace: false)
        @name = name
        @superclass = superclass.is_a?(String) ? Regexp.new(superclass) : superclass
        @includes = includes && Array(includes)
        @name_suffix = name_suffix
        @path_includes = path_includes
        @keep_methods = Array(keep_methods).map(&:to_s)
        @keep_prefixes = Array(keep_prefixes).map(&:to_s)
        @keep_constants = Array(keep_constants).map(&:to_s)
        @keep_namespace = keep_namespace
      end

      def keep_namespace?
        @keep_namespace
      end

      # @param superclass [String, nil] the sliced superclass name (`Foo::Bar` for `< Foo::Bar`)
      # @param class_name [String] the class short (demodulized) name
      # @param file_path [String] the file the class is defined in
      # @param includes [Array<String>] module names the class `include`s at the top level
      def matches?(superclass:, class_name:, file_path:, includes:)
        matches_superclass?(superclass) ||
          matches_includes?(includes) ||
          matches_name?(class_name, file_path)
      end

      private

      def matches_superclass?(superclass)
        !@superclass.nil? && !superclass.nil? && superclass.match?(@superclass)
      end

      def matches_includes?(includes)
        !@includes.nil? && includes.any? { |mod| @includes.include?(mod) }
      end

      def matches_name?(class_name, file_path)
        return false if @name_suffix.nil?
        return false unless class_name.end_with?(@name_suffix)

        @path_includes.nil? || file_path.include?(@path_includes)
      end
    end
  end
end
