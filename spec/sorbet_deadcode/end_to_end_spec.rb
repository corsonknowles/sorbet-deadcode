# frozen_string_literal: true

require_relative "../spec_helper"
require "tempfile"
require "shellwords"

module SorbetDeadcode
  class EndToEndSpec < Minitest::Test
    EXE = File.expand_path("../../exe/sorbet-deadcode", __dir__)
    LIB = File.expand_path("../../lib", __dir__)

    # --report must flow into the confidence/classify pipeline (#37): a cached index
    # should be annotatable without re-analyzing. --confidence needs no ripgrep, so it
    # is a stable proxy for "the report path no longer returns before rendering."
    def test_report_index_supports_confidence_annotation
      results = SorbetDeadcode.analyze(File.join(FIXTURES_PATH, "app"))
      refute_empty results, "fixture analysis should surface dead code"

      Tempfile.create(["deadcode", ".json"]) do |f|
        Index.new(dead_definitions: results, paths: [FIXTURES_PATH]).write(f.path)

        output = `#{Shellwords.escape(RbConfig.ruby)} -I #{Shellwords.escape(LIB)} #{Shellwords.escape(EXE)} --report #{Shellwords.escape(f.path)} --confidence 2>&1`

        assert_includes output, "Loaded #{results.size} dead code candidates"
        # Confidence tier tag ([high]/[medium]/[low]) only appears via the shared
        # render path that --report previously short-circuited.
        assert_match(/\[(high|medium|low)\]/, output, "expected a confidence tier in report output")
      end
    end


    # #31: the --report-dynamic-dispatch flag must thread :report through to
    # SorbetDeadcode.analyze so namespace-dispatched methods surface as candidates.
    def test_report_dynamic_dispatch_flag_surfaces_namespace_dispatched_methods
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "s.rb"), <<~RUBY)
          class MemberSerializer
            def dump_company_member
            end

            def dump(member)
              method_name = some_lookup(member)
              __send__(method_name, member)
            end
          end
        RUBY

        base = "#{Shellwords.escape(RbConfig.ruby)} -I #{Shellwords.escape(LIB)} " \
               "#{Shellwords.escape(EXE)} #{Shellwords.escape(dir)} --no-verify " \
               "--project-root #{Shellwords.escape(dir)}"

        without_flag = `#{base} 2>&1`
        refute_match(/dump_company_member/, without_flag,
          "namespace-dispatched method should be conservatively kept alive by default")

        with_flag = `#{base} --report-dynamic-dispatch 2>&1`
        assert_match(/dump_company_member/, with_flag,
          "--report-dynamic-dispatch should surface the namespace-dispatched method")
      end
    end

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
      assert_includes dead_names, "Report#archive"

      # send_deprecated_alert is NOT dead: NotificationService#dispatch calls
      # public_send(:"send_#{type}"), so any send_* method may be reached. The
      # interpolated-dispatch detector keeps the whole send_* family alive.
      refute_includes dead_names, "NotificationService#send_deprecated_alert"
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
