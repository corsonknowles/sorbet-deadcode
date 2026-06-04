# frozen_string_literal: true

require "prism"

module SorbetDeadcode
  module Spoom
    # Safety net around spoom's Deadcode::Remover, which can OVER-DELETE. When the target
    # definition sits in a contiguous run of trailing-comment lines (e.g. several
    # `CONST = value # note` lines with no blank separators), spoom mis-attaches the PRECEDING
    # siblings' trailing comments to the target node and deletes those siblings too — silently
    # removing live code while the classifier correctly kept it.
    #
    # (Found dogfooding a payments "constants" module: removing one dead `EXPECTED_RUNTIME_*`
    # constant also deleted three live siblings above it, which only surfaced as `srb tc`
    # "unable to resolve constant" errors after the fact.)
    #
    # collateral_definitions re-parses the before/after sources with the DefinitionCollector and
    # returns any definition that was removed but is NEITHER the target, NOR nested under it (the
    # members of a class/module we're intentionally deleting), NOR an inline member of the target.
    # Spoom::Remover refuses to apply (reports :failed) whenever this is non-empty, so a removal can
    # never silently take out a definition we didn't classify as dead.
    module RemovalGuard
      module_function

      # @param old_source [String] file contents before removal
      # @param new_source [String] contents spoom produced for removing `target_full_name`
      # @param target_full_name [String] full_name of the definition being removed
      # @param co_located_names [Array<String>] inline-constant member names removed with the target
      # @param file [String] path label for the collector (only used for location formatting)
      # @return [Array<String>] full_names removed beyond the intended target; empty when safe.
      def collateral_definitions(old_source, new_source, target_full_name:, co_located_names: [], file: "(removal)")
        removed = definition_full_names(file, old_source) - definition_full_names(file, new_source)
        removed.reject { |full_name| allowed?(full_name, target_full_name, co_located_names) }
      end

      def allowed?(full_name, target_full_name, co_located_names)
        # The target itself.
        return true if full_name == target_full_name
        # A member of a class/module we're intentionally removing (`Foo::Bar`, `Foo#baz`).
        return true if full_name.start_with?("#{target_full_name}::") || full_name.start_with?("#{target_full_name}#")

        # An inline-constant member deleted along with its enclosing literal (`PARENT = [CHILD = 1]`).
        co_located_names.include?(full_name.split("::").last)
      end

      def definition_full_names(file, source)
        collector = Collector::DefinitionCollector.new(file)
        collector.visit(Prism.parse(source).value)
        collector.definitions.map(&:full_name)
      end
    end
  end
end
