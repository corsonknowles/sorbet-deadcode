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
