# frozen_string_literal: true

require_relative "../spec_helper"

# Unit tests for the path-scope guard that detects analysis targets living outside the project
# root (the wrong-git-root false-positive footgun). Pure path logic, so no IO/fixtures needed.
class PathScopeSpec < Minitest::Test
  ROOT = "/repo/project"

  def outside(paths, root = ROOT)
    SorbetDeadcode::PathScope.paths_outside_root(paths, root)
  end

  def test_path_nested_under_root_is_inside
    assert_empty outside(["#{ROOT}/packs/foo"])
  end

  def test_root_itself_is_inside
    assert_empty outside([ROOT])
  end

  def test_path_in_a_different_repo_is_outside
    other = "/repo/other_project/packs/foo"
    assert_equal [other], outside([other])
  end

  def test_sibling_prefix_is_not_treated_as_nested
    # "/repo/project-2" must NOT count as nested under "/repo/project" despite the string prefix.
    sibling = "/repo/project-2/app"
    assert_equal [sibling], outside([sibling])
  end

  def test_mixed_paths_returns_only_the_outside_ones
    inside = "#{ROOT}/app"
    outside_path = "/elsewhere/app"
    assert_equal [outside_path], outside([inside, outside_path])
  end

  def test_relative_paths_resolve_against_cwd
    Dir.chdir(ROOT == Dir.pwd ? Dir.pwd : Dir.pwd) do
      # A relative path resolves under the cwd; with the cwd as root it is inside.
      assert_empty SorbetDeadcode::PathScope.paths_outside_root(["packs/foo"], Dir.pwd)
    end
  end

  def test_filesystem_root_does_not_double_the_separator
    # File.expand_path strips trailing separators, so the filesystem root "/" is the only root that
    # ends in one. The prefix guard must not turn it into "//"; everything is nested under "/".
    assert_empty SorbetDeadcode::PathScope.paths_outside_root(["/foo/bar"], "/")
  end
end
