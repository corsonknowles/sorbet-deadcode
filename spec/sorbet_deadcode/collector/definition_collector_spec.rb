# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Collector
    class DefinitionCollectorSpec < Minitest::Test
      def test_collects_class_definitions
        defs = collect(<<~RUBY)
          class Foo
          end
        RUBY

        assert_includes defs.map(&:full_name), "Foo"
        assert_equal :class, defs.find { |d| d.name == "Foo" }.kind
      end

      def test_collects_nested_class_definitions
        defs = collect(<<~RUBY)
          module Outer
            class Inner
            end
          end
        RUBY

        assert_includes defs.map(&:full_name), "Outer::Inner"
      end

      def test_collects_method_definitions
        defs = collect(<<~RUBY)
          class MyClass
            def my_method
            end
          end
        RUBY

        method_def = defs.find { |d| d.name == "my_method" }
        assert method_def
        assert_equal :method, method_def.kind
        assert_equal "MyClass#my_method", method_def.full_name
        assert_equal "MyClass", method_def.owner_name
      end

      def test_collects_constant_definitions
        defs = collect(<<~RUBY)
          class Config
            MAX_RETRIES = 3
          end
        RUBY

        const_def = defs.find { |d| d.name == "MAX_RETRIES" }
        assert const_def
        assert_equal :constant, const_def.kind
        assert_equal "Config::MAX_RETRIES", const_def.full_name
      end

      def test_collects_attr_reader
        defs = collect(<<~RUBY)
          class Person
            attr_reader :name, :age
          end
        RUBY

        names = defs.select { |d| d.kind == :attr_reader }.map(&:name)
        assert_includes names, "name"
        assert_includes names, "age"
      end

      def test_collects_attr_writer
        defs = collect(<<~RUBY)
          class Person
            attr_writer :name
          end
        RUBY

        writer = defs.find { |d| d.kind == :attr_writer }
        assert writer
        assert_equal "name=", writer.name
      end

      def test_collects_attr_accessor_as_both
        defs = collect(<<~RUBY)
          class Person
            attr_accessor :email
          end
        RUBY

        reader = defs.find { |d| d.kind == :attr_reader && d.name == "email" }
        writer = defs.find { |d| d.kind == :attr_writer && d.name == "email=" }
        assert reader
        assert writer
      end

      def test_collects_module_definitions
        defs = collect(<<~RUBY)
          module Helpers
            def help
            end
          end
        RUBY

        mod = defs.find { |d| d.kind == :module }
        assert mod
        assert_equal "Helpers", mod.full_name
      end

      def test_top_level_method
        defs = collect(<<~RUBY)
          def standalone
          end
        RUBY

        method_def = defs.find { |d| d.name == "standalone" }
        assert method_def
        assert_equal "standalone", method_def.full_name
        assert_nil method_def.owner_name
      end

      def test_inline_constants_in_array_are_co_located
        defs = collect(<<~RUBY)
          class Config
            CATEGORIES = [
              CATEGORY_A = "a",
              CATEGORY_B = "b",
            ].freeze
          end
        RUBY

        parent = defs.find { |d| d.name == "CATEGORIES" }
        assert_equal %w[CATEGORY_A CATEGORY_B], parent.co_located_names
      end

      def test_inline_constants_in_hash_are_co_located
        defs = collect(<<~RUBY)
          class Config
            MAPPING = {
              first: FIRST_KEY = "f",
              second: SECOND_KEY = "s",
              **defaults,
            }.freeze
          end
        RUBY

        parent = defs.find { |d| d.name == "MAPPING" }
        assert_equal %w[FIRST_KEY SECOND_KEY], parent.co_located_names
      end

      def test_nested_constant_chain_is_collected
        defs = collect(<<~RUBY)
          class Config
            A = B = C = 1
          end
        RUBY

        parent = defs.find { |d| d.name == "A" }
        assert_equal %w[B C], parent.co_located_names
      end

      def test_plain_constant_has_no_co_located_names
        defs = collect(<<~RUBY)
          class Config
            SIMPLE = 42
          end
        RUBY

        assert_equal [], defs.find { |d| d.name == "SIMPLE" }.co_located_names
      end

      def test_constant_assigned_to_bare_call_has_no_co_located
        defs = collect(<<~RUBY)
          class Config
            VALUE = compute_default
          end
        RUBY

        assert_equal [], defs.find { |d| d.name == "VALUE" }.co_located_names
      end

      def test_attr_reader_without_arguments_is_ignored
        defs = collect(<<~RUBY)
          class Empty
            attr_reader
          end
        RUBY

        assert_empty(defs.select { |d| d.kind == :attr_reader })
      end

      def test_top_level_attr_reader_has_no_owner
        defs = collect(<<~RUBY)
          attr_reader :loose
        RUBY

        reader = defs.find { |d| d.kind == :attr_reader && d.name == "loose" }
        assert reader
        assert_equal "loose", reader.full_name
        assert_nil reader.owner_name
      end

      def test_attr_reader_with_non_symbol_argument_is_ignored
        defs = collect(<<~RUBY)
          class Person
            attr_reader "stringish", :real
          end
        RUBY

        names = defs.select { |d| d.kind == :attr_reader }.map(&:name)
        assert_equal ["real"], names
      end

      private

      def collect(source)
        result = Prism.parse(source)
        collector = DefinitionCollector.new("test.rb")
        collector.visit(result.value)
        collector.definitions
      end
    end
  end
end
