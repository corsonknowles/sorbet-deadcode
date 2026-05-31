# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Scans ERB templates for Ruby method and constant references.
    #
    # Views, mailers, and other templates call helper/model methods that have no Ruby
    # call site, e.g. `<%= widget.display_name %>` or `<%= render_widget(thing) %>`.
    # Methods used only from `.erb` are otherwise wrongly reported dead.
    #
    # Rather than regex the expressions (lossy) or compile with Erubi (an extra dependency),
    # we extract the Ruby snippets from the `<% %>` / `<%= %>` tags, join them, and run the
    # existing Prism-based ReferenceCollector over the result. Joining preserves block
    # structure (`<% items.each do |i| %>...<% end %>` reconstructs valid Ruby), so calls on
    # block-locals resolve correctly. Template receivers are untyped, so references are
    # name-only — exactly what we want for keeping same-named methods alive.
    class ErbScanner
      DEFAULT_GLOBS = ["**/*.erb"].freeze
      DEFAULT_EXCLUDE_DIRS = %w[node_modules vendor tmp log coverage .git].freeze

      # Matches an ERB tag's Ruby body, skipping `<%# comments %>` and `<%% literals %>`.
      # Drops the optional output (`=`) and trim (`-`) markers.
      TAG = /<%(?![%#])=?-?(.*?)-?%>/m

      def initialize(project_root, globs: DEFAULT_GLOBS, exclude_dirs: DEFAULT_EXCLUDE_DIRS)
        @project_root = File.expand_path(project_root)
        @globs = globs
        @exclude_dirs = exclude_dirs
      end

      # @return [Array<Reference>]
      def references
        erb_files.flat_map { |path| scan_file(path) }
      end

      private

      def erb_files
        FileFinder.find(@project_root, @globs, exclude_dirs: @exclude_dirs)
      end

      def scan_file(path)
        text = File.read(path)
        ruby = extract_ruby(text)
        return [] if ruby.empty?

        result = Prism.parse(ruby)
        collector = Collector::ReferenceCollector.new(path, type_resolver: nil)
        collector.visit(result.value)
        collector.references
      rescue StandardError
        []
      end

      # Pull the Ruby out of every ERB tag, in source order, and join into one buffer.
      def extract_ruby(text)
        text.scan(TAG).flatten.reject { |snippet| snippet.lstrip.start_with?("#") }.join("\n")
      end
    end
  end
end
