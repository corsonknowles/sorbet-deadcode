# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class KindFilterSpec < Minitest::Test
    def test_default_is_methods_only
      result = KindFilter.parse(KindFilter::DEFAULT)

      assert_equal Set[:method], result.kinds
      assert_empty result.invalid
    end

    def test_all_expands_to_every_kind
      result = KindFilter.parse("all")

      assert_equal KindFilter::ALL.to_set, result.kinds
      assert_empty result.invalid
    end

    # `all` wins even when combined with other (including unknown) tokens.
    def test_all_short_circuits_other_tokens
      result = KindFilter.parse("method,all,bogus")

      assert_equal KindFilter::ALL.to_set, result.kinds
      assert_empty result.invalid
    end

    def test_comma_separated_list
      result = KindFilter.parse("method,constant,class")

      assert_equal Set[:method, :constant, :class], result.kinds
      assert_empty result.invalid
    end

    # Plural forms, whitespace, and case are all normalized.
    def test_normalizes_plurals_whitespace_and_case
      result = KindFilter.parse("  Methods , CONSTANTS , classes , modules , attr_writers ")

      assert_equal Set[:method, :constant, :class, :module, :attr_writer], result.kinds
      assert_empty result.invalid
    end

    def test_unknown_tokens_reported_as_invalid
      result = KindFilter.parse("method,bogus,widget")

      assert_equal Set[:method], result.kinds
      assert_equal %w[bogus widget], result.invalid
    end

    def test_empty_value_yields_no_kinds
      result = KindFilter.parse("")

      assert_empty result.kinds
      assert_empty result.invalid
    end
  end
end
