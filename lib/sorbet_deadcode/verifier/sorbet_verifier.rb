# frozen_string_literal: true

module SorbetDeadcode
  module Verifier
    # Type-checker oracle (issue #134). Static analysis can't fully resolve Ruby references, so a
    # small class of false positives slips through `safe_delete` (e.g. an unqualified call from a
    # nested class). In a Sorbet-typed repo, removing a still-referenced definition makes `srb tc`
    # error — so removing the candidates, typechecking, and dropping any candidate the type checker
    # complains about eliminates those FPs automatically.
    #
    # Safe by construction: it requires a CLEAN baseline typecheck (otherwise pre-existing errors
    # can't be attributed, so it warns and verifies nothing), snapshots the exact bytes of every
    # file it edits, and restores them in an `ensure` block regardless of outcome.
    #
    # The heavy collaborators are injected so the orchestration is unit-tested without Sorbet/Spoom:
    #   remover     — `call(candidates)` edits the working tree to remove the definitions.
    #   typechecker — `call` returns [clean? (Boolean), output (String)].
    class SorbetVerifier
      def initialize(project_root:, remover:, typechecker:)
        @project_root = File.expand_path(project_root)
        @remover = remover
        @typechecker = typechecker
      end

      # @param candidates [Array<Definition>] dead-code candidates to confirm
      # @return [Array<Definition>] candidates the type checker did NOT object to removing
      def verify(candidates)
        return candidates if candidates.empty?

        baseline_clean, = @typechecker.call
        unless baseline_clean
          $stderr.puts "[sorbet-deadcode] Sorbet typecheck is not clean before removal; skipping " \
                       "--verify-with-sorbet (can't attribute pre-existing errors). Fix `srb tc` first."
          return candidates
        end

        snapshot = snapshot_files(candidates)
        begin
          @remover.call(candidates)
          clean, output = @typechecker.call
          return candidates if clean

          confirmed = candidates.reject { |candidate| mentioned_in_errors?(output, candidate) }
          $stderr.puts "[sorbet-deadcode] Sorbet rejected #{candidates.size - confirmed.size} candidate(s) " \
                       "as still-referenced; #{confirmed.size} confirmed dead."
          confirmed
        ensure
          snapshot.each { |file, contents| File.write(file, contents) }
        end
      end

      private

      # Exact-byte snapshot of every existing file a candidate is defined in, so the working tree
      # can be restored after the trial removal.
      def snapshot_files(candidates)
        candidates.map { |candidate| File.expand_path(candidate.file.to_s) }
                  .uniq
                  .select { |path| File.file?(path) }
                  .to_h { |path| [path, File.read(path)] }
      end

      # A candidate is still referenced if the type checker names it after removal. Sorbet quotes
      # the missing method/constant in backticks (e.g. "Method `foo` does not exist"); matching the
      # backtick-wrapped name is conservative — a coincidental mention only keeps a candidate alive.
      def mentioned_in_errors?(output, candidate)
        output.include?("`#{candidate.name}`")
      end
    end
  end
end
