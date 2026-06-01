# frozen_string_literal: true

require "tempfile"

module SorbetDeadcode
  # Helpers around the external ripgrep (`rg`) binary, which the verifier and
  # classifier both depend on. Centralizes the availability check plus the search
  # mechanics (exclude globs, predicate-name splitting, command construction) so the
  # two callers can't drift out of sync — the predicate-name fix in particular has to
  # be applied identically in both places to hold.
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

      # Glob passed to `rg --glob !<pattern>` to exclude a path. A literal path is
      # widened to a recursive "**/<path>**" so e.g. "spec/" also excludes nested
      # matches; a path that already contains "*" is used verbatim.
      def glob_pattern(path)
        return path if path.include?("*")

        "**/#{path}**"
      end

      # Candidate names ending in ?/!/= can't use rg's -w word boundaries (\b won't
      # match after a non-word character), so they must be matched as exact literals.
      # Returns [word_boundable, literal_only].
      def partition_by_predicate(names)
        names.partition { |n| !n.match?(/[?!=]$/) }
      end

      # Search `project_root` for literal occurrences of `names` (via `rg -F -o`),
      # yielding each output line. Runs the binary at most twice: once word-bounded
      # for normal names and once literal for predicate (?/!/=) names. Pass
      # with_filename: true to get `path:match` lines instead of bare matches.
      def search(names, project_root:, exclude_paths: [], with_filename: false, &block)
        return if names.empty?

        normal, special = partition_by_predicate(names)
        run(normal, word_bounded: true, project_root: project_root, exclude_paths: exclude_paths,
                    with_filename: with_filename, &block)
        run(special, word_bounded: false, project_root: project_root, exclude_paths: exclude_paths,
                     with_filename: with_filename, &block)
      end

      private

      def run(names, word_bounded:, project_root:, exclude_paths:, with_filename:, &block)
        return if names.empty?

        pattern_file = write_pattern_file(names)
        cmd = command(pattern_file, project_root: project_root, exclude_paths: exclude_paths,
                                    word_bounded: word_bounded, with_filename: with_filename)
        IO.popen(cmd, err: File::NULL) do |io|
          io.each_line(&block)
        end
      ensure
        File.delete(pattern_file) if pattern_file && File.exist?(pattern_file)
      end

      def command(pattern_file, project_root:, exclude_paths:, word_bounded:, with_filename:)
        cmd = ["rg", "-F", "-f", pattern_file, "-o"]
        cmd << (with_filename ? "--with-filename" : "--no-filename")
        cmd << "-w" if word_bounded
        exclude_paths.each { |ep| cmd += ["--glob", "!#{glob_pattern(ep)}"] }
        cmd << project_root
        cmd
      end

      def write_pattern_file(names)
        file = Tempfile.new(["sorbet_deadcode_rg", ".txt"])
        file.write(names.join("\n") + "\n")
        file.close
        file.path
      end
    end
  end
end
