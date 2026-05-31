# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Analyzer
    class ConfidenceSpec < Minitest::Test
      def make_def(kind:, name: "foo", owner_name: "Foo")
        Definition.new(name: name, full_name: "#{owner_name}##{name}", kind: kind, location: "f:1", owner_name: owner_name)
      end

      def ref_index(typed_by_name: {}, untyped_methods: Set.new)
        { typed_by_name: typed_by_name, untyped_methods: untyped_methods,
          constants: Set.new, method_prefixes: Set.new, dynamic_namespaces: Set.new }
      end

      def test_class_is_always_high
        assert_equal Confidence::HIGH, Confidence.for(make_def(kind: :class), ref_index)
      end

      def test_module_is_always_high
        assert_equal Confidence::HIGH, Confidence.for(make_def(kind: :module), ref_index)
      end

      def test_constant_is_always_high
        assert_equal Confidence::HIGH, Confidence.for(make_def(kind: :constant), ref_index)
      end

      def test_method_with_no_refs_anywhere_is_high
        assert_equal Confidence::HIGH, Confidence.for(make_def(kind: :method), ref_index)
      end

      def test_method_with_only_typed_refs_is_high
        # Typed refs exist for the name but from a different owner → confirms dead for Foo
        idx = ref_index(typed_by_name: { "foo" => Set.new(["Bar"]) })
        assert_equal Confidence::HIGH, Confidence.for(make_def(kind: :method), idx)
      end

      def test_method_with_untyped_refs_only_is_medium
        idx = ref_index(untyped_methods: Set.new(["foo"]))
        assert_equal Confidence::MEDIUM, Confidence.for(make_def(kind: :method), idx)
      end

      def test_method_without_owner_is_low
        defn = Definition.new(name: "orphan", full_name: "orphan", kind: :method, location: "f:1")
        assert_equal Confidence::LOW, Confidence.for(defn, ref_index)
      end

      def test_attr_reader_follows_method_logic
        idx = ref_index(untyped_methods: Set.new(["foo"]))
        assert_equal Confidence::MEDIUM, Confidence.for(make_def(kind: :attr_reader), idx)
      end

      def test_unknown_kind_is_low
        defn = Definition.allocate
        defn.instance_variable_set(:@name, "x")
        defn.instance_variable_set(:@kind, :weird)
        defn.instance_variable_set(:@owner_name, "X")
        assert_equal Confidence::LOW, Confidence.for(defn, ref_index)
      end
    end
  end
end
