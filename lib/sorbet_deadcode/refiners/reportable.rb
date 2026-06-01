# frozen_string_literal: true

module SorbetDeadcode
  module Refiners
    # Shared exclude-vs-report behavior for the non-Ruby refiners.
    #
    # In the default :exclude mode a matched candidate is removed from the dead set (it's
    # referenced from a route/template/config/SDL, so it isn't dead). In :report mode the
    # candidate is kept but tagged with the refiner's REASON via Definition#kept_by, so the
    # Classifier can surface it as a low-confidence "review" candidate instead of silently
    # dropping it. Mirrors the dynamic_dispatch: :report mode for in-Ruby dispatch.
    #
    # Including classes must define a `REASON` constant (e.g. :graphql_sdl) and set @mode.
    module Reportable
      private

      # @param candidates [Array<Definition>]
      # @yieldparam definition [Definition] => true if the refiner matched (would keep alive)
      # @return [Array<Definition>]
      def resolve(candidates)
        return candidates.reject { |defn| yield(defn) } unless @mode == :report

        candidates.each { |defn| defn.kept_by ||= self.class::REASON if yield(defn) }
        candidates
      end
    end
  end
end
