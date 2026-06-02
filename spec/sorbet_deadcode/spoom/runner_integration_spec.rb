# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"

module SorbetDeadcode
  module Spoom
    # Exercises the live Spoom::Runner against a real spoom install, so any drift in spoom's
    # internal dead-code API (which the runner couples to) breaks CI immediately rather than
    # silently. Skipped unless spoom is available; the dedicated `spoom-integration` CI lane
    # installs spoom (`bundle config with spoom`) so this runs there.
    class RunnerIntegrationSpec < Minitest::Test
      def setup
        require "spoom"
      rescue LoadError
        skip "spoom not installed (enable the spoom-integration lane with `bundle config with spoom`)"
      end

      def test_runner_reports_dead_method_in_our_full_name_format
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "widget.rb"), <<~RUBY)
            class Widget
              def used
                helper
              end

              def helper
                1
              end

              def never_called
                2
              end
            end

            Widget.new.used
          RUBY

          index = Runner.dead_index([dir], project_root: dir)
          full_names = index.dead_definitions.map(&:full_name)

          # `never_called` is dead; spoom reports it as `Widget::never_called`, the runner must
          # normalize to our `Widget#never_called` so the intersection matches.
          assert_includes full_names, "Widget#never_called"
          refute_includes full_names, "Widget#used"
          refute_includes full_names, "Widget#helper"

          dead = index.dead_definitions.find { |d| d.full_name == "Widget#never_called" }
          assert_equal :method, dead.kind
        end
      end
    end
  end
end
