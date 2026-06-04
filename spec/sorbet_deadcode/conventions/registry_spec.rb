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

      def test_from_config_send_handler_without_positional_key
        # No `positional` key → the `attrs[:positional].to_sym` conversion is skipped
        # (SendHandler defaults positional to :methods).
        registry = Registry.from_config(
          "send_handlers" => [{ "name" => "track_event", "methods" => ["handle_event"] }],
        )

        assert registry.send_handler_for("handle_event")
      end

      def test_conventions_reader_exposes_builtins_for_introspection
        names = Registry.default.conventions.map(&:name)

        # Used by the CLI's --show-plugins. Built-ins should include the new rubocop_cop convention.
        assert_includes names, "rubocop_cop"
        assert_includes names, "active_job"
      end

      def test_default_send_handlers_cover_callbacks_and_validates
        registry = Registry.default

        assert_equal "rails_callbacks", registry.send_handler_for("before_save")&.name
        assert_equal "rails_callbacks", registry.send_handler_for("after_touch")&.name
        assert_equal "validates", registry.send_handler_for("validates")&.name
        assert_nil registry.send_handler_for("some_unknown_dsl")
      end

      def test_register_send_handler_keyword_and_instance
        from_attrs = Registry.new.register_send_handler(name: "track", methods: ["track_event"])
        assert_equal "track", from_attrs.send_handler_for("track_event")&.name

        handler = SendHandler.new(name: "inst", methods: ["log_event"])
        from_instance = Registry.new.register_send_handler(handler)
        assert_equal "inst", from_instance.send_handler_for("log_event")&.name
      end

      def test_from_config_builds_custom_send_handlers
        config = {
          "send_handlers" => [
            { "name" => "track", "methods" => %w[track_event log_event], "positional" => "methods",
              "conditional_options" => true },
          ],
        }
        registry = Registry.from_config(config)

        handler = registry.send_handler_for("log_event")
        assert_equal "track", handler&.name
        assert handler.positional_methods?
        assert handler.conditional_options?
        # built-in send-handlers still present
        assert_equal "rails_callbacks", registry.send_handler_for("before_save")&.name
      end

      def test_send_handlers_reader_exposes_builtins
        names = Registry.default.send_handlers.map(&:name)

        assert_includes names, "rails_callbacks"
        assert_includes names, "validates"
      end
    end
  end
end
