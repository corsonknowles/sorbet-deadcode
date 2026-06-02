# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Conventions
    class RegistrySpec < Minitest::Test
      def test_default_includes_builtin_rubocop_cop_convention
        registry = Registry.default
        matches = registry.matching(superclass: "RuboCop::Cop::Base", class_name: "NoFoo", file_path: "x.rb", includes: [])

        cop = matches.find { |c| c.name == "rubocop_cop" }
        assert cop, "expected the built-in rubocop_cop convention to match a Cop subclass"
        assert_includes cop.keep_prefixes, "on_"
      end

      def test_default_matches_sidekiq_job_by_included_module
        registry = Registry.default
        matches = registry.matching(superclass: nil, class_name: "Worker", file_path: "x.rb", includes: ["Sidekiq::Job"])

        assert(matches.any? { |c| c.name == "active_job" && c.keep_methods.include?("perform") })
      end

      def test_register_keyword_convention_is_matched
        registry = Registry.new.register(name: "custom", superclass: /EventConsumer\z/, keep_methods: ["consume"])
        matches = registry.matching(superclass: "EventConsumer", class_name: "X", file_path: "x.rb", includes: [])

        assert_equal ["custom"], matches.map(&:name)
        assert_equal ["consume"], matches.first.keep_methods
      end

      def test_register_convention_instance
        convention = Convention.new(name: "inst", name_suffix: "Worker", keep_namespace: true)
        registry = Registry.new.register(convention)

        matches = registry.matching(superclass: nil, class_name: "EmailWorker", file_path: "x.rb", includes: [])
        assert_equal ["inst"], matches.map(&:name)
      end

      def test_from_config_appends_custom_conventions_to_builtins
        config = {
          "conventions" => [
            {
              "name" => "event_consumer",
              "superclass" => "EventConsumer",
              "keep_methods" => ["consume"],
              "ignored_unknown_key" => "tolerated",
            },
          ],
        }
        registry = Registry.from_config(config)

        # built-ins still present...
        assert(registry.matching(superclass: "RuboCop::Cop::Base", class_name: "X", file_path: "x.rb", includes: []).any? { |c| c.name == "rubocop_cop" })
        # ...and the custom one matches
        custom = registry.matching(superclass: "EventConsumer", class_name: "X", file_path: "x.rb", includes: [])
        assert_equal ["event_consumer"], custom.map(&:name)
      end

      def test_from_config_tolerates_nil_and_missing_conventions_key
        assert_kind_of Registry, Registry.from_config(nil)
        assert_kind_of Registry, Registry.from_config({})
      end
    end
  end
end
