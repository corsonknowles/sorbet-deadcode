# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class IndexSpec < Minitest::Test
    def make_def(name, kind: :method, location: "lib/foo.rb:1", owner_name: "Foo")
      Definition.new(name: name, full_name: "#{owner_name}##{name}", kind: kind,
                     location: location, owner_name: owner_name)
    end

    def test_to_json_and_load_round_trip
      defs = [make_def("dead_method"), make_def("FOO", kind: :constant)]
      index = Index.new(dead_definitions: defs, paths: ["lib/"], exclude_paths: ["/spec/"])

      json = index.to_json
      loaded = Index.load(json)

      assert_equal 2, loaded.dead_definitions.size
      assert_equal "dead_method", loaded.dead_definitions.first.name
      assert_equal :constant, loaded.dead_definitions.last.kind
      assert_equal ["lib/"], loaded.paths
    end

    def test_write_and_load_from_file
      dir = Dir.mktmpdir
      path = File.join(dir, "index.json")
      defs = [make_def("foo")]
      Index.new(dead_definitions: defs, paths: ["lib/"]).write(path)

      loaded = Index.load(path)
      assert_equal ["foo"], loaded.dead_definitions.map(&:name)
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    def test_filter_paths_keeps_matching
      defs = [
        make_def("in_lib", location: "/project/lib/foo.rb:1"),
        make_def("in_spec", location: "/project/spec/foo_spec.rb:1")
      ]
      index = Index.new(dead_definitions: defs, paths: ["/project"])
      filtered = index.filter_paths(["/project/lib"])

      assert_equal ["in_lib"], filtered.dead_definitions.map(&:name)
    end

    def test_for_paths_is_alias_for_filter_paths
      defs = [make_def("foo", location: "/a/foo.rb:1"), make_def("bar", location: "/b/bar.rb:1")]
      index = Index.new(dead_definitions: defs, paths: ["/"])
      assert_equal ["foo"], index.for_paths("/a").dead_definitions.map(&:name)
    end

    def test_intersect_keeps_shared_name_and_kind
      defs_a = [make_def("shared"), make_def("only_a")]
      defs_b = [make_def("shared"), make_def("only_b")]

      index_a = Index.new(dead_definitions: defs_a, paths: [])
      index_b = Index.new(dead_definitions: defs_b, paths: [])

      result = index_a.intersect(index_b)
      assert_equal ["shared"], result.dead_definitions.map(&:name)
    end

    def test_intersect_respects_kind
      method_def = make_def("foo", kind: :method)
      const_def  = make_def("foo", kind: :constant)

      index_a = Index.new(dead_definitions: [method_def], paths: [])
      index_b = Index.new(dead_definitions: [const_def], paths: [])

      assert_empty index_a.intersect(index_b).dead_definitions
    end

    def test_created_at_is_preserved_on_load
      defs = [make_def("foo")]
      index = Index.new(dead_definitions: defs, paths: [])
      loaded = Index.load(index.to_json)
      refute_nil loaded.created_at
    end

    def test_load_from_file_path
      dir = Dir.mktmpdir
      path = File.join(dir, "idx.json")
      Index.new(dead_definitions: [make_def("x")], paths: []).write(path)
      loaded = Index.load(path)
      assert_equal 1, loaded.dead_definitions.size
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end
end
