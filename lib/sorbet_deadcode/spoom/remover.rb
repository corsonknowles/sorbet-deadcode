# frozen_string_literal: true

require "pathname"
require "tempfile"

module SorbetDeadcode
  module Spoom
    # Batch, tier-aware dead-code removal that LEVERAGES spoom's syntax-aware
    # Deadcode::Remover (it deletes the node plus its attached comments and Sorbet sigs)
    # instead of reimplementing ~600 lines of source editing. spoom is an OPTIONAL dependency,
    # required lazily here exactly like Spoom::Runner — users who never pass --remove don't need it.
    #
    # What we add on top of spoom's one-location-at-a-time `deadcode remove`:
    #   * remove every candidate in a confidence tier in a single pass,
    #   * a dry run by default (print a unified diff) with an explicit --apply to write,
    #   * resilient per-target handling (a location spoom can't remove is skipped + reported,
    #     never aborting the batch).
    # Combined with --spoom (which intersects our set with spoom's before classification),
    # `--remove safe_delete --spoom` removes only what both tools agree is dead.
    #
    # Excluded from unit coverage: it only runs against a live spoom install editing real files.
    # The pure location resolution it depends on (NodeLocator) is unit-tested.
    module Remover
      module_function

      # Kinds we hand to spoom today. attr_reader/attr_writer removal (symbol-node targeting,
      # sig rewriting, attr_accessor->reader/writer conversion) is supported by spoom but needs us
      # to resolve the exact symbol location first; deferred to a follow-up. inline-constant members
      # are skipped too: they can't be deleted without rewriting their enclosing literal.
      SUPPORTED_KINDS = %i[method class module constant].freeze

      # @!attribute definition [SorbetDeadcode::Definition]
      # @!attribute status [Symbol] :removed / :would_remove / :skipped / :failed
      # @!attribute detail [String] diff (dry run), path (applied), or reason (skipped/failed)
      Result = Struct.new(:definition, :status, :detail, keyword_init: true)

      # @param definitions [Array<SorbetDeadcode::Definition>] confirmed-dead candidates to remove
      # @param project_root [String] root the (relative) file paths and spoom Context resolve against
      # @param apply [Boolean] false (default) = dry run/diff only; true = write the edits
      # @return [Array<Result>] one Result per definition
      def remove(definitions, project_root: ".", apply: false)
        Runner.require_spoom!
        context = ::Spoom::Context.new(File.expand_path(project_root))

        # Within a file, process higher-line targets first so an edit never shifts the recorded
        # start line of a not-yet-processed (lower) target. We also re-read+re-parse per target,
        # so locations stay valid even when applying several edits to one file.
        definitions
          .sort_by { |definition| [definition.file.to_s, -(definition.line || 0)] }
          .map { |definition| remove_one(context, definition, apply: apply) }
      end

      def remove_one(context, definition, apply:)
        unless SUPPORTED_KINDS.include?(definition.kind)
          return result(definition, :skipped, "unsupported kind: #{definition.kind}")
        end
        if definition.inline_member
          return result(definition, :skipped, "inline constant member; edit the enclosing literal")
        end

        rel = relative_path(context, definition.file)
        return result(definition, :skipped, "file not found: #{rel}") unless context.file?(rel)

        source = context.read(rel)
        loc = NodeLocator.locate(source, kind: definition.kind, name: definition.name, line: definition.line)
        unless loc
          return result(definition, :skipped, "couldn't locate #{definition.kind} #{definition.name} at #{definition.location}")
        end

        location = ::Spoom::Location.new(
          rel,
          start_line: loc.start_line,
          start_column: loc.start_column,
          end_line: loc.end_line,
          end_column: loc.end_column,
        )
        new_source = ::Spoom::Deadcode::Remover.new(context).remove_location(nil, location)

        # Safety net: spoom's remover can over-delete preceding siblings when the target sits in a
        # contiguous run of trailing-comment lines (it mis-attaches their comments). Refuse to apply
        # a removal that would also delete a definition we didn't classify as dead. See RemovalGuard.
        collateral = RemovalGuard.collateral_definitions(
          source, new_source,
          target_full_name: definition.full_name,
          co_located_names: definition.co_located_names,
          file: rel,
        )
        unless collateral.empty?
          return result(definition, :failed,
                        "refused: removal would also delete #{collateral.join(', ')} " \
                        "(spoom over-attached adjacent comments); skipped to avoid removing live code")
        end

        if apply
          context.write!(rel, new_source)
          result(definition, :removed, rel)
        else
          result(definition, :would_remove, unified_diff(rel, source, new_source))
        end
      rescue ::Spoom::Error => e
        # Includes Remover::Error ("Unsupported node type", "Unexpected case ...") and
        # Location::LocationError. Skip the offending target, keep the batch going.
        result(definition, :failed, e.message)
      end

      # Path relative to the spoom Context root (spoom Context#read/#file?/#write! are all relative).
      # Definition#file is relative to the analysis cwd, so normalize via absolute paths.
      def relative_path(context, file)
        absolute = File.expand_path(file)
        Pathname.new(absolute).relative_path_from(Pathname.new(context.absolute_path)).to_s
      rescue ArgumentError
        file.to_s
      end

      # Unified diff without touching the working tree (unlike spoom's CLI, which writes a PATCH
      # file into the repo). Returns "" when nothing would change.
      def unified_diff(rel, old_source, new_source)
        return "" if old_source == new_source

        Tempfile.create("sd_old") do |old_file|
          Tempfile.create("sd_new") do |new_file|
            old_file.write(old_source)
            old_file.flush
            new_file.write(new_source)
            new_file.flush
            body = IO.popen(["diff", "-u", old_file.path, new_file.path], &:read).lines[2..] || []
            "--- a/#{rel}\n+++ b/#{rel}\n#{body.join}"
          end
        end
      end

      def result(definition, status, detail)
        Result.new(definition: definition, status: status, detail: detail)
      end
    end
  end
end
