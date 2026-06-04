# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Verifier
    class SorbetVerifierSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write(rel, contents)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
        path
      end

      def defn(name, path, kind: :method)
        Definition.new(name: name, full_name: "Foo##{name}", kind: kind,
                       location: "#{path}:1", owner_name: "Foo")
      end

      # A typechecker stub returning a fixed [clean?, output] sequence per call.
      def typechecker(*results)
        queue = results.dup
        ->() { queue.shift }
      end

      def test_empty_candidates_short_circuits
        called = false
        verifier = SorbetVerifier.new(project_root: @dir, remover: ->(_) { called = true }, typechecker: -> { [true, ""] })

        assert_empty verifier.verify([])
        refute called, "should not typecheck or remove when there are no candidates"
      end

      def test_dirty_baseline_skips_verification
        path = write("foo.rb", "class Foo\n  def bar; end\nend\n")
        removed = false
        verifier = SorbetVerifier.new(
          project_root: @dir,
          remover: ->(_) { removed = true },
          typechecker: typechecker([false, "baseline error"]),
        )

        candidates = [defn("bar", path)]
        assert_equal candidates, verifier.verify(candidates)
        refute removed, "must not edit files when the baseline is dirty"
      end

      def test_clean_after_removal_confirms_all
        path = write("foo.rb", "class Foo\n  def bar; end\nend\n")
        verifier = SorbetVerifier.new(
          project_root: @dir,
          remover: ->(_) { File.write(path, "class Foo\nend\n") },
          typechecker: typechecker([true, ""], [true, ""]), # baseline clean, post-removal clean
        )

        candidates = [defn("bar", path)]
        assert_equal candidates, verifier.verify(candidates)
        assert_equal "class Foo\n  def bar; end\nend\n", File.read(path), "tree restored"
      end

      def test_error_drops_only_the_mentioned_candidate
        path = write("foo.rb", "class Foo\n  def used; end\n  def dead; end\nend\n")
        verifier = SorbetVerifier.new(
          project_root: @dir,
          remover: ->(_) { File.write(path, "class Foo\nend\n") },
          # baseline clean; post-removal errors mention `used` (still referenced) but not `dead`.
          typechecker: typechecker([true, ""], [false, "test.rb:9: Method `used` does not exist"]),
        )

        confirmed = verifier.verify([defn("used", path), defn("dead", path)]).map(&:name)
        assert_equal ["dead"], confirmed
        assert_equal "class Foo\n  def used; end\n  def dead; end\nend\n", File.read(path), "tree restored"
      end

      def test_tree_restored_even_when_typecheck_raises
        path = write("foo.rb", "class Foo\n  def bar; end\nend\n")
        original = File.read(path)
        boom = lambda do
          @calls = (@calls || 0) + 1
          return [true, ""] if @calls == 1 # baseline ok

          raise "typecheck blew up"
        end
        verifier = SorbetVerifier.new(project_root: @dir, remover: ->(_) { File.write(path, "") }, typechecker: boom)

        assert_raises(RuntimeError) { verifier.verify([defn("bar", path)]) }
        assert_equal original, File.read(path), "ensure block restores the tree on error"
      end
    end
  end
end
