# frozen_string_literal: true

require "prism"

require_relative "sorbet_deadcode/version"
require_relative "sorbet_deadcode/definition"
require_relative "sorbet_deadcode/reference"
require_relative "sorbet_deadcode/collector/definition_collector"
require_relative "sorbet_deadcode/collector/reference_collector"
require_relative "sorbet_deadcode/resolver/type_resolver"
require_relative "sorbet_deadcode/analyzer/dead_code_analyzer"

module SorbetDeadcode
  class Error < StandardError; end

  class << self
    def analyze(paths, exclude_paths: [])
      analyzer = Analyzer::DeadCodeAnalyzer.new(
        paths: paths,
        exclude_paths: exclude_paths,
      )
      analyzer.run
    end
  end
end
