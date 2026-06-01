# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Verifier
    class RipgrepVerifierSpec < Minitest::Test
      def setup
        @project_root = FIXTURES_PATH
        @verifier = RipgrepVerifier.new(project_root: @project_root)
      end

      def test_empty_candidates_returns_empty
        assert_equal [], @verifier.verify([])
      end

      def test_returns_candidates_unverified_when_ripgrep_missing
        candidate = Definition.new(name: "foo", full_name: "Foo#foo", kind: :method, location: "f:1")
        out = capture_stderr do
          SorbetDeadcode::Ripgrep.stub(:available?, false) do
            assert_equal [candidate], @verifier.verify([candidate])
          end
        end
        assert_match(/ripgrep .* not found/, out)
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
        $stderr.string
      ensure
        $stderr = original
      end

      def test_method_names_with_question_mark_matched_literally
        # Methods ending in `?` must not be treated as regex quantifiers.
        # `valid?` as a regex would mean "optionally match 'd'" — wrong.
        dir = Dir.mktmpdir
        File.write(File.join(dir, "model.rb"), <<~RUBY)
          class Model
            def valid?
              true
            end

            def truly_dead_predicate?
            end
          end

          Model.new.valid?
        RUBY

        SorbetDeadcode.analyze(File.join(dir, "app"))
        verifier = RipgrepVerifier.new(project_root: dir)

        all_candidates = SorbetDeadcode.analyze(dir)
        verified = verifier.verify(all_candidates)
        verified_names = verified.map(&:name)

        refute_includes verified_names, "valid?"
        assert_includes verified_names, "truly_dead_predicate?"
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      def test_glob_pattern_passes_through_explicit_globs
        # A path that already contains a glob is used verbatim.
        assert_equal "**/spec/**", @verifier.send(:glob_pattern, "**/spec/**")
      end

      def test_glob_pattern_wraps_plain_paths
        assert_equal "**/spec/**", @verifier.send(:glob_pattern, "spec/")
      end

      def test_truly_dead_methods_survive_verification
        candidates = SorbetDeadcode.analyze(
          File.join(FIXTURES_PATH, "app"),
        )

        verified = @verifier.verify(candidates)
        verified_names = verified.map(&:full_name)

        assert_includes verified_names, "Company#old_billing_plan"
        assert_includes verified_names, "UserService#unused_helper"
        assert_includes verified_names, "Report#archive"
        refute_includes verified_names, "NotificationService#send_deprecated_alert"
      end

      def test_methods_with_references_elsewhere_are_filtered_out
        candidates = SorbetDeadcode.analyze(
          File.join(FIXTURES_PATH, "app"),
        )

        verified = @verifier.verify(candidates)
        verified_names = verified.map(&:full_name)

        # obsolete_export_format is referenced in user_spec.rb, so rg finds 2+
        # matches and the verifier conservatively filters it out
        refute_includes verified_names, "User#obsolete_export_format"
      end

      def test_exclude_paths_limits_ripgrep_search
        verifier = RipgrepVerifier.new(
          project_root: @project_root,
          exclude_paths: ["spec/"],
        )

        candidates = SorbetDeadcode.analyze(
          File.join(FIXTURES_PATH, "app"),
        )

        verified = verifier.verify(candidates)
        verified_names = verified.map(&:full_name)

        # With specs excluded from the rg search, obsolete_export_format only
        # appears at its definition (count=1) so it survives verification
        assert_includes verified_names, "User#obsolete_export_format"
      end

      def test_analyze_and_verify_integration
        verified = SorbetDeadcode.analyze_and_verify(
          paths: [File.join(FIXTURES_PATH, "app")],
          project_root: FIXTURES_PATH,
        )

        verified_names = verified.map(&:full_name)

        assert_includes verified_names, "Company#old_billing_plan"
        assert_includes verified_names, "UserService#unused_helper"
        assert_includes verified_names, "Report#archive"
        refute_includes verified_names, "NotificationService#send_deprecated_alert"
      end
    end
  end
end
