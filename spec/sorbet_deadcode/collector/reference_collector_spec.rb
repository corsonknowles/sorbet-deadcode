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

      def test_constant_path_emits_prefix_components
        refs = collect(<<~RUBY)
          Outer::Middle::Inner.new
        RUBY

        constant_names = refs.select { |r| r.kind == :constant }.map(&:name)
        assert_includes constant_names, "Outer"
        assert_includes constant_names, "Outer::Middle"
        assert_includes constant_names, "Outer::Middle::Inner"
      end

      # Issue #21: RSpec predicate matchers
      def test_be_matcher_emits_predicate_reference
        refs = collect(<<~RUBY)
          expect(record.type).to be_task_run_execution
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "task_run_execution?"
      end

      def test_be_a_matcher_strips_article
        refs = collect("expect(x).to be_a_user")
        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "user?"
      end

      def test_be_an_matcher_strips_article
        refs = collect("expect(x).to be_an_admin")
        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "admin?"
      end

      def test_have_matcher_emits_has_predicate
        refs = collect("expect(x).to have_key(:a)")
        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "has_key?"
        assert_includes names, "have_key?"
      end

      def test_non_matcher_call_emits_no_predicate_reference
        refs = collect("foo.bar")
        refute refs.any? { |r| r.kind == :method && r.name == "bar?" }
      end

      def test_delegate_emits_method_reference
        refs = collect(<<~RUBY)
          class Foo
            delegate :bar, :baz, to: :target
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "bar"
        assert_includes names, "baz"
      end

      def test_delegate_with_string_prefix_emits_prefixed_name
        refs = collect(<<~RUBY)
          class Foo
            delegate :name, to: :profile, prefix: :user
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "user_name"
      end

      def test_delegate_with_true_prefix_emits_method_prefix
        refs = collect(<<~RUBY)
          class Foo
            delegate :name, to: :profile, prefix: true
          end
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix }
        assert prefix
      end

      def test_aasm_event_after_callback_emits_references
        refs = collect(<<~RUBY)
          class Order
            event :activate, after: [:notify_user, :log_event]
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "notify_user"
        assert_includes names, "log_event"
      end

      def test_aasm_event_guard_emits_reference
        refs = collect(<<~RUBY)
          class Order
            event :activate, guard: :can_activate?
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "can_activate?"
      end

      def test_aasm_error_on_all_events_emits_reference
        refs = collect(<<~RUBY)
          class Order
            error_on_all_events :handle_aasm_error
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "handle_aasm_error"
      end

      def test_graphql_builds_emits_build_method
        refs = collect(<<~RUBY)
          class CreateOrder < BaseMutation
            builds :order
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "build_order"
      end

      def test_graphql_argument_prepare_emits_reference
        refs = collect(<<~RUBY)
          class CreateOrder < BaseMutation
            argument :assignee_id, ID, prepare: :load_assignee
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "load_assignee"
      end

      def test_delegate_with_hash_splat_does_not_crash
        refs = collect(<<~RUBY)
          opts = { to: :target }
          delegate :name, **opts
        RUBY

        assert_kind_of Array, refs
      end

      def test_aasm_with_non_symbol_non_hash_arg_is_skipped
        # Integer or string literal as first arg → no crash, no method ref
        refs = collect(<<~RUBY)
          class Order
            event :activate, "extra_string_arg"
          end
        RUBY

        assert_kind_of Array, refs
      end

      def test_graphql_builds_with_non_symbol_arg_is_skipped
        refs = collect(<<~RUBY)
          class Mutation
            builds "not_a_symbol"
          end
        RUBY

        refute refs.any? { |r| r.name == "build_not_a_symbol" }
      end

      def test_graphql_argument_with_hash_splat_does_not_crash
        refs = collect(<<~RUBY)
          opts = { null: false }
          argument :id, ID, **opts
        RUBY

        assert_kind_of Array, refs
      end

      def test_graphql_argument_with_non_matching_key_is_skipped
        refs = collect(<<~RUBY)
          argument :name, String, null: false, description: "The name"
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name == "description" }
      end

      def test_aasm_with_hash_splat_does_not_crash
        refs = collect(<<~RUBY)
          opts = { after: :notify }
          event :activate, **opts
        RUBY

        assert_kind_of Array, refs
      end

      def test_delegate_prefix_false_uses_bare_name
        refs = collect(<<~RUBY)
          class Foo
            delegate :name, to: :profile, prefix: false
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "name"
      end

      def test_delegate_without_prefix_option_uses_bare_name
        refs = collect(<<~RUBY)
          class Foo
            delegate :name, to: :profile
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "name"
      end

      def test_aasm_event_with_no_matching_callback_key
        # Non-callback hash key in AASM event is silently ignored
        refs = collect(<<~RUBY)
          class Order
            event :activate, transitions_to: :active
          end
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name == "active" }
      end

      def test_aasm_collect_symbol_or_array_with_non_symbol_element
        # An array containing a string literal instead of a symbol is silently skipped
        refs = collect(<<~RUBY)
          class Order
            event :activate, after: ["not_a_symbol"]
          end
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name == "not_a_symbol" }
      end

      def test_graphql_argument_non_symbol_prepare_is_skipped
        refs = collect(<<~RUBY)
          class Mutation
            argument :id, ID, prepare: -> (v, _) { v }
          end
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name.start_with?("load_") }
      end

      def test_graphql_non_builds_non_keyword_arg_is_skipped
        refs = collect(<<~RUBY)
          class Mutation
            argument :id, ID
          end
        RUBY

        # No prepare:/method: keyword → no extra method refs emitted
        refute refs.any? { |r| r.kind == :method && r.name == "id" }
      end

      def test_graphql_field_method_emits_reference
        refs = collect(<<~RUBY)
          class UserType < BaseObject
            field :full_name, String, method: :display_name
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "display_name"
      end

      def test_validate_symbol_emits_method_reference
        refs = collect(<<~RUBY)
          class Model
            validate :check_name
            validate :check_email, on: :create
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "check_name"
        assert_includes names, "check_email"
      end

      def test_before_save_symbol_emits_method_reference
        refs = collect(<<~RUBY)
          class Model
            before_save :normalize_email
            after_commit :flush_cache
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "normalize_email"
        assert_includes names, "flush_cache"
      end

      def test_validate_with_non_symbol_arg_is_ignored
        refs = collect(<<~RUBY)
          class Model
            validate SomeValidator
          end
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name == "SomeValidator" }
      end

      def test_accepts_nested_attributes_emits_prefix_reference
        refs = collect(<<~RUBY)
          class Order
            accepts_nested_attributes_for :line_items
          end
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix && r.name.include?("line_items") }
        assert_equal "line_items_attributes", prefix&.name
      end

      def test_accepts_nested_attributes_ignores_non_symbol_arg
        refs = collect(<<~RUBY)
          class Order
            accepts_nested_attributes_for "line_items"
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix && r.name.include?("line_items") }
      end

      def test_class_with_no_name_components_is_not_dynamic
        # Edge case: anonymous or deeply-nested constant where split("::").last is
        # still a non-Preview string. Should NOT mark as dynamic.
        refs = collect(<<~RUBY)
          class Widget
            def render; end
          end
        RUBY

        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_class_inheriting_from_preview_superclass_is_dynamic
        refs = collect(<<~RUBY)
          class MyPreview < ActionMailer::Preview
            def some_action
            end
          end
        RUBY

        ns_ref = refs.find { |r| r.kind == :dynamic_namespace }
        assert ns_ref, "superclass containing Preview should mark the namespace dynamic"
      end

      def test_mailer_preview_class_marks_namespace_as_dynamic
        refs = collect(<<~RUBY)
          class WelcomeMailerPreview < ActionMailer::Preview
            def welcome_email
            end
          end
        RUBY

        ns_ref = refs.find { |r| r.kind == :dynamic_namespace }
        assert ns_ref, "expected a dynamic_namespace reference for the preview class"
      end

      def test_class_ending_in_preview_without_superclass_is_dynamic
        refs = collect(<<~RUBY)
          class CompanyMailerPreview
            def company_created
            end
          end
        RUBY

        ns_ref = refs.find { |r| r.kind == :dynamic_namespace }
        assert ns_ref
      end

      def test_non_preview_class_is_not_dynamic
        refs = collect(<<~RUBY)
          class WelcomeService
            def call
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_visitor_subclass_emits_visit_prefix_reference
        refs = collect(<<~RUBY)
          class MyVisitor < Prism::Visitor
            def visit_call_node(node); end
          end
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix && r.name == "visit_" }
        assert prefix, "expected a method_prefix reference for 'visit_'"
      end

      def test_non_visitor_subclass_does_not_emit_visit_prefix
        refs = collect(<<~RUBY)
          class Transformer < Prism::Mutation
            def transform_call_node(node); end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix && r.name == "visit_" }
      end

      def test_class_with_no_superclass_does_not_emit_visit_prefix
        refs = collect(<<~RUBY)
          class Plain
            def visit_something; end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix && r.name == "visit_" }
      end

      def test_self_receiver_resolves_to_namespace_with_resolver
        resolver = Resolver::TypeResolver.new
        refs = collect(<<~RUBY, type_resolver: resolver)
          class MyClass
            def call
              self.other_method
            end
          end
        RUBY

        ref = refs.find { |r| r.name == "other_method" }
        assert_equal "MyClass", ref.receiver_type
      end

      def test_constant_path_receiver_resolves_to_slice
        resolver = Resolver::TypeResolver.new
        refs = collect(<<~RUBY, type_resolver: resolver)
          Foo::Bar.build
        RUBY

        ref = refs.find { |r| r.name == "build" }
        assert_equal "Foo::Bar", ref.receiver_type
      end

      def test_constant_read_receiver_resolves_to_name
        resolver = Resolver::TypeResolver.new
        refs = collect(<<~RUBY, type_resolver: resolver)
          Widget.create
        RUBY

        ref = refs.find { |r| r.name == "create" }
        assert_equal "Widget", ref.receiver_type
      end

      def test_interpolated_string_dispatch_collects_prefix
        refs = collect(<<~'RUBY')
          public_send("dump_#{type}")
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix }
        assert_equal "dump_", prefix.name
      end

      def test_interpolated_symbol_dispatch_collects_prefix
        refs = collect(<<~'RUBY')
          public_send(:"render_#{type}")
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix }
        assert_equal "render_", prefix.name
      end

      def test_interpolated_string_to_sym_dispatch_collects_prefix
        refs = collect(<<~'RUBY')
          public_send("build_#{type}".to_sym)
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix }
        assert_equal "build_", prefix.name
      end

      def test_variable_dispatch_inside_namespace_marks_namespace
        refs = collect(<<~RUBY)
          class Serializer
            def render(method_name)
              __send__(method_name)
            end
          end
        RUBY

        ns = refs.find { |r| r.kind == :dynamic_namespace }
        assert_equal "Serializer", ns.name
      end

      def test_variable_dispatch_outside_namespace_collects_nothing
        refs = collect(<<~RUBY)
          send(method_name)
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix || r.kind == :dynamic_namespace }
      end

      def test_interpolation_leading_with_expression_has_no_prefix
        # Starts with the interpolation, so there's no literal prefix to collect.
        refs = collect(<<~'RUBY')
          class Worker
            def go(type)
              public_send("#{type}_suffix")
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix }
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_bare_send_with_symbol_has_no_receiver_type
        refs = collect(<<~RUBY)
          send(:bare_target)
        RUBY

        ref = refs.find { |r| r.name == "bare_target" }
        assert ref
        refute ref.typed?
      end

      def test_param_types_registered_and_cleared_for_sigged_method
        resolver = Resolver::TypeResolver.new
        resolver.register_method(
          owner: "Service",
          method_name: "call",
          return_type: "String",
          param_types: { "user" => "User" },
        )
        resolver.register_method(owner: "User", method_name: "name", return_type: "String")

        refs = collect(<<~RUBY, type_resolver: resolver)
          class Service
            def call(user)
              user.name
            end
          end
        RUBY

        name_ref = refs.find { |r| r.name == "name" }
        assert_equal "User", name_ref.receiver_type
      end

      def test_compound_constant_path_definition_is_not_a_reference
        refs = collect(<<~RUBY)
          class Foo::Bar
          end
        RUBY

        # The `Foo::Bar` in the class declaration is a definition, not a reference.
        refute refs.any? { |r| r.kind == :constant && r.name == "Foo::Bar" }
      end

      def test_local_variable_write_with_non_call_value_is_ignored
        resolver = Resolver::TypeResolver.new
        refs = collect(<<~RUBY, type_resolver: resolver)
          class Service
            def call
              count = 42
              count
            end
          end
        RUBY

        # No crash, and the literal assignment didn't register a type.
        assert_kind_of Array, refs
      end

      def test_local_variable_type_tracking
        resolver = Resolver::TypeResolver.new
        resolver.register_method(owner: "Factory", method_name: "build", return_type: "Widget")
        resolver.register_method(owner: "Widget", method_name: "ship", return_type: "Status")

        refs = collect(<<~RUBY, type_resolver: resolver)
          class Service
            def call
              widget = Factory.build
              widget.ship
            end
          end
        RUBY

        ship = refs.find { |r| r.name == "ship" }
        assert_equal "Widget", ship.receiver_type
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
