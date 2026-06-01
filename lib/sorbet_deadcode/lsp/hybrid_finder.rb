# frozen_string_literal: true

module SorbetDeadcode
  module Lsp
    class HybridFinder
      attr_reader :dead_definitions

      def initialize(project_root:, paths:, exclude_paths: [], parallel: 1)
        @project_root = File.expand_path(project_root)
        @paths = Array(paths)
        @exclude_paths = Array(exclude_paths)
        @parallel = [parallel.to_i, 1].max
        @dead_definitions = []
      end

      def run
        candidates = prism_pass
        if candidates.empty?
          $stderr.puts "Prism pass found no dead code candidates."
          return []
        end

        $stderr.puts "Prism pass found #{candidates.size} candidates. Validating with LSP..."

        client = Client.new(@project_root)
        begin
          @dead_definitions = lsp_validate(client, candidates)
        ensure
          client.shutdown
        end

        @dead_definitions
      end

      private

      def prism_pass
        analyzer = Analyzer::DeadCodeAnalyzer.new(
          paths: @paths,
          exclude_paths: @exclude_paths,
        )
        analyzer.run
      end

      def lsp_validate(client, candidates)
        confirmed_dead = []
        total = candidates.size

        if @parallel > 1
          confirmed_dead = lsp_validate_parallel(client, candidates, total)
        else
          confirmed_dead = lsp_validate_sequential(client, candidates, total)
        end

        $stderr.puts
        confirmed_dead
      end

      def lsp_validate_sequential(client, candidates, total)
        confirmed_dead = []

        candidates.each_with_index do |defn, index|
          $stderr.print "\rValidating candidates: #{index + 1}/#{total}"

          if lsp_confirms_dead?(client, defn)
            confirmed_dead << defn
          end
        end

        confirmed_dead
      end

      def lsp_validate_parallel(client, candidates, total)
        confirmed_dead = []
        batches = candidates.each_slice(@parallel).to_a

        checked = 0
        batches.each do |batch|
          request_ids = batch.map do |defn|
            send_reference_request(client, defn)
          end

          batch.zip(request_ids).each do |defn, req_id|
            checked += 1
            $stderr.print "\rValidating candidates: #{checked}/#{total}"

            next unless req_id

            refs = client.collect_response(req_id) || []
            live_refs = filter_references(refs, defn)
            confirmed_dead << defn if live_refs.empty?
          end
        end

        confirmed_dead
      end

      def send_reference_request(client, defn)
        file_path = defn.file
        return nil unless file_path && defn.line

        line = defn.line - 1
        column = detect_column(file_path, line, defn)

        client.async_references(file_path, line, column)
      end

      def lsp_confirms_dead?(client, defn)
        file_path = defn.file
        return true unless file_path && defn.line

        line = defn.line - 1
        column = detect_column(file_path, line, defn)

        refs = client.references(file_path, line, column)
        live_refs = filter_references(refs, defn)
        live_refs.empty?
      end

      def filter_references(refs, defn)
        return [] unless refs.is_a?(Array)

        file_path = defn.file
        def_line = defn.line - 1
        def_file_uri = "file://#{File.expand_path(file_path)}"

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
          return match.begin(0) + match[0].index(defn.name) if match
        when :module
          match = source_line.match(/\bmodule\s+#{Regexp.escape(defn.name)}\b/)
          return match.begin(0) + match[0].index(defn.name) if match
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
    end
  end
end
