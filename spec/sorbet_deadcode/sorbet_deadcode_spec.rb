# frozen_string_literal: true

require_relative "../spec_helper"

class SorbetDeadcodeModuleSpec < Minitest::Test
  # A stand-in finder/analyzer whose #run returns a sentinel.
  class FakeRunner
    RESULT = [:sentinel].freeze

    def run
      RESULT
    end
  end

  def test_analyze_delegates_to_analyzer
    dir = Dir.mktmpdir
    File.write(File.join(dir, "a.rb"), "class A\n  def dead; end\nend\n")
    results = SorbetDeadcode.analyze(dir)
    assert_includes results.map(&:name), "dead"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_analyze_with_lsp_delegates_to_dead_code_finder
    SorbetDeadcode::Lsp::DeadCodeFinder.stub(:new, FakeRunner.new) do
      result = SorbetDeadcode.analyze_with_lsp(project_root: "/tmp", paths: ["/tmp"], parallel: 4)
      assert_equal FakeRunner::RESULT, result
    end
  end

  def test_analyze_hybrid_delegates_to_hybrid_finder
    SorbetDeadcode::Lsp::HybridFinder.stub(:new, FakeRunner.new) do
      result = SorbetDeadcode.analyze_hybrid(project_root: "/tmp", paths: ["/tmp"])
      assert_equal FakeRunner::RESULT, result
    end
  end

  def test_analyze_file_table_delegates_to_file_table_analyzer
    SorbetDeadcode::Sorbet::FileTableAnalyzer.stub(:new, FakeRunner.new) do
      result = SorbetDeadcode.analyze_file_table(project_root: "/tmp", paths: ["/tmp"])
      assert_equal FakeRunner::RESULT, result
    end
  end

  def test_analyze_and_refine_applies_refiners
    SorbetDeadcode::Lsp::DeadCodeFinder.stub(:new, FakeRunner.new) do
      applied = false
      stub_refiner = Object.new
      stub_refiner.define_singleton_method(:refine) do |c|
        applied = true
        c
      end
      SorbetDeadcode.analyze_and_refine(paths: ["."], refiners: [stub_refiner])
      assert applied
    end
  end

  def test_analyze_and_verify_runs_verifier
    dir = Dir.mktmpdir
    File.write(File.join(dir, "a.rb"), "class A\n  def lonely_method; end\nend\n")
    results = SorbetDeadcode.analyze_and_verify(paths: [dir], project_root: dir)
    assert_includes results.map(&:name), "lonely_method"
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
