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
                       keep_methods keep_prefixes keep_namespace].freeze

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
        ].freeze
      end

      # @return [Registry] a fresh registry preloaded with the built-in conventions.
      def self.default
        new(builtins)
      end

      # Build a registry from a parsed config hash (e.g. YAML). Custom conventions are appended to
      # the built-ins. Unknown keys are ignored so configs stay forward-compatible.
      def self.from_config(config)
        registry = default
        Array(config && config["conventions"]).each do |entry|
          attrs = CONFIG_KEYS.each_with_object({}) do |key, hash|
            value = entry[key.to_s]
            hash[key] = value unless value.nil?
          end
          registry.register(**attrs)
        end
        registry
      end

      # @return [Array<Convention>] the registered conventions (built-ins + custom), in order.
      attr_reader :conventions

      def initialize(conventions = [])
        @conventions = conventions.to_a
      end

      # Register a custom convention — pass a Convention or its keyword attributes.
      # @return [self] for chaining.
      def register(*convention, **attrs)
        @conventions += convention
        @conventions << Convention.new(**attrs) unless attrs.empty?
        self
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
