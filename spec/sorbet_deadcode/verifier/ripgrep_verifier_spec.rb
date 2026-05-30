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

      def test_truly_dead_methods_survive_verification
        candidates = SorbetDeadcode.analyze(
          File.join(FIXTURES_PATH, "app"),
        )

        verified = @verifier.verify(candidates)
        verified_names = verified.map(&:full_name)

        assert_includes verified_names, "Company#old_billing_plan"
        assert_includes verified_names, "UserService#unused_helper"
        assert_includes verified_names, "NotificationService#send_deprecated_alert"
        assert_includes verified_names, "Report#archive"
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
        assert_includes verified_names, "NotificationService#send_deprecated_alert"
        assert_includes verified_names, "Report#archive"
      end
    end
  end
end
