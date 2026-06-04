# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class YamlScannerSpec < Minitest::Test
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

      def refs(**opts)
        YamlScanner.new(@dir, **opts).references
      end

      def method_names(**opts)
        refs(**opts).select { |r| r.kind == :method }.map(&:name)
      end

      def constant_names(**opts)
        refs(**opts).select { |r| r.kind == :constant }.map(&:name)
      end

      def test_extracts_constant_from_array_registry
        write("config/scenarios.yml", <<~YAML)
          - Demo::Scenarios::WithWidget
          - Demo::Scenarios::WithGadget
        YAML
        names = constant_names
        assert_includes names, "Demo::Scenarios::WithWidget"
        assert_includes names, "WithWidget" # short name too
        assert_includes names, "Demo::Scenarios::WithGadget"
      end

      def test_extracts_constant_from_scalar_value
        write("config/handlers.yml", "handler: My::Event::Handler\n")
        assert_includes constant_names, "My::Event::Handler"
      end

      def test_extracts_quoted_constant_array_item
        write("config/scenarios.yml", %(- "Demo::Scenarios::Quoted"\n))
        assert_includes constant_names, "Demo::Scenarios::Quoted"
      end

      def test_ignores_unqualified_capitalized_scalar
        # `state: California` is data, not a class reference (no `::`).
        write("config/x.yml", "state: California\n")
        refute_includes constant_names, "California"
      end

      def test_extracts_qualified_method_reference
        write("config/widget.yml", <<~YAML)
          some_field:
            sanitizer:
              method: Sanitizers::Helpers::WidgetSanitizer.sanitize_widget
        YAML

        method_ref = refs.find { |r| r.kind == :method }
        assert_equal "sanitize_widget", method_ref.name
        assert_equal "Sanitizers::Helpers::WidgetSanitizer", method_ref.receiver_type
      end

      def test_emits_constant_references_for_receiver_full_and_short_name
        write("config/widget.yml",
              "method: Sanitizers::Helpers::WidgetSanitizer.sanitize_widget\n")
        consts = constant_names
        assert_includes consts, "Sanitizers::Helpers::WidgetSanitizer"
        assert_includes consts, "WidgetSanitizer"
      end

      def test_ignores_bare_value_under_qualified_key
        # A generic `method:` with a non-qualified value must be ignored to avoid hiding
        # unrelated dead methods (e.g. `method: post` in some HTTP config).
        write("cfg/http.yml", "method: post\n")
        assert_empty method_names
      end

      def test_ignores_unconfigured_keys
        write("config/a.yml", "other_key: Foo::Bar.baz\n")
        assert_empty refs
      end

      def test_strips_quotes_and_trailing_comments
        write("config/a.yml", %(method: "Foo::Bar.baz" # legacy\n))
        method_ref = refs.find { |r| r.kind == :method }
        assert_equal "baz", method_ref.name
        assert_equal "Foo::Bar", method_ref.receiver_type
      end

      def test_bare_keys_capture_name_only_references
        write("config/a.yml", "sanitize_method: sanitize_token\n")
        result = refs(bare_keys: ["sanitize_method"])
        method_ref = result.find { |r| r.kind == :method }
        assert_equal "sanitize_token", method_ref.name
        assert_nil method_ref.receiver_type
      end

      def test_bare_keys_accept_predicate_and_bang_suffix
        write("config/a.yml", "sanitize_method: clean!\n")
        assert_includes method_names(bare_keys: ["sanitize_method"]), "clean!"
      end

      def test_default_has_no_bare_keys
        write("config/a.yml", "sanitize_method: sanitize_token\n")
        assert_empty refs
      end

      def test_scans_yaml_and_yml_extensions
        write("a.yaml", "method: A::B.from_yaml\n")
        write("b.yml", "method: A::B.from_yml\n")
        result = method_names
        assert_includes result, "from_yaml"
        assert_includes result, "from_yml"
      end

      def test_excludes_vendored_directories
        write("vendor/gems/x/config.yml", "method: A::B.vendored\n")
        refute_includes method_names, "vendored"
      end

      def test_tolerates_erb_in_yaml
        write("config/a.yml", <<~YAML)
          host: <%= ENV.fetch("HOST") %>
          method: A::B.sanitize_token
        YAML
        assert_includes method_names, "sanitize_token"
      end

      def test_returns_empty_when_no_keys_configured
        write("config/a.yml", "method: A::B.sanitize_token\n")
        assert_empty refs(keys: [], bare_keys: [])
      end

      def test_returns_empty_when_no_yaml_files
        assert_empty refs
      end

      def test_skips_unreadable_paths_gracefully
        # A directory whose name matches the glob is returned by Dir.glob; reading it
        # raises EISDIR, which the scanner must swallow rather than crash on.
        FileUtils.mkdir_p(File.join(@dir, "weird.yml"))
        write("config/a.yml", "method: A::B.sanitize_token\n")
        assert_includes method_names, "sanitize_token"
      end

      def test_discovers_tracked_files_via_git_when_available
        write("config/offer.yml", "method: A::B.sanitize_token\n")
        system("git", "-C", @dir, "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "-C", @dir, "add", "-A", out: File::NULL, err: File::NULL)

        # With a git checkout, discovery goes through `git ls-files` (the fast path)
        # rather than Dir.glob, and must still find tracked YAML.
        assert_includes method_names, "sanitize_token"
      end

      def test_falls_back_to_glob_when_git_cannot_be_spawned
        write("config/a.yml", "method: A::B.sanitize_token\n")
        # Simulate git being unavailable (IO.popen raises Errno::ENOENT in the wild).
        IO.stub(:popen, ->(*) { raise StandardError, "git not found" }) do
          assert_includes YamlScanner.new(@dir).references.map(&:name), "sanitize_token"
        end
      end

      def test_git_path_only_sees_tracked_files
        write("config/tracked.yml", "method: A::B.tracked_method\n")
        system("git", "-C", @dir, "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "-C", @dir, "add", "config/tracked.yml", out: File::NULL, err: File::NULL)
        # Untracked file is invisible to `git ls-files`.
        write("config/untracked.yml", "method: A::B.untracked_method\n")

        result = method_names
        assert_includes result, "tracked_method"
        refute_includes result, "untracked_method"
      end

      def test_bare_keys_skips_non_matching_lines_and_non_bare_values
        write("config/jobs.yml", <<~YAML)
          processor: do_thing
          processor: SomeClass
          other: irrelevant
        YAML
        # `other:` line doesn't match the bare matcher (m nil); `SomeClass` matches the key
        # but isn't a valid bare method name (BARE fails, b nil); only `do_thing` is emitted.
        names = method_names(bare_keys: ["processor"])
        assert_includes names, "do_thing"
        refute_includes names, "SomeClass"
      end
    end
  end
end
