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
