# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class FileFinderSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write(rel, content = "x")
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end

      def find(globs, **opts)
        FileFinder.find(@dir, globs, **opts)
      end

      def test_finds_matching_files_via_glob_fallback
        a = write("app/a.erb")
        write("app/b.txt")
        assert_equal [a], find(["**/*.erb"])
      end

      def test_honors_multiple_globs
        a = write("a.yml")
        b = write("b.yaml")
        assert_equal [a, b].sort, find(["**/*.yml", "**/*.yaml"]).sort
      end

      def test_excludes_configured_directories_on_glob_path
        write("vendor/x/dep.erb")
        keep = write("app/keep.erb")
        assert_equal [keep], find(["**/*.erb"], exclude_dirs: ["vendor"])
      end

      def test_discovers_tracked_files_via_git
        a = write("app/a.erb")
        system("git", "-C", @dir, "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "-C", @dir, "add", "-A", out: File::NULL, err: File::NULL)
        assert_equal [a], find(["**/*.erb"])
      end

      def test_git_path_ignores_untracked_files
        tracked = write("app/tracked.erb")
        system("git", "-C", @dir, "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "-C", @dir, "add", "app/tracked.erb", out: File::NULL, err: File::NULL)
        write("app/untracked.erb")
        assert_equal [tracked], find(["**/*.erb"])
      end

      def test_falls_back_to_glob_when_git_cannot_be_spawned
        a = write("app/a.erb")
        IO.stub(:popen, ->(*) { raise StandardError, "git not found" }) do
          assert_equal [a], find(["**/*.erb"])
        end
      end

      def test_returns_empty_when_nothing_matches
        assert_empty find(["**/*.erb"])
      end
    end
  end
end
