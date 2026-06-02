# frozen_string_literal: true

module SorbetDeadcode
  module Conventions
    # A receiver-less DSL "send" handler: "the message `name` references the methods/constants named
    # in its arguments". This is the `on_send` half of the convention system (Convention covers the
    # base-class half). It captures the common, declarative shape shared by Rails/ActiveModel
    # callbacks and validations — and, crucially, lets a project register its own in-house DSL
    # (`track_event :foo` → keep `foo`) via `.sorbet-deadcode.yml` without patching the gem.
    #
    # What a matching call references (the ReferenceCollector does the emitting):
    #   * positional symbol args — method refs when `positional: :methods` (`before_save :touch`,
    #     `track_event :foo`); treated as ATTRIBUTE names (no method ref) when `:attributes`
    #     (`validates :email, ...` — :email is a column, not a method).
    #   * `if:` / `unless:` option values — method refs when `conditional_options: true` (the guard
    #     methods run at callback/validation time).
    #   * any other option key — a `<CamelizedKey>Validator` constant ref when `option_constants:
    #     true` (`validates :x, strong_password: true` → StrongPasswordValidator).
    #
    # Pure value object (no Prism/IO), so it is unit-tested on its own.
    class SendHandler
      POSITIONAL_MODES = %i[methods attributes].freeze

      attr_reader :name

      def initialize(name:, methods:, positional: :methods, conditional_options: false, option_constants: false)
        @name = name
        @methods = Array(methods).map(&:to_s).to_set
        @positional = POSITIONAL_MODES.include?(positional) ? positional : :methods
        @conditional_options = conditional_options
        @option_constants = option_constants
      end

      # @return [Boolean] whether this handler applies to the given (receiver-less) message name.
      def matches?(message)
        @methods.include?(message.to_s)
      end

      def positional_methods?
        @positional == :methods
      end

      def conditional_options?
        @conditional_options
      end

      def option_constants?
        @option_constants
      end
    end
  end
end
