# frozen_string_literal: true

module SorbetDeadcode
  module Analyzer
    class DeadCodeAnalyzer
      attr_reader :definitions, :references, :type_resolver

      def initialize(paths:, exclude_paths: [])
        @paths = Array(paths)
        @exclude_paths = Array(exclude_paths)
        @definitions = []
        @references = []
        @type_resolver = Resolver::TypeResolver.new
      end

      def run
        files = collect_files
        index_files(files)
        dead_definitions
      end

      def dead_definitions
        alive_names = build_alive_set
        @definitions.reject { |d| alive?(d, alive_names) }
      end

      private

      def collect_files
        @paths.flat_map { |path|
          if File.file?(path)
            [path]
          else
            Dir.glob(File.join(path, "**", "*.rb"))
          end
        }.reject { |f|
          @exclude_paths.any? { |ep| f.include?(ep) }
        }.sort
      end

      def index_files(files)
        files.each { |file| index_file(file) }
      end

      def index_file(file)
        source = File.read(file)
        result = Prism.parse(source)
        return unless result.success?

        node = result.value

        def_collector = Collector::DefinitionCollector.new(file)
        def_collector.visit(node)
        @definitions.concat(def_collector.definitions)

        extract_type_info(node, file)

        ref_collector = Collector::ReferenceCollector.new(file, type_resolver: @type_resolver)
        ref_collector.visit(node)
        @references.concat(ref_collector.references)
      end

      def extract_type_info(node, file)
        SigExtractor.new(file, @type_resolver).visit(node)
      end

      # Determine if a definition is alive based on references
      def alive?(definition, alive_names)
        case definition.kind
        when :class, :module
          alive_names[:constants].include?(definition.name) ||
            alive_names[:constants].include?(definition.full_name)
        when :constant
          alive_names[:constants].include?(definition.name) ||
            alive_names[:constants].include?(definition.full_name)
        when :method, :attr_reader, :attr_writer
          typed_alive?(definition) || name_alive?(definition, alive_names)
        else
          false
        end
      end

      # Type-aware liveness: if ANY reference specifies this definition's
      # owner type, only that typed reference counts.
      def typed_alive?(definition)
        return false unless definition.owner_name

        @references.any? do |ref|
          ref.kind == :method &&
            ref.name == definition.name &&
            ref.typed? &&
            ref.receiver_type == definition.owner_name
        end
      end

      # Name-based liveness: fallback when no typed references exist.
      # A definition is alive if any untyped reference shares its name.
      def name_alive?(definition, alive_names)
        # If there are typed references for this name but none match our owner,
        # the definition is dead even though the name appears in references.
        has_typed_refs = @references.any? { |r|
          r.kind == :method && r.name == definition.name && r.typed?
        }

        if has_typed_refs
          # All references to this name are typed — none matched our owner
          # in typed_alive?, so this definition is dead.
          false
        else
          alive_names[:methods].include?(definition.name)
        end
      end

      def build_alive_set
        methods = Set.new
        constants = Set.new

        @references.each do |ref|
          case ref.kind
          when :method
            methods << ref.name unless ref.typed?
          when :constant
            constants << ref.name
          end
        end

        { methods: methods, constants: constants }
      end
    end

    # Extracts type information from Sorbet sig blocks
    class SigExtractor < Prism::Visitor
      def initialize(file_path, type_resolver)
        super()
        @file_path = file_path
        @type_resolver = type_resolver
        @namespace_stack = []
        @pending_sig = nil
      end

      def visit_class_node(node)
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_module_node(node)
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_call_node(node)
        if node.receiver.nil? && node.name.to_s == "sig"
          @pending_sig = extract_sig_info(node)
        end
        super
      end

      def visit_def_node(node)
        if @pending_sig && current_namespace
          @type_resolver.register_method(
            owner: current_namespace,
            method_name: node.name.to_s,
            return_type: @pending_sig[:returns],
            param_types: @pending_sig[:params],
          )
        end
        @pending_sig = nil
        super
      end

      private

      def current_namespace
        return nil if @namespace_stack.empty?

        @namespace_stack.join("::")
      end

      def extract_sig_info(sig_node)
        info = { params: {}, returns: nil }

        block = sig_node.block
        return info unless block

        body = case block
        when Prism::BlockNode then block.body
        when Prism::LambdaNode then block.body
        else return info
        end

        return info unless body

        visit_sig_chain(body, info)
        info
      end

      def visit_sig_chain(node, info)
        case node
        when Prism::StatementsNode
          node.body.each { |n| visit_sig_chain(n, info) }
        when Prism::CallNode
          case node.name.to_s
          when "returns"
            arg = node.arguments&.arguments&.first
            info[:returns] = extract_type_name(arg) if arg
          when "params"
            extract_params(node, info)
          end
          visit_sig_chain(node.receiver, info) if node.receiver
        end
      end

      def extract_type_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          node.slice
        when Prism::CallNode
          # T.nilable(Foo) etc — extract the inner type
          if node.receiver&.slice == "T"
            arg = node.arguments&.arguments&.first
            return extract_type_name(arg) if arg
          end
          node.slice
        else
          node.slice
        end
      end

      def extract_params(node, info)
        node.arguments&.arguments&.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            param_name = assoc.key.slice.delete_suffix(":")
            param_type = extract_type_name(assoc.value)
            info[:params][param_name] = param_type
          end
        end
      end
    end
  end
end
