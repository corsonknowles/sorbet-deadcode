# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Second-pass refiner: removes dead code candidates that are controller
    # actions referenced from Rails route files.
    #
    # This runs AFTER the primary Prism analysis. The primary analysis
    # produces a list of dead candidates; this refiner filters out any
    # that are reachable via routes. This architecture means:
    #
    # - The expensive Prism pass can be cached (--index) and re-used.
    # - Route scanning is fast and can be re-run against a cached index.
    # - Other non-Ruby scanners (YAML, ERB, GraphQL) follow the same pattern.
    class RouteRefiner
      include Reportable
      REASON = :route

      def initialize(project_root, mode: :exclude)
        @project_root = File.expand_path(project_root)
        @mode = mode
      end

      # Filter dead_candidates, removing any that are reachable from routes.
      #
      # @param dead_candidates [Array<Definition>]
      # @return [Array<Definition>] with routed items removed
      def refine(dead_candidates)
        return dead_candidates if dead_candidates.empty?

        routed = build_routed_set
        return dead_candidates if routed.empty?

        resolve(dead_candidates) { |d| routed_alive?(d, routed) }
      end

      private

      # Build a set of {[owner_class, method_name]} pairs from route references,
      # plus a set of controller class names (to keep the class itself alive too).
      def build_routed_set
        scanner = Scanners::RouteScanner.new(@project_root)
        refs = scanner.references

        routed_methods = Set.new
        routed_classes = Set.new

        refs.each do |ref|
          case ref.kind
          when :method
            routed_methods << [ref.receiver_type, ref.name] if ref.receiver_type
          when :constant
            routed_classes << ref.name
          end
        end

        { methods: routed_methods, classes: routed_classes }
      end

      def routed_alive?(defn, routed)
        case defn.kind
        when :method, :attr_reader, :attr_writer
          routed[:methods].include?([defn.owner_name, defn.name])
        when :class, :module
          routed[:classes].include?(defn.name) ||
            routed[:classes].include?(defn.full_name)
        else
          false
        end
      end
    end
  end
end
