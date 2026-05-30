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

        by_name = candidates.group_by(&:name)
        pattern_file = write_pattern_file(by_name.keys)

        $stderr.puts "[sorbet-deadcode] Verifying #{candidates.size} candidates (#{by_name.size} unique names) with ripgrep..."

        ref_counts = run_ripgrep(pattern_file)

        verified = candidates.select { |defn| truly_dead?(defn, ref_counts) }
        $stderr.puts "[sorbet-deadcode] #{verified.size}/#{candidates.size} candidates confirmed dead."
        verified
      ensure
        File.delete(pattern_file) if pattern_file && File.exist?(pattern_file)
      end

      private

      def write_pattern_file(names)
        file = Tempfile.new(["sorbet_deadcode_patterns", ".txt"])
        file.write(names.join("\n") + "\n")
        file.close
        file.path
      end

      def run_ripgrep(pattern_file)
        cmd = build_rg_command(pattern_file)

        counts = Hash.new(0)
        IO.popen(cmd, err: File::NULL) do |io|
          io.each_line { |line| counts[line.strip] += 1 }
        end
        counts
      end

      def build_rg_command(pattern_file)
        cmd = ["rg", "-f", pattern_file, "-w", "--no-filename", "-o"]
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
