# frozen_string_literal: true

module SorbetDeadcode
  module Collector
    # Walks a Prism AST and collects all references (method calls, constant
    # lookups). When a Sorbet sig is available on the receiver, the reference
    # is typed — meaning we know which class the method is called on.
    class ReferenceCollector < Prism::Visitor
      attr_reader :references

      DYNAMIC_DISPATCH_METHODS = %w[send __send__ public_send try].to_set.freeze

      # Keyword/mass-assignment entry points: `Model.new(foo: x)`, `record.update(foo: x)`,
      # FactoryBot `build(:m, foo: x)`, etc. each invoke the `foo=` setter. The keyword key
      # `foo:` never appears as the literal `foo=`, so without this a write-only attribute
      # set exclusively through mass-assignment looks dead. Emitting `foo=` references here
      # is conservative (it can only keep a setter alive).
      MASS_ASSIGNMENT_METHODS = %w[
        new create create! build build_stubbed build_stubbed_list
        update update! update_columns update_attributes update_attributes!
        assign_attributes attributes= with
        insert insert! upsert
      ].to_set.freeze

      # Bulk-write methods that take an ARRAY of attribute hashes (`Model.insert_all([{a: 1}])`);
      # each hash key sets the `key=` setter, same as single-record mass assignment.
      ARRAY_MASS_ASSIGNMENT_METHODS = %w[insert_all insert_all! upsert_all].to_set.freeze

      # Rails `delegate :foo, :bar, to: :target` creates forwarding methods.
      # The delegated names are referenced via define_method at class load time.
      DELEGATE_DSL_METHODS = %w[delegate].to_set.freeze

      # AASM `event :activate, after: [:notify], guard: :can_activate?` dispatches
      # symbol names as callbacks or guards. Also handles `error_on_all_events :method`.
      AASM_DSL_METHODS = %w[
        error_on_all_events
        aasm_event event
      ].to_set.freeze

      # AASM event option keys whose value is a method name (or array of them) dispatched
      # as a callback/guard during a transition: `event :activate, after: [:notify], guard: :can?`.
      AASM_CALLBACK_KEYS = %w[
        after before guard unless success error ensure
        after_commit after_rollback on_transition
        before_transaction after_transaction
      ].to_set.freeze

      # GraphQL-ruby DSL patterns that reference Ruby methods by symbol.
      # `builds :foo` → calls `build_foo`
      # `argument :x, prepare: :method` → calls `method`
      # `field :x, method: :method_name` → calls `method_name`
      GRAPHQL_DSL_METHODS = %w[builds argument field mutation].to_set.freeze

      # `assert_predicate obj, :foo?` / `refute_predicate obj, :foo?` invoke `foo?`.
      ASSERT_PREDICATE_METHODS = %w[assert_predicate refute_predicate].to_set.freeze

      # Reflection methods that look up a constant by symbol/string name (Module#const_get etc.).
      CONSTANT_REFLECTION_METHODS = %w[const_get const_defined? const_source_location].to_set.freeze

      # Rails validation/callback conditional options whose value is a method name (or array of
      # them) invoked at validation/callback time: `validate :x, if: :ready?`, `unless: :skip?`.
      VALIDATOR_CONDITIONAL_KEYS = %w[if unless].to_set.freeze

      # `validates` options that are NOT validators — every other key maps to a `<Key>Validator`
      # class. (`if`/`unless` are handled separately as conditional method references.)
      VALIDATES_STANDARD_OPTIONS = %w[on allow_nil allow_blank message strict].to_set.freeze

      def initialize(file_path, type_resolver: nil, conventions: nil)
        super()
        @file_path = file_path
        @references = []
        @type_resolver = type_resolver
        @conventions = conventions || Conventions::Registry.default
        @namespace_stack = []
        @local_types = {}
        # Byte-offset ranges of the constant NAME being defined (`Foo` / `Foo::Bar` in
        # `class Foo::Bar < Base`). Used to suppress a definition's own name from counting
        # as a self-reference WITHOUT also suppressing other constants on the same line —
        # most importantly the superclass after `<`, which is a real reference to the parent.
        @definition_name_ranges = []
        @current_method_name = nil
        # Local var name => interpolation prefix, e.g. `m = "dump_#{x}"` records "dump_".
        @local_prefixes = {}
        # Local var name => interpolation suffix, e.g. `m = "#{x}_at"` records "_at".
        @local_suffixes = {}
        # Constant name => [symbol names] for literal symbol arrays, e.g. METHODS = %i[a b].
        @symbol_array_constants = {}
        # Block-param name => [symbol names] in scope while visiting an iteration block.
        @iterated_symbols = {}
      end

      def visit_class_node(node)
        record_definition_name(node.constant_path)
        @namespace_stack.push(node.constant_path.slice)

        location = format_location(node.location)

        # Base-class-scoped framework conventions (visitor / graphql / job / rubocop cop / minitest
        # / migration / generator / mailer_preview + any project-registered ones): keep
        # framework-invoked methods alive, scoped to the matching class. See Conventions::Registry.
        emit_convention_references(node, location)

        super
        @namespace_stack.pop
      end

      def visit_module_node(node)
        record_definition_name(node.constant_path)
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_def_node(node)
        old_method = @current_method_name
        @current_method_name = node.name.to_s

        # Local variables (and our derived tracking of them — types and interpolation
        # prefixes) do not outlive their defining method, so snapshot and restore the
        # per-method maps around the body. Without this, `m = "dump_#{x}"` in one method
        # would leak a `dump_` prefix into a different method that reuses the name `m`.
        saved_local_types = @local_types.dup
        saved_local_prefixes = @local_prefixes.dup
        saved_local_suffixes = @local_suffixes.dup

        if @type_resolver && current_namespace
          sig = @type_resolver.method_signatures.dig(current_namespace, @current_method_name)
          sig&.dig(:params)&.each do |param_name, param_type|
            @local_types[param_name] = param_type
          end
        end

        super

        @local_types = saved_local_types
        @local_prefixes = saved_local_prefixes
        @local_suffixes = saved_local_suffixes
        @current_method_name = old_method
      end

      ITERATION_METHODS = %w[each map flat_map collect each_with_object select filter reject find detect].to_set.freeze
      SUBCLASS_DISCOVERY_METHODS = %w[descendants subclasses].to_set.freeze

      def visit_call_node(node)
        name = node.name.to_s
        location = format_location(node.location)

        # RSpec dynamic predicate matchers (be_foo, be_a_foo, have_foo) call
        # foo?/has_foo? without the literal name appearing. Emit those predicate
        # references so methods tested only through a matcher aren't reported dead.
        collect_predicate_matcher_references(name, location)

        # `Base.descendants` / `Base.subclasses` discovers every subclass at runtime, so
        # those subclasses must not be reported dead even though nothing names them.
        collect_subclass_discovery_reference(node, name, location)

        # Keyword mass-assignment (`Model.new(foo: x)`, `build(:m, foo: x)`, etc.) invokes
        # the `foo=` setter; emit those writer references so set-only attributes aren't dead.
        collect_mass_assignment_references(node, location) if MASS_ASSIGNMENT_METHODS.include?(name)
        collect_array_mass_assignment_references(node, location) if ARRAY_MASS_ASSIGNMENT_METHODS.include?(name)

        # `assert_predicate obj, :ready?` invokes the `ready?` predicate (Minitest).
        collect_assert_predicate_reference(node, location) if ASSERT_PREDICATE_METHODS.include?(name) && node.arguments

        # Strong-params `params.permit(:foo, bar: [])` whitelists attributes that are then
        # mass-assigned (`record.assign_attributes(permitted)`); the attribute names appear
        # only as permit keys, so emit `foo=`/`bar=` writer references to keep those setters
        # alive. Conservative: matching the bare `permit` name can only keep a setter alive.
        collect_permit_references(node, location) if name == "permit"

        # Reflection that names a method/constant by symbol or string without a literal call site:
        # `alias_method :new, :old` (old kept), `method(:foo)` (foo kept), and dynamic constant
        # access `const_get(:Foo)` / `const_defined?("A::B")` (the constant kept).
        if node.arguments
          collect_alias_method_reference(node, location) if name == "alias_method"
          collect_method_handle_reference(node, location) if name == "method"
          collect_constant_reflection_references(node, location) if CONSTANT_REFLECTION_METHODS.include?(name)
        end

        # Resolve dispatch over a finite symbol list, e.g. `[:a, :b].each { |m| send(m) }`
        # or `METHODS.each { |m| send(m) }`. Bind the block param to the resolved symbol
        # list while visiting the block so the send(m) inside emits concrete references.
        if ITERATION_METHODS.include?(name) && (param = iteration_block_param(node)) && (syms = resolve_symbol_array(node.receiver))
          @iterated_symbols[param] = syms
          super
          @iterated_symbols.delete(param)
          return
        end

        if DYNAMIC_DISPATCH_METHODS.include?(name) && node.arguments
          collect_dynamic_dispatch(node, location)
        elsif name == "accepts_nested_attributes_for" && node.receiver.nil? && node.arguments
          collect_nested_attributes_references(node, location)
          super
          return
        elsif DELEGATE_DSL_METHODS.include?(name) && node.receiver.nil? && node.arguments
          collect_delegate_references(node, location)
          super
          return
        elsif AASM_DSL_METHODS.include?(name) && node.receiver.nil? && node.arguments
          collect_aasm_references(node, location)
          super
          return
        elsif GRAPHQL_DSL_METHODS.include?(name) && node.receiver.nil? && node.arguments
          collect_graphql_references(node, location, method_name: name)
          super
          return
        elsif %w[attribute attributes].include?(name) && node.receiver.nil? && node.arguments
          # `attribute :foo` defines foo/foo= dynamically; emit refs so an overriding
          # `def foo` / `def foo=` on the model isn't reported dead.
          collect_attribute_references(node, location)
          super
          return
        elsif name == "rescue_from" && node.receiver.nil? && node.arguments
          # `rescue_from SomeError, with: :handler` dispatches to the `with:` method when the
          # error is raised. (Positional args are error constants, handled as normal constant refs.)
          collect_rescue_from_references(node, location)
          super
          return
        elsif node.receiver.nil? && node.arguments && (handler = @conventions.send_handler_for(name))
          # Receiver-less DSL send (callbacks, validations, or a project-registered in-house DSL):
          # reference the methods/constants named in its arguments. See Conventions::SendHandler.
          apply_send_handler(handler, node, location)
          super
          return
        elsif node.receiver
          receiver_type = resolve_receiver_type(node.receiver)
          @references << Reference.new(
            name: name,
            location: location,
            kind: :method,
            receiver_type: receiver_type,
          )
        else
          @references << Reference.new(
            name: name,
            location: location,
            kind: :method,
          )
        end

        super
      end

      def visit_constant_read_node(node)
        return super if within_definition_name?(node)

        @references << Reference.new(
          name: node.name.to_s,
          location: format_location(node.location),
          kind: :constant,
        )
        super
      end

      def visit_constant_path_node(node)
        return super if within_definition_name?(node)

        location = format_location(node.location)
        full_name = node.slice

        # Emit a reference for each prefix component so that e.g.
        # `SorbetDeadcode::Lsp::Client` also keeps `module SorbetDeadcode` and
        # `module SorbetDeadcode::Lsp` alive.
        parts = full_name.split("::")
        parts.each_with_index do |_part, i|
          @references << Reference.new(
            name: parts[0..i].join("::"),
            location: location,
            kind: :constant,
          )
        end
        super
      end

      # Track local variable assignments with type annotations for resolution
      def visit_local_variable_write_node(node)
        if node.value.is_a?(Prism::CallNode) && @type_resolver
          type = @type_resolver.return_type_of(
            resolve_receiver_type(node.value.receiver),
            node.value.name.to_s,
          )
          @local_types[node.name.to_s] = type if type
        end

        # Track `m = "dump_#{x}"` so a later send(m) can emit a precise method_prefix
        # reference (keeping `dump_*` methods alive) instead of excluding the whole namespace.
        prefix = literal_prefix(node.value)
        if prefix && !prefix.empty?
          @local_prefixes[node.name.to_s] = prefix
        end

        # Track `m = "#{x}_at"` so a later send(m) can emit a precise method_suffix
        # reference (keeping `*_at` methods alive) instead of excluding the whole namespace.
        suffix = literal_suffix(node.value)
        if suffix && !suffix.empty?
          @local_suffixes[node.name.to_s] = suffix
        end

        super
      end

      # Track `METHODS = [:a, :b]` so iteration over the constant can resolve the
      # dispatched method names to concrete references.
      def visit_constant_write_node(node)
        syms = symbol_array_values(node.value)
        @symbol_array_constants[node.name.to_s] = syms if syms
        super
      end

      # Operator-assignment to a method receiver invokes the setter, e.g.
      # `obj.foo ||= x`, `obj.foo &&= x`, `obj.foo += 1` all call `foo=` (and read `foo`).
      # These are distinct Prism nodes from a plain `obj.foo = x` CallNode, so without
      # handling them the setter looks dead even though it is written.
      def visit_call_or_write_node(node)
        emit_call_write_references(node)
        super
      end

      def visit_call_and_write_node(node)
        emit_call_write_references(node)
        super
      end

      def visit_call_operator_write_node(node)
        emit_call_write_references(node)
        super
      end

      private

      def collect_dynamic_dispatch(node, location)
        first_arg = node.arguments.arguments.first

        if first_arg.is_a?(Prism::SymbolNode)
          # Literal symbol: precise method reference.
          receiver_type = node.receiver ? resolve_receiver_type(node.receiver) : nil
          @references << Reference.new(
            name: first_arg.unescaped,
            location: location,
            kind: :method,
            receiver_type: receiver_type,
          )
          return
        end

        # Variable bound to a finite symbol list via iteration,
        # e.g. `[:a, :b].each { |m| send(m) }` => emit each concrete method name.
        if first_arg.is_a?(Prism::LocalVariableReadNode) && @iterated_symbols.key?(first_arg.name.to_s)
          receiver_type = node.receiver ? resolve_receiver_type(node.receiver) : nil
          @iterated_symbols[first_arg.name.to_s].each do |sym|
            @references << Reference.new(name: sym, location: location, kind: :method, receiver_type: receiver_type)
          end
          return
        end

        # Variable assigned an interpolated string with a literal prefix and/or suffix,
        # e.g. `m = "dump_#{x}"; send(m)` => emit the `dump_` prefix.
        if first_arg.is_a?(Prism::LocalVariableReadNode) &&
           (@local_prefixes.key?(first_arg.name.to_s) || @local_suffixes.key?(first_arg.name.to_s))
          name = first_arg.name.to_s
          @references << Reference.new(name: @local_prefixes[name], location: location, kind: :method_prefix) if @local_prefixes.key?(name)
          @references << Reference.new(name: @local_suffixes[name], location: location, kind: :method_suffix) if @local_suffixes.key?(name)
          return
        end

        # Non-literal target: the method name is built at runtime. An interpolated
        # argument may carry a literal prefix (`"dump_#{x}"`) and/or suffix
        # (`"#{x}_start_time"`); emit whichever are present so the matching method
        # family stays alive.
        prefix = literal_prefix(first_arg)
        suffix = literal_suffix(first_arg)
        if (prefix && !prefix.empty?) || (suffix && !suffix.empty?)
          # e.g. public_send("dump_#{type}") => any `dump_*` method may be reached;
          #      public_send("#{p}_start_time") => any `*_start_time` method may be reached.
          @references << Reference.new(name: prefix, location: location, kind: :method_prefix) if prefix && !prefix.empty?
          @references << Reference.new(name: suffix, location: location, kind: :method_suffix) if suffix && !suffix.empty?
        elsif current_namespace
          # e.g. __send__(method_name) inside a class => the runtime target is
          # unknowable, so any method in this namespace may be reached. Conservatively
          # exclude them all from dead results (the precise cases above are handled
          # before reaching this fallback).
          @references << Reference.new(name: current_namespace, location: location, kind: :dynamic_namespace)
        end
      end

      # Returns the first block parameter name of an iteration call, or nil.
      def iteration_block_param(node)
        block = node.block
        return nil unless block.is_a?(Prism::BlockNode)

        params = block.parameters
        return nil unless params.is_a?(Prism::BlockParametersNode)

        required = params.parameters&.requireds
        first = required&.first
        first.is_a?(Prism::RequiredParameterNode) ? first.name.to_s : nil
      end

      # Resolve a node to an array of symbol names if it is a literal symbol array
      # or a constant pointing to one. Returns nil otherwise.
      def resolve_symbol_array(node)
        case node
        when Prism::ArrayNode
          symbol_array_values(node)
        when Prism::ConstantReadNode
          @symbol_array_constants[node.name.to_s]
        end
      end

      # Returns the unescaped symbol names if node is an ArrayNode of only symbols
      # (optionally frozen via .freeze), else nil.
      def symbol_array_values(node)
        node = node.receiver if node.is_a?(Prism::CallNode) && node.name.to_s == "freeze" && node.receiver
        return nil unless node.is_a?(Prism::ArrayNode)
        return nil if node.elements.empty?
        return nil unless node.elements.all? { |el| el.is_a?(Prism::SymbolNode) }

        node.elements.map(&:unescaped)
      end

      # RSpec dynamic predicate matchers reference predicate methods implicitly:
      #   be_foo            => foo?
      #   be_a_foo / be_an_foo => foo?   (a_/an_ article stripped)
      #   have_foo          => has_foo?  (and have_foo? as a fallback shape)
      # Over-emitting references here is safe: it can only keep a method alive, never
      # mark one dead.
      def collect_predicate_matcher_references(name, location)
        predicate_matcher_names(name).each do |predicate|
          @references << Reference.new(name: predicate, location: location, kind: :method)
        end
      end

      # `Base.descendants` / `Base.subclasses` — emit a dynamic_subclasses reference for the
      # receiver constant so the analyzer keeps every subclass of `Base` alive.
      def collect_subclass_discovery_reference(node, name, location)
        return unless SUBCLASS_DISCOVERY_METHODS.include?(name)

        short = constant_short_name(node.receiver)
        return unless short

        @references << Reference.new(name: short, location: location, kind: :dynamic_subclasses)
      end

      # Short (demodulized) name of a constant receiver, or nil if the receiver isn't a
      # constant. Unwraps Sorbet casts first, since `.descendants` is commonly called as
      # `T.unsafe(Base).descendants` (Sorbet doesn't type reflection well).
      def constant_short_name(receiver)
        receiver = unwrap_sorbet_cast(receiver)
        receiver.name.to_s if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      end

      # `T.unsafe(X)` / `T.must(X)` / `T.let(X, ...)` / `T.cast(X, ...)` => X.
      def unwrap_sorbet_cast(node)
        return node unless node.is_a?(Prism::CallNode)
        return node unless node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :T
        return node unless %w[unsafe must let cast].include?(node.name.to_s)

        node.arguments&.arguments&.first || node
      end

      def predicate_matcher_names(name)
        if name.start_with?("be_an_")
          ["#{name.delete_prefix('be_an_')}?"]
        elsif name.start_with?("be_a_")
          ["#{name.delete_prefix('be_a_')}?"]
        elsif name.start_with?("be_")
          ["#{name.delete_prefix('be_')}?"]
        elsif name.start_with?("have_")
          base = name.delete_prefix("have_")
          ["has_#{base}?", "have_#{base}?"]
        else
          []
        end
      end

      # `delegate :foo, :bar, to: :target` — foo/bar are dispatched by ActiveSupport, and
      # `target` is invoked on `self` to obtain the receiver (so it's a reference too).
      # Optionally `prefix: true` or `prefix: :target` changes the generated name.
      def collect_delegate_references(node, location)
        prefix = nil
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            key = assoc.key.slice.delete_suffix(":")
            val = assoc.value

            case key
            when "prefix"
              prefix = if val.is_a?(Prism::TrueNode)
                # `prefix: true` → method name is inferred from :to value; we
                # conservatively emit a method_prefix reference so all prefixed
                # variants stay alive.
                :true_prefix
              elsif val.is_a?(Prism::SymbolNode)
                val.unescaped
              end
            when "to"
              # `to: :reader` calls `reader` on `self` at load/runtime to get the delegation
              # target — a real reference (commonly an attr_reader). Only the symbol form names
              # a self method; `to: "Klass"`/`to: SomeConst` name a constant handled elsewhere.
              if val.is_a?(Prism::SymbolNode)
                @references << Reference.new(name: val.unescaped, location: location, kind: :method)
              end
            end
          end
        end

        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          name = arg.unescaped
          method_name = prefix && prefix != :true_prefix ? "#{prefix}_#{name}" : name
          @references << Reference.new(name: method_name, location: location, kind: :method)

          if prefix == :true_prefix
            # Emit a method_prefix so `target_foo` style names all survive.
            @references << Reference.new(name: "#{name}_", location: location, kind: :method_prefix)
          end
        end
      end

      # AASM event callbacks/guards: `event :activate, after: [:notify], guard: :can?`
      # Also: `error_on_all_events :handle_error`
      def collect_aasm_references(node, location)
        node.arguments.arguments.each do |arg|
          if arg.is_a?(Prism::SymbolNode)
            # First positional symbol: `error_on_all_events :handle_error`
            @references << Reference.new(name: arg.unescaped, location: location, kind: :method)
          elsif arg.is_a?(Prism::KeywordHashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              key = assoc.key.slice.delete_suffix(":")
              next unless AASM_CALLBACK_KEYS.include?(key)

              collect_symbol_or_array(assoc.value, location)
            end
          end
        end
      end

      def collect_symbol_or_array(node, location)
        case node
        when Prism::SymbolNode
          @references << Reference.new(name: node.unescaped, location: location, kind: :method)
        when Prism::ArrayNode
          node.elements.each { |el| collect_symbol_or_array(el, location) }
        end
      end

      # GraphQL-ruby DSL patterns.
      # `builds :thing` → `build_thing` method called by the mutation framework.
      # `argument :x, prepare: :method` → `method` called when resolving the input.
      # `field :x, method: :method_name` / `argument :x, method: :method_name`.
      # `argument :foo_id, loads: SomeType` → graphql-ruby calls a `load_foo` loader
      #   (the argument name with a trailing `_id` stripped, prefixed with `load_`).
      def collect_graphql_references(node, location, method_name:)
        if method_name == "builds"
          node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::SymbolNode)

            @references << Reference.new(
              name: "build_#{arg.unescaped}",
              location: location,
              kind: :method,
            )
          end
          return
        end

        args = node.arguments.arguments
        first = args.first
        arg_name = first.is_a?(Prism::SymbolNode) ? first.unescaped : nil

        # `field :foo` is resolved by calling a same-named method `foo` on the type when one is
        # defined (graphql-ruby's default resolver); emit that so field resolver methods aren't
        # reported dead. Arguments are passed as kwargs (no same-named method), so this is
        # field-only. An explicit `method:`/`resolver_method:` override is handled below too.
        if method_name == "field" && arg_name
          @references << Reference.new(name: arg_name, location: location, kind: :method)
        end

        # argument / field: look for `prepare:`, `method:`, `resolver_method:` and `loads:` options.
        args.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            key = assoc.key
            next unless key.is_a?(Prism::SymbolNode)

            case key.unescaped
            when "prepare", "method", "resolver_method"
              val = assoc.value
              @references << Reference.new(name: val.unescaped, location: location, kind: :method) if val.is_a?(Prism::SymbolNode)
            when "loads"
              # `argument :foo_id, loads: X` → `load_foo` is invoked by graphql-ruby
              # to resolve the argument; the `_id` suffix is stripped by convention.
              next unless arg_name

              @references << Reference.new(name: "load_#{arg_name.delete_suffix('_id')}", location: location, kind: :method)
            end
          end
        end
      end

      def collect_nested_attributes_references(node, location)
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          @references << Reference.new(
            name: "#{arg.unescaped}_attributes",
            location: location,
            kind: :method_prefix,
          )
        end
      end

      # `rescue_from Error, with: :handler` — the `with:` value is dispatched when the error is
      # raised. Positional args are error constants (kept alive by the normal constant-ref pass).
      def collect_rescue_from_references(node, location)
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            next unless assoc.key.slice.delete_suffix(":") == "with"

            collect_symbol_or_array(assoc.value, location)
          end
        end
      end

      # Emit the references a matched send-handler prescribes for a receiver-less DSL call:
      # positional symbols (as methods unless the handler marks them attributes), `if:`/`unless:`
      # guard methods, and (for the validates family) `<Camelized>Validator` option constants.
      def apply_send_handler(handler, node, location)
        node.arguments.arguments.each do |arg|
          case arg
          when Prism::SymbolNode
            @references << Reference.new(name: arg.unescaped, location: location, kind: :method) if handler.positional_methods?
          when Prism::KeywordHashNode, Prism::HashNode
            arg.elements.each { |assoc| apply_send_handler_option(handler, assoc, location) }
          end
        end
      end

      def apply_send_handler_option(handler, assoc, location)
        return unless assoc.is_a?(Prism::AssocNode)

        key = assoc.key.slice.delete_suffix(":")
        if VALIDATOR_CONDITIONAL_KEYS.include?(key)
          collect_symbol_or_array(assoc.value, location) if handler.conditional_options?
        elsif handler.option_constants? && !VALIDATES_STANDARD_OPTIONS.include?(key)
          # `validates :x, strong_password: true` resolves to a `StrongPasswordValidator` class
          # instantiated by ActiveModel; keep that validator constant alive.
          @references << Reference.new(name: "#{camelize(key)}Validator", location: location, kind: :constant)
        end
      end

      # `attribute :foo` / `attributes :a, :b` — keep an overriding reader/writer alive.
      def collect_attribute_references(node, location)
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          @references << Reference.new(name: arg.unescaped, location: location, kind: :method)
          @references << Reference.new(name: "#{arg.unescaped}=", location: location, kind: :method)
          # `attribute :foo, :type` — only the first symbol is the attribute name; the rest are
          # the type/options, so stop after the first.
          break unless node.name.to_s == "attributes"
        end
      end

      # snake_case => CamelCase (e.g. "strong_password" => "StrongPassword").
      def camelize(str)
        str.split("_").map(&:capitalize).join
      end

      # `assert_predicate obj, :foo?` / `refute_predicate obj, :foo?` — the 2nd arg is the
      # predicate method invoked on the object.
      def collect_assert_predicate_reference(node, location)
        predicate = node.arguments.arguments[1]
        return unless predicate.is_a?(Prism::SymbolNode)

        @references << Reference.new(name: predicate.unescaped, location: location, kind: :method)
      end

      # `alias_method :new_name, :old_name` defines new_name as a copy of old_name, so old_name is
      # referenced (and stays alive) even if the original name is never called directly afterward.
      def collect_alias_method_reference(node, location)
        target = node.arguments.arguments.last
        return unless target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode)

        @references << Reference.new(name: target.unescaped, location: location, kind: :method)
      end

      # `method(:foo)` / `obj.method(:foo)` builds a Method object for `foo`, invoking it later with
      # no literal `foo` call site. Emit the method reference so it isn't reported dead.
      def collect_method_handle_reference(node, location)
        arg = node.arguments.arguments.first
        @references << Reference.new(name: arg.unescaped, location: location, kind: :method) if arg.is_a?(Prism::SymbolNode)
      end

      # `const_get(:Foo)` / `const_defined?("A::B")` / `const_source_location(:Foo)` access a
      # constant by name. Reference it (each `::` segment for a string path) so it isn't dead.
      def collect_constant_reflection_references(node, location)
        arg = node.arguments.arguments.first
        case arg
        when Prism::SymbolNode
          @references << Reference.new(name: arg.unescaped, location: location, kind: :constant)
        when Prism::StringNode
          arg.unescaped.split("::").reject(&:empty?).each do |segment|
            @references << Reference.new(name: segment, location: location, kind: :constant)
          end
        end
      end

      # Consult the convention registry for this class and emit the kept-alive references each
      # matching convention prescribes. keep_methods are owner-typed (scoped to this class) so a
      # same-named method elsewhere is still analyzed; keep_prefixes are method-prefix references
      # (kept alive wherever they occur, like the visit_/test_ families); keep_namespace marks the
      # whole class dynamically dispatched (reflection-driven classes — migrations, generators).
      def emit_convention_references(class_node, location)
        superclass = class_node.superclass&.slice
        class_name = node_class_name(class_node)
        includes = included_modules(class_node)

        @conventions.matching(
          superclass: superclass, class_name: class_name, file_path: @file_path, includes: includes,
        ).each do |convention|
          convention.keep_methods.each do |hook|
            @references << Reference.new(name: hook, location: location, kind: :method, receiver_type: current_namespace)
          end
          convention.keep_prefixes.each do |prefix|
            @references << Reference.new(name: prefix, location: location, kind: :method_prefix)
          end
          convention.keep_constants.each do |const|
            # Owner-scoped: reference the fully-qualified constant so only this class's `MSG`
            # (etc.) is kept alive, not a same-named constant elsewhere. current_namespace is always
            # set here — emit_convention_references runs from visit_class_node, inside the class.
            @references << Reference.new(name: "#{current_namespace}::#{const}", location: location, kind: :constant)
          end
          @references << Reference.new(name: current_namespace, location: location, kind: :dynamic_namespace) if convention.keep_namespace?
        end
      end

      # Module names `include`d at the top level of the class body (`include Sidekiq::Job`), used
      # by conventions that match on an included module rather than a superclass.
      def included_modules(class_node)
        body = class_node.body
        return [] unless body.is_a?(Prism::StatementsNode)

        body.body.flat_map do |stmt|
          next [] unless stmt.is_a?(Prism::CallNode) && stmt.name == :include && stmt.receiver.nil?

          stmt.arguments ? stmt.arguments.arguments.map(&:slice) : []
        end
      end

      # Emit read + write references for an operator-assignment to a method receiver
      # (`obj.foo ||= x`, `obj.foo += 1`): both `foo` and `foo=` are invoked.
      def emit_call_write_references(node)
        location = format_location(node.location)
        # A call-operator-write (`recv.msg op= val`) always has an explicit receiver.
        receiver_type = resolve_receiver_type(node.receiver)
        [node.read_name.to_s, node.write_name.to_s].each do |method_name|
          @references << Reference.new(name: method_name, location: location, kind: :method, receiver_type: receiver_type)
        end
      end

      # Emit `key=` writer references for each symbol keyword argument of a mass-assignment
      # call, e.g. `Model.new(foo: x, bar: y)` => references `foo=` and `bar=`.
      def collect_mass_assignment_references(node, location)
        return unless node.arguments

        node.arguments.arguments.each do |arg|
          emit_hash_key_writers(arg, location) if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
        end
      end

      # Bulk-write methods take an array of attribute hashes: `Model.insert_all([{a: 1}, {b: 2}])`.
      # Each hash key sets the corresponding `key=` writer.
      def collect_array_mass_assignment_references(node, location)
        return unless node.arguments

        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::ArrayNode)

          arg.elements.each do |el|
            emit_hash_key_writers(el, location) if el.is_a?(Prism::HashNode)
          end
        end
      end

      # Emit a `key=` writer reference for each symbol key of a hash literal.
      def emit_hash_key_writers(hash_node, location)
        hash_node.elements.each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key = assoc.key
          next unless key.is_a?(Prism::SymbolNode)

          @references << Reference.new(name: "#{key.unescaped}=", location: location, kind: :method)
        end
      end

      # Emit `key=` writer references for the permitted attributes of a strong-params
      # `permit` call. Top-level positional symbols (`permit(:foo)` => `foo=`) and every
      # symbol hash key, at any nesting depth (`permit(apps: [{ category_slugs: [] }])` =>
      # `apps=`, `category_slugs=`), name setters invoked by the eventual mass-assignment.
      # Nesting matters because Rails permits collections as `key: [{ nested_key: [] }]`.
      # Bare symbols inside a value array (`baz: [:x]`) name nested scalar params rather
      # than setters, so they're intentionally not emitted.
      def collect_permit_references(node, location)
        return unless node.arguments

        node.arguments.arguments.each do |arg|
          case arg
          when Prism::SymbolNode
            emit_writer_reference(arg.unescaped, location)
          when Prism::KeywordHashNode, Prism::HashNode
            collect_permit_hash_keys(arg, location)
          end
        end
      end

      # Emit `key=` for each symbol key of a permit hash, then recurse into its values to
      # reach hashes nested inside arrays (`key: [{ nested: [] }]`).
      def collect_permit_hash_keys(hash_node, location)
        hash_node.elements.each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key = assoc.key
          emit_writer_reference(key.unescaped, location) if key.is_a?(Prism::SymbolNode)
          collect_permit_nested(assoc.value, location)
        end
      end

      # Recurse through a permit value: descend into nested hashes (emitting their keys)
      # and walk arrays to find hashes. Bare array-element symbols are left alone.
      def collect_permit_nested(node, location)
        case node
        when Prism::KeywordHashNode, Prism::HashNode
          collect_permit_hash_keys(node, location)
        when Prism::ArrayNode
          node.elements.each { |el| collect_permit_nested(el, location) }
        end
      end

      def emit_writer_reference(name, location)
        @references << Reference.new(name: "#{name}=", location: location, kind: :method)
      end

      # Extract the leading literal text of an interpolated string/symbol, e.g.
      # `"dump_#{x}"` or `:"dump_#{x}"` => "dump_". Returns nil if not interpolated
      # or has no leading literal part.
      def literal_prefix(node)
        node = node.receiver if node.is_a?(Prism::CallNode) && node.receiver # e.g. "...".to_sym
        return nil unless node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedSymbolNode)

        first = node.parts.first
        return nil unless first.is_a?(Prism::StringNode)

        first.unescaped
      end

      # The trailing literal of an interpolated string/symbol, e.g. the `_start_time`
      # in `"#{x}_start_time"`. Returns nil when the last part is not a literal string.
      def literal_suffix(node)
        node = node.receiver if node.is_a?(Prism::CallNode) && node.receiver # e.g. "...".to_sym
        return nil unless node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedSymbolNode)

        last = node.parts.last
        return nil unless last.is_a?(Prism::StringNode)

        last.unescaped
      end

      def resolve_receiver_type(receiver_node)
        return nil unless @type_resolver

        case receiver_node
        when Prism::LocalVariableReadNode
          @local_types[receiver_node.name.to_s]
        when Prism::SelfNode
          current_namespace
        when Prism::ConstantReadNode
          receiver_node.name.to_s
        when Prism::ConstantPathNode
          receiver_node.slice
        when Prism::CallNode
          # For chained calls like `user.company.name`, resolve step by step
          recv_type = resolve_receiver_type(receiver_node.receiver)
          @type_resolver.return_type_of(recv_type, receiver_node.name.to_s)
        end
      end

      # Record the byte-offset span of a class/module's NAME node so its own constant
      # reads (and the nested reads inside a `Foo::Bar` path) are not counted as references
      # to themselves. Anything OUTSIDE this span on the same line — e.g. the superclass —
      # is visited and emitted normally.
      def record_definition_name(constant_path_node)
        loc = constant_path_node.location
        @definition_name_ranges << (loc.start_offset...loc.end_offset)
      end

      # True when `node` falls within a recorded definition-name span (i.e. it IS the name
      # being defined, or a component of it), and so must not be treated as a reference.
      def within_definition_name?(node)
        start_offset = node.location.start_offset
        end_offset = node.location.end_offset
        @definition_name_ranges.any? { |range| range.begin <= start_offset && end_offset <= range.end }
      end

      def node_class_name(class_node)
        class_node.constant_path.slice.split("::").last
      end

      def current_namespace
        return nil if @namespace_stack.empty?

        @namespace_stack.join("::")
      end

      def format_location(loc)
        "#{@file_path}:#{loc.start_line}"
      end
    end
  end
end
