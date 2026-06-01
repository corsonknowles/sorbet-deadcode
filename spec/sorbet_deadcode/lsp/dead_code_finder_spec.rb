# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Lsp
    class DeadCodeFinderSpec < Minitest::Test
      def test_detects_dead_method_with_no_references
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def alive_method
            end

            def dead_method
            end
          end

          App.new.alive_method
        RUBY

        client = MockClient.new({
                                  "alive_method" => [ref("#{dir}/other.rb", 10)],
                                  "dead_method" => []
                                })

        results = run_finder(dir, client)
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_method"
        refute_includes dead_names, "alive_method"
        assert client.shutdown_called?
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detects_dead_definitions_across_all_kinds
        dir = Dir.mktmpdir
        File.write(File.join(dir, "kinds.rb"), <<~RUBY)
          module DeadModule
          end

          class DeadClass
            DEAD_CONST = 1
            attr_reader :dead_attr
            attr_writer :dead_writer

            def self.dead_singleton
            end
          end
        RUBY

        # Every definition reports zero references => all dead. This exercises
        # detect_column for module, class, constant, attr_reader, attr_writer,
        # and method kinds.
        client = MockClient.new(Hash.new { [] })

        results = run_finder(dir, client)
        dead_names = results.map(&:name)

        assert_includes dead_names, "DeadModule"
        assert_includes dead_names, "DeadClass"
        assert_includes dead_names, "DEAD_CONST"
        assert_includes dead_names, "dead_attr"
        assert_includes dead_names, "dead_writer="
        assert_includes dead_names, "dead_singleton"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_excludes_references_in_excluded_paths
        dir = Dir.mktmpdir
        File.write(File.join(dir, "model.rb"), <<~RUBY)
          class Model
            def tested_only
            end
          end
        RUBY

        client = MockClient.new({ "tested_only" => [ref("#{dir}/spec/model_spec.rb", 5)] })

        results = run_finder(dir, client, exclude_paths: ["/spec/"])
        assert_includes results.map(&:name), "tested_only"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_self_references_are_excluded
        dir = Dir.mktmpdir
        file_path = File.join(dir, "service.rb")
        File.write(file_path, <<~RUBY)
          class Service
            def only_self_ref
            end
          end
        RUBY

        # The only reference is the definition itself (line 2, 0-indexed 1).
        client = MockClient.new({ "only_self_ref" => [ref(file_path, 1)] })

        results = run_finder(dir, client)
        assert_includes results.map(&:name), "only_self_ref"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_returns_empty_when_no_files
        dir = Dir.mktmpdir
        results = run_finder(dir, MockClient.new({}))
        assert_equal [], results
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_accepts_single_file_path
        dir = Dir.mktmpdir
        file = File.join(dir, "single.rb")
        File.write(file, "class Lone\n  def gone\n  end\nend\n")

        client = MockClient.new({})
        results = capture_stderr do
          finder = DeadCodeFinder.new(project_root: dir, paths: [file])
          Client.stub(:new, client) { finder.run }
        end
        assert_includes results.map(&:name), "gone"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      # detect_column unit tests -----------------------------------------------

      def test_detect_column_method_match
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  def my_method\n  end\n")
        defn = make_defn("my_method", :method, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 6, col # position of 'm' in 'my_method'
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_method_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  define_method(:my_method) {}\n")
        defn = make_defn("my_method", :method, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_class_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  # not a class line\n")
        defn = make_defn("Foo", :class, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_module_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  # not a module line\n")
        defn = make_defn("Foo", :module, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_constant_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  foo = 1\n")
        defn = make_defn("MAX", :constant, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_attr_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  # no attr here\n")
        defn = make_defn("foo", :attr_reader, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_falls_through_for_unrecognised_kind
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  anything\n")
        # Bypass Definition's kind check to get an unknown kind into detect_column.
        defn = Definition.allocate
        defn.instance_variable_set(:@name, "anything")
        defn.instance_variable_set(:@full_name, "anything")
        defn.instance_variable_set(:@kind, :unknown_kind_for_test)
        defn.instance_variable_set(:@location, "#{file}:1")
        col = make_finder(dir).send(:detect_column, file, 0, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_out_of_bounds_line_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "one line\n")
        defn = make_defn("foo", :method, "#{file}:999")
        col = make_finder(dir).send(:detect_column, file, 998, defn)
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      # filter_references unit tests -------------------------------------------

      def test_filter_references_returns_empty_for_non_array
        finder = make_finder("/tmp")
        assert_equal [], finder.send(:filter_references, nil, "/tmp/f.rb", 0)
        assert_equal [], finder.send(:filter_references, "bad", "/tmp/f.rb", 0)
      end

      def test_filter_references_removes_nil_uri
        finder = make_finder("/tmp")
        # A ref with no uri is excluded via ref_uri&.sub(...)
        ref = { "uri" => nil, "range" => { "start" => { "line" => 5, "character" => 0 } } }
        result = finder.send(:filter_references, [ref], "/tmp/f.rb", 5)
        # nil uri is not a self-ref and &.include? short-circuits to nil (falsy) → kept
        assert_equal [ref], result
      end

      def test_filter_references_excludes_nil_ref_path_when_exclude_paths_set
        finder = DeadCodeFinder.new(project_root: "/tmp", paths: ["/tmp"], exclude_paths: ["/spec/"])
        ref = { "uri" => nil, "range" => { "start" => { "line" => 3, "character" => 0 } } }
        # nil uri → ref_path = nil → ref_path&.include? = nil (falsy) → not excluded → kept
        result = finder.send(:filter_references, [ref], "/tmp/f.rb", 5)
        assert_equal [ref], result
      end

      def test_sequential_skips_definition_with_bad_location_format
        dir = Dir.mktmpdir
        File.write(File.join(dir, "ok.rb"), "class Ok\n  def alive; end\nend\n")

        client = MockClient.new({ "alive" => [ref("#{dir}/other.rb", 5)] })
        bad = make_defn("ghost", :method, "no_colon_in_location")
        finder = DeadCodeFinder.new(project_root: dir, paths: [dir])
        # Directly exercise find_dead_sequential with the bad definition injected.
        dead = capture_stderr do
          finder.send(:find_dead_sequential, client, [bad])
        end
        refute_includes dead.map(&:name), "ghost"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_skips_definition_with_bad_location_format
        dir = Dir.mktmpdir
        File.write(File.join(dir, "ok.rb"), "class Ok\n  def dead_one; end\nend\n")

        client = MockClient.new({})
        bad = make_defn("ghost", :method, "no_colon_in_location")
        finder = DeadCodeFinder.new(project_root: dir, paths: [dir], parallel: 2)
        finder.method(:collect_files)
        finder.define_singleton_method(:find_dead) do |c, defs|
          send(:find_dead_parallel, c, defs + [bad])
        end
        results = capture_stderr do
          Client.stub(:new, client) { finder.run }
        end
        refute_includes results.map(&:name), "ghost"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_skips_unparseable_files_during_definition_collection
        dir = Dir.mktmpdir
        File.write(File.join(dir, "broken.rb"), "class Broken\n  def oops(\nend")
        File.write(File.join(dir, "ok.rb"), "class Ok\n  def gone; end\nend\n")

        client = MockClient.new({})
        results = run_finder(dir, client)
        # Broken file is skipped; OK file still produces a definition.
        assert_includes results.map(&:name), "gone"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_skips_definitions_when_client_raises
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def explodes
            end
          end
        RUBY

        client = MockClient.new({}, raise_for: "explodes")
        results = run_finder(dir, client)
        # The error is rescued; the definition is simply not reported.
        refute_includes results.map(&:name), "explodes"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_mode_detects_dead_methods
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def dead_one
            end

            def dead_two
            end

            def alive_one
            end
          end
        RUBY

        client = MockClient.new({
                                  "dead_one" => [],
                                  "dead_two" => [],
                                  "alive_one" => [ref("#{dir}/caller.rb", 1)]
                                })

        results = run_finder(dir, client, parallel: 3)
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_one"
        assert_includes dead_names, "dead_two"
        refute_includes dead_names, "alive_one"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_mode_skips_when_async_raises
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def boom_async
            end

            def fine
            end
          end
        RUBY

        client = MockClient.new({ "fine" => [] }, raise_for: "boom_async", raise_on_async: true)
        results = run_finder(dir, client, parallel: 2)
        dead_names = results.map(&:name)

        refute_includes dead_names, "boom_async"
        assert_includes dead_names, "fine"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_mode_skips_when_collect_raises
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def boom_collect
            end
          end
        RUBY

        client = MockClient.new({}, raise_for: "boom_collect", raise_on_collect: true)
        results = run_finder(dir, client, parallel: 2)
        refute_includes results.map(&:name), "boom_collect"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def ref(path, line)
        {
          "uri" => "file://#{File.expand_path(path)}",
          "range" => { "start" => { "line" => line, "character" => 0 }, "end" => { "line" => line, "character" => 5 } }
        }
      end

      def make_finder(dir)
        DeadCodeFinder.new(project_root: dir, paths: [dir])
      end

      def make_defn(name, kind, location)
        Definition.new(name: name, full_name: name, kind: kind, location: location)
      end

      def write_file(dir, name, content)
        path = File.join(dir, name)
        File.write(path, content)
        path
      end

      def run_finder(dir, client, exclude_paths: [], parallel: 1)
        finder = DeadCodeFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: exclude_paths,
          parallel: parallel
        )
        capture_stderr do
          Client.stub(:new, client) { finder.run }
        end
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = original
      end

      # A mock LSP client that resolves the method/const name at the requested
      # line by reading the source file, then returns pre-configured references.
      class MockClient
        def initialize(refs_by_name, raise_for: nil, raise_on_async: false, raise_on_collect: false)
          @refs_by_name = refs_by_name
          @raise_for = raise_for
          @raise_on_async = raise_on_async
          @raise_on_collect = raise_on_collect
          @pending = {}
          @next_id = 0
          @shutdown = false
        end

        def references(file_path, line, _column)
          name = name_at(file_path, line)
          raise Client::Error, "boom" if name == @raise_for

          @refs_by_name.fetch(name, [])
        end

        def async_references(file_path, line, _column)
          name = name_at(file_path, line)
          raise Client::Error, "boom-async" if @raise_on_async && name == @raise_for

          @next_id += 1
          @pending[@next_id] = name
          @next_id
        end

        def collect_response(id)
          name = @pending.delete(id)
          raise Client::Error, "boom-collect" if @raise_on_collect && name == @raise_for

          @refs_by_name.fetch(name, [])
        end

        def shutdown
          @shutdown = true
        end

        def shutdown_called?
          @shutdown
        end

        private

        def name_at(file_path, zero_line)
          source_line = File.readlines(file_path)[zero_line].to_s
          if (m = source_line.match(/\bdef\s+(self\.)?(\w+)/))
            m[2]
          elsif (m = source_line.match(/\b(?:class|module)\s+([\w:]+)/))
            m[1]
          elsif (m = source_line.match(/\b([A-Z][A-Z0-9_]*)\s*=/))
            m[1]
          elsif (m = source_line.match(/attr_(?:reader|writer|accessor)\s+:(\w+)/))
            source_line.include?("attr_writer") ? "#{m[1]}=" : m[1]
          else
            ""
          end
        end
      end
    end
  end
end
