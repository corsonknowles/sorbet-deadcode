# frozen_string_literal: true

require_relative "spec_helper"
require "open3"

# Guards the CLI option definitions in exe/sorbet-deadcode. A continuation description line passed
# to `opts.on` that *starts with* `--word` is silently parsed by OptionParser as an ALIAS of the
# option, inheriting its argument arity. That regression made `--spoom` (a flag) demand an argument
# because `--remove`'s help text had a line beginning "--spoom ...". These tests catch that shape.
class CliHelpSpec < Minitest::Test
  EXE = File.expand_path("../exe/sorbet-deadcode", __dir__)

  def help_output
    @help_output ||= begin
      out, _err, status = Open3.capture3(RbConfig.ruby, EXE, "--help")
      assert status.success?, "exe --help should exit 0"
      out
    end
  end

  def test_spoom_is_a_standalone_flag
    # `--spoom` must render as its own flag entry (multiple spaces then its description), and must
    # NOT take an all-caps ARG placeholder (the bug rendered it as taking --remove's TIER arg).
    assert_match(/^\s*--spoom\s{2,}\S/, help_output, "expected --spoom listed as its own flag")
    refute_match(/--spoom[ =]+[A-Z][A-Z0-9_]+\b/, help_output, "--spoom must not take an ARG placeholder")
  end

  def test_no_option_lists_spoom_as_an_alias
    # The bug signature: another option (e.g. --remove) listing --spoom as a comma alias.
    refute_match(/--\w[\w-]*,\s*--spoom/, help_output)
  end

  def test_no_opts_on_continuation_line_starts_with_a_double_dash
    # Root-cause guard: no description continuation string in exe should begin with `--`,
    # which OptionParser would treat as an option alias rather than help text.
    source = File.read(EXE)
    offenders = source.lines.each_with_index.select do |line, _i|
      # a string literal line that is purely a description argument starting with --
      line.strip.match?(/\A"--/)
    end
    assert_empty offenders.map { |line, i| "line #{i + 1}: #{line.strip}" },
      "opts.on description lines must not start with `--` (OptionParser reads them as aliases)"
  end
end
