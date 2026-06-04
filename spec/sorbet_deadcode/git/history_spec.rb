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
        d = defn("bar", path)

        result = History.new(@dir).prepare([d]).added(d)

        assert result
        assert_includes result, "Introduce bar"
        assert_match(/\A\h+ \d{4}-\d\d-\d\d /, result) # "<sha> <yyyy-mm-dd> <subject>"
      end

      def test_prepare_batches_multiple_names_in_one_file
        # method_a introduced first, method_b in a later commit — one git pass attributes both.
        path = commit("app/foo.rb", "class Foo\n  def method_a; end\nend\n", "Add method_a")
        File.write(path, "class Foo\n  def method_a; end\n  def method_b; end\nend\n")
        git("add", "app/foo.rb")
        git("commit", "-q", "-m", "Add method_b")

        history = History.new(@dir).prepare([defn("method_a", path), defn("method_b", path)])

        assert_includes history.added(defn("method_a", path)), "Add method_a"
        assert_includes history.added(defn("method_b", path)), "Add method_b"
      end

      def test_added_returns_nil_for_name_never_introduced
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")
        d = defn("never_defined_here", path)

        assert_nil History.new(@dir).prepare([d]).added(d)
      end

      def test_added_returns_nil_when_not_prepared
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")

        assert_nil History.new(@dir).added(defn("bar", path))
      end

      def test_added_returns_nil_outside_git_checkout
        Dir.mktmpdir do |non_git|
          path = File.join(non_git, "a.rb")
          File.write(path, "class Foo\n  def bar; end\nend\n")
          d = defn("bar", path)
          assert_nil History.new(non_git).prepare([d]).added(d)
        end
      end

      def test_added_returns_nil_on_git_error
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Introduce bar")
        d = defn("bar", path)
        IO.stub(:popen, ->(*) { raise "boom" }) do
          assert_nil History.new(@dir).prepare([d]).added(d)
        end
      end

      # #135: dead_since is off unless explicitly enabled (it runs an expensive repo-wide pickaxe).
      def test_dead_since_disabled_by_default
        path = commit("app/foo.rb", "class Foo\n  def lonely_method; end\nend\n", "Add lonely_method")
        d = defn("lonely_method", path)

        history = nil
        capture_io { history = History.new(@dir).prepare([d]) }

        assert_nil history.dead_since(d)
      end

      # A name whose reference count never changed after introduction is dead-on-arrival.
      def test_dead_since_reports_dead_on_arrival
        path = commit("app/foo.rb", "class Foo\n  def lonely_method; end\nend\n", "Add lonely_method")
        d = defn("lonely_method", path)

        history = nil
        capture_io { history = History.new(@dir, dead_since: true).prepare([d]) }

        assert_includes history.dead_since(d), "dead-on-arrival"
        assert_includes history.dead_since(d), "Add lonely_method"
      end

      # A name that gained a caller and then lost it is "dead since" the caller-removing commit.
      def test_dead_since_reports_orphaning_commit
        path = commit("app/foo.rb", "class Foo\n  def orphaned_method; end\nend\n", "Add orphaned_method")
        commit("app/caller.rb", "Foo.new.orphaned_method\n", "Call orphaned_method")
        File.write(File.join(@dir, "app/caller.rb"), "# no more call\n")
        git("add", "app/caller.rb")
        git("commit", "-q", "-m", "Remove orphaned_method caller")
        d = defn("orphaned_method", path)

        history = nil
        capture_io { history = History.new(@dir, dead_since: true).prepare([d]) }

        assert_includes history.dead_since(d), "dead since"
        assert_includes history.dead_since(d), "Remove orphaned_method caller"
      end

      def test_dead_since_nil_when_name_never_appears
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Add bar")
        d = defn("name_that_never_appears", path)

        history = nil
        capture_io { history = History.new(@dir, dead_since: true).prepare([d]) }

        assert_nil history.dead_since(d)
      end

      def test_dead_since_nil_on_git_error
        path = commit("app/foo.rb", "class Foo\n  def bar; end\nend\n", "Add bar")
        d = defn("bar", path)

        history = nil
        capture_io do
          IO.stub(:popen, ->(*) { raise "boom" }) do
            history = History.new(@dir, dead_since: true).prepare([d])
          end
        end

        assert_nil history.dead_since(d)
      end

      # The expensive path warns loudly up front and prints live per-name progress.
      def test_dead_since_emits_cost_warning_and_progress
        path = commit("app/foo.rb", "class Foo\n  def lonely_method; end\nend\n", "Add lonely_method")
        d = defn("lonely_method", path)

        _out, err = capture_io { History.new(@dir, dead_since: true).prepare([d]) }

        assert_includes err, "REPO-WIDE git pickaxe"
        assert_includes err, "dead-since pickaxe 1/1: lonely_method"
      end
    end
  end
end
