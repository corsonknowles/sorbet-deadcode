# frozen_string_literal: true

module SorbetDeadcode
  module Resolver
    # Resolves types from Sorbet sig annotations parsed from source.
    # This is the key differentiator from name-based tools: when we know
    # the receiver type of a call, we can match it to a specific class's
    # method definition rather than marking ALL methods with that name alive.
    #
    # Phase 1 (current): Parse Sorbet sigs from source using Prism.
    # Phase 2 (future): Integrate with Sorbet LSP for full type inference.
    class TypeResolver
      attr_reader :method_signatures

      def initialize
        # { "ClassName" => { "method_name" => { params: {}, returns: "Type" } } }
        @method_signatures = {}
        # { "ClassName" => { "attr_name" => "Type" } }
        @attr_types = {}
      end

      # Register a method's return type from a parsed sig
      def register_method(owner:, method_name:, return_type:, param_types: {})
        @method_signatures[owner] ||= {}
        @method_signatures[owner][method_name] = {
          params: param_types,
          returns: return_type,
        }
      end

      # Register an attribute's type (from T.let or sig)
      def register_attr(owner:, attr_name:, type:)
        @attr_types[owner] ||= {}
        @attr_types[owner][attr_name] = type
      end

      # Given a receiver type and method name, return the method's return type
      def return_type_of(receiver_type, method_name)
        return nil unless receiver_type

        sig = @method_signatures.dig(receiver_type, method_name)
        return sig[:returns] if sig

        @attr_types.dig(receiver_type, method_name)
      end

      # Check if we have type info for a given owner and method
      def typed?(owner, method_name)
        @method_signatures.dig(owner, method_name) != nil ||
          @attr_types.dig(owner, method_name) != nil
      end
    end
  end
end
