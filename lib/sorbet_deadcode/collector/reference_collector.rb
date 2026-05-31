# frozen_string_literal: true

module SorbetDeadcode
  module Collector
    # Walks a Prism AST and collects all references (method calls, constant
    # lookups). When a Sorbet sig is available on the receiver, the reference
    # is typed — meaning we know which class the method is called on.
    class ReferenceCollector < Prism::Visitor
      attr_reader :references

      DYNAMIC_DISPATCH_METHODS = %w[send __send__ public_send try].to_set.freeze

      # Rails `delegate :foo, :bar, to: :target` creates forwarding methods.
      # The delegated names are referenced via define_method at class load time.
      DELEGATE_DSL_METHODS = %w[delegate].to_set.freeze

      # AASM `event :activate, after: [:notify], guard: :can_activate?` dispatches
      # symbol names as callbacks or guards. Also handles `error_on_all_events :method`.
      AASM_DSL_METHODS = %w[
        error_on_all_events
        aasm_event event
      ].to_set.freeze

      # GraphQL-ruby DSL patterns that reference Ruby methods by symbol.
      # `builds :foo` → calls `build_foo`
      # `argument :x, prepare: :method` → calls `method`
      # `field :x, method: :method_name` → calls `method_name`
      GRAPHQL_DSL_METHODS = %w[builds argument field mutation].to_set.freeze

      # ActiveModel/Rails DSL methods that take symbol names of methods to call.
      # `validate :method_name` dispatches via send(method_name) during validation.
      # `before_validation/after_validation :method` similarly dispatches.
      VALIDATOR_DSL_METHODS = %w[
        validate
        before_validation after_validation
        before_create after_create around_create
        before_update after_update around_update
        before_save after_save around_save
        before_destroy after_destroy around_destroy
        after_commit after_rollback
        after_initialize after_find
        before_action after_action around_action
        prepend_before_action append_before_action
        skip_before_action
        after_update before_update
      ].to_set.freeze

      def initialize(file_path, type_resolver: nil)
        super()
        @file_path = file_path
        @references = []
        @type_resolver = type_resolver
        @namespace_stack = []
        @local_types = {}
        @definition_locations = Set.new
        @current_method_name = nil
        # Issue #10 fix 1: local var name => interpolation prefix (e.g. m = "dump_#{x}")
        @local_prefixes = {}
        # Issue #10 fix 2: constant name => [symbol names] for literal symbol arrays
        @symbol_array_constants = {}
        # Issue #10 fix 2: block-param name => [symbol names] currently in scope
        @iterated_symbols = {}
      end

      def visit_class_node(node)
        @definition_locations << node.constant_path.location.start_line
        @namespace_stack.push(node.constant_path.slice)

        # If this class inherits from a Visitor-protocol base (e.g. Prism::Visitor,
        # Prism::BasicVisitor), its visit_* methods are dispatched dynamically by
        # the framework via public_send("visit_#{type}", node). Emit a method_prefix
        # reference so the existing dynamically_dispatched? guard keeps them alive.
        location = format_location(node.location)

        if visitor_subclass?(node)
          # Prism::Visitor subclasses: visit_* methods dispatched by framework.
          @references << Reference.new(name: "visit_", location: location, kind: :method_prefix)
        end

        if mailer_preview_class?(node)
          # ActionMailer::Preview subclasses: preview methods are invoked by the
          # Rails mail preview UI via routing, not by explicit Ruby calls.
          # Mark the whole namespace as dynamically dispatched so all its methods
          # (the preview actions) are kept alive.
          ns = node.constant_path.slice
          @references << Reference.new(name: ns, location: location, kind: :dynamic_namespace)
        end

        super
        @namespace_stack.pop
      end

      def visit_module_node(node)
        @definition_locations << node.constant_path.location.start_line
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_def_node(node)
        old_method = @current_method_name
        @current_method_name = node.name.to_s

        added_params = []
        if @type_resolver && current_namespace
          sig = @type_resolver.method_signatures.dig(current_namespace, @current_method_name)
          sig&.dig(:params)&.each do |param_name, param_type|
            @local_types[param_name] = param_type
            added_params << param_name
          end
        end

        super

        # Clear only the param types we added for this method.
        added_params.each { |k| @local_types.delete(k) }
        @current_method_name = old_method
      end

      ITERATION_METHODS = %w[each map flat_map collect each_with_object select filter reject find detect].to_set.freeze

      def visit_call_node(node)
        name = node.name.to_s
        location = format_location(node.location)

        # Issue #10 fix 2: `[:a, :b].each { |m| send(m) }` or `METHODS.each { |m| ... }`.
        # Bind the block param to the resolved symbol list while visiting the block.
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
        elsif VALIDATOR_DSL_METHODS.include?(name) && node.receiver.nil? && node.arguments
          # ActiveModel/Rails validator DSL: `validate :check_something` calls the
          # named method via send when running validations. Collect each symbol arg
          # as a method reference so the target is never reported dead.
          collect_validator_references(node, location)
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
        return super if @definition_locations.include?(node.location.start_line)

        @references << Reference.new(
          name: node.name.to_s,
          location: format_location(node.location),
          kind: :constant,
        )
        super
      end

      def visit_constant_path_node(node)
        return super if @definition_locations.include?(node.location.start_line)

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

        # Issue #10 fix 1: track `m = "dump_#{x}"` so a later send(m) can emit a
        # precise method_prefix reference instead of excluding the whole namespace.
        prefix = literal_prefix(node.value)
        if prefix && !prefix.empty?
          @local_prefixes[node.name.to_s] = prefix
        end

        super
      end

      # Issue #10 fix 2: track `METHODS = [:a, :b]` so iteration over the constant
      # can resolve the dispatched method names.
      def visit_constant_write_node(node)
        syms = symbol_array_values(node.value)
        @symbol_array_constants[node.name.to_s] = syms if syms
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

        # Issue #10 fix 2: variable bound to a finite symbol list via iteration,
        # e.g. `[:a, :b].each { |m| send(m) }` => emit each concrete method name.
        if first_arg.is_a?(Prism::LocalVariableReadNode) && @iterated_symbols.key?(first_arg.name.to_s)
          receiver_type = node.receiver ? resolve_receiver_type(node.receiver) : nil
          @iterated_symbols[first_arg.name.to_s].each do |sym|
            @references << Reference.new(name: sym, location: location, kind: :method, receiver_type: receiver_type)
          end
          return
        end

        # Issue #10 fix 1: variable assigned an interpolated string with a literal
        # prefix, e.g. `m = "dump_#{x}"; send(m)` => emit the `dump_` prefix.
        if first_arg.is_a?(Prism::LocalVariableReadNode) && @local_prefixes.key?(first_arg.name.to_s)
          @references << Reference.new(name: @local_prefixes[first_arg.name.to_s], location: location, kind: :method_prefix)
          return
        end

        # Non-literal target: the method name is built at runtime.
        prefix = literal_prefix(first_arg)
        if prefix && !prefix.empty?
          # e.g. public_send("dump_#{type}") => any `dump_*` method may be reached.
          @references << Reference.new(name: prefix, location: location, kind: :method_prefix)
        elsif current_namespace
          # e.g. __send__(method_name) inside a class => any method in this
          # namespace may be reached; exclude them from dead results (conservative
          # fallback — see issue #10).
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

      # `delegate :foo, :bar, to: :target` — foo= and bar are dispatched by ActiveSupport.
      # Optionally `prefix: true` or `prefix: :target` changes the generated name.
      def collect_delegate_references(node, location)
        prefix = nil
        node.arguments.arguments.each do |arg|
          if arg.is_a?(Prism::KeywordHashNode)
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              key = assoc.key.slice.delete_suffix(":")
              next unless key == "prefix"

              val = assoc.value
              prefix = if val.is_a?(Prism::TrueNode)
                # `prefix: true` → method name is inferred from :to value; we
                # conservatively emit a method_prefix reference so all prefixed
                # variants stay alive.
                :true_prefix
              elsif val.is_a?(Prism::SymbolNode)
                val.unescaped
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
              next unless %w[after before guard after_commit after_rollback on_transition error].include?(key)

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

        # argument / field: look for `prepare:` and `method:` keyword options.
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            key = assoc.key.slice.delete_suffix(":")
            next unless %w[prepare method].include?(key)

            val = assoc.value
            next unless val.is_a?(Prism::SymbolNode)

            @references << Reference.new(name: val.unescaped, location: location, kind: :method)
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

      def collect_validator_references(node, location)
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          @references << Reference.new(
            name: arg.unescaped,
            location: location,
            kind: :method,
          )
        end
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

      # Returns true when the class inherits from any class whose name contains
      # "Visitor" — covers Prism::Visitor, Prism::BasicVisitor, and custom visitor
      # base classes following the same naming convention.
      def visitor_subclass?(class_node)
        superclass = class_node.superclass
        return false unless superclass

        superclass.slice.include?("Visitor")
      end

      # ActionMailer::Preview subclasses are invoked by the Rails preview UI via
      # routes, not by explicit Ruby calls. Covers both direct inheritance and the
      # naming convention (classes whose name ends in MailerPreview / Preview).
      def mailer_preview_class?(class_node)
        superclass = class_node.superclass
        name = node_class_name(class_node)

        (superclass && superclass.slice.include?("Preview")) ||
          name.end_with?("MailerPreview") ||
          name.end_with?("Preview")
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
