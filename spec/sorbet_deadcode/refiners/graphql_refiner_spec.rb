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

      # Definition path is absolute (under @dir) so directory-scoping can compare it against
      # the (absolute) schema directories the scanner reports.
      def make_def(name, kind: :method, owner: "UserType", path: "app/graphql/user_type.rb")
        Definition.new(
          name: name, full_name: "#{owner}##{name}", kind: kind,
          location: "#{File.join(@dir, path)}:1", owner_name: owner,
        )
      end

      def refiner
        GraphqlRefiner.new(@dir)
      end

      def test_removes_resolver_method_referenced_in_sdl
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        defn = make_def("full_name")
        assert_empty refiner.refine([defn])
      end

      def test_keeps_method_not_referenced_in_sdl
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        defn = make_def("genuinely_dead")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_matching_is_name_only_across_owners
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        defn = make_def("full_name", owner: "SomeOtherType")
        assert_empty refiner.refine([defn])
      end

      def test_does_not_remove_non_method_kinds
        # A constant whose name coincides with a field must not be removed by a method ref.
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        const = make_def("full_name", kind: :constant, owner: "Full_name")
        assert_equal [const], refiner.refine([const])
      end

      def test_returns_unchanged_when_no_sdl_references
        write_graphql("app/graphql/empty.graphql", "scalar DateTime\n")
        defn = make_def("full_name")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_returns_empty_input_unchanged
        assert_equal [], refiner.refine([])
      end

      # ---- #60: directory scoping ------------------------------------------

      def test_field_is_scoped_to_its_schema_directory_subtree
        # A schema under packs/a/ keeps a resolver defined under packs/a/ alive, but not a
        # same-named method defined in an unrelated directory (packs/b/).
        write_graphql("packs/a/schema.graphql", "type User { fullName: String }\n")
        in_a = make_def("full_name", owner: "TypeA", path: "packs/a/resolver.rb")
        in_b = make_def("full_name", owner: "TypeB", path: "packs/b/resolver.rb")

        refined = refiner.refine([in_a, in_b])

        refute_includes refined, in_a, "resolver under the schema's directory should be kept alive"
        assert_includes refined, in_b, "same-named method in an unrelated directory should not leak"
      end

      def test_generic_field_name_does_not_leak_across_subgraphs
        # Generic names (id/name/status) are exactly what over-matched before scoping.
        write_graphql("packs/a/schema.graphql", "type User { name: String }\n")
        unrelated = make_def("name", path: "packs/b/widget.rb")
        assert_equal [unrelated], refiner.refine([unrelated])
      end

      # ---- #61: report mode (tag instead of exclude) -----------------------

      def test_report_mode_tags_kept_by_instead_of_removing
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        defn = make_def("full_name")

        refined = GraphqlRefiner.new(@dir, mode: :report).refine([defn])

        assert_equal [defn], refined, "report mode keeps the candidate"
        assert_equal :graphql_sdl, defn.kept_by
      end

      def test_report_mode_leaves_unmatched_candidate_untagged
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String }\n")
        defn = make_def("genuinely_dead")

        refined = GraphqlRefiner.new(@dir, mode: :report).refine([defn])

        assert_equal [defn], refined
        assert_nil defn.kept_by
      end

      # ---- integration: fixture .graphql + Ruby resolver --------------------

      def test_full_pipeline_keeps_resolver_method_alive
        write_graphql("app/graphql/schema.graphql", <<~GQL)
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
        write_graphql("app/graphql/schema.graphql", "type User { fullName: String! }\n")
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
