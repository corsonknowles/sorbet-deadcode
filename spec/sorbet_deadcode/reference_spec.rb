# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class ReferenceSpec < Minitest::Test
    def test_raises_on_unknown_kind
      error = assert_raises(ArgumentError) do
        Reference.new(name: "x", location: "f:1", kind: :bogus)
      end
      assert_match(/unknown kind/, error.message)
    end

    def test_typed_predicate
      typed = Reference.new(name: "foo", location: "f:1", kind: :method, receiver_type: "A")
      untyped = Reference.new(name: "foo", location: "f:1", kind: :method)

      assert typed.typed?
      refute untyped.typed?
    end

    def test_equality_and_hash
      a = Reference.new(name: "foo", location: "f:1", kind: :method, receiver_type: "A")
      b = Reference.new(name: "foo", location: "f:9", kind: :method, receiver_type: "A")
      c = Reference.new(name: "foo", location: "f:1", kind: :method, receiver_type: "B")

      assert_equal a, b
      assert a.eql?(b)
      assert_equal a.hash, b.hash
      refute_equal a, c
      refute_equal a, "not a reference"
    end

    def test_supports_prefix_and_namespace_kinds
      prefix = Reference.new(name: "dump_", location: "f:1", kind: :method_prefix)
      ns = Reference.new(name: "Foo::Bar", location: "f:1", kind: :dynamic_namespace)

      assert_equal :method_prefix, prefix.kind
      assert_equal :dynamic_namespace, ns.kind
    end
  end
end
