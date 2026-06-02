# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class ErbScannerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write(rel, content)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end

      def refs
        ErbScanner.new(@dir).references
      end

      def method_names
        refs.select { |r| r.kind == :method }.map(&:name)
      end

      def constant_names
        refs.select { |r| r.kind == :constant }.map(&:name)
      end

      def test_extracts_method_from_output_tag
        write("app/views/show.erb", "<h1><%= widget.display_name %></h1>\n")
        assert_includes method_names, "display_name"
      end

      def test_extracts_method_from_code_tag
        write("app/views/show.erb", "<% render_widget(thing) %>\n")
        assert_includes method_names, "render_widget"
      end

      def test_handles_blocks_spanning_multiple_tags
        write("app/views/list.erb", <<~ERB)
          <% items.each do |item| %>
            <%= item.render_label %>
          <% end %>
        ERB
        assert_includes method_names, "render_label"
      end

      def test_extracts_constant_reference
        write("app/views/show.erb", "<%= Formatter.format(value) %>\n")
        assert_includes constant_names, "Formatter"
        assert_includes method_names, "format"
      end

      def test_skips_comment_tags
        write("app/views/show.erb", "<%# widget.secret_method %>\n")
        refute_includes method_names, "secret_method"
      end

      def test_skips_literal_tags
        write("app/views/show.erb", "<%% not_ruby_method %%>\n")
        refute_includes method_names, "not_ruby_method"
      end

      def test_handles_trim_markers
        write("app/views/show.erb", "<%- compute_value -%>\n")
        assert_includes method_names, "compute_value"
      end

      def test_handles_multiline_tag_body
        write("app/views/show.erb", <<~ERB)
          <%= render_partial(
                some_arg,
              ) %>
        ERB
        assert_includes method_names, "render_partial"
      end

      def test_references_are_name_only
        write("app/views/show.erb", "<%= widget.display_name %>\n")
        method_ref = refs.find { |r| r.name == "display_name" }
        assert_nil method_ref.receiver_type
      end

      def test_tolerates_unparseable_file
        # A file matching the glob but unreadable as a normal file must not crash the scan.
        FileUtils.mkdir_p(File.join(@dir, "weird.erb"))
        write("app/views/show.erb", "<%= ok_method %>\n")
        assert_includes method_names, "ok_method"
      end

      def test_returns_empty_for_template_without_tags
        write("app/views/static.erb", "<h1>No ruby here</h1>\n")
        assert_empty refs
      end

      def test_returns_empty_when_no_erb_files
        assert_empty refs
      end
    end
  end
end
