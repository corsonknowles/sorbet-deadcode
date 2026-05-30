# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class EndToEndSpec < Minitest::Test
    def test_app_only_analysis
      # Analyze only app code (no specs)
      results = SorbetDeadcode.analyze(
        File.join(FIXTURES_PATH, "app"),
      )

      dead_names = results.map(&:full_name)

      # Cross-file calls keep methods alive
      refute_includes dead_names, "User#full_name"   # called from UserService
      refute_includes dead_names, "User#company"      # called from UserService
      refute_includes dead_names, "Company#employee_count" # called from UserService

      # These have no callers in app code
      assert_includes dead_names, "User#obsolete_export_format"
      assert_includes dead_names, "Company#old_billing_plan"
      assert_includes dead_names, "UserService#unused_helper"
      assert_includes dead_names, "NotificationService#send_deprecated_alert"
      assert_includes dead_names, "Report#archive"
    end

    def test_including_specs_keeps_tested_methods_alive
      # Analyze everything including specs
      results = SorbetDeadcode.analyze(FIXTURES_PATH)

      dead_names = results.map(&:full_name)

      # obsolete_export_format is called in user_spec.rb, so alive when specs included
      refute_includes dead_names, "User#obsolete_export_format"

      # old_billing_plan has no spec coverage, still dead
      assert_includes dead_names, "Company#old_billing_plan"
    end

    def test_excluding_specs_reveals_test_only_code
      # Analyze full fixture tree but exclude the spec subdirectory within it
      results = SorbetDeadcode.analyze(
        FIXTURES_PATH,
        exclude_paths: ["fixtures/spec/"],
      )

      dead_names = results.map(&:full_name)

      # Dead in production (only called from specs)
      assert_includes dead_names, "User#obsolete_export_format"
      assert_includes dead_names, "Company#old_billing_plan"
      assert_includes dead_names, "Report#archive"
    end

    def test_type_aware_display_name_disambiguation
      results = SorbetDeadcode.analyze(
        File.join(FIXTURES_PATH, "app"),
      )

      dead = results.select { |d| d.name == "display_name" }
      dead_owners = dead.map(&:owner_name)

      # Report#display_name has no callers in app code
      assert_includes dead_owners, "Report"
    end
  end
end
