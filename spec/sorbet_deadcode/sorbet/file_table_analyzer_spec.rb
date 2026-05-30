# frozen_string_literal: true

require_relative "../../spec_helper"
require "open3"

module SorbetDeadcode
  module Sorbet
    class FileTableAnalyzerSpec < Minitest::Test
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

        assert results.any? { |d| d.name == "orphan_method" }
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

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
