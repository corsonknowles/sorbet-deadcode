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

        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
        )

        mock_client = MockLspClient.new({})
        stub_finder_with_mock_client(finder, mock_client)

        results = capture_stderr { finder.run }
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

        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
        )

        mock_client = MockLspClient.new(
          "looks_dead" => [
            { "uri" => "file://#{dir}/other.rb", "range" => { "start" => { "line" => 10, "character" => 0 }, "end" => { "line" => 10, "character" => 10 } } },
          ],
          "truly_dead" => [],
        )
        stub_finder_with_mock_client(finder, mock_client)

        results = capture_stderr { finder.run }
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

        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: ["/spec/"],
        )

        spec_ref = { "uri" => "file://#{dir}/spec/model_spec.rb", "range" => { "start" => { "line" => 5, "character" => 0 }, "end" => { "line" => 5, "character" => 11 } } }
        mock_client = MockLspClient.new("tested_only" => [spec_ref])
        stub_finder_with_mock_client(finder, mock_client)

        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "tested_only"
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

        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
        )

        results = capture_stderr { finder.run }
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

        finder = HybridFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: [],
          parallel: 3,
        )

        mock_client = MockAsyncLspClient.new(
          "alive_via_lsp" => [
            { "uri" => "file://#{dir}/caller.rb", "range" => { "start" => { "line" => 1, "character" => 0 }, "end" => { "line" => 1, "character" => 12 } } },
          ],
          "dead_one" => [],
          "dead_two" => [],
        )
        stub_finder_with_async_mock_client(finder, mock_client)

        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_one"
        assert_includes dead_names, "dead_two"
        refute_includes dead_names, "alive_via_lsp"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def stub_finder_with_mock_client(finder, mock_client)
        finder.define_singleton_method(:lsp_confirms_dead?) do |_client, defn|
          name = defn.name
          refs = mock_client.references_by_name(name)
          live_refs = send(:filter_references, refs, defn)
          live_refs.empty?
        end

        finder.define_singleton_method(:run) do
          candidates = send(:prism_pass)
          return [] if candidates.empty?

          $stderr.puts "Prism pass found #{candidates.size} candidates. Validating with LSP..."

          confirmed_dead = []
          candidates.each_with_index do |defn, index|
            $stderr.print "\rValidating candidates: #{index + 1}/#{candidates.size}"
            if send(:lsp_confirms_dead?, mock_client, defn)
              confirmed_dead << defn
            end
          end
          $stderr.puts

          @dead_definitions = confirmed_dead
        end
      end

      def stub_finder_with_async_mock_client(finder, mock_client)
        finder.define_singleton_method(:run) do
          candidates = send(:prism_pass)
          return [] if candidates.empty?

          $stderr.puts "Prism pass found #{candidates.size} candidates. Validating with LSP..."

          confirmed_dead = send(:lsp_validate, mock_client, candidates)
          @dead_definitions = confirmed_dead
        end
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        result = yield
        result
      ensure
        $stderr = original
      end

      class MockLspClient
        def initialize(name_to_refs)
          @name_to_refs = name_to_refs
        end

        def references(_file_path, _line, _column)
          []
        end

        def references_by_name(name)
          @name_to_refs.fetch(name, [])
        end

        def shutdown; end
      end

      class MockAsyncLspClient
        def initialize(name_to_refs)
          @name_to_refs = name_to_refs
          @pending = {}
          @next_id = 0
        end

        def async_references(file_path, line, column)
          @next_id += 1
          id = @next_id
          lines = File.readlines(file_path)
          source_line = lines[line]
          name = detect_name_at(source_line)
          @pending[id] = @name_to_refs.fetch(name, [])
          id
        end

        def collect_response(id)
          @pending.delete(id) || []
        end

        def shutdown; end

        private

        def detect_name_at(source_line)
          return "" unless source_line
          match = source_line&.match(/\bdef\s+(self\.)?(\w+)/)
          match ? match[2] : ""
        end
      end
    end
  end
end
