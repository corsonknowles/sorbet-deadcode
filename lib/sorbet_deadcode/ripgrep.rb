# frozen_string_literal: true

module SorbetDeadcode
  # Small helpers around the external ripgrep (`rg`) binary, which the verifier and
  # classifier depend on. Centralizes the availability check so callers can degrade
  # gracefully when `rg` is not installed (relevant now that --verify is the default).
  module Ripgrep
    class << self
      # True if the `rg` executable is on PATH and runnable.
      def available?
        return @available unless @available.nil?

        @available = system("rg", "--version", out: File::NULL, err: File::NULL) || false
      rescue StandardError
        @available = false
      end

      # Test seam: reset the memoized availability check.
      def reset!
        @available = nil
      end
    end
  end
end
