# frozen_string_literal: true

module SorbetDeadcode
  module Collector
    # Walks a Prism AST and collects all references (method calls, constant
    # lookups). When a Sorbet sig is available on the receiver, the reference
    # is typed — meaning we know which class the method is called on.
    class ReferenceCollector < Prism::Visitor
      attr_reader :references

      DYNAMIC_DISPATCH_METHODS = %w[send __send__ public_send try].to_set.freeze

      def initialize(file_path, type_resolver: nil)
        super()
        @file_path = file_path
        @references = []
        @type_resolver = type_resolver
        @namespace_stack = []
        @local_types = {}
        @definition_locations = Set.new
        @current_method_name = nil
      end

      def visit_class_node(node)
        @definition_locations << node.constant_path.location.start_line
        @namespace_stack.push(node.constant_path.slice)
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

        if @type_resolver && current_namespace
          sig = @type_resolver.method_signatures.dig(current_namespace, @current_method_name)
          if sig
            sig[:params].each do |param_name, param_type|
              @local_types[param_name] = param_type
            end
          end
        end

        super

        @current_method_name = old_method
        # Clear param types after leaving the method
        if @type_resolver && current_namespace
          sig = @type_resolver.method_signatures.dig(current_namespace, @current_method_name.to_s)
          sig&.dig(:params)&.each_key { |k| @local_types.delete(k) }
        end
      end

      def visit_call_node(node)
        name = node.name.to_s
        location = format_location(node.location)

        if DYNAMIC_DISPATCH_METHODS.include?(name) && node.arguments
          collect_dynamic_dispatch(node, location)
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

        @references << Reference.new(
          name: node.slice,
          location: format_location(node.location),
          kind: :constant,
        )
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
        super
      end

      private

      def collect_dynamic_dispatch(node, location)
        first_arg = node.arguments.arguments.first
        return unless first_arg.is_a?(Prism::SymbolNode)

        receiver_type = node.receiver ? resolve_receiver_type(node.receiver) : nil

        @references << Reference.new(
          name: first_arg.unescaped,
          location: location,
          kind: :method,
          receiver_type: receiver_type,
        )
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
