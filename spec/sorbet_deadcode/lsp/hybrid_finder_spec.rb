# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Lsp
    class HybridFinderSpec < Minitest::Test
      def test_validates_prism_candidates_with_lsp
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def alive_method
              dead_method
            end

            def dead_method
            end

            def truly_dead
            end
          end

          App.new.alive_method
        RUBY

        client = MockClient.new({ "truly_dead" => [] })

        results = run_finder(dir, client)
        dead_names = results.map(&:name)

        assert_includes dead_names, "truly_dead"
        refute_includes dead_names, "alive_method"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_removes_false_positives_via_lsp
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def looks_dead
            end

            def truly_dead
            end
          end
        RUBY

        client = MockClient.new({
          "looks_dead" => [ref("#{dir}/other.rb", 10)],
          "truly_dead" => [],
        })

        results = run_finder(dir, client)
        dead_names = results.map(&:name)

        refute_includes dead_names, "looks_dead"
        assert_includes dead_names, "truly_dead"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_excludes_spec_references_from_lsp_validation
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

      def test_returns_empty_when_prism_finds_no_candidates
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def used
            end
          end

          App.new.used
        RUBY

        results = capture_stderr do
          HybridFinder.new(project_root: dir, paths: [dir], exclude_paths: []).run
        end
        assert_equal [], results
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_validation_works
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def dead_one
            end

            def dead_two
            end

            def alive_via_lsp
            end
          end
        RUBY

        client = MockClient.new({
          "dead_one" => [],
          "dead_two" => [],
          "alive_via_lsp" => [ref("#{dir}/caller.rb", 1)],
        })

        results = run_finder(dir, client, parallel: 3)
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_one"
        assert_includes dead_names, "dead_two"
        refute_includes dead_names, "alive_via_lsp"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_parallel_skips_candidate_with_unparseable_location
        dir = Dir.mktmpdir
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          class App
            def dead_real
            end
          end
        RUBY

        client = MockClient.new({ "dead_real" => [] })
        finder = HybridFinder.new(project_root: dir, paths: [dir], exclude_paths: [], parallel: 2)

        bad = Definition.new(name: "ghost", full_name: "App#ghost", kind: :method, location: "nofile")
        real_pass = finder.method(:prism_pass)
        finder.define_singleton_method(:prism_pass) { real_pass.call + [bad] }

        results = capture_stderr { Client.stub(:new, client) { finder.run } }
        refute_includes results.map(&:name), "ghost"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      # detect_column tests — HybridFinder has its own copy of the method ------

      def test_detect_column_method_match
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  def my_method\n  end\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("my_method", :method, "#{file}:1"))
        assert_equal 6, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_method_self_dot
        dir = Dir.mktmpdir
        file = write_file(dir, "app.rb", "  def self.my_method\n  end\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("my_method", :method, "#{file}:1"))
        assert_equal 11, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_class_match
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "class Foo\nend\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("Foo", :class, "#{file}:1"))
        assert_equal 6, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_module_match
        dir = Dir.mktmpdir
        file = write_file(dir, "m.rb", "module Bar\nend\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("Bar", :module, "#{file}:1"))
        assert_equal 7, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_constant_match
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "MAX = 42\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("MAX", :constant, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_attr_reader_match
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "  attr_reader :name\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("name", :attr_reader, "#{file}:1"))
        assert_equal 14, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_attr_writer_match
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "  attr_writer :name\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("name=", :attr_writer, "#{file}:1"))
        assert_equal 14, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_method_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "a.rb", "  define_method(:foo) {}\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("foo", :method, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_class_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "  # no class here\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("Foo", :class, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_module_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "m.rb", "  # no module here\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("Foo", :module, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_constant_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "  # no constant here\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("MAX", :constant, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_attr_no_match_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "  # no attr\n")
        col = make_finder(dir).send(:detect_column, file, 0, make_defn("name", :attr_reader, "#{file}:1"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_out_of_bounds_returns_zero
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "one\n")
        col = make_finder(dir).send(:detect_column, file, 998, make_defn("foo", :method, "#{file}:999"))
        assert_equal 0, col
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detect_column_falls_through_for_unrecognised_kind
        dir = Dir.mktmpdir
        file = write_file(dir, "c.rb", "anything\n")
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

      # filter_references -------------------------------------------------------

      def test_filter_references_returns_empty_for_non_array
        finder = make_finder("/tmp")
        assert_equal [], finder.send(:filter_references, nil, make_defn("x", :method, "/tmp/f.rb:1"))
        assert_equal [], finder.send(:filter_references, "bad", make_defn("x", :method, "/tmp/f.rb:1"))
      end

      def test_filter_references_excludes_nil_ref_uri
        finder = make_finder("/tmp")
        ref_nil_uri = { "uri" => nil, "range" => { "start" => { "line" => 3, "character" => 0 } } }
        defn = make_defn("x", :method, "/tmp/f.rb:4")
        result = finder.send(:filter_references, [ref_nil_uri], defn)
        # nil uri is not a self-ref; &.include?(ep) is nil (falsy) → not excluded → kept
        assert_equal [ref_nil_uri], result
      end

      def test_filter_references_with_exclude_paths_and_nil_uri
        finder = HybridFinder.new(project_root: "/tmp", paths: ["/tmp"], exclude_paths: ["/spec/"])
        ref_nil_uri = { "uri" => nil, "range" => { "start" => { "line" => 3, "character" => 0 } } }
        defn = make_defn("x", :method, "/tmp/f.rb:4")
        result = finder.send(:filter_references, [ref_nil_uri], defn)
        # nil uri → ref_path nil → &.include? nil (falsy) → not excluded → kept
        assert_equal [ref_nil_uri], result
      end

      # send_reference_request with unparseable location -----------------------

      def test_send_reference_request_returns_nil_for_bad_location
        dir = Dir.mktmpdir
        File.write(File.join(dir, "x.rb"), "class X; end\n")
        bad_defn = make_defn("x", :method, "no_colon_here")
        result = make_finder(dir).send(:send_reference_request, Object.new, bad_defn)
        assert_nil result
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      # lsp_confirms_dead? with unparseable location ---------------------------

      def test_lsp_confirms_dead_returns_true_for_bad_location
        dir = Dir.mktmpdir
        File.write(File.join(dir, "x.rb"), "class X; end\n")
        bad_defn = make_defn("x", :method, "no_colon_here")
        result = make_finder(dir).send(:lsp_confirms_dead?, Object.new, bad_defn)
        assert result
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def ref(path, line)
        {
          "uri" => "file://#{File.expand_path(path)}",
          "range" => { "start" => { "line" => line, "character" => 0 }, "end" => { "line" => line, "character" => 5 } },
        }
      end

      def run_finder(dir, client, exclude_paths: [], parallel: 1)
        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: exclude_paths,
          parallel: parallel,
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

      def make_finder(dir)
        HybridFinder.new(project_root: dir, paths: [dir])
      end

      def make_defn(name, kind, location)
        Definition.new(name: name, full_name: name, kind: kind, location: location)
      end

      def write_file(dir, name, content)
        path = File.join(dir, name)
        File.write(path, content)
        path
      end

      class MockClient
        def initialize(refs_by_name)
          @refs_by_name = refs_by_name
          @pending = {}
          @next_id = 0
        end

        def references(file_path, line, _column)
          @refs_by_name.fetch(name_at(file_path, line), [])
        end

        def async_references(file_path, line, _column)
          @next_id += 1
          @pending[@next_id] = name_at(file_path, line)
          @next_id
        end

        def collect_response(id)
          @refs_by_name.fetch(@pending.delete(id), [])
        end

        def shutdown; end

        private

        def name_at(file_path, zero_line)
          source_line = File.readlines(file_path)[zero_line].to_s
          m = source_line.match(/\bdef\s+(self\.)?(\w+)/)
          m ? m[2] : ""
        end
      end
    end
  end
end
