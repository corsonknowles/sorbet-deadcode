# frozen_string_literal: true

module SorbetDeadcode
  module Conventions
    # An ordered set of base-class-scoped Conventions consulted by the ReferenceCollector for every
    # class it visits. Ships sensible built-ins for common frameworks and lets a project add its own
    # (programmatically via #register, or declaratively via a `.sorbet-deadcode.yml`) WITHOUT
    # patching the gem — so in-house base classes (a custom job/cop/consumer base) can be covered.
    class Registry
      # Recognized convention option keys (used when loading from YAML/config).
      CONFIG_KEYS = %i[name superclass includes name_suffix path_includes
                       keep_methods keep_prefixes keep_constants keep_namespace].freeze

      # Recognized send-handler option keys (used when loading from YAML/config).
      SEND_HANDLER_CONFIG_KEYS = %i[name methods positional conditional_options option_constants].freeze

      # Rails/ActiveModel/ActiveJob/controller callbacks whose positional symbol args are METHOD
      # names dispatched at callback time (`before_save :touch`), with `if:`/`unless:` guard methods.
      CALLBACK_DSL_METHODS = %w[
        validate
        before_validation after_validation
        before_create after_create around_create
        before_update after_update around_update
        before_save after_save around_save
        before_destroy after_destroy around_destroy
        after_commit after_rollback before_commit
        after_create_commit after_update_commit after_destroy_commit after_save_commit
        after_initialize after_find after_touch
        before_action after_action around_action
        prepend_before_action append_before_action skip_before_action
        prepend_after_action append_after_action skip_after_action
        prepend_around_action append_around_action skip_around_action
        before_enqueue after_enqueue around_enqueue
        before_perform after_perform around_perform
        helper_method
        setup teardown
      ].freeze

      # `validates`-family DSL: positional args are ATTRIBUTE names (not methods); option keys map to
      # validator constants; `if:`/`unless:` are guard methods.
      VALIDATES_DSL_METHODS = %w[validates validates! validates_each].freeze

      # Built-in send-handlers (the `on_send` DSL half). Mirrors the previously-inlined validator
      # handling exactly; projects append their own via .sorbet-deadcode.yml `send_handlers:`.
      def self.builtin_send_handlers
        [
          SendHandler.new(name: "rails_callbacks", methods: CALLBACK_DSL_METHODS,
                          positional: :methods, conditional_options: true),
          SendHandler.new(name: "validates", methods: VALIDATES_DSL_METHODS,
                          positional: :attributes, conditional_options: true, option_constants: true),
        ].freeze
      end

      # Built-in conventions. Each scopes a generic, framework-invoked name set to the classes that
      # actually use it (by superclass / included module / name), so the same name on an unrelated
      # class stays subject to analysis. Patterns mirror the previously-inlined collector checks.
      def self.builtins
        [
          # Visitor protocol (Prism::Visitor & co): visit_* dispatched via public_send.
          Convention.new(name: "visitor", superclass: /Visitor/, keep_prefixes: ["visit_"]),

          # graphql-ruby type/mutation/resolver/scalar/enum classes: resolve/coerce_*/etc by convention.
          Convention.new(
            name: "graphql",
            superclass: /GraphQL::Schema::|(?:\A|::)Base(Object|Mutation|Resolver|InputObject|Interface|Enum|Scalar|Union|Subscription)\z/,
            keep_methods: %w[resolve coerce_input coerce_result resolve_type graphql_name subscribed unsubscribed],
          ),

          # ActiveJob / Sidekiq jobs: the framework calls perform (and iteration hooks).
          Convention.new(
            name: "active_job",
            superclass: /\A(ApplicationJob|ApplicationWorker)\z|ActiveJob::Base/,
            includes: ["Sidekiq::Job", "Sidekiq::Worker"],
            keep_methods: %w[perform build_enumerator each_iteration],
          ),

          # RuboCop cops: every on_<node> handler is invoked by the node traversal, plus the
          # investigation lifecycle. Scoped to Cop subclasses so `on_*` isn't allow-listed globally.
          Convention.new(
            name: "rubocop_cop",
            superclass: /RuboCop::Cop|(?:\A|::)\w*Cop\z/,
            keep_prefixes: ["on_"],
            keep_methods: %w[investigate on_new_investigation after_investigation],
            keep_constants: %w[MSG RESTRICT_ON_SEND],
          ),

          # Minitest / ActiveSupport::TestCase: test_* methods and lifecycle hooks run by reflection.
          Convention.new(
            name: "minitest",
            superclass: /(Minitest::(Test|Spec)|ActiveSupport::TestCase|Test::Unit::TestCase)\z/,
            name_suffix: "Test",
            keep_prefixes: ["test_"],
            keep_methods: %w[setup teardown before_setup after_setup before_teardown after_teardown
                             before_all after_all around around_all],
          ),

          # ActiveModel::EachValidator: validate_each invoked by the validation framework.
          Convention.new(name: "each_validator", superclass: /EachValidator\z/, keep_methods: ["validate_each"]),

          # ActiveRecord migrations: run by the migration framework via version/filename — keep all.
          Convention.new(name: "migration", superclass: /ActiveRecord::Migration/, keep_namespace: true),

          # Rails/Thor generators & commands: every public method is an ordered step run by reflection.
          Convention.new(name: "generator", superclass: /Generators::(Named)?Base\z|\AThor(::Group)?\z/, keep_namespace: true),

          # ActionMailer::Preview classes: the Rails mail preview UI invokes their action methods via
          # routes, not explicit calls. Two conventions reproduce the original heuristic (kept
          # deliberately conservative so an unrelated `*Preview` service isn't silently kept alive):
          #   1. a `*Preview` superclass (e.g. ActionMailer::Preview) or a `*MailerPreview` class name;
          #   2. a `*Preview` class name living in a mailer_preview(s) path.
          Convention.new(name: "mailer_preview", superclass: /Preview/, name_suffix: "MailerPreview", keep_namespace: true),
          Convention.new(name: "mailer_preview_path", name_suffix: "Preview", path_includes: "mailer_preview", keep_namespace: true),

          # ActiveAdmin: controllers' public methods are actions/DSL hooks invoked via routing, and
          # AA helper modules (e.g. `ActiveAdmin::FooHelper` under app/helpers/active_admin/) are
          # invoked from arbre views / register blocks the analyzer doesn't scan. Keep both alive.
          # Matches AA controllers by superclass OR `*Helper` modules in an active_admin path.
          Convention.new(
            name: "active_admin",
            superclass: /ActiveAdmin::(Base|Resource|Page)Controller/,
            name_suffix: "Helper",
            path_includes: "active_admin",
            keep_namespace: true,
          ),
        ].freeze
      end

      # @return [Registry] a fresh registry preloaded with the built-in conventions + send-handlers.
      def self.default
        new(builtins, builtin_send_handlers)
      end

      # Build a registry from a parsed config hash (e.g. YAML). Custom conventions and send-handlers
      # are appended to the built-ins. Unknown keys are ignored so configs stay forward-compatible.
      def self.from_config(config)
        registry = default
        Array(config && config["conventions"]).each do |entry|
          registry.register(**config_attrs(entry, CONFIG_KEYS))
        end
        Array(config && config["send_handlers"]).each do |entry|
          attrs = config_attrs(entry, SEND_HANDLER_CONFIG_KEYS)
          attrs[:positional] = attrs[:positional].to_sym if attrs[:positional]
          registry.register_send_handler(**attrs)
        end
        registry
      end

      # Pick the listed keys out of a (string-keyed) config entry into a symbol-keyed attrs hash.
      def self.config_attrs(entry, keys)
        keys.each_with_object({}) do |key, hash|
          value = entry[key.to_s]
          hash[key] = value unless value.nil?
        end
      end

      # @return [Array<Convention>] the registered conventions (built-ins + custom), in order.
      attr_reader :conventions

      # @return [Array<SendHandler>] the registered send-handlers (built-ins + custom), in order.
      attr_reader :send_handlers

      def initialize(conventions = [], send_handlers = [])
        @conventions = conventions.to_a
        @send_handlers = send_handlers.to_a
      end

      # Register a custom convention — pass a Convention or its keyword attributes.
      # @return [self] for chaining.
      def register(*convention, **attrs)
        @conventions += convention
        @conventions << Convention.new(**attrs) unless attrs.empty?
        self
      end

      # Register a custom send-handler — pass a SendHandler or its keyword attributes.
      # @return [self] for chaining.
      def register_send_handler(*handler, **attrs)
        @send_handlers += handler
        @send_handlers << SendHandler.new(**attrs) unless attrs.empty?
        self
      end

      # @return [SendHandler, nil] the first send-handler matching a receiver-less message, or nil.
      def send_handler_for(message)
        @send_handlers.find { |handler| handler.matches?(message) }
      end

      # @return [Array<Convention>] conventions whose matcher accepts this class.
      def matching(superclass:, class_name:, file_path:, includes:)
        @conventions.select do |convention|
          convention.matches?(superclass: superclass, class_name: class_name, file_path: file_path, includes: includes)
        end
      end
    end
  end
end
