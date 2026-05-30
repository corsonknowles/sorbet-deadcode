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

        mock_client = MockClient.new({
          # alive_method at line 2 (0-indexed: 1), returns a reference
          [1, "alive_method"] => [
            { "uri" => "file://#{dir}/other.rb", "range" => { "start" => { "line" => 10, "character" => 0 }, "end" => { "line" => 10, "character" => 12 } } },
          ],
          # dead_method at line 5 (0-indexed: 4), returns nothing
          [4, "dead_method"] => [],
        })

        finder = build_finder(dir, mock_client)
        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "dead_method"
        refute_includes dead_names, "alive_method"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_detects_dead_class_with_no_references
        dir = Dir.mktmpdir
        File.write(File.join(dir, "models.rb"), <<~RUBY)
          class UsedModel
          end

          class DeadModel
          end
        RUBY

        mock_client = MockClient.new({
          [0, "UsedModel"] => [
            { "uri" => "file://#{dir}/service.rb", "range" => { "start" => { "line" => 3, "character" => 0 }, "end" => { "line" => 3, "character" => 9 } } },
          ],
          [3, "DeadModel"] => [],
        })

        finder = build_finder(dir, mock_client)
        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "DeadModel"
        refute_includes dead_names, "UsedModel"
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

        spec_ref_uri = "file://#{dir}/spec/model_spec.rb"
        mock_client = MockClient.new({
          [1, "tested_only"] => [
            { "uri" => spec_ref_uri, "range" => { "start" => { "line" => 5, "character" => 0 }, "end" => { "line" => 5, "character" => 11 } } },
          ],
        })

        finder = build_finder(dir, mock_client, exclude_paths: ["/spec/"])
        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "tested_only"
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

        mock_client = MockClient.new({
          [1, "only_self_ref"] => [
            { "uri" => "file://#{file_path}", "range" => { "start" => { "line" => 1, "character" => 6 }, "end" => { "line" => 1, "character" => 19 } } },
          ],
        })

        finder = build_finder(dir, mock_client)
        results = capture_stderr { finder.run }
        dead_names = results.map(&:name)

        assert_includes dead_names, "only_self_ref"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_returns_empty_when_no_files
        dir = Dir.mktmpdir

        mock_client = MockClient.new({})
        finder = build_finder(dir, mock_client)
        results = capture_stderr { finder.run }

        assert_equal [], results
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      private

      def build_finder(dir, mock_client, exclude_paths: [])
        finder = DeadCodeFinder.new(
          project_root: dir,
          paths: [dir],
          exclude_paths: exclude_paths,
        )

        # Replace the client creation with our mock
        finder.define_singleton_method(:run) do
          files = send(:collect_files)
          definitions = send(:collect_definitions, files)

          if definitions.empty?
            $stderr.puts "No definitions found."
            return []
          end

          $stderr.puts "Found #{definitions.size} definitions to check."

          begin
            @dead_definitions = send(:find_dead, mock_client, definitions)
          ensure
            mock_client.shutdown
          end

          @dead_definitions
        end

        finder
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        result = yield
        result
      ensure
        $stderr = original
      end

      # A mock LSP client that returns pre-configured reference results
      class MockClient
        def initialize(reference_map)
          @reference_map = reference_map
          @shutdown_called = false
        end

        def references(file_path, line, column)
          @reference_map.each do |(expected_line, expected_name), refs|
            return refs if line == expected_line
          end
          []
        end

        def shutdown
          @shutdown_called = true
        end

        def shutdown_called?
          @shutdown_called
        end
      end
    end
  end
end
