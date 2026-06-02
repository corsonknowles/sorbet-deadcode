# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Conventions
    class ConventionSpec < Minitest::Test
      def test_matches_by_superclass_regexp
        convention = Convention.new(name: "cop", superclass: /Cop\z/, keep_prefixes: ["on_"])

        assert convention.matches?(superclass: "RuboCop::Cop::Base::Cop", class_name: "X", file_path: "x.rb", includes: [])
        refute convention.matches?(superclass: "ApplicationRecord", class_name: "X", file_path: "x.rb", includes: [])
      end

      def test_string_superclass_is_compiled_to_regexp
        convention = Convention.new(name: "job", superclass: "ApplicationJob")

        assert convention.matches?(superclass: "ApplicationJob", class_name: "X", file_path: "x.rb", includes: [])
      end

      def test_matches_by_included_module
        convention = Convention.new(name: "sidekiq", includes: ["Sidekiq::Job", "Sidekiq::Worker"])

        assert convention.matches?(superclass: nil, class_name: "X", file_path: "x.rb", includes: ["Sidekiq::Job"])
        refute convention.matches?(superclass: nil, class_name: "X", file_path: "x.rb", includes: ["Comparable"])
      end

      def test_matches_by_name_suffix_with_optional_path_gate
        gated = Convention.new(name: "preview", name_suffix: "Preview", path_includes: "mailer_preview")

        assert gated.matches?(superclass: nil, class_name: "UserPreview", file_path: "app/mailer_preview/user_preview.rb", includes: [])
        # right name, wrong path → no match (path gate)
        refute gated.matches?(superclass: nil, class_name: "UserPreview", file_path: "app/services/user_preview.rb", includes: [])
        # wrong name → no match
        refute gated.matches?(superclass: nil, class_name: "UserService", file_path: "app/mailer_preview/x.rb", includes: [])
      end

      def test_name_suffix_without_path_gate_matches_anywhere
        convention = Convention.new(name: "test", name_suffix: "Test")

        assert convention.matches?(superclass: nil, class_name: "WidgetTest", file_path: "anywhere.rb", includes: [])
      end

      def test_no_matchers_never_matches
        convention = Convention.new(name: "noop", keep_methods: ["x"])

        refute convention.matches?(superclass: "Anything", class_name: "Whatever", file_path: "x.rb", includes: ["Mod"])
      end

      def test_keep_attributes_are_normalized_to_strings
        convention = Convention.new(name: "c", keep_methods: [:perform], keep_prefixes: [:on_], keep_namespace: true)

        assert_equal ["perform"], convention.keep_methods
        assert_equal ["on_"], convention.keep_prefixes
        assert convention.keep_namespace?
      end
    end
  end
end
