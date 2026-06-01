# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Refiners
    class GraphqlRefinerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write_graphql(rel, content)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      def make_def(name, kind: :method, owner: "UserType")
        Definition.new(
          name: name, full_name: "#{owner}##{name}", kind: kind,
          location: "app/graphql/user_type.rb:1", owner_name: owner,
        )
      end

      def refiner
        GraphqlRefiner.new(@dir)
      end

      def test_removes_resolver_method_referenced_in_sdl
        write_graphql("schema/user.graphql", "type User { fullName: String }\n")
        defn = make_def("full_name")
        assert_empty refiner.refine([defn])
      end

      def test_keeps_method_not_referenced_in_sdl
        write_graphql("schema/user.graphql", "type User { fullName: String }\n")
        defn = make_def("genuinely_dead")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_matching_is_name_only_across_owners
        write_graphql("schema/user.graphql", "type User { fullName: String }\n")
        defn = make_def("full_name", owner: "SomeOtherType")
        assert_empty refiner.refine([defn])
      end

      def test_does_not_remove_non_method_kinds
        # A constant whose name coincides with a field must not be removed by a method ref.
        write_graphql("schema/user.graphql", "type User { fullName: String }\n")
        const = Definition.new(name: "full_name", full_name: "Full_name", kind: :constant, location: "f:1")
        assert_equal [const], refiner.refine([const])
      end

      def test_returns_unchanged_when_no_sdl_references
        write_graphql("schema/empty.graphql", "scalar DateTime\n")
        defn = make_def("full_name")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_returns_empty_input_unchanged
        assert_equal [], refiner.refine([])
      end

      # ---- integration: fixture .graphql + Ruby resolver --------------------

      def test_full_pipeline_keeps_resolver_method_alive
        FileUtils.mkdir_p(File.join(@dir, "app", "graphql"))
        write_graphql("schema/user.graphql", <<~GQL)
          type User {
            fullName: String!
          }
        GQL
        File.write(File.join(@dir, "app", "graphql", "user_type.rb"), <<~RUBY)
          class UserType
            def full_name; end
            def truly_dead; end
          end
        RUBY

        candidates = SorbetDeadcode.analyze(File.join(@dir, "app", "graphql"))
        refined = GraphqlRefiner.new(@dir).refine(candidates)
        names = refined.map(&:name)

        refute_includes names, "full_name"
        assert_includes names, "truly_dead"
      end

      def test_composes_with_analyze_and_refine
        FileUtils.mkdir_p(File.join(@dir, "app", "graphql"))
        write_graphql("schema/user.graphql", "type User { fullName: String! }\n")
        File.write(File.join(@dir, "app", "graphql", "user_type.rb"), <<~RUBY)
          class UserType
            def full_name; end
            def truly_dead; end
          end
        RUBY

        results = SorbetDeadcode.analyze_and_refine(
          paths: [File.join(@dir, "app", "graphql")],
          refiners: [GraphqlRefiner.new(@dir)],
        )
        names = results.map(&:name)

        refute_includes names, "full_name"
        assert_includes names, "truly_dead"
      end
    end
  end
end
