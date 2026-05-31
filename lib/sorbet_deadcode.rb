# frozen_string_literal: true

require "prism"

require_relative "sorbet_deadcode/version"
require_relative "sorbet_deadcode/definition"
require_relative "sorbet_deadcode/reference"
require_relative "sorbet_deadcode/collector/definition_collector"
require_relative "sorbet_deadcode/collector/reference_collector"
require_relative "sorbet_deadcode/resolver/type_resolver"
require_relative "sorbet_deadcode/analyzer/dead_code_analyzer"
require_relative "sorbet_deadcode/analyzer/confidence"
require_relative "sorbet_deadcode/index"
require_relative "sorbet_deadcode/scanners/route_scanner"
require_relative "sorbet_deadcode/refiners/route_refiner"
require_relative "sorbet_deadcode/lsp/client"
require_relative "sorbet_deadcode/lsp/dead_code_finder"
require_relative "sorbet_deadcode/lsp/hybrid_finder"
require_relative "sorbet_deadcode/sorbet/file_table_analyzer"
require_relative "sorbet_deadcode/verifier/ripgrep_verifier"

module SorbetDeadcode
  class Error < StandardError; end

  class << self
    def analyze(paths, exclude_paths: [], reference_paths: nil, dynamic_dispatch: :exclude)
      analyzer = Analyzer::DeadCodeAnalyzer.new(
        paths: paths,
        exclude_paths: exclude_paths,
        reference_paths: reference_paths,
        dynamic_dispatch: dynamic_dispatch,
      )
      analyzer.run
    end

    # Run analysis and then apply a chain of second-pass refiners.
    # Refiners remove false positives from non-Ruby sources (routes, YAML, ERB).
    # Each refiner responds to #refine(candidates) → candidates.
    #
    # Example:
    #   SorbetDeadcode.analyze_and_refine(
    #     paths: ["app/"],
    #     refiners: [SorbetDeadcode::Refiners::RouteRefiner.new(".")]
    #   )
    def analyze_and_refine(paths:, exclude_paths: [], reference_paths: nil, refiners: [])
      candidates = analyze(paths, exclude_paths: exclude_paths, reference_paths: reference_paths)
      refiners.reduce(candidates) { |c, refiner| refiner.refine(c) }
    end

    def analyze_with_lsp(project_root:, paths:, exclude_paths: [], parallel: 1)
      finder = Lsp::DeadCodeFinder.new(
        project_root: project_root,
        paths: paths,
        exclude_paths: exclude_paths,
        parallel: parallel,
      )
      finder.run
    end

    def analyze_hybrid(project_root:, paths:, exclude_paths: [], parallel: 1)
      finder = Lsp::HybridFinder.new(
        project_root: project_root,
        paths: paths,
        exclude_paths: exclude_paths,
        parallel: parallel,
      )
      finder.run
    end

    def analyze_file_table(project_root:, paths:, exclude_paths: [])
      analyzer = Sorbet::FileTableAnalyzer.new(
        project_root: project_root,
        paths: paths,
        exclude_paths: exclude_paths,
      )
      analyzer.run
    end

    def analyze_and_verify(paths:, project_root: ".", exclude_paths: [])
      candidates = analyze(paths, exclude_paths: exclude_paths)
      verifier = Verifier::RipgrepVerifier.new(
        project_root: project_root,
        exclude_paths: exclude_paths,
      )
      verifier.verify(candidates)
    end
  end
end
