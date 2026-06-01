# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead-code candidates referenced only from framework
    # YAML configs (e.g. `method: Sanitizers::WidgetSanitizer.sanitize_widget`).
    #
    # Mirrors RouteRefiner: runs after the primary Prism analysis and can be applied to a
    # cached --index. From the harvested YAML references it keeps alive:
    #   - methods whose [owner, name] matches a qualified `Class.method` reference,
    #   - methods whose name matches a configured bare-key reference (no receiver), and
    #   - the classes/constants named in the values.
    #
    # Qualified matching is owner-precise so that an unrelated `method: OtherLib::Geo.city`
    # value cannot keep a genuinely dead `City#city` alive. (The analyzer reports the owner
    # of a `class << self` method as its fully-qualified constant, which matches the receiver
    # written in the YAML.)
    class YamlRefiner
      include Reportable
      METHOD_KINDS = %i[method attr_reader attr_writer].freeze
      REASON = :yaml

      def initialize(project_root, keys: Scanners::YamlScanner::DEFAULT_KEYS,
                     bare_keys: Scanners::YamlScanner::DEFAULT_BARE_KEYS,
                     globs: Scanners::YamlScanner::DEFAULT_GLOBS, mode: :exclude)
        @project_root = File.expand_path(project_root)
        @keys = keys
        @bare_keys = bare_keys
        @globs = globs
        @mode = mode
      end

      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with YAML-referenced methods and classes removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        referenced = build_referenced_set
        if referenced[:typed_methods].empty? && referenced[:bare_methods].empty? && referenced[:classes].empty?
          return dead_candidates
        end

        resolve(dead_candidates) { |d| yaml_referenced?(d, referenced) }
      end

      private

      def build_referenced_set
        refs = Scanners::YamlScanner.new(
          @project_root, keys: @keys, bare_keys: @bare_keys, globs: @globs
        ).references

        typed_methods = Set.new # [owner, name] from qualified Class.method values
        bare_methods = Set.new  # name only, from configured bare keys
        classes = Set.new
        refs.each do |ref|
          if ref.kind == :method
            ref.receiver_type ? typed_methods << [ref.receiver_type, ref.name] : bare_methods << ref.name
          end
          classes << ref.name if ref.kind == :constant
        end
        { typed_methods: typed_methods, bare_methods: bare_methods, classes: classes }
      end

      def yaml_referenced?(defn, referenced)
        if METHOD_KINDS.include?(defn.kind)
          return referenced[:typed_methods].include?([defn.owner_name, defn.name]) ||
              referenced[:bare_methods].include?(defn.name)
        end

        referenced[:classes].include?(defn.name) ||
          referenced[:classes].include?(defn.full_name)
      end
    end
  end
end
