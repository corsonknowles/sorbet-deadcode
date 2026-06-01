# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Scans Rails route files to extract controller action references.
    #
    # Controller actions are referenced from routes like:
    #   get '/widgets', to: 'widgets#index'
    #   namespace :admin { resources :companies }
    #
    # Without route scanning, every controller action appears dead because
    # nothing in Ruby source explicitly calls `widgets_controller.index`.
    class RouteScanner
      def initialize(project_root)
        @project_root = File.expand_path(project_root)
      end

      # Returns an Array of Reference objects for all discovered controller actions.
      def references
        route_files.flat_map { |f| scan_file(f) }
      end

      private

      def route_files
        main = File.join(@project_root, "config", "routes.rb")
        return [] unless File.exist?(main)

        # Also scan any split route files under config/routes/
        extras = Dir.glob(File.join(@project_root, "config", "routes", "**", "*.rb"))
        [main, *extras]
      end

      def scan_file(path)
        source = File.read(path)
        result = Prism.parse(source)
        return [] unless result.success?

        collector = RouteReferenceCollector.new(path)
        collector.visit(result.value)
        collector.references
      rescue StandardError
        []
      end
    end

    # Prism visitor that walks a routes file and emits method references for
    # every `to: 'controller#action'` style declaration.
    #
    # Also handles:
    # - `resources :widgets` / `resource :widget` → standard CRUD actions as
    #   method references on the inferred controller class
    # - `namespace :admin { }` / `scope module: 'admin' { }` → namespace tracking
    # - `controller :widgets { get :index }` → action references on explicit controller
    class RouteReferenceCollector < Prism::Visitor
      ROUTE_METHODS = %w[get post put patch delete match root].to_set.freeze
      CRUD_ACTIONS = %w[index show new create edit update destroy].freeze

      attr_reader :references

      def initialize(file_path)
        super()
        @file_path = file_path
        @references = []
        @namespace_stack = []    # e.g. ["admin", "billing"]
        @controller_stack = []   # explicit `controller :foo` blocks
      end

      def visit_call_node(node)
        name = node.name.to_s
        location = "#{@file_path}:#{node.location.start_line}"

        case name
        when *ROUTE_METHODS
          collect_route_reference(node, location)
        when "resources", "resource"
          collect_resources_references(node, location, singular: name == "resource")
        when "namespace"
          visit_with_namespace(node)
          return # already visited children
        when "scope"
          visit_with_scope_namespace(node)
          return
        when "controller"
          visit_with_controller(node)
          return
        end

        super
      end

      private

      # Extract the controller/action a route verb maps to. Handles both forms:
      #   get '/x', to: 'admin/widgets#index'
      #   get '/x', controller: 'admin/widgets', action: 'index'   (string or symbol)
      #   get :index, controller: :widgets                          (action as 1st arg)
      def collect_route_reference(node, location)
        return unless node.arguments

        to = controller = action = nil
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            case assoc.key.slice.delete_suffix(":")
            when "to" then to = symbol_or_string(assoc.value)
            when "controller" then controller = symbol_or_string(assoc.value)
            when "action" then action = symbol_or_string(assoc.value)
            else
              # Hash-rocket form: `get '/path' => 'controller#action'` (string URL key).
              value = symbol_or_string(assoc.value)
              to ||= value if value&.include?("#")
            end
          end
        end

        if to&.include?("#")
          emit_to_reference(to, location)
        elsif controller
          # `get :show, controller: :widgets` — action defaults to the leading symbol arg.
          action ||= leading_symbol_arg(node)
          emit_controller_action(controller_class_name(controller, namespace: @namespace_stack), action, location)
        end
      end

      # The first positional argument, when it's a symbol (the action shorthand).
      def leading_symbol_arg(node)
        first = node.arguments.arguments.first
        first.unescaped if first.is_a?(Prism::SymbolNode)
      end

      # `resources :widgets` → references for all CRUD actions on WidgetsController.
      # `resource :widget` → references for CRUD except :index.
      def collect_resources_references(node, location, singular:)
        return unless node.arguments

        controller_name = nil
        only_actions = nil
        except_actions = nil
        module_opt = nil

        first_arg = node.arguments.arguments.first
        resource_name = case first_arg
                        when Prism::SymbolNode then first_arg.unescaped
                        when Prism::StringNode then first_arg.unescaped
                        end
        return unless resource_name

        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            k = assoc.key.slice.delete_suffix(":")
            v = assoc.value
            case k
            when "controller"
              controller_name = symbol_or_string(v)
            when "module"
              module_opt = symbol_or_string(v)
            when "only"
              only_actions = extract_symbol_array(v)
            when "except"
              except_actions = extract_symbol_array(v)
            end
          end
        end

        # Infer controller name from resource name
        controller_name ||= resource_name
        ns = @namespace_stack.dup
        ns << module_opt if module_opt
        class_name = controller_class_name(controller_name, namespace: ns)

        actions = singular ? CRUD_ACTIONS - ["index"] : CRUD_ACTIONS.dup
        actions = actions & only_actions if only_actions
        actions -= except_actions if except_actions

        unless actions.empty?
          # Emit the controller class as a constant reference so it's not reported dead.
          @references << Reference.new(name: class_name.split("::").last, location: location, kind: :constant)
          @references << Reference.new(name: class_name, location: location, kind: :constant)
        end

        actions.each do |action|
          @references << Reference.new(
            name: action,
            location: location,
            kind: :method,
            receiver_type: class_name,
          )
        end
      end

      # Push a namespace segment for the duration of the block.
      def visit_with_namespace(node)
        seg = first_symbol_or_string_arg(node)
        if seg
          @namespace_stack.push(seg)
          visit_block_children(node)
          @namespace_stack.pop
        else
          visit_block_children(node)
        end
      end

      # `scope module: 'admin'` adds a namespace prefix without an extra URL segment.
      def visit_with_scope_namespace(node)
        mod_seg = keyword_arg_value(node, "module")
        if mod_seg
          @namespace_stack.push(mod_seg)
          visit_block_children(node)
          @namespace_stack.pop
        else
          visit_block_children(node)
        end
      end

      # `controller :widgets { ... }` sets the default controller for the block.
      def visit_with_controller(node)
        ctrl = first_symbol_or_string_arg(node)
        @controller_stack.push(ctrl) if ctrl
        visit_block_children(node)
        @controller_stack.pop if ctrl
      end

      def visit_block_children(node)
        return unless node.block.respond_to?(:body) && node.block&.body

        visit(node.block.body)
      end

      # Parse `'controller#action'` or `'namespace/controller#action'`
      # and emit a typed method reference.
      def emit_to_reference(to_string, location)
        controller_part, action = to_string.split("#", 2)
        return unless action

        emit_controller_action(controller_class_name(controller_part, namespace: @namespace_stack), action, location)
      end

      # Emit a constant reference for the controller class (short + fully-qualified, so it's
      # kept alive regardless of how the analyzer named it) and, when known, a typed method
      # reference for the action.
      def emit_controller_action(class_name, action, location)
        @references << Reference.new(name: class_name.split("::").last, location: location, kind: :constant)
        @references << Reference.new(name: class_name, location: location, kind: :constant)
        return unless action

        @references << Reference.new(name: action, location: location, kind: :method, receiver_type: class_name)
      end

      # Convert `'admin/widgets'` + namespace stack `["billing"]` →
      # `"Billing::Admin::WidgetsController"`.
      def controller_class_name(controller_path, namespace:)
        parts = controller_path.split("/").map { |p| camelize(p) }
        all_parts = namespace.map { |n| camelize(n.to_s) } + parts
        last = all_parts.last
        all_parts[-1] = last.end_with?("Controller") ? last : "#{last}Controller"
        all_parts.join("::")
      end

      def camelize(str)
        str.split("_").map(&:capitalize).join
      end

      def symbol_or_string(node)
        case node
        when Prism::SymbolNode then node.unescaped
        when Prism::StringNode then node.unescaped
        end
      end

      def first_symbol_or_string_arg(node)
        return unless node.arguments

        symbol_or_string(node.arguments.arguments.first)
      end

      def keyword_arg_value(node, key)
        return unless node.arguments

        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            return symbol_or_string(assoc.value) if assoc.key.slice.delete_suffix(":") == key
          end
        end
        nil
      end

      def extract_symbol_array(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then [node.unescaped]
        when Prism::ArrayNode
          node.elements.filter_map { |el| symbol_or_string(el) }
        end
      end
    end
  end
end
