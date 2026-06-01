# frozen_string_literal: true

require_relative "../../spec_helper"
require "open3"

module SorbetDeadcode
  module Sorbet
    class FileTableAnalyzerSpec < Minitest::Test
      FakeStatus = Struct.new(:ok) do
        def success?
          ok
        end
      end

      SAMPLE_SYMBOL_TABLE = {
        "id" => 1,
        "name" => { "kind" => "CONSTANT", "name" => "<root>" },
        "kind" => "CLASS_OR_MODULE",
        "children" => [
          {
            "id" => 100,
            "name" => { "kind" => "CONSTANT", "name" => "UserService" },
            "kind" => "CLASS_OR_MODULE",
            "children" => [
              {
                "id" => 101,
                "name" => { "kind" => "UTF8", "name" => "perform" },
                "kind" => "METHOD",
                "arguments" => [],
              },
              {
                "id" => 102,
                "name" => { "kind" => "UTF8", "name" => "unused_helper" },
                "kind" => "METHOD",
                "arguments" => [],
              },
              {
                "id" => 103,
                "name" => { "kind" => "UTF8", "name" => "<static-init>" },
                "kind" => "METHOD",
                "arguments" => [],
              },
            ],
          },
          {
            "id" => 200,
            "name" => { "kind" => "CONSTANT", "name" => "DeadClass" },
            "kind" => "CLASS_OR_MODULE",
            "children" => [
              {
                "id" => 201,
                "name" => { "kind" => "UTF8", "name" => "do_nothing" },
                "kind" => "METHOD",
                "arguments" => [],
              },
            ],
          },
          {
            "id" => 300,
            "name" => { "kind" => "CONSTANT", "name" => "UsedClass" },
            "kind" => "CLASS_OR_MODULE",
            "children" => [],
          },
        ],
      }.freeze

      def test_extracts_definitions_from_symbol_table
        analyzer = FileTableAnalyzer.new(
          project_root: "/tmp",
          paths: ["/tmp"],
          exclude_paths: [],
        )

        defs = analyzer.send(:extract_definitions, SAMPLE_SYMBOL_TABLE)
        names = defs.map(&:name)

        assert_includes names, "UserService"
        assert_includes names, "perform"
        assert_includes names, "unused_helper"
        assert_includes names, "DeadClass"
        assert_includes names, "do_nothing"
        assert_includes names, "UsedClass"

        refute_includes names, "<static-init>"
        refute_includes names, "<root>"
      end

      def test_skips_synthetic_names
        analyzer = FileTableAnalyzer.new(
          project_root: "/tmp",
          paths: ["/tmp"],
          exclude_paths: [],
        )

        synthetic_table = {
          "id" => 1,
          "name" => { "kind" => "CONSTANT", "name" => "<root>" },
          "kind" => "CLASS_OR_MODULE",
          "children" => [
            {
              "id" => 50,
              "name" => { "kind" => "CONSTANT", "name" => "<describe 'something'>" },
              "kind" => "CLASS_OR_MODULE",
              "children" => [],
            },
            {
              "id" => 51,
              "name" => { "kind" => "UTF8", "name" => "initialize" },
              "kind" => "METHOD",
              "arguments" => [],
            },
          ],
        }

        defs = analyzer.send(:extract_definitions, synthetic_table)
        assert_empty defs
      end

      def test_builds_correct_full_names
        analyzer = FileTableAnalyzer.new(
          project_root: "/tmp",
          paths: ["/tmp"],
          exclude_paths: [],
        )

        defs = analyzer.send(:extract_definitions, SAMPLE_SYMBOL_TABLE)
        method_def = defs.find { |d| d.name == "perform" }
        class_def = defs.find { |d| d.name == "UserService" }

        assert_equal "UserService#perform", method_def.full_name
        assert_equal "UserService", class_def.full_name
        assert_equal "UserService", method_def.owner_name
      end

      def test_find_dead_identifies_unreferenced_definitions
        analyzer = FileTableAnalyzer.new(
          project_root: "/tmp",
          paths: ["/tmp"],
          exclude_paths: [],
        )

        definitions = [
          Definition.new(name: "alive_method", full_name: "Foo#alive_method", kind: :method, location: "test:1"),
          Definition.new(name: "dead_method", full_name: "Foo#dead_method", kind: :method, location: "test:2"),
          Definition.new(name: "UsedClass", full_name: "UsedClass", kind: :class, location: "test:3"),
          Definition.new(name: "DeadClass", full_name: "DeadClass", kind: :class, location: "test:4"),
        ]

        ref_alive = Reference.new(name: "alive_method", kind: :method, location: "caller:10")
        ref_class = Reference.new(name: "UsedClass", kind: :constant, location: "caller:20")
        references = [ref_alive, ref_class]

        dead = analyzer.send(:find_dead, definitions, references)
        dead_names = dead.map(&:name)

        assert_includes dead_names, "dead_method"
        assert_includes dead_names, "DeadClass"
        refute_includes dead_names, "alive_method"
        refute_includes dead_names, "UsedClass"
      end

      def test_find_dead_keeps_other_kinds
        analyzer = build_analyzer
        # A constant definition falls through to the `else => true` branch and is
        # always retained (this analyzer only reasons about classes/methods).
        definitions = [
          Definition.new(name: "SOME_CONST", full_name: "Foo::SOME_CONST", kind: :constant, location: "t:1"),
        ]
        dead = analyzer.send(:find_dead, definitions, [])
        assert_equal ["SOME_CONST"], dead.map(&:name)
      end

      def test_run_returns_empty_when_symbol_table_has_no_definitions
        analyzer = build_analyzer
        analyzer.define_singleton_method(:load_symbol_table) do
          { "name" => { "kind" => "CONSTANT", "name" => "<root>" }, "kind" => "CLASS_OR_MODULE", "children" => [] }
        end
        results = capture_stderr { analyzer.run }
        assert_equal [], results
      end

      def test_load_symbol_table_parses_successful_output
        analyzer = build_analyzer
        status = FakeStatus.new(true)
        result = nil
        Open3.stub(:capture3, ['{"name":{"kind":"CONSTANT","name":"<root>"},"kind":"CLASS_OR_MODULE"}', "", status]) do
          result = analyzer.send(:load_symbol_table)
        end
        assert_equal "<root>", result.dig("name", "name")
      end

      def test_load_symbol_table_returns_nil_on_failure
        analyzer = build_analyzer
        status = FakeStatus.new(false)
        result = nil
        capture_stderr do
          Open3.stub(:capture3, ["", "srb exploded", status]) do
            result = analyzer.send(:load_symbol_table)
          end
        end
        assert_nil result
      end

      def test_load_symbol_table_returns_nil_on_parse_error
        analyzer = build_analyzer
        status = FakeStatus.new(true)
        result = nil
        capture_stderr do
          Open3.stub(:capture3, ["this is not json", "", status]) do
            result = analyzer.send(:load_symbol_table)
          end
        end
        assert_nil result
      end

      def test_extract_definitions_returns_empty_for_non_hash
        analyzer = build_analyzer
        assert_equal [], analyzer.send(:extract_definitions, nil)
        assert_equal [], analyzer.send(:extract_definitions, "string")
        assert_equal [], analyzer.send(:extract_definitions, 42)
      end

      def test_extract_definitions_skips_node_without_name_or_kind
        analyzer = build_analyzer
        # A node with neither name nor kind should not produce any definitions.
        node = { "children" => [] }
        assert_equal [], analyzer.send(:extract_definitions, node)
      end

      def test_extract_definitions_skips_class_with_non_constant_name_kind
        analyzer = build_analyzer
        node = {
          "name" => { "kind" => "UTF8", "name" => "something" },
          "kind" => "CLASS_OR_MODULE",
          "children" => [],
        }
        # UTF8 kind on a CLASS_OR_MODULE is not extracted (we only want CONSTANT).
        assert_equal [], analyzer.send(:extract_definitions, node)
      end

      def test_extract_definitions_skips_method_with_non_utf8_name_kind
        analyzer = build_analyzer
        node = {
          "name" => { "kind" => "CONSTANT", "name" => "MyConst" },
          "kind" => "METHOD",
          "children" => [],
        }
        # CONSTANT kind on a METHOD is not extracted.
        assert_equal [], analyzer.send(:extract_definitions, node)
      end

      def test_extract_definitions_skips_unknown_kind
        analyzer = build_analyzer
        node = {
          "name" => { "kind" => "UTF8", "name" => "field_name" },
          "kind" => "FIELD",
          "children" => [],
        }
        assert_equal [], analyzer.send(:extract_definitions, node)
      end

      def test_extract_definitions_with_no_children_key
        analyzer = build_analyzer
        # A node with no "children" key is handled cleanly (not an Array).
        node = {
          "name" => { "kind" => "CONSTANT", "name" => "Leaf" },
          "kind" => "CLASS_OR_MODULE",
        }
        defs = analyzer.send(:extract_definitions, node)
        assert_equal ["Leaf"], defs.map(&:name)
      end

      def test_synthetic_name_returns_true_for_nil
        analyzer = build_analyzer
        assert analyzer.send(:synthetic_name?, nil)
      end

      def test_synthetic_name_returns_true_for_initialize
        analyzer = build_analyzer
        assert analyzer.send(:synthetic_name?, "initialize")
      end

      def test_synthetic_name_returns_true_for_angle_bracket
        analyzer = build_analyzer
        assert analyzer.send(:synthetic_name?, "<block>")
      end

      def test_synthetic_name_returns_false_for_normal_name
        analyzer = build_analyzer
        refute analyzer.send(:synthetic_name?, "perform")
      end

      def test_find_dead_keeps_unknown_kinds
        analyzer = build_analyzer
        # :attr_reader falls through to `else => true` in find_dead
        defn = Definition.new(name: "name", full_name: "Foo#name", kind: :attr_reader, location: "t:1")
        dead = analyzer.send(:find_dead, [defn], [])
        assert_equal ["name"], dead.map(&:name)
      end

      def test_extract_definitions_top_level_method_has_no_owner
        analyzer = build_analyzer
        node = {
          "name" => { "kind" => "UTF8", "name" => "top_level_method" },
          "kind" => "METHOD",
        }
        defs = analyzer.send(:extract_definitions, node)
        assert_equal 1, defs.size
        assert_equal "top_level_method", defs.first.full_name
        assert_nil defs.first.owner_name
      end

      def test_find_dead_handles_unknown_kind_via_else_branch
        analyzer = build_analyzer
        defn = Definition.new(name: "f", full_name: "A#f", kind: :attr_reader, location: "t:1")
        dead = analyzer.send(:find_dead, [defn], [])
        assert_includes dead.map(&:name), "f"
      end

      def test_find_dead_ignores_method_prefix_and_dynamic_namespace_references
        analyzer = build_analyzer
        defn = Definition.new(name: "used", full_name: "Foo#used", kind: :method, location: "t:1")
        # References with kinds other than :method/:constant fall through the case :else.
        prefix_ref = Reference.new(name: "dump_", location: "t:2", kind: :method_prefix)
        ns_ref = Reference.new(name: "Foo", location: "t:3", kind: :dynamic_namespace)
        dead = analyzer.send(:find_dead, [defn], [prefix_ref, ns_ref])
        # "used" has no :method reference, so it's dead.
        assert_includes dead.map(&:name), "used"
      end

      def test_extract_definitions_child_namespace_uses_parent_for_synthetic
        analyzer = build_analyzer
        # Parent has a synthetic name → child_ns stays as parent namespace.
        node = {
          "name" => { "kind" => "CONSTANT", "name" => "<describe>" },
          "kind" => "CLASS_OR_MODULE",
          "children" => [
            {
              "name" => { "kind" => "CONSTANT", "name" => "Real" },
              "kind" => "CLASS_OR_MODULE",
              "children" => [],
            },
          ],
        }
        defs = analyzer.send(:extract_definitions, node)
        # Parent is synthetic → skipped; child is real but namespace stays []
        assert_equal ["Real"], defs.map(&:name)
      end

      def test_run_with_mocked_subprocess
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class MyApp
            def used_method
            end

            def dead_method
            end
          end

          MyApp.new.used_method
        RUBY

        analyzer = FileTableAnalyzer.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
        )

        symbol_table = {
          "id" => 1,
          "name" => { "kind" => "CONSTANT", "name" => "<root>" },
          "kind" => "CLASS_OR_MODULE",
          "children" => [
            {
              "id" => 10,
              "name" => { "kind" => "CONSTANT", "name" => "MyApp" },
              "kind" => "CLASS_OR_MODULE",
              "children" => [
                {
                  "id" => 11,
                  "name" => { "kind" => "UTF8", "name" => "used_method" },
                  "kind" => "METHOD",
                  "arguments" => [],
                },
                {
                  "id" => 12,
                  "name" => { "kind" => "UTF8", "name" => "dead_method" },
                  "kind" => "METHOD",
                  "arguments" => [],
                },
              ],
            },
          ],
        }

        analyzer.define_singleton_method(:load_symbol_table) { symbol_table }

        results = capture_stderr { analyzer.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_method"
        refute_includes dead_names, "used_method"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_fallback_when_symbol_table_fails
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class FallbackApp
            def orphan_method
            end
          end
        RUBY

        analyzer = FileTableAnalyzer.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
        )

        analyzer.define_singleton_method(:load_symbol_table) { nil }

        results = capture_stderr { analyzer.run }

        assert(results.any? { |d| d.name == "orphan_method" })
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def build_analyzer
        FileTableAnalyzer.new(project_root: "/tmp", paths: ["/tmp"], exclude_paths: [])
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        result = yield
        result
      ensure
        $stderr = original
      end
    end
  end
end
