# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Collector
    class ReferenceCollectorSpec < Minitest::Test
      def test_collects_method_calls
        refs = collect(<<~RUBY)
          user.full_name
        RUBY

        assert_includes refs.map(&:name), "full_name"
        assert_equal :method, refs.find { |r| r.name == "full_name" }.kind
      end

      def test_collects_unqualified_method_calls
        refs = collect(<<~RUBY)
          do_something
        RUBY

        ref = refs.find { |r| r.name == "do_something" }
        assert ref
        refute ref.typed?
      end

      def test_collects_constant_references
        refs = collect(<<~RUBY)
          User.new
          Company::TYPES
        RUBY

        names = refs.select { |r| r.kind == :constant }.map(&:name)
        assert_includes names, "User"
      end

      def test_collects_send_dynamic_dispatch
        refs = collect(<<~RUBY)
          obj.send(:foo)
        RUBY

        assert_includes refs.map(&:name), "foo"
      end

      def test_collects_public_send_dynamic_dispatch
        refs = collect(<<~RUBY)
          obj.public_send(:bar)
        RUBY

        assert_includes refs.map(&:name), "bar"
      end

      def test_collects___send___dynamic_dispatch
        refs = collect(<<~RUBY)
          obj.__send__(:baz)
        RUBY

        assert_includes refs.map(&:name), "baz"
      end

      def test_collects_try_dynamic_dispatch
        refs = collect(<<~RUBY)
          obj.try(:maybe_method)
        RUBY

        assert_includes refs.map(&:name), "maybe_method"
      end

      def test_typed_reference_with_self
        refs = collect(<<~RUBY)
          class MyClass
            def call
              self.other_method
            end
          end
        RUBY

        ref = refs.find { |r| r.name == "other_method" }
        assert ref
        # Without type_resolver, self resolves via namespace stack
      end

      def test_typed_reference_with_type_resolver
        resolver = Resolver::TypeResolver.new
        resolver.register_method(
          owner: "User",
          method_name: "company",
          return_type: "Company",
        )

        refs = collect(<<~RUBY, type_resolver: resolver)
          class Service
            def call(user)
              user.company.display_name
            end
          end
        RUBY

        # company call should be present
        assert_includes refs.map(&:name), "company"
        assert_includes refs.map(&:name), "display_name"
      end

      private

      def collect(source, type_resolver: nil)
        result = Prism.parse(source)
        collector = ReferenceCollector.new("test.rb", type_resolver: type_resolver)
        collector.visit(result.value)
        collector.references
      end
    end
  end
end
