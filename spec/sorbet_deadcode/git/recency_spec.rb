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

      def commit(rel, date:)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "class X\n  def m; end\nend\n")
        git("add", rel)
        git("commit", "-q", "-m", "add #{rel}", date: date)
        path
      end

      def defn(file)
        Definition.new(name: "m", full_name: "X#m", kind: :method, location: "#{file}:2")
      end

      def recency(days = 30)
        Recency.new(@dir, days * 86_400)
      end

      def test_file_added_recently_is_recent
        path = commit("recent.rb", date: Time.now.utc.iso8601)
        assert recency.recently_added?(defn(path))
      end

      def test_file_added_long_ago_is_not_recent
        path = commit("old.rb", date: "2020-01-01T00:00:00Z")
        refute recency.recently_added?(defn(path))
      end

      def test_definition_without_file_is_not_recent
        # location with no path component => file is "" / falsey-ish; guard returns false.
        d = Definition.new(name: "m", full_name: "X#m", kind: :method, location: "")
        refute recency.recently_added?(d)
      end

      def test_untracked_file_is_not_recent
        path = File.join(@dir, "untracked.rb")
        File.write(path, "x\n")
        refute recency.recently_added?(defn(path))
      end

      def test_outside_git_checkout_is_not_recent
        Dir.mktmpdir do |non_git|
          path = File.join(non_git, "a.rb")
          File.write(path, "x\n")
          refute Recency.new(non_git, 30 * 86_400).recently_added?(defn(path))
        end
      end

      def test_git_error_yields_empty_recent_set
        IO.stub(:popen, ->(*) { raise "boom" }) do
          r = Recency.new(@dir, 30 * 86_400)
          refute r.recently_added?(defn(File.join(@dir, "anything.rb")))
        end
      end
    end
  end
end
