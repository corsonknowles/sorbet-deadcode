# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class DefinitionSpec < Minitest::Test
    def test_raises_on_unknown_kind
      error = assert_raises(ArgumentError) do
        Definition.new(name: "x", full_name: "x", kind: :bogus, location: "f:1")
      end
      assert_match(/unknown kind/, error.message)
    end

    def test_qualified_name_for_method_uses_hash_separator
      defn = Definition.new(name: "foo", full_name: "A::B#foo", kind: :method, location: "f:1", owner_name: "A::B")
      assert_equal "A::B#foo", defn.qualified_name
    end

    def test_qualified_name_for_constant_uses_colon_separator
      defn = Definition.new(name: "FOO", full_name: "A::FOO", kind: :constant, location: "f:1", owner_name: "A")
      assert_equal "A::FOO", defn.qualified_name
    end

    def test_qualified_name_without_owner_returns_full_name
      defn = Definition.new(name: "Top", full_name: "Top", kind: :class, location: "f:1")
      assert_equal "Top", defn.qualified_name
    end

    def test_equality_and_hash
      a = Definition.new(name: "foo", full_name: "A#foo", kind: :method, location: "f:1")
      b = Definition.new(name: "foo", full_name: "A#foo", kind: :method, location: "f:99")
      c = Definition.new(name: "bar", full_name: "A#bar", kind: :method, location: "f:1")

      assert_equal a, b
      assert a.eql?(b)
      assert_equal a.hash, b.hash
      refute_equal a, c
      refute_equal a, "not a definition"
    end

    def test_co_located_names_default_empty
      defn = Definition.new(name: "X", full_name: "X", kind: :constant, location: "f:1")
      assert_equal [], defn.co_located_names
    end
  end
end
