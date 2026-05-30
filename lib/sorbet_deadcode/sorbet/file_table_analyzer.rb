# frozen_string_literal: true

require "json"
require "open3"

module SorbetDeadcode
  module Sorbet
    class FileTableAnalyzer
      # Sorbet's --print=file-table-json only outputs file metadata (path, strictness).
      # For definitions, we use --print=symbol-table-json which dumps the full symbol
      # table as a nested JSON structure. However, this only contains definitions (classes,
      # modules, methods) — NOT references/call sites. Dead code detection therefore relies
      # on comparing the symbol table against Prism-collected references.
      #
      # Limitation: This approach cannot detect references that only exist in Sorbet's
      # type-level analysis (e.g., calls resolved through T.let/T.cast). For full
      # type-aware analysis, use --lsp or --hybrid mode.

      attr_reader :dead_definitions

      def initialize(project_root:, paths:, exclude_paths: [])
        @project_root = File.expand_path(project_root)
        @paths = Array(paths)
        @exclude_paths = Array(exclude_paths)
        @dead_definitions = []
      end

      def run
        symbol_table = load_symbol_table
        unless symbol_table
          $stderr.puts "Failed to load Sorbet symbol table. Falling back to Prism-only analysis."
          return fallback_prism_analysis
        end

        definitions = extract_definitions(symbol_table)
        if definitions.empty?
          $stderr.puts "No definitions found in symbol table."
          return []
        end

        $stderr.puts "Symbol table contains #{definitions.size} definitions."

        references = collect_prism_references
        @dead_definitions = find_dead(definitions, references)
        @dead_definitions
      end

      private

      def load_symbol_table
        cmd = ["bundle", "exec", "srb", "tc", "--print=symbol-table-json"]
        stdout, stderr, status = Open3.capture3(*cmd, chdir: @project_root)

        unless status.success?
          $stderr.puts "srb tc --print=symbol-table-json failed: #{stderr.lines.first}"
          return nil
        end

        JSON.parse(stdout)
      rescue JSON::ParserError => e
        $stderr.puts "Failed to parse symbol table JSON: #{e.message}"
        nil
      end

      def extract_definitions(node, namespace: [])
        defs = []
        return defs unless node.is_a?(Hash)

        name_info = node["name"]
        kind = node["kind"]

        if name_info && kind
          name = name_info["name"]
          name_kind = name_info["kind"]

          unless synthetic_name?(name)
            case kind
            when "CLASS_OR_MODULE"
              if name_kind == "CONSTANT"
                full_name = (namespace + [name]).join("::")
                defs << build_definition(
                  name: name,
                  full_name: full_name,
                  kind: :class,
                  namespace: namespace,
                )
              end
            when "METHOD"
              if name_kind == "UTF8" && !synthetic_name?(name)
                owner = namespace.last
                full_name = owner ? "#{namespace.join("::")}##{name}" : name
                defs << build_definition(
                  name: name,
                  full_name: full_name,
                  kind: :method,
                  namespace: namespace,
                )
              end
            end
          end
        end

        children = node["children"]
        if children.is_a?(Array)
          child_ns = if node.dig("name", "kind") == "CONSTANT" && !synthetic_name?(node.dig("name", "name"))
            namespace + [node.dig("name", "name")]
          else
            namespace
          end

          children.each do |child|
            defs.concat(extract_definitions(child, namespace: child_ns))
          end
        end

        defs
      end

      def synthetic_name?(name)
        return true unless name
        name.start_with?("<") || name == "initialize"
      end

      def build_definition(name:, full_name:, kind:, namespace:)
        owner = namespace.empty? ? nil : namespace.join("::")
        Definition.new(
          name: name,
          full_name: full_name,
          kind: kind,
          location: "symbol-table",
          owner_name: owner,
        )
      end

      def collect_prism_references
        analyzer = Analyzer::DeadCodeAnalyzer.new(
          paths: @paths,
          exclude_paths: @exclude_paths,
        )
        files = analyzer.send(:collect_files)
        files.each { |f| analyzer.send(:index_file, f) }
        analyzer.references
      end

      def find_dead(definitions, references)
        ref_method_names = Set.new
        ref_constant_names = Set.new

        references.each do |ref|
          case ref.kind
          when :method
            ref_method_names << ref.name
          when :constant
            ref_constant_names << ref.name
          end
        end

        definitions.select do |defn|
          case defn.kind
          when :class, :module
            !ref_constant_names.include?(defn.name) &&
              !ref_constant_names.include?(defn.full_name)
          when :method
            !ref_method_names.include?(defn.name)
          else
            true
          end
        end
      end

      def fallback_prism_analysis
        Analyzer::DeadCodeAnalyzer.new(
          paths: @paths,
          exclude_paths: @exclude_paths,
        ).run
      end
    end
  end
end
