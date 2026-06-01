# frozen_string_literal: true

require "shellwords"
require "fileutils"
require "tempfile"

module SorbetDeadcode
  module Verifier
    class RipgrepVerifier
      def initialize(project_root:, exclude_paths: [])
        @project_root = File.expand_path(project_root)
        @exclude_paths = exclude_paths
      end

      # Takes an array of Definition objects (dead code candidates).
      # Returns only the ones that are truly dead (no references found by rg).
      def verify(candidates)
        return [] if candidates.empty?

        unless Ripgrep.available?
          warn "[sorbet-deadcode] ripgrep (rg) not found — skipping verification. " \
               "Install ripgrep for fewer false positives, or pass --no-verify."
          return candidates
        end

        by_name = candidates.group_by(&:name)
        pattern_file = write_pattern_file(by_name.keys)

        warn "[sorbet-deadcode] Verifying #{candidates.size} candidates (#{by_name.size} unique names) with ripgrep..."

        ref_counts = run_ripgrep(pattern_file)

        verified = candidates.select { |defn| truly_dead?(defn, ref_counts) }
        warn "[sorbet-deadcode] #{verified.size}/#{candidates.size} candidates confirmed dead."
        verified
      ensure
        File.delete(pattern_file) if pattern_file && File.exist?(pattern_file)
      end

      private

      def write_pattern_file(names)
        file = Tempfile.new(["sorbet_deadcode_patterns", ".txt"])
        file.write("#{names.join("\n")}\n")
        file.close
        file.path
      end

      def run_ripgrep(pattern_file)
        # Split patterns into two groups and run each exactly once:
        # - Normal names (no trailing ?/!/=): use -w (word boundaries) for precision
        # - Special names ending in ?/!/=: -w breaks them because \b won't match
        #   after a non-word character; use exact -F literal matching instead.
        names = File.read(pattern_file).lines.map(&:chomp).reject(&:empty?)
        normal, special = names.partition { |n| !n.match?(/[?!=]$/) }

        counts = Hash.new(0)
        run_with_pattern_list(normal, word_bounded: true, counts: counts)
        run_with_pattern_list(special, word_bounded: false, counts: counts)
        counts
      end

      def run_with_pattern_list(names, word_bounded:, counts:)
        return if names.empty?

        tmp = write_pattern_file(names)
        begin
          cmd = build_rg_command(tmp, word_bounded: word_bounded)
          IO.popen(cmd, err: File::NULL) do |io|
            io.each_line { |line| counts[line.strip] += 1 }
          end
        ensure
          File.delete(tmp) if tmp && File.exist?(tmp)
        end
      end

      def build_rg_command(pattern_file, word_bounded: true)
        cmd = ["rg", "-F", "-f", pattern_file, "--no-filename", "-o"]
        cmd << "-w" if word_bounded
        @exclude_paths.each { |ep| cmd += ["--glob", "!#{glob_pattern(ep)}"] }
        cmd << @project_root
        cmd
      end

      def glob_pattern(path)
        return path if path.include?("*")

        # Use ** to cross directory boundaries so "spec/" excludes nested paths
        "**/#{path}**"
      end

      def truly_dead?(defn, ref_counts)
        count = ref_counts[defn.name] || 0
        # 0 = rg didn't find the name at all (definition might use different syntax)
        # 1 = only the definition itself was found
        count <= 1
      end
    end
  end
end
