# frozen_string_literal: true

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
          $stderr.puts "[sorbet-deadcode] ripgrep (rg) not found — skipping verification. " \
                       "Install ripgrep for fewer false positives, or pass --no-verify."
          return candidates
        end

        by_name = candidates.group_by(&:name)
        $stderr.puts "[sorbet-deadcode] Verifying #{candidates.size} candidates (#{by_name.size} unique names) with ripgrep..."

        ref_counts = count_references(by_name.keys)

        verified = candidates.select { |defn| truly_dead?(defn, ref_counts) }
        $stderr.puts "[sorbet-deadcode] #{verified.size}/#{candidates.size} candidates confirmed dead."
        verified
      end

      private

      # name => total occurrences of the bare name across the project.
      def count_references(names)
        counts = Hash.new(0)
        Ripgrep.search(names, project_root: @project_root, exclude_paths: @exclude_paths) do |line|
          counts[line.strip] += 1
        end
        counts
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
