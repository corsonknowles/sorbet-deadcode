# frozen_string_literal: true

module SorbetDeadcode
  module Collector
    # Walks a Prism AST and collects all definitions (classes, modules,
    # methods, constants, accessors) with their owning namespace.
    class DefinitionCollector < Prism::Visitor
      attr_reader :definitions

      def initialize(file_path)
        super()
        @file_path = file_path
        @definitions = []
        @namespace_stack = []
        @enum_stack = [] # parallel to @namespace_stack: is each enclosing class a T::Enum?
        @in_constant_value = false # true while visiting a constant's value (for inline members)
      end

      def visit_class_node(node)
        name = node.constant_path.slice
        full_name = current_namespace_prefix + name
        @definitions << Definition.new(
          name: name,
          full_name: full_name,
          kind: :class,
          location: format_location(node.location),
          superclass_name: superclass_short_name(node),
        )
        @namespace_stack.push(name)
        @enum_stack.push(t_enum_subclass?(node))
        super
        @enum_stack.pop
        @namespace_stack.pop
      end

      def visit_module_node(node)
        name = node.constant_path.slice
        full_name = current_namespace_prefix + name
        @definitions << Definition.new(
          name: name,
          full_name: full_name,
          kind: :module,
          location: format_location(node.location),
        )
        @namespace_stack.push(name)
        @enum_stack.push(false)
        super
        @enum_stack.pop
        @namespace_stack.pop
      end

      def visit_def_node(node)
        name = node.name.to_s
        owner = current_namespace
        @definitions << Definition.new(
          name: name,
          full_name: owner ? "#{owner}##{name}" : name,
          kind: :method,
          location: format_location(node.location),
          owner_name: owner,
          # Body span, so the --cascade pass can drop references that originate inside this method.
          end_line: node.location.end_line,
        )
        super
      end

      def visit_constant_write_node(node)
        # T::Enum values (`Active = new('active')` inside `enums do`) are reached via
        # `.values` / `.deserialize(<string>)` / serialization, not by their Ruby constant,
        # so they must not be reported dead. Skip recording them as definitions.
        return super if enum_value_definition?(node)

        name = node.name.to_s
        @definitions << Definition.new(
          name: name,
          full_name: current_namespace_prefix + name,
          kind: :constant,
          location: format_location(node.location),
          owner_name: current_namespace,
          co_located_names: nested_constant_names(node.value),
          # We're inside another constant's value if the depth guard is set — i.e. this is an
          # inline assignment like `PARENT = [CHILD = 1]`, so CHILD is an inline member.
          inline_member: @in_constant_value,
        )

        # While visiting this constant's value, any nested ConstantWriteNode is an inline member.
        was_in_value = @in_constant_value
        @in_constant_value = true
        super
        @in_constant_value = was_in_value
      end

      # Ruby evaluates assignments inside literals as side effects:
      #   PARENT = [CHILD_A = 'a', CHILD_B = 'b'].freeze
      # defines CHILD_A/CHILD_B. Collect those nested constant names so the parent
      # is never reported dead while a nested child is still alive.
      def nested_constant_names(value)
        names = []
        collect_nested_constant_writes(value, names)
        names
      end

      def collect_nested_constant_writes(node, names)
        case node
        when Prism::ConstantWriteNode
          names << node.name.to_s
          collect_nested_constant_writes(node.value, names)
        when Prism::ArrayNode
          node.elements.each { |el| collect_nested_constant_writes(el, names) }
        when Prism::HashNode
          node.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            collect_nested_constant_writes(assoc.value, names)
          end
        when Prism::CallNode
          # e.g. `[...].freeze` — descend into the receiver, and into call arguments so
          # the common Sorbet form `PARENT = T.let([CHILD = ...].freeze, T::Array[...])`
          # (where the array is an argument, not the receiver) still records its children.
          collect_nested_constant_writes(node.receiver, names) if node.receiver
          node.arguments&.arguments&.each { |arg| collect_nested_constant_writes(arg, names) }
        end
      end

      def visit_call_node(node)
        if node.receiver.nil?
          case node.name.to_s
          when "attr_reader"
            collect_accessors(node, :attr_reader)
          when "attr_writer"
            collect_accessors(node, :attr_writer)
          when "attr_accessor"
            collect_accessors(node, :attr_reader)
            collect_accessors(node, :attr_writer)
          end
        end
        super
      end

      private

      # `class Foo < T::Enum` (also matches the fully-qualified `< ::T::Enum`).
      def t_enum_subclass?(node)
        node.superclass&.slice&.delete_prefix("::") == "T::Enum"
      end

      # Short (demodulized) name of a class's direct superclass, e.g. `< A::Base` => "Base".
      def superclass_short_name(node)
        node.superclass&.slice&.split("::")&.last
      end

      # A constant assigned a bare `new(...)` inside a T::Enum subclass — i.e. an enum value.
      def enum_value_definition?(node)
        return false unless @enum_stack.last
        return false unless node.value.is_a?(Prism::CallNode)

        node.value.receiver.nil? && node.value.name.to_s == "new"
      end

      def collect_accessors(node, kind)
        return unless node.arguments

        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)

          name = arg.unescaped
          writer_name = kind == :attr_writer ? "#{name}=" : name
          owner = current_namespace
          @definitions << Definition.new(
            name: writer_name,
            full_name: owner ? "#{owner}##{writer_name}" : writer_name,
            kind: kind,
            location: format_location(arg.location),
            owner_name: owner,
          )
        end
      end

      def current_namespace
        return nil if @namespace_stack.empty?

        @namespace_stack.join("::")
      end

      def current_namespace_prefix
        ns = current_namespace
        ns ? "#{ns}::" : ""
      end

      def format_location(loc)
        "#{@file_path}:#{loc.start_line}"
      end
    end
  end
end
