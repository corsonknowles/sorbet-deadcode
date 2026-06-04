# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"

module SorbetDeadcode
  module Spoom
    # Exercises the live Spoom::Remover against a real spoom install: it must resolve our
    # `file:line` definitions to exact node locations (via NodeLocator) and drive spoom's
    # syntax-aware Deadcode::Remover end to end. Skipped unless spoom is available; the
    # `spoom-integration` CI lane installs spoom so this runs there.
    class RemoverIntegrationSpec < Minitest::Test
      def setup
        require "spoom"
      rescue LoadError
        skip "spoom not installed (enable the spoom-integration lane with `bundle config with spoom`)"
      end

      def test_dry_run_reports_diff_without_writing
        with_file(<<~RUBY) do |dir, path|
          class Widget
            def used
              1
            end

            def dead_one
              2
            end
          end
        RUBY
          defn = Definition.new(name: "dead_one", full_name: "Widget#dead_one", kind: :method, location: "#{path}:6")
          results = Remover.remove([defn], project_root: dir, apply: false)

          assert_equal :would_remove, results.first.status
          assert_includes results.first.detail, "-  def dead_one"
          assert_includes File.read(path), "def dead_one", "dry run must not modify the file"
        end
      end

      def test_apply_removes_the_method
        with_file(<<~RUBY) do |dir, path|
          class Widget
            def used
              1
            end

            def dead_one
              2
            end
          end
        RUBY
          defn = Definition.new(name: "dead_one", full_name: "Widget#dead_one", kind: :method, location: "#{path}:6")
          results = Remover.remove([defn], project_root: dir, apply: true)

          assert_equal :removed, results.first.status
          source = File.read(path)
          refute_includes source, "def dead_one"
          assert_includes source, "def used", "must only remove the dead method"
        end
      end

      def test_skips_unsupported_kind_and_inline_member
        with_file("X = 1\n") do |dir, path|
          attr = Definition.new(name: "foo", full_name: "Widget#foo", kind: :attr_reader, location: "#{path}:1")
          inline = Definition.new(name: "CHILD", full_name: "PARENT::CHILD", kind: :constant,
                                  location: "#{path}:1", inline_member: true)

          results = Remover.remove([attr, inline], project_root: dir, apply: true)
          statuses = results.to_h { |r| [r.definition.name, r.status] }

          assert_equal :skipped, statuses["foo"]
          assert_equal :skipped, statuses["CHILD"]
        end
      end

      # Regression: spoom's remover over-deletes preceding siblings in a contiguous run of
      # trailing-comment constants. The RemovalGuard must catch this and refuse to apply, leaving
      # the live siblings (LIVE_A, LIVE_B) intact rather than silently deleting them.
      def test_refuses_removal_that_would_delete_live_siblings
        with_file(<<~RUBY) do |dir, path|
          module Vals
            LIVE_A = 'a' # note
            LIVE_B = 'b' # note
            DEAD_C = 'c' # note
          end
        RUBY
          defn = Definition.new(name: "DEAD_C", full_name: "Vals::DEAD_C", kind: :constant, location: "#{path}:4")
          results = Remover.remove([defn], project_root: dir, apply: true)

          source = File.read(path)
          if results.first.status == :removed
            # spoom removed precisely the target — guard correctly stayed out of the way.
            assert_includes source, "LIVE_A", "must not delete the live sibling"
            assert_includes source, "LIVE_B", "must not delete the live sibling"
            refute_includes source, "DEAD_C"
          else
            # spoom over-attached the siblings' comments → guard refused to apply (file unchanged).
            assert_equal :failed, results.first.status
            assert_includes results.first.detail, "would also delete"
            assert_includes source, "LIVE_A"
            assert_includes source, "LIVE_B"
            assert_includes source, "DEAD_C", "nothing written when the removal is refused"
          end
        end
      end

      private

      def with_file(contents)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "widget.rb")
          File.write(path, contents)
          yield dir, path
        end
      end
    end
  end
end
