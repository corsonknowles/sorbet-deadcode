# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Spoom
    class NodeLocatorSpec < Minitest::Test
      SOURCE = <<~RUBY
        module Outer
          class Foo < Base
            def baz
              1
            end
          end
        end

        ANSWER = 42
        A = B = 1
      RUBY

      def test_locates_method_by_name_and_line
        loc = NodeLocator.locate(SOURCE, kind: :method, name: "baz", line: 3)

        assert_equal 3, loc.start_line
        assert_equal 4, loc.start_column
        assert_equal 5, loc.end_line
        assert_equal 7, loc.end_column
      end

      def test_locates_class_by_short_name
        loc = NodeLocator.locate(SOURCE, kind: :class, name: "Foo", line: 2)

        assert_equal 2, loc.start_line
        assert_equal 6, loc.end_line
      end

      def test_locates_module
        loc = NodeLocator.locate(SOURCE, kind: :module, name: "Outer", line: 1)

        assert_equal 1, loc.start_line
        assert_equal 7, loc.end_line
      end

      def test_locates_constant
        loc = NodeLocator.locate(SOURCE, kind: :constant, name: "ANSWER", line: 9)

        assert_equal 9, loc.start_line
        assert_equal 0, loc.start_column
      end

      def test_name_disambiguates_constants_sharing_a_line
        a = NodeLocator.locate(SOURCE, kind: :constant, name: "A", line: 10)
        b = NodeLocator.locate(SOURCE, kind: :constant, name: "B", line: 10)

        assert_equal 0, a.start_column
        assert_equal 4, b.start_column
      end

      def test_kind_mismatch_returns_nil
        assert_nil NodeLocator.locate(SOURCE, kind: :method, name: "Foo", line: 2)
      end

      def test_unknown_kind_returns_nil
        assert_nil NodeLocator.locate(SOURCE, kind: :attr_reader, name: "baz", line: 3)
      end

      def test_missing_node_returns_nil
        assert_nil NodeLocator.locate(SOURCE, kind: :method, name: "nope", line: 99)
      end

      def test_nil_name_matches_on_kind_and_line_only
        loc = NodeLocator.locate(SOURCE, kind: :method, name: nil, line: 3)

        assert_equal 3, loc.start_line
      end
    end
  end
end
