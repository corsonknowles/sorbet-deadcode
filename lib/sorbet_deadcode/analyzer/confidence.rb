# frozen_string_literal: true

module SorbetDeadcode
  module Analyzer
    # Assigns a confidence tier to each dead code candidate based on how certain
    # we are that it is truly unreachable.
    #
    # :high   — type-aware analysis confirmed no callers (or ripgrep verified)
    # :medium — name-based fallback (untyped code); a matching name could exist elsewhere
    # :low    — the definition is in a class/module we have limited information about
    #           (no sigs, anonymous class, etc.)
    module Confidence
      HIGH = :high
      MEDIUM = :medium
      LOW = :low

      # Returns the confidence tier for a dead definition given the reference index.
      def self.for(definition, ref_index)
        case definition.kind
        when :class, :module
          # Classes/modules are checked via constant references — very reliable.
          HIGH
        when :constant
          HIGH
        when :method, :attr_reader, :attr_writer
          method_confidence(definition, ref_index)
        else
          LOW
        end
      end

      def self.method_confidence(definition, ref_index)
        return LOW unless definition.owner_name

        # If there were typed references for this name (matching other owners),
        # we can be confident this specific owner's method is unreachable.
        if ref_index[:typed_by_name].key?(definition.name)
          HIGH
        # If the name appears nowhere in untyped calls either, very confident.
        elsif !ref_index[:untyped_methods].include?(definition.name)
          HIGH
        else
          # The name appears in untyped calls — we're relying on owner disambiguation
          # or ripgrep to rule it out; more uncertain.
          MEDIUM
        end
      end
      private_class_method :method_confidence
    end
  end
end
