# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Analyzer
    class DeadCodeAnalyzerSpec < Minitest::Test
      def test_finds_dead_methods_in_single_file
        analyzer = analyze_source(<<~RUBY)
          class Foo
            def alive_method
            end

            def dead_method
            end
          end

          Foo.new.alive_method
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "alive_method"
        assert_includes dead_names, "dead_method"
      end

      def test_class_referenced_by_constant_is_alive
        analyzer = analyze_source(<<~RUBY)
          class UsedClass
          end

          class DeadClass
          end

          UsedClass.new
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "UsedClass"
        assert_includes dead_names, "DeadClass"
      end

      def test_send_keeps_method_alive
        analyzer = analyze_source(<<~RUBY)
          class Dispatcher
            def target_method
            end

            def dead_method
            end

            def dispatch
              send(:target_method)
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "target_method"
        assert_includes dead_names, "dead_method"
      end

      def test_public_send_keeps_method_alive
        analyzer = analyze_source(<<~RUBY)
          class Dispatcher
            def target_method
            end

            def dead_method
            end

            def dispatch
              public_send(:target_method)
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "target_method"
        assert_includes dead_names, "dead_method"
      end

      def test_type_aware_disambiguation
        # Two classes define display_name, but only Company#display_name
        # is called via a typed reference. Report#display_name should be dead.
        analyzer = analyze_sources(
          "company.rb" => <<~RUBY,
            class Company
              sig { returns(String) }
              def display_name
                "ACME"
              end
            end
          RUBY
          "report.rb" => <<~RUBY,
            class Report
              sig { returns(String) }
              def display_name
                "Report"
              end
            end
          RUBY
          "service.rb" => <<~RUBY,
            class Service
              sig { params(company: Company).returns(String) }
              def show(company)
                company.display_name
              end
            end
          RUBY
        )

        dead = analyzer.dead_definitions.select { |d| d.name == "display_name" }
        dead_owners = dead.map(&:owner_name)

        # Report#display_name should be dead (no typed reference to Report)
        assert_includes dead_owners, "Report"
        # Company#display_name should be alive (called in Service#show)
        refute_includes dead_owners, "Company"
      end

      def test_attr_reader_alive_when_called
        analyzer = analyze_source(<<~RUBY)
          class Person
            attr_reader :name, :unused_field

            def greet
              name
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "name"
        assert_includes dead_names, "unused_field"
      end

      def test_exclude_paths
        dir = Dir.mktmpdir
        FileUtils.mkdir_p("#{dir}/app")
        FileUtils.mkdir_p("#{dir}/spec")

        File.write("#{dir}/app/model.rb", <<~RUBY)
          class Model
            def alive
            end

            def only_in_spec
            end
          end
        RUBY

        File.write("#{dir}/spec/model_spec.rb", <<~RUBY)
          Model.new.alive
          Model.new.only_in_spec
        RUBY

        # Without exclusion, both are alive
        analyzer_all = DeadCodeAnalyzer.new(paths: [dir])
        analyzer_all.run
        dead_all = analyzer_all.dead_definitions.map(&:name)
        refute_includes dead_all, "only_in_spec"

        # With spec exclusion, only_in_spec is dead
        analyzer_no_spec = DeadCodeAnalyzer.new(paths: [dir], exclude_paths: ["/spec/"])
        analyzer_no_spec.run
        dead_no_spec = analyzer_no_spec.dead_definitions.map(&:name)
        assert_includes dead_no_spec, "only_in_spec"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_constant_alive_when_referenced
        analyzer = analyze_source(<<~RUBY)
          class Config
            MAX = 100
            UNUSED = 0
          end

          Config::MAX
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "MAX"
        assert_includes dead_names, "UNUSED"
      end

      def test_writer_set_via_or_assign_is_alive
        analyzer = analyze_source(<<~RUBY)
          class AbilityCache
            attr_writer :cached_definition

            def fetch
              self.cached_definition ||= compute
            end
          end
        RUBY

        refute_includes analyzer.dead_definitions.map(&:name), "cached_definition="
      end

      def test_writer_set_via_mass_assignment_is_alive
        analyzer = analyze_source(<<~RUBY)
          class Donation
            attr_writer :charity_ein
          end

          class Builder
            def build
              Donation.new(charity_ein: "12-3456789")
            end
          end
        RUBY

        refute_includes analyzer.dead_definitions.map(&:name), "charity_ein="
      end

      def test_interpolated_dispatch_keeps_prefix_family_alive
        analyzer = analyze_source(<<~RUBY)
          class Serializer
            def dump_company
            end

            def dump_employee
            end

            def render(type)
              public_send("dump_\#{type}")
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "dump_company"
        refute_includes dead_names, "dump_employee"
      end

      def test_interpolated_dispatch_does_not_protect_other_prefixes
        analyzer = analyze_source(<<~RUBY)
          class Serializer
            def dump_company
            end

            def truly_dead
            end

            def render(type)
              public_send("dump_\#{type}")
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "dump_company"
        assert_includes dead_names, "truly_dead"
      end

      # :report mode reports namespace-dispatched methods as dead
      # (downgraded to :low confidence) instead of excluding them.
      def test_report_mode_reports_variable_dispatched_methods
        source = <<~RUBY
          class MemberSerializer
            def dump_company_member
            end

            def dump(member)
              method_name = some_lookup(member)
              __send__(method_name, member)
            end
          end
        RUBY

        dir = Dir.mktmpdir
        File.write("#{dir}/s.rb", source)

        exclude_mode = DeadCodeAnalyzer.new(paths: [dir], dynamic_dispatch: :exclude)
        exclude_mode.run
        refute_includes exclude_mode.dead_definitions.map(&:name), "dump_company_member"

        report_mode = DeadCodeAnalyzer.new(paths: [dir], dynamic_dispatch: :report)
        report_mode.run
        # In :report mode the method surfaces as a (low-confidence) candidate.
        assert_includes report_mode.dead_definitions.map(&:name), "dump_company_member"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      # VALIDATION: the LSP cross-check cannot rescue this case.
      # Sorbet's textDocument/references is static and also cannot resolve
      # __send__(variable), so an LSP pass over a :report-mode candidate would find
      # zero references and confirm it dead — a false positive. This test documents
      # why the conservative :exclude default is retained even in hybrid/LSP mode.
      def test_report_mode_candidate_has_no_static_references
        source = <<~RUBY
          class MemberSerializer
            def dump_company_member
            end

            def dump(member)
              __send__("dump_\#{member.class.name}", member)
            end
          end
        RUBY

        dir = Dir.mktmpdir
        File.write("#{dir}/s.rb", source)
        analyzer = DeadCodeAnalyzer.new(paths: [dir], dynamic_dispatch: :report)
        analyzer.run

        # The interpolated prefix "dump_" still rescues it via fix-1/prefix logic,
        # so it should NOT be dead even in report mode — prefix resolution wins.
        refute_includes analyzer.dead_definitions.map(&:name), "dump_company_member"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_dynamic_dispatch_on_variable_protects_namespace
        # __send__(method_name) where method_name is a local variable: we can't
        # know the target, so every method in the class is kept alive.
        analyzer = analyze_source(<<~RUBY)
          class MemberSerializer
            def dump_company_member
            end

            def dump_accountant
            end

            def dump(member)
              method_name = "dump_\#{member.class.name}".to_sym
              __send__(method_name, member)
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "dump_company_member"
        refute_includes dead_names, "dump_accountant"
      end

      def test_inline_constant_in_array_keeps_parent_alive
        # PARENT defines CHILD as a side effect; CHILD is referenced, so deleting
        # PARENT would break CHILD. PARENT must not be reported dead.
        analyzer = analyze_source(<<~RUBY)
          class Config
            CATEGORIES = [
              CATEGORY_A = "a",
              CATEGORY_B = "b",
            ].freeze
          end

          Config::CATEGORY_A
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "CATEGORIES"
        refute_includes dead_names, "CATEGORY_A"
      end

      def test_inline_constant_parent_dead_when_no_child_referenced
        analyzer = analyze_source(<<~RUBY)
          class Config
            CATEGORIES = [
              CATEGORY_A = "a",
              CATEGORY_B = "b",
            ].freeze
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        # No child is referenced, so the whole group is genuinely dead.
        assert_includes dead_names, "CATEGORIES"
        assert_includes dead_names, "CATEGORY_A"
      end

      def test_module_alive_when_referenced
        analyzer = analyze_source(<<~RUBY)
          module UsedModule
          end

          module DeadModule
          end

          include UsedModule
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "UsedModule"
        assert_includes dead_names, "DeadModule"
      end

      def test_predicate_used_only_via_be_matcher_is_alive_when_specs_included
        dir = Dir.mktmpdir
        File.write(File.join(dir, "status.rb"), <<~RUBY)
          class Status
            def active?
              @state == :active
            end
          end
        RUBY
        File.write(File.join(dir, "status_spec.rb"), <<~RUBY)
          RSpec.describe Status do
            it { expect(subject).to be_active }
          end
        RUBY

        analyzer = DeadCodeAnalyzer.new(paths: [dir])
        analyzer.run
        # `be_active` in the spec references `active?` — not dead.
        refute_includes analyzer.dead_definitions.map(&:name), "active?"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_respond_to_missing_is_never_dead
        analyzer = analyze_source(<<~RUBY)
          class Proxy
            def respond_to_missing?(name, include_private = false)
              @target.respond_to?(name, include_private)
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "respond_to_missing?"
      end

      def test_validate_callback_method_is_alive
        analyzer = analyze_source(<<~RUBY)
          class Order
            validate :check_total

            def check_total
              errors.add(:total, "must be positive") if total <= 0
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "check_total"
      end

      def test_before_save_callback_method_is_alive
        analyzer = analyze_source(<<~RUBY)
          class User
            before_save :normalize_email

            def normalize_email
              self.email = email.downcase
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "normalize_email"
      end

      def test_mailer_preview_methods_are_alive
        analyzer = analyze_source(<<~RUBY)
          class UserMailerPreview
            def welcome_email
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "welcome_email"
      end

      def test_accepts_nested_attributes_override_is_alive
        analyzer = analyze_source(<<~RUBY)
          class Order
            accepts_nested_attributes_for :line_items

            def line_items_attributes=(attrs)
              super(attrs.reject { |a| a[:_destroy] })
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "line_items_attributes="
      end

      def test_initialize_is_never_dead
        analyzer = analyze_source(<<~RUBY)
          class Service
            def initialize(name)
              @name = name
            end
          end
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "initialize"
      end

      def test_module_alive_via_qualified_constant_path
        analyzer = analyze_source(<<~RUBY)
          module Outer
            module Inner
            end
          end

          Outer::Inner.new
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "Outer"
        refute_includes dead_names, "Inner"
      end

      def test_reference_paths_keeps_public_api_alive
        dir = Dir.mktmpdir
        lib_dir = File.join(dir, "lib")
        exe_dir = File.join(dir, "exe")
        FileUtils.mkdir_p(lib_dir)
        FileUtils.mkdir_p(exe_dir)

        File.write(File.join(lib_dir, "service.rb"), <<~RUBY)
          class Service
            def public_method
            end

            def truly_dead
            end
          end
        RUBY

        File.write(File.join(exe_dir, "runner.rb"), <<~RUBY)
          Service.new.public_method
        RUBY

        # Without reference_paths: public_method looks dead (caller in exe/ not scanned)
        analyzer_narrow = DeadCodeAnalyzer.new(paths: [lib_dir])
        analyzer_narrow.run
        assert_includes analyzer_narrow.dead_definitions.map(&:name), "public_method"

        # With reference_paths pointing at exe/: public_method is alive
        analyzer_wide = DeadCodeAnalyzer.new(paths: [lib_dir], reference_paths: [exe_dir])
        analyzer_wide.run
        refute_includes analyzer_wide.dead_definitions.map(&:name), "public_method"
        assert_includes analyzer_wide.dead_definitions.map(&:name), "truly_dead"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_reference_paths_accepts_single_file
        dir = Dir.mktmpdir
        lib_dir = File.join(dir, "lib")
        FileUtils.mkdir_p(lib_dir)
        File.write(File.join(lib_dir, "service.rb"), "class S\n  def api; end\nend\n")
        caller_file = File.join(dir, "caller.rb")
        File.write(caller_file, "S.new.api\n")

        analyzer = DeadCodeAnalyzer.new(paths: [lib_dir], reference_paths: [caller_file])
        analyzer.run
        refute_includes analyzer.dead_definitions.map(&:name), "api"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_reference_paths_skips_unparseable_files
        dir = Dir.mktmpdir
        lib_dir = File.join(dir, "lib")
        ref_dir = File.join(dir, "ref")
        FileUtils.mkdir_p([lib_dir, ref_dir])
        File.write(File.join(lib_dir, "service.rb"), "class S\n  def dead; end\nend\n")
        File.write(File.join(ref_dir, "broken.rb"), "class Broken\n  def oops(\nend")

        analyzer = DeadCodeAnalyzer.new(paths: [lib_dir], reference_paths: [ref_dir])
        analyzer.run
        # The broken ref file is skipped; `dead` remains dead.
        assert_includes analyzer.dead_definitions.map(&:name), "dead"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_reference_paths_skips_files_already_in_definition_set
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def self_caller
              self_caller
            end
          end
        RUBY

        # Passing the same dir as both paths and reference_paths should not
        # double-count files. self_caller calls itself but is otherwise dead.
        analyzer = DeadCodeAnalyzer.new(paths: [dir], reference_paths: [dir])
        analyzer.run
        # self_caller is an untyped self-call; alive because name is referenced.
        refute_includes analyzer.dead_definitions.map(&:name), "self_caller"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_accepts_a_single_file_path
        dir = Dir.mktmpdir
        file = File.join(dir, "single.rb")
        File.write(file, <<~RUBY)
          class Single
            def dead_one
            end
          end
        RUBY

        analyzer = DeadCodeAnalyzer.new(paths: file)
        analyzer.run
        assert_includes analyzer.dead_definitions.map(&:name), "dead_one"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_alive_returns_false_for_unknown_kind
        analyzer = DeadCodeAnalyzer.new(paths: [])
        fake = Struct.new(:kind, :name, :full_name, :owner_name).new(:weird, "x", "x", nil)
        index = analyzer.send(:build_reference_index)
        refute analyzer.send(:alive?, fake, index)
      end

      def test_build_reference_index_ignores_unknown_reference_kind
        analyzer = DeadCodeAnalyzer.new(paths: [])
        fake_ref = Struct.new(:kind).new(:something_else)
        analyzer.instance_variable_set(:@references, [fake_ref])
        index = analyzer.send(:build_reference_index)
        assert_empty index[:untyped_methods]
        assert_empty index[:constants]
      end

      def test_skips_unparseable_files
        dir = Dir.mktmpdir
        File.write(File.join(dir, "broken.rb"), "class Broken\n  def oops(\nend")
        File.write(File.join(dir, "ok.rb"), <<~RUBY)
          class Ok
            def dead_here
            end
          end
        RUBY

        analyzer = DeadCodeAnalyzer.new(paths: [dir])
        analyzer.run
        # Parsing the broken file is skipped without raising; the good file still works.
        assert_includes analyzer.dead_definitions.map(&:name), "dead_here"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_top_level_inline_constant_without_owner_stays_alive
        analyzer = analyze_source(<<~RUBY)
          PARENT = [CHILD = "x"].freeze
          CHILD
        RUBY

        dead_names = analyzer.dead_definitions.map(&:name)
        refute_includes dead_names, "PARENT"
      end

      def test_sig_extraction_covers_type_shapes
        # Exercises every branch of SigExtractor's type/param extraction. We only
        # assert the run completes and returns definitions; the point is coverage
        # of the sig-parsing paths.
        analyzer = analyze_source(<<~RUBY)
          extend T::Sig

          sig { returns(String) }
          def top_level_method
          end

          class Wrapper
            sig { returns(Outer::Inner) }
            def const_path; end

            sig { returns(T.nilable(String)) }
            def t_with_arg; end

            sig { returns(T.foo) }
            def t_without_arg; end

            sig { returns(Kernel.rand) }
            def call_non_t; end

            sig { returns(bare_helper) }
            def call_no_receiver; end

            sig { returns }
            def returns_without_arg; end

            sig { params.returns(String) }
            def params_without_args; end

            sig { returns(:weird) }
            def symbol_type; end

            sig { params(x: Integer, y: String).returns(String) }
            def with_params(x, y); end

            sig { params(Integer).returns(String) }
            def positional_param; end

            sig { params(**rest).returns(String) }
            def splat_param; end

            sig { void }
            def void_method; end

            sig { returns(String).checked(:never) }
            def chained; end

            sig {}
            def empty_block; end

            sig
            def no_block; end

            sig { Helper.configure }
            def receiver_recursion; end
          end
        RUBY

        assert_kind_of Array, analyzer.dead_definitions
        # The signatures referencing Outer::Inner registered a return type for const_path.
        assert analyzer.type_resolver.method_signatures.dig("Wrapper", "const_path")
      end

      private

      def analyze_source(source)
        dir = Dir.mktmpdir
        File.write("#{dir}/test.rb", source)
        analyzer = DeadCodeAnalyzer.new(paths: [dir])
        analyzer.run
        analyzer
      ensure
        # Don't clean up — let the test process handle it
      end

      def analyze_sources(files)
        dir = Dir.mktmpdir
        files.each do |filename, source|
          File.write("#{dir}/#{filename}", source)
        end
        analyzer = DeadCodeAnalyzer.new(paths: [dir])
        analyzer.run
        analyzer
      end
    end
  end
end
