# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Git
    class HistorySpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
        git("init", "-q", "--initial-branch=main")
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      # Hermetic git env so global config can't interfere.
      def git(*args)
        env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL,
                "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@e.com",
                "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@e.com" }
        system(env, "git", "-C", @dir, *args, out: File::NULL, err: File::NULL)
      end

      def commit(rel, content, message)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        git("add", rel)
        git("commit", "-q", "-m", message)
        path
      end

      def defn(name, path)
        Definition.new(name: name, full_name: "Foo##{name}", kind: :method,
                       location: "#{path}:2", owner_name: "Foo")
      end

      def test_added_returns_introducing_commit
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")

        result = History.new(@dir).added(defn("bar", path))

        assert result
        assert_includes result, "Introduce bar"
        assert_match(/\A\h+ \d{4}-\d\d-\d\d /, result) # "<sha> <yyyy-mm-dd> <subject>"
      end

      def test_added_returns_nil_for_name_never_introduced
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")

        assert_nil History.new(@dir).added(defn("never_defined_here", path))
      end

      def test_added_returns_nil_outside_git_checkout
        Dir.mktmpdir do |non_git|
          path = File.join(non_git, "a.rb")
          File.write(path, "class Foo\n  def bar; end\nend\n")
          assert_nil History.new(non_git).added(defn("bar", path))
        end
      end

      def test_added_returns_nil_on_git_error
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")
        IO.stub(:popen, ->(*) { raise "boom" }) do
          assert_nil History.new(@dir).added(defn("bar", path))
        end
      end
    end
  end
end
