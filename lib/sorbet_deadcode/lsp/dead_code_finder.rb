# frozen_string_literal: true

module SorbetDeadcode
  module Lsp
    class DeadCodeFinder
      attr_reader :dead_definitions

      def initialize(project_root:, paths:, exclude_paths: [], parallel: 1)
        @project_root = File.expand_path(project_root)
        @paths = Array(paths)
        @exclude_paths = Array(exclude_paths)
        @parallel = [parallel.to_i, 1].max
        @dead_definitions = []
      end

      def run
        files = collect_files
        definitions = collect_definitions(files)

        if definitions.empty?
          $stderr.puts "No definitions found."
          return []
        end

        $stderr.puts "Found #{definitions.size} definitions to check."

        client = Client.new(@project_root)
        begin
          @dead_definitions = find_dead(client, definitions)
        ensure
          client.shutdown
        end

        @dead_definitions
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

      def collect_definitions(files)
        definitions = []
        files.each do |file|
          source = File.read(file)
          result = Prism.parse(source)
          next unless result.success?

          collector = Collector::DefinitionCollector.new(file)
          collector.visit(result.value)
          definitions.concat(collector.definitions)
        end
        definitions
      end

      def find_dead(client, definitions)
        if @parallel > 1
          find_dead_parallel(client, definitions)
        else
          find_dead_sequential(client, definitions)
        end
      end

      def find_dead_sequential(client, definitions)
        dead = []
        total = definitions.size

        definitions.each_with_index do |defn, index|
          $stderr.print "\rChecking definitions: #{index + 1}/#{total}"

          file_path = defn.file
          next unless file_path && defn.line

          line = defn.line - 1
          column = detect_column(file_path, line, defn)

          refs = client.references(file_path, line, column)
          live_refs = filter_references(refs, file_path, line)
          dead << defn if live_refs.empty?
        rescue Client::Error => e
          $stderr.puts "\n  Skipping #{defn.full_name}: #{e.message}"
        end

        $stderr.puts
        dead
      end

      def find_dead_parallel(client, definitions)
        dead = []
        total = definitions.size
        checked = 0

        definitions.each_slice(@parallel) do |batch|
          request_ids = batch.map do |defn|
            file_path = defn.file
            next nil unless file_path && defn.line

            line = defn.line - 1
            column = detect_column(file_path, line, defn)
            begin
              client.async_references(file_path, line, column)
            rescue Client::Error => e
              $stderr.puts "\n  Skipping #{defn.full_name}: #{e.message}"
              nil
            end
          end

          batch.zip(request_ids).each do |defn, req_id|
            checked += 1
            $stderr.print "\rChecking definitions: #{checked}/#{total}"

            next unless req_id

            begin
              refs = client.collect_response(req_id) || []
            rescue Client::Error => e
              $stderr.puts "\n  Skipping #{defn.full_name}: #{e.message}"
              next
            end

            file_path = defn.file
            line = defn.line - 1

            live_refs = filter_references(refs, file_path, line)
            dead << defn if live_refs.empty?
          end
        end

        $stderr.puts
        dead
      end

      def detect_column(file_path, zero_indexed_line, defn)
        lines = File.readlines(file_path)
        source_line = lines[zero_indexed_line]
        return 0 unless source_line

        case defn.kind
        when :method
          match = source_line.match(/\bdef\s+(self\.)?#{Regexp.escape(defn.name)}\b/)
          if match
            name_start = match.begin(0) + match[0].index(defn.name)
            return name_start
          end
        when :class
          match = source_line.match(/\bclass\s+#{Regexp.escape(defn.name)}\b/)
          if match
            return match.begin(0) + match[0].index(defn.name)
          end
        when :module
          match = source_line.match(/\bmodule\s+#{Regexp.escape(defn.name)}\b/)
          if match
            return match.begin(0) + match[0].index(defn.name)
          end
        when :constant
          match = source_line.match(/\b#{Regexp.escape(defn.name)}\s*=/)
          return match.begin(0) if match
        when :attr_reader, :attr_writer
          attr_name = defn.name.delete_suffix("=")
          match = source_line.match(/:#{Regexp.escape(attr_name)}\b/)
          return match.begin(0) if match
        end

        0
      end

      def filter_references(refs, def_file, def_line)
        return [] unless refs.is_a?(Array)

        def_file_uri = "file://#{File.expand_path(def_file)}"

        refs.reject do |ref|
          ref_uri = ref["uri"]
          ref_line = ref.dig("range", "start", "line")

          is_self_ref = ref_uri == def_file_uri && ref_line == def_line

          is_excluded = @exclude_paths.any? do |ep|
            ref_path = ref_uri&.sub(%r{^file://}, "")
            ref_path&.include?(ep)
          end

          is_self_ref || is_excluded
        end
      end
    end
  end
end
