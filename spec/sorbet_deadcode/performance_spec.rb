# frozen_string_literal: true

require_relative "../spec_helper"

# Regression guard for the O(1) liveness analysis. The original O(N*M) approach
# hung for hours on a 46K-file repo; the hash-indexed implementation runs in ~80s.
# This test ensures the algorithm stays fast on a synthetic codebase at scale.
class PerformanceSpec < Minitest::Test
  # Generate a synthetic codebase with `class_count` classes, each having
  # `methods_per_class` methods. Half the methods are called from a caller file.
  def build_synthetic_codebase(dir, class_count:, methods_per_class:)
    class_count.times do |i|
      class_name = "Klass#{i}"
      methods = methods_per_class.times.map do |j|
        "  def method_#{j}; end"
      end.join("\n")

      File.write(File.join(dir, "klass_#{i}.rb"), <<~RUBY)
        class #{class_name}
        #{methods}
        end
      RUBY
    end

    # Caller file references half the methods in each class
    callers = class_count.times.flat_map do |i|
      (methods_per_class / 2).times.map { |j| "Klass#{i}.new.method_#{j}" }
    end.join("\n")

    File.write(File.join(dir, "caller.rb"), callers)
  end

  def test_liveness_analysis_scales_linearly
    dir = Dir.mktmpdir

    # 50 classes × 20 methods = 1000 definitions, 500 callers — representative
    # of a mid-size pack. Should complete well under 5 seconds on any modern CPU.
    build_synthetic_codebase(dir, class_count: 50, methods_per_class: 20)

    elapsed = Benchmark.realtime do
      SorbetDeadcode.analyze(dir)
    end

    assert elapsed < 5.0,
      "Liveness analysis took #{elapsed.round(2)}s on 1000 definitions — " \
      "expected < 5s. Possible O(N²) regression."
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_dead_code_count_is_correct_on_synthetic_codebase
    dir = Dir.mktmpdir
    build_synthetic_codebase(dir, class_count: 10, methods_per_class: 10)

    results = SorbetDeadcode.analyze(dir)
    dead_names = results.map(&:name)

    # method_0..method_4 are called, method_5..method_9 are dead
    refute_includes dead_names, "method_0"
    refute_includes dead_names, "method_4"
    assert_includes dead_names, "method_5"
    assert_includes dead_names, "method_9"
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
