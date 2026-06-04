# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class RablScannerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write(rel, content)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end

      def refs
        RablScanner.new(@dir).references
      end

      def method_names
        refs.select { |r| r.kind == :method }.map(&:name)
      end

      def constant_names
        refs.select { |r| r.kind == :constant }.map(&:name)
      end

      def test_extracts_attributes_symbol_args
        write("app/views/show.json.rabl", <<~RABL)
          object @widget
          attributes :id, :display_name
        RABL
        result = method_names
        assert_includes result, "id"
        assert_includes result, "display_name"
      end

      def test_extracts_singular_attribute
        write("app/views/show.json.rabl", "attribute :token\n")
        assert_includes method_names, "token"
      end

      def test_extracts_method_calls_inside_node_block
        write("app/views/show.json.rabl", <<~RABL)
          node(:status) { |w| w.current_status }
        RABL
        assert_includes method_names, "current_status"
      end

      def test_does_not_treat_node_key_as_method
        # The node key is an output name, not a model method; only the block body counts.
        write("app/views/show.json.rabl", "node(:only_a_json_key) { 1 }\n")
        refute_includes method_names, "only_a_json_key"
      end

      def test_extracts_child_association_symbol
        write("app/views/show.json.rabl", "child(:parts) { attributes :sku }\n")
        result = method_names
        assert_includes result, "parts"
        assert_includes result, "sku"
      end

      def test_extracts_child_hash_key_as_method_excluding_options
        write("app/views/show.json.rabl", "child(parts: :components, root: :ignored) { attributes :sku }\n")
        result = method_names
        assert_includes result, "parts"
        refute_includes result, "root"
        refute_includes result, "ignored"
      end

      def test_ignores_child_instance_variable_source
        # `child @ivar do ... end` names an ivar, not a model method; only the block counts.
        write("app/views/show.json.rabl", "child @widget do\n  attributes :sku\nend\n")
        result = method_names
        refute_includes result, "widget"
        assert_includes result, "sku"
      end

      def test_extracts_constant_reference
        write("app/views/show.json.rabl", "node(:formatted) { Formatter.format(value) }\n")
        assert_includes constant_names, "Formatter"
        assert_includes method_names, "format"
      end

      def test_ignores_object_and_collection_ivars
        write("app/views/show.json.rabl", <<~RABL)
          object @widget
          collection @widgets
        RABL
        refute_includes method_names, "widget"
        refute_includes method_names, "widgets"
      end

      def test_ignores_extends_string
        write("app/views/show.json.rabl", "extends 'shared/base'\n")
        refute_includes method_names, "shared/base"
      end

      def test_tolerates_unparseable_path
        FileUtils.mkdir_p(File.join(@dir, "weird.rabl"))
        write("app/views/ok.json.rabl", "attributes :ok_attr\n")
        assert_includes method_names, "ok_attr"
      end

      def test_returns_empty_when_no_rabl_files
        assert_empty refs
      end

      def test_child_hash_with_splat_assoc_is_skipped
        write("app/views/show.json.rabl", <<~RABL)
          child(:parts, alias_key: :a, **opts) { attribute :sku }
        RABL
        # **opts is an AssocSplatNode (skipped); the symbol-keyed entry still resolves.
        assert_includes method_names, "parts"
        assert_includes method_names, "alias_key"
      end

      def test_child_hash_with_non_symbol_key_is_skipped
        write("app/views/show.json.rabl", <<~RABL)
          child(:parts, "string_key" => :a) { attribute :sku }
        RABL
        # "string_key" is a StringNode key → skipped; :parts still emits.
        assert_includes method_names, "parts"
        refute_includes method_names, "string_key"
      end

      def test_attribute_dsl_call_without_arguments_does_not_crash
        # Bare `attributes` (no args) exercises the no-arguments arm of the DSL `arguments`
        # helper. (Pass A's ReferenceCollector still records the bare call itself.)
        write("app/views/show.json.rabl", "attributes\n")
        assert_kind_of Array, refs
      end
    end
  end
end
