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
  end
end
