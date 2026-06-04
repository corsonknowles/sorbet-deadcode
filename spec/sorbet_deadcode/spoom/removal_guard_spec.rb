# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Spoom
    class RemovalGuardSpec < Minitest::Test
      # A clean removal that deletes only the target reports no collateral.
      def test_clean_removal_has_no_collateral
        old = "A = 1\nB = 2\n"
        new = "A = 1\n"

        collateral = RemovalGuard.collateral_definitions(old, new, target_full_name: "B")

        assert_empty collateral
      end

      # The bug this guards against: removing the target also deleted a live sibling.
      def test_over_removal_of_sibling_is_flagged
        old = "A = 1\nB = 2\n"
        new = "" # spoom over-deleted A while removing B

        collateral = RemovalGuard.collateral_definitions(old, new, target_full_name: "B")

        assert_equal ["A"], collateral
      end

      # Removing a class legitimately removes its nested members — not collateral.
      def test_nested_members_of_removed_class_are_allowed
        old = <<~RUBY
          class Foo
            def bar; end
            BAZ = 1
          end
        RUBY

        collateral = RemovalGuard.collateral_definitions(old, "", target_full_name: "Foo")

        assert_empty collateral
      end

      # Inline-constant members removed with their enclosing literal are allowed.
      def test_inline_members_are_allowed
        old = "PARENT = [CHILD = 1].freeze\n"

        collateral = RemovalGuard.collateral_definitions(
          old, "", target_full_name: "PARENT", co_located_names: ["CHILD"]
        )

        assert_empty collateral
      end
    end
  end
end
