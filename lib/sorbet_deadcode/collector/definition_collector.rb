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
      end

      def visit_class_node(node)
        name = node.constant_path.slice
        full_name = current_namespace_prefix + name
        @definitions << Definition.new(
          name: name,
          full_name: full_name,
          kind: :class,
          location: format_location(node.location),
        )
        @namespace_stack.push(name)
        super
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
        super
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
        )
        super
      end

      def visit_constant_write_node(node)
        name = node.name.to_s
        @definitions << Definition.new(
          name: name,
          full_name: current_namespace_prefix + name,
          kind: :constant,
          location: format_location(node.location),
          owner_name: current_namespace,
        )
        super
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
