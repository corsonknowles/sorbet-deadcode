# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Resolver
    class TypeResolverSpec < Minitest::Test
      def setup
        @resolver = TypeResolver.new
      end

      def test_register_and_lookup_method
        @resolver.register_method(
          owner: "User",
          method_name: "company",
          return_type: "Company",
        )

        assert_equal "Company", @resolver.return_type_of("User", "company")
      end

      def test_returns_nil_for_unknown_method
        assert_nil @resolver.return_type_of("User", "nonexistent")
      end

      def test_returns_nil_for_nil_receiver
        assert_nil @resolver.return_type_of(nil, "anything")
      end

      def test_register_and_lookup_attr
        @resolver.register_attr(owner: "User", attr_name: "name", type: "String")

        assert_equal "String", @resolver.return_type_of("User", "name")
      end

      def test_typed_check
        refute @resolver.typed?("User", "unknown")

        @resolver.register_method(
          owner: "User",
          method_name: "company",
          return_type: "Company",
        )

        assert @resolver.typed?("User", "company")
      end

      def test_method_takes_precedence_over_attr
        @resolver.register_attr(owner: "User", attr_name: "name", type: "String")
        @resolver.register_method(
          owner: "User",
          method_name: "name",
          return_type: "Symbol",
        )

        assert_equal "Symbol", @resolver.return_type_of("User", "name")
      end

      def test_param_types_stored
        @resolver.register_method(
          owner: "Service",
          method_name: "call",
          return_type: "String",
          param_types: { "input" => "Integer" },
        )

        sig = @resolver.method_signatures.dig("Service", "call")
        assert_equal({ "input" => "Integer" }, sig[:params])
      end
    end
  end
end
