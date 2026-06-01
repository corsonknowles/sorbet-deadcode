# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class GraphqlScannerSpec < Minitest::Test
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
        GraphqlScanner.new(@dir).references
      end

      def method_names
        refs.select { |r| r.kind == :method }.map(&:name)
      end

      def test_extracts_field_name_and_snake_cases_it
        write("schema/user.graphql", <<~GQL)
          type User {
            fullName: String!
          }
        GQL
        # Conservatively emits both the literal field and the snake_cased resolver name.
        assert_includes method_names, "fullName"
        assert_includes method_names, "full_name"
      end

      def test_extracts_field_with_arguments_and_argument_names
        write("schema/query.graphql", <<~GQL)
          type Query {
            searchWidgets(maxResults: Int): [Widget!]!
          }
        GQL
        assert_includes method_names, "search_widgets"
        assert_includes method_names, "max_results"
      end

      def test_extracts_input_object_fields
        write("schema/input.graphql", <<~GQL)
          input CreateUserInput {
            firstName: String!
            lastName: String!
          }
        GQL
        assert_includes method_names, "first_name"
        assert_includes method_names, "last_name"
      end

      def test_single_word_field_emits_one_name
        write("schema/user.graphql", "type User { id: ID! }\n")
        # `id` underscores to itself, so only one reference is emitted.
        assert_equal 1, method_names.count { |n| n == "id" }
      end

      def test_handles_graphqls_extension
        write("schema/user.graphqls", "type User { displayName: String }\n")
        assert_includes method_names, "display_name"
      end

      def test_skips_block_string_description_content
        write("schema/user.graphql", <<~GQL)
          """
          A user. secretField: String
          """
          type User {
            realField: String
          }
        GQL
        assert_includes method_names, "real_field"
        refute_includes method_names, "secret_field"
        refute_includes method_names, "secretField"
      end

      def test_skips_inline_string_content
        write("schema/user.graphql", <<~GQL)
          type User {
            name: String @deprecated(reason: "use otherField: String instead")
          }
        GQL
        refute_includes method_names, "otherField"
        refute_includes method_names, "other_field"
      end

      def test_skips_comment_content
        write("schema/user.graphql", <<~GQL)
          type User {
            # hiddenField: String
            name: String
          }
        GQL
        assert_includes method_names, "name"
        refute_includes method_names, "hidden_field"
      end

      def test_does_not_capture_directive_names
        write("schema/user.graphql", "type User { name: String @include(if: true) }\n")
        refute_includes method_names, "include"
      end

      def test_does_not_capture_enum_values
        write("schema/status.graphql", <<~GQL)
          enum Status {
            ACTIVE
            INACTIVE
          }
        GQL
        refute_includes method_names, "ACTIVE"
        refute_includes method_names, "INACTIVE"
      end

      def test_references_are_name_only
        write("schema/user.graphql", "type User { fullName: String }\n")
        ref = refs.find { |r| r.name == "full_name" }
        assert_nil ref.receiver_type
      end

      def test_tolerates_unreadable_file
        # A directory matching the glob must not crash the scan.
        FileUtils.mkdir_p(File.join(@dir, "weird.graphql"))
        write("schema/ok.graphql", "type T { okField: String }\n")
        assert_includes method_names, "ok_field"
      end

      def test_returns_empty_when_no_graphql_files
        assert_empty refs
      end
    end
  end
end
