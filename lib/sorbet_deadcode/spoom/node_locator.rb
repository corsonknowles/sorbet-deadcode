# frozen_string_literal: true

module SorbetDeadcode
  module Spoom
    # Pure-Prism locator that resolves a definition's exact source location.
    #
    # spoom's Deadcode::Remover finds the node to delete by EXACT location equality
    # (start_line:start_column-end_line:end_column), but our Definition only records
    # `file:start_line`. NodeLocator re-parses the file and recovers the full node location
    # so we can hand spoom what it needs. It deliberately has no spoom dependency, so it is
    # unit-tested on its own; Spoom::Remover feeds its result into spoom's Location/Remover.
    module NodeLocator
      module_function

      Loc = Struct.new(:start_line, :start_column, :end_line, :end_column, keyword_init: true)

      # Constant assignment node types spoom's Remover can delete. Mirrors the constant arm of
      # NodeRemover#apply_edit so we only claim a match for nodes spoom actually handles.
      CONSTANT_WRITE_NODES = [
        Prism::ConstantWriteNode,
        Prism::ConstantOperatorWriteNode,
        Prism::ConstantAndWriteNode,
        Prism::ConstantOrWriteNode,
      ].freeze

      # @param source [String] the file's current contents
      # @param kind [Symbol] :method / :class / :module / :constant
      # @param name [String, Symbol, nil] short (demodulized) definition name; disambiguates
      #   multiple nodes sharing a start line (e.g. `A = B = 1`). When nil, line+kind alone match.
      # @param line [Integer] the definition's start line (Definition#line)
      # @return [Loc, nil] the precise node location, or nil if no matching node is found.
      def locate(source, kind:, name:, line:)
        node = find(Prism.parse(source).value, kind, name&.to_s, line)
        return unless node

        loc = node.location
        Loc.new(
          start_line: loc.start_line,
          start_column: loc.start_column,
          end_line: loc.end_line,
          end_column: loc.end_column,
        )
      end

      # Pre-order search for the first node matching (kind, name, line).
      def find(node, kind, name, line)
        return node if matches?(node, kind, name, line)

        node.compact_child_nodes.each do |child|
          found = find(child, kind, name, line)
          return found if found
        end
        nil
      end

      def matches?(node, kind, name, line)
        return false unless node.location.start_line == line
        return false unless kind_matches?(node, kind)

        # Every node kind_matches? admits (Def/Class/Module/Constant* writes) responds to #name.
        name.nil? || node.name.to_s == name
      end

      def kind_matches?(node, kind)
        case kind
        when :method then node.is_a?(Prism::DefNode)
        when :class then node.is_a?(Prism::ClassNode)
        when :module then node.is_a?(Prism::ModuleNode)
        when :constant then CONSTANT_WRITE_NODES.any? { |klass| node.is_a?(klass) }
        else false
        end
      end
    end
  end
end
