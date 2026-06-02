# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Conventions
    class SendHandlerSpec < Minitest::Test
      def test_matches_message_by_name_and_normalizes_to_string
        handler = SendHandler.new(name: "h", methods: %w[before_save after_save])

        assert handler.matches?("before_save")
        assert handler.matches?(:after_save)
        refute handler.matches?("destroy")
      end

      def test_positional_methods_mode
        handler = SendHandler.new(name: "h", methods: ["validate"], positional: :methods)

        assert handler.positional_methods?
      end

      def test_positional_attributes_mode
        handler = SendHandler.new(name: "h", methods: ["validates"], positional: :attributes)

        refute handler.positional_methods?
      end

      def test_unknown_positional_mode_defaults_to_methods
        handler = SendHandler.new(name: "h", methods: ["x"], positional: :bogus)

        assert handler.positional_methods?
      end

      def test_option_flags
        handler = SendHandler.new(name: "h", methods: ["validates"], conditional_options: true, option_constants: true)

        assert handler.conditional_options?
        assert handler.option_constants?
      end

      def test_option_flags_default_false
        handler = SendHandler.new(name: "h", methods: ["x"])

        refute handler.conditional_options?
        refute handler.option_constants?
      end
    end
  end
end
