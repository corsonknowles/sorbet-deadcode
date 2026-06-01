# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class RipgrepSpec < Minitest::Test
    def teardown
      Ripgrep.reset!
    end

    def test_available_is_true_when_rg_runs
      Ripgrep.reset!
      # rg is installed in CI and dev; this should be true.
      assert Ripgrep.available?
    end

    def test_available_is_memoized
      Ripgrep.reset!
      first = Ripgrep.available?
      # Stub system to blow up; memoized value should be returned without re-invoking.
      Ripgrep.stub(:system, ->(*) { raise "should not be called" }) do
        assert_equal first, Ripgrep.available?
      end
    end

    def test_available_false_when_rg_missing
      Ripgrep.reset!
      Ripgrep.stub(:system, false) do
        refute Ripgrep.available?
      end
    end

    def test_available_false_on_error
      Ripgrep.reset!
      Ripgrep.stub(:system, ->(*) { raise Errno::ENOENT }) do
        refute Ripgrep.available?
      end
    end

    def test_glob_pattern_passes_through_explicit_glob
      assert_equal "**/spec/**", Ripgrep.glob_pattern("**/spec/**")
    end

    def test_glob_pattern_wraps_plain_path
      assert_equal "**/spec/**", Ripgrep.glob_pattern("spec/")
    end

    def test_partition_by_predicate_splits_normal_from_predicate_names
      normal, special = Ripgrep.partition_by_predicate(%w[plain valid? danger! attr=])
      assert_equal %w[plain], normal
      assert_equal %w[valid? danger! attr=], special
    end

    def test_search_is_a_noop_for_empty_names
      yielded = false
      Ripgrep.search([], project_root: Dir.pwd) { yielded = true }
      refute yielded
    end

    def test_search_yields_matches_and_honors_excludes
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "live.rb"), "widget_count\nvalid?\n")
        File.write(File.join(dir, "ignored.rb"), "widget_count\n")

        # Bare matches (no filename): both normal and predicate names are found,
        # and the excluded file's occurrence is dropped.
        counts = Hash.new(0)
        Ripgrep.search(%w[widget_count valid?], project_root: dir, exclude_paths: ["ignored.rb"]) do |line|
          counts[line.strip] += 1
        end
        assert_equal 1, counts["widget_count"]
        assert_equal 1, counts["valid?"]

        # with_filename: true emits `path:match` lines.
        with_path = []
        Ripgrep.search(%w[widget_count], project_root: dir, with_filename: true) { |l| with_path << l.rstrip }
        assert(with_path.all? { |l| l.include?(":widget_count") })
      end
    end
  end
end
