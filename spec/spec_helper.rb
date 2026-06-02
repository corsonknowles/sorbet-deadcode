# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :branch

  track_files "lib/**/*.rb"
  add_filter "/spec/"
  add_filter "/exe/"
  # version.rb is required by the gemspec at Bundler load time, before
  # SimpleCov starts, so it can never be tracked. It is a bare constant.
  add_filter "lib/sorbet_deadcode/version.rb"
  # The spoom runner only executes with a live spoom install against a real project context
  # (it can't run in the unit sandbox); its pure row->Index mapping is unit-tested via
  # Spoom::Converter. Integration is exercised manually / behind the optional spoom dep.
  add_filter "lib/sorbet_deadcode/spoom/runner.rb"
  # Same rationale for the spoom remover: it drives spoom's live Deadcode::Remover against real
  # files. Its pure location resolution (Spoom::NodeLocator) is unit-tested; end-to-end behavior
  # is covered by remover_integration_spec behind the optional spoom dep.
  add_filter "lib/sorbet_deadcode/spoom/remover.rb"

  # Line coverage is held at 100%. Branch coverage floor is 96%: the small
  # remainder are defensive parser-edge guards (e.g. `next unless node.is_a?(...)`
  # for Prism node shapes that don't occur in valid Ruby reached by our visitors).
  minimum_coverage line: 100, branch: 96
end

require "benchmark"
require "minitest/autorun"
require "minitest/mock"
require "sorbet_deadcode"

FIXTURES_PATH = File.expand_path("fixtures", __dir__)
