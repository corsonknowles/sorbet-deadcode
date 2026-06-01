# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Git
    class RecencySpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
        git("init", "-q", "--initial-branch=main")
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      # Hermetic git env so global config can't interfere (and supplies author/committer date).
      def git(*args, date: nil)
        env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL,
                "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@e.com",
                "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@e.com" }
        if date
          env["GIT_AUTHOR_DATE"] = date
          env["GIT_COMMITTER_DATE"] = date
        end
        system(env, "git", "-C", @dir, *args, out: File::NULL, err: File::NULL)
      end

      def commit(rel, content, date:)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        git("add", rel)
        git("commit", "-q", "-m", "add #{rel}", date: date)
        path
      end

      def defn(file, line)
        Definition.new(name: "x", full_name: "X#x", kind: :method, location: "#{file}:#{line}")
      end

      def recency(days = 30)
        Recency.new(@dir, days * 86_400)
      end

      def test_recently_committed_line_is_recent
        path = commit("a.rb", "class A\n  def x; end\nend\n", date: Time.now.iso8601)
        assert recency.recently_added?(defn(path, 2))
      end

      def test_old_line_is_not_recent
        path = commit("a.rb", "class A\n  def x; end\nend\n", date: "2020-01-01T00:00:00Z")
        refute recency.recently_added?(defn(path, 2))
      end

      def test_definition_without_line_is_not_recent
        assert_nil defn("symbol-table", nil).line
        refute recency.recently_added?(defn("symbol-table", nil))
      end

      def test_untracked_file_is_not_recent
        path = File.join(@dir, "untracked.rb")
        File.write(path, "class U; def x; end; end\n")
        refute recency.recently_added?(defn(path, 1))
      end

      def test_outside_git_checkout_is_not_recent
        Dir.mktmpdir do |non_git|
          path = File.join(non_git, "a.rb")
          File.write(path, "x\n")
          refute Recency.new(non_git, 30 * 86_400).recently_added?(defn(path, 1))
        end
      end

      def test_empty_git_output_is_not_recent
        r = recency
        r.stub(:git_line_log, "\n\n") do
          refute r.recently_added?(defn(File.join(@dir, "a.rb"), 1))
        end
      end

      def test_git_error_is_not_recent
        r = recency
        IO.stub(:popen, ->(*) { raise "boom" }) do
          refute r.recently_added?(defn(File.join(@dir, "a.rb"), 1))
        end
      end
    end
  end
end
