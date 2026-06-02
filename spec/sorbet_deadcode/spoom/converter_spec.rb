# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Spoom
    class ConverterSpec < Minitest::Test
      def test_index_from_rows_builds_definitions
        # spoom joins method owners with `::` (e.g. "Reports::Monthly::total"); the converter
        # rewrites that to our `#` form so the intersection matches.
        index = Converter.index_from_rows(
          [
            { full_name: "Reports::Monthly", kind: "class", file: "app/reports/monthly.rb", line: 3 },
            { full_name: "Reports::Monthly::total", kind: "method", file: "app/reports/monthly.rb", line: 8 },
            { full_name: "Reports::FORMAT", kind: "constant", file: "app/reports/monthly.rb", line: 2 },
          ],
          paths: ["app/reports"],
        )

        by_full = index.dead_definitions.to_h { |d| [d.full_name, d] }
        assert_equal :class, by_full["Reports::Monthly"].kind
        assert_equal "Monthly", by_full["Reports::Monthly"].name
        # method full_name normalized from "Reports::Monthly::total" to "Reports::Monthly#total"
        assert_equal :method, by_full["Reports::Monthly#total"].kind
        assert_equal "total", by_full["Reports::Monthly#total"].name
        assert_equal "app/reports/monthly.rb:8", by_full["Reports::Monthly#total"].location
        assert_equal ["app/reports"], index.paths
      end

      def test_method_full_name_normalized_to_match_our_format
        index = Converter.index_from_rows(
          [
            { full_name: "A::B::run", kind: "method", file: "a.rb", line: 1 },
            { full_name: "top_level_method", kind: "method", file: "b.rb", line: 1 },
          ],
          paths: ["."],
        )
        names = index.dead_definitions.map(&:full_name)
        assert_includes names, "A::B#run"        # last `::` -> `#`
        assert_includes names, "top_level_method" # no owner: unchanged
      end

      def test_demodulize_handles_namespaces_methods_and_class_methods
        assert_equal "C", Converter.demodulize("A::B::C")
        assert_equal "bar", Converter.demodulize("Foo#bar")
        assert_equal "baz", Converter.demodulize("Foo.baz")
        assert_equal "top", Converter.demodulize("top")
      end

      def test_normalize_kind_maps_known_and_falls_back
        assert_equal :attr_reader, Converter.normalize_kind("attr_reader")
        assert_equal :module, Converter.normalize_kind("module")
        assert_equal :method, Converter.normalize_kind("something_else")
      end

      def test_intersect_with_our_index_is_owner_precise
        spoom = Converter.index_from_rows(
          [
            { full_name: "A::shared", kind: "method", file: "a.rb", line: 1 },
            { full_name: "B::only_spoom", kind: "method", file: "b.rb", line: 1 },
          ],
          paths: ["."],
        )
        ours = Index.new(
          dead_definitions: [
            Definition.new(name: "shared", full_name: "A#shared", kind: :method, location: "a.rb:1"),
            Definition.new(name: "only_ours", full_name: "C#only_ours", kind: :method, location: "c.rb:1"),
          ],
          paths: ["."],
        )

        shared = ours.intersect(spoom).dead_definitions.map(&:full_name)
        assert_equal ["A#shared"], shared
      end
    end
  end
end
