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

      def test_aasm_event_transaction_and_other_callbacks_emit_references
        refs = collect(<<~RUBY)
          class Order
            event :send_to_remove,
                  before_transaction: :set_remove_date,
                  after_transaction: :finalize_removal,
                  unless: :skip_removal?,
                  success: :notify_removed,
                  ensure: :cleanup
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "set_remove_date"
        assert_includes names, "finalize_removal"
        assert_includes names, "skip_removal?"
        assert_includes names, "notify_removed"
        assert_includes names, "cleanup"
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

      def test_graphql_field_emits_same_named_resolver_method
        refs = collect(<<~RUBY)
          class MemberPayroll < BaseObject
            field :on_leave_during_pay_period, Boolean, null: false
            field :member_payrolls, MemberPayrollType, connection: true, null: false
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "on_leave_during_pay_period"
        assert_includes names, "member_payrolls"
      end

      def test_graphql_field_resolver_method_option_emits_reference
        refs = collect(<<~RUBY)
          class Obj < BaseObject
            field :foo, String, null: true, resolver_method: :compute_foo
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "foo"          # the field's own default resolver
        assert_includes names, "compute_foo"  # the explicit override
      end

      def test_graphql_argument_does_not_emit_bare_name_as_method
        refs = collect(<<~RUBY)
          class M < BaseMutation
            argument :assignee, String, required: true
          end
        RUBY

        # arguments are passed as kwargs, not resolved by a same-named method
        refute_includes refs.select { |r| r.kind == :method }.map(&:name), "assignee"
      end

      def test_graphql_argument_prepare_emits_reference
        refs = collect(<<~RUBY)
          class CreateOrder < BaseMutation
            argument :assignee_id, ID, prepare: :load_assignee
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "load_assignee"
      end

      def test_graphql_argument_loads_emits_loader_reference
        refs = collect(<<~RUBY)
          class SaveScorecard < BaseMutation
            argument :job_applicant_id, ID, required: true, loads: Types::JobApplicantType
          end
        RUBY

        # graphql-ruby strips the `_id` suffix and calls `load_job_applicant`.
        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "load_job_applicant"
      end

      def test_graphql_argument_loads_without_id_suffix
        refs = collect(<<~RUBY)
          class M < BaseMutation
            argument :widget, ID, loads: Types::WidgetType
          end
        RUBY

        assert_includes refs.select { |r| r.kind == :method }.map(&:name), "load_widget"
      end

      def test_graphql_loads_with_non_symbol_name_emits_no_loader
        refs = collect(<<~RUBY)
          class T
            field some_dynamic_name, loads: Types::X, method: :resolver_m
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "resolver_m"           # method: still resolved
        refute(names.any? { |n| n.start_with?("load_") }) # no loader without a symbol name
      end

      def test_graphql_string_option_key_is_skipped
        refs = collect(<<~'RUBY')
          class T < BaseMutation
            argument :x, ID, "method" => :should_be_ignored
          end
        RUBY

        refute_includes refs.select { |r| r.kind == :method }.map(&:name), "should_be_ignored"
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

      def test_validate_if_unless_conditionals_emit_method_references
        refs = collect(<<~RUBY)
          class Model
            validate :bonus_only, if: :off_cycle_bonus_only_payroll?
            validate :check, unless: :skip_check?
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "bonus_only"                   # positional method (custom validation)
        assert_includes names, "off_cycle_bonus_only_payroll?" # if: conditional
        assert_includes names, "skip_check?"                  # unless: conditional
      end

      def test_validates_conditional_emitted_but_attribute_is_not
        refs = collect(<<~RUBY)
          class Model
            validates :frequency, presence: true, if: :frequency_required?
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "frequency_required?"  # if: conditional is a method
        refute_includes names, "frequency"            # validates positional arg is an attribute, not a method
      end

      def test_callback_if_conditional_array_emits_method_references
        refs = collect(<<~RUBY)
          class Model
            before_save :normalize, if: [:ready?, :enabled?]
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "normalize"
        assert_includes names, "ready?"
        assert_includes names, "enabled?"
      end

      def test_validate_conditional_options_with_splat_do_not_crash
        refs = collect(<<~RUBY)
          class Model
            validate :x, if: :guard?, **shared_options
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "x"
        assert_includes names, "guard?"
      end

      def test_transactional_commit_callbacks_emit_method_references
        refs = collect(<<~RUBY)
          class Model
            after_create_commit :emit_created
            after_update_commit :emit_updated
            after_destroy_commit :emit_destroyed
            after_save_commit :sync_changes
            before_commit :stage_changes
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "emit_created"
        assert_includes names, "emit_updated"
        assert_includes names, "emit_destroyed"
        assert_includes names, "sync_changes"
        assert_includes names, "stage_changes"
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

      def test_rails_named_base_generator_marks_namespace_dynamic
        refs = collect(<<~RUBY)
          class AppGenerator < Rails::Generators::NamedBase
            def copy_adapter_file; end
            def add_to_list; end
          end
        RUBY

        ns_ref = refs.find { |r| r.kind == :dynamic_namespace }
        assert_equal "AppGenerator", ns_ref.name
      end

      def test_generator_dynamic_namespace_uses_fully_qualified_name
        # The dynamic_namespace ref must match the fully-qualified owner_name recorded for
        # nested method definitions, otherwise the methods are not kept alive.
        refs = collect(<<~RUBY)
          module AppEcosystem
            class AppGenerator < Rails::Generators::NamedBase
              def copy_adapter_file; end
            end
          end
        RUBY

        ns_ref = refs.find { |r| r.kind == :dynamic_namespace }
        assert_equal "AppEcosystem::AppGenerator", ns_ref.name
      end

      def test_rails_base_generator_marks_namespace_dynamic
        refs = collect(<<~RUBY)
          class MyGenerator < Rails::Generators::Base
            def run_step; end
          end
        RUBY

        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_thor_subclass_marks_namespace_dynamic
        refs = collect(<<~RUBY)
          class Cli < Thor
            def build; end
          end
        RUBY

        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_non_generator_class_is_not_dynamic_via_generator_rule
        refs = collect(<<~RUBY)
          class RegularService < ApplicationService
            def call; end
          end
        RUBY

        refute refs.any? { |r| r.kind == :dynamic_namespace }
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

      def test_bare_preview_name_outside_mailer_path_is_not_dynamic
        # A class merely ending in "Preview" (no superclass, not *MailerPreview, not
        # in a mailer_previews path) must NOT be treated as a mailer preview — otherwise
        # we'd hide dead methods in arbitrary service classes.
        refs = collect_at_path("app/services/data_preview.rb", <<~RUBY)
          class DataPreview
            def render
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_bare_preview_name_inside_mailer_path_is_dynamic
        refs = collect_at_path("app/mailer_previews/report_preview.rb", <<~RUBY)
          class ReportPreview
            def monthly_report
            end
          end
        RUBY

        assert refs.any? { |r| r.kind == :dynamic_namespace }
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

      # Local var assigned an interpolated string with a prefix
      def test_local_prefix_does_not_leak_across_methods
        # `m` is assigned an interpolated prefix in `a`, then reused as a plain
        # variable in `b`. The `dump_` prefix must NOT leak into b's send(m).
        refs = collect(<<~'RUBY')
          class Worker
            def a(x)
              m = "dump_#{x}"
              send(m)
            end

            def b(obj)
              m = obj
              send(m)
            end
          end
        RUBY

        prefixes = refs.select { |r| r.kind == :method_prefix }.map(&:name)
        # exactly one dump_ prefix (from method a), none leaked into b
        assert_equal ["dump_"], prefixes
        # b's send(m) falls back to the namespace exclusion
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_local_var_interpolation_prefix_emits_method_prefix
        refs = collect(<<~'RUBY')
          class Serializer
            def render(type)
              name = "dump_#{type}"
              __send__(name)
            end
          end
        RUBY

        prefix = refs.find { |r| r.kind == :method_prefix }
        assert_equal "dump_", prefix&.name
        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      # Inline literal symbol array iterated and dispatched
      def test_inline_symbol_array_iteration_emits_method_refs
        refs = collect(<<~RUBY)
          class Runner
            def run
              [:start, :stop].each { |m| send(m) }
            end
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "start"
        assert_includes names, "stop"
        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      # Symbol array via a constant, then iterated
      def test_constant_symbol_array_iteration_emits_method_refs
        refs = collect(<<~RUBY)
          class Runner
            CALLBACKS = [:before, :after].freeze
            def run
              CALLBACKS.each { |m| public_send(m) }
            end
          end
        RUBY

        names = refs.select { |r| r.kind == :method }.map(&:name)
        assert_includes names, "before"
        assert_includes names, "after"
      end

      def test_iteration_over_non_symbol_array_falls_back
        refs = collect(<<~RUBY)
          class Runner
            def run(items)
              items.each { |m| send(m) }
            end
          end
        RUBY

        # items is not a literal symbol array → conservative namespace fallback
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_iteration_with_block_pass_falls_through
        refs = collect(<<~RUBY)
          class Runner
            def run
              [:a, :b].each(&handler)
            end
          end
        RUBY

        # &handler is a block-pass, not a literal block → no binding, no crash
        assert_kind_of Array, refs
      end

      def test_iteration_with_destructuring_param_falls_through
        refs = collect(<<~RUBY)
          class Runner
            def run
              [[:a, 1], [:b, 2]].each { |(name, val)| send(name) }
            end
          end
        RUBY

        # Destructured param is not a simple required param → conservative handling
        assert_kind_of Array, refs
      end

      def test_iteration_block_without_params_falls_through
        refs = collect(<<~RUBY)
          class Runner
            def run
              [:a, :b].each { do_thing }
            end
          end
        RUBY

        assert_kind_of Array, refs
      end

      def test_empty_symbol_array_constant_not_tracked
        refs = collect(<<~RUBY)
          class Runner
            EMPTY = [].freeze
            def run
              EMPTY.each { |m| send(m) }
            end
          end
        RUBY

        # Empty array → not a resolvable symbol array → conservative fallback
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_mixed_array_not_treated_as_symbol_array
        refs = collect(<<~RUBY)
          class Runner
            def run
              [:a, "b"].each { |m| send(m) }
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method && r.name == "a" }
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_local_var_non_interpolated_assignment_not_tracked_as_prefix
        refs = collect(<<~RUBY)
          class Runner
            def run
              name = "literal_string"
              send(name)
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix }
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_iteration_without_block_param_falls_through
        refs = collect(<<~RUBY)
          class Runner
            def run
              [:a, :b].each
            end
          end
        RUBY

        assert_kind_of Array, refs
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

      def test_interpolation_leading_with_expression_emits_suffix_not_namespace
        # Starts with the interpolation, so there's no literal prefix — but the trailing
        # literal is collected as a method_suffix, keeping `*_suffix` methods alive without
        # falling back to excluding the whole namespace.
        refs = collect(<<~'RUBY')
          class Worker
            def go(type)
              public_send("#{type}_suffix")
            end
          end
        RUBY

        refute refs.any? { |r| r.kind == :method_prefix }
        suffix_ref = refs.find { |r| r.kind == :method_suffix }
        assert_equal "_suffix", suffix_ref.name
        refute refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_local_var_interpolated_suffix_emits_method_suffix
        refs = collect(<<~'RUBY')
          class Worker
            def go(p)
              m = "#{p}_start_time"
              public_send(m)
            end
          end
        RUBY

        suffix_ref = refs.find { |r| r.kind == :method_suffix }
        assert_equal "_start_time", suffix_ref.name
      end

      def test_interpolated_prefix_and_suffix_emits_both
        refs = collect(<<~'RUBY')
          class Worker
            def go(x)
              public_send("a_#{x}_b")
            end
          end
        RUBY

        assert_equal "a_", refs.find { |r| r.kind == :method_prefix }&.name
        assert_equal "_b", refs.find { |r| r.kind == :method_suffix }&.name
      end

      def test_local_suffix_does_not_leak_across_methods
        refs = collect(<<~'RUBY')
          class Worker
            def first(p)
              m = "#{p}_at"
              public_send(m)
            end

            def second(m)
              public_send(m)
            end
          end
        RUBY

        # Only the first method's send should carry the `_at` suffix; the second reuses
        # the name `m` as a plain parameter and must fall back to dynamic_namespace.
        assert_equal 1, refs.count { |r| r.kind == :method_suffix }
        assert refs.any? { |r| r.kind == :dynamic_namespace }
      end

      def test_operator_or_write_emits_reader_and_writer
        refs = collect(<<~RUBY)
          self.class.cached_ability_definition ||= build_it
        RUBY

        names = refs.map(&:name)
        assert_includes names, "cached_ability_definition"
        assert_includes names, "cached_ability_definition="
      end

      def test_operator_plus_write_emits_writer
        refs = collect("obj.counter += 1\n")
        assert_includes refs.map(&:name), "counter="
      end

      def test_and_write_emits_writer
        refs = collect("obj.flag &&= false\n")
        assert_includes refs.map(&:name), "flag="
      end

      def test_mass_assignment_keyword_emits_writer_references
        refs = collect("EmployeeDonation.new(charity_ein: ein, amount: amt)\n")
        names = refs.map(&:name)
        assert_includes names, "charity_ein="
        assert_includes names, "amount="
      end

      def test_factory_build_keyword_emits_writer_references
        refs = collect("build(:employee_donation, charity_ein: ein)\n")
        assert_includes refs.map(&:name), "charity_ein="
      end

      def test_non_mass_assignment_call_does_not_emit_writers
        refs = collect("some_helper(charity_ein: ein)\n")
        refute_includes refs.map(&:name), "charity_ein="
      end

      def test_permit_symbol_keys_emit_writer_references
        refs = collect("params.permit(:display_name, :category_slugs)\n")
        names = refs.map(&:name)
        assert_includes names, "display_name="
        assert_includes names, "category_slugs="
      end

      def test_permit_hash_style_keys_emit_writer_references
        refs = collect("params.permit(:foo, bar: [], baz: [:x])\n")
        names = refs.map(&:name)
        assert_includes names, "foo="
        assert_includes names, "bar="
        assert_includes names, "baz="
        # the nested `:x` names a nested param, not a setter — not emitted
        refute_includes names, "x="
      end

      def test_permit_ignores_non_symbol_and_splat_args
        refs = collect("params.permit(*allowed, dynamic_key => [])\n")
        # no crash, and no stray writer reference from the non-symbol forms
        assert(refs.is_a?(Array))
        refute_includes refs.map(&:name), "dynamic_key="
      end

      def test_permit_nested_collection_hash_keys_emit_writer_references
        refs = collect(<<~RUBY)
          @params.permit(
            apps: [
              :slug,
              { type_uuids: [], category_slugs: [], app_photos_attributes: [:description] },
            ],
          )
        RUBY
        names = refs.map(&:name)
        assert_includes names, "apps="
        assert_includes names, "type_uuids="
        assert_includes names, "category_slugs="
        assert_includes names, "app_photos_attributes="
        # bare symbols inside a value array name nested params, not setters
        refute_includes names, "slug="
        refute_includes names, "description="
      end

      def test_setter_kept_alive_by_permit_is_not_dead
        source = <<~RUBY
          class App
            def category_slugs=(value)
              @category_slugs = value
            end

            def sync(params)
              assign_attributes(params.permit(:category_slugs))
            end
          end
        RUBY

        refs = collect(source)
        assert_includes refs.map(&:name), "category_slugs="
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

      def test_descendants_emits_dynamic_subclasses_reference
        refs = collect("Base.descendants.each(&:run)")
        ref = refs.find { |r| r.kind == :dynamic_subclasses }
        assert ref, "expected a dynamic_subclasses reference"
        assert_equal "Base", ref.name
      end

      def test_subclasses_on_namespaced_constant_uses_short_name
        refs = collect("Foo::Bar.subclasses")
        ref = refs.find { |r| r.kind == :dynamic_subclasses }
        assert_equal "Bar", ref.name
      end

      def test_descendants_on_non_constant_receiver_is_ignored
        refs = collect("registry.descendants")
        refute(refs.any? { |r| r.kind == :dynamic_subclasses })
      end

      def test_descendants_unwraps_sorbet_cast_receiver
        # Common Sorbet idiom: T.unsafe(Base).descendants
        refs = collect("T.unsafe(Base).descendants.map(&:name)")
        ref = refs.find { |r| r.kind == :dynamic_subclasses }
        assert_equal "Base", ref.name
      end

      private

      def collect(source, type_resolver: nil)
        collect_at_path("test.rb", source, type_resolver: type_resolver)
      end

      def collect_at_path(file_path, source, type_resolver: nil)
        result = Prism.parse(source)
        collector = ReferenceCollector.new(file_path, type_resolver: type_resolver)
        collector.visit(result.value)
        collector.references
      end
    end
  end
end
