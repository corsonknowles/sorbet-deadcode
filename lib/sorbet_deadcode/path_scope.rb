# frozen_string_literal: true

module SorbetDeadcode
  # Guards against the most damaging misconfiguration: analyzing paths that live OUTSIDE the
  # resolved project root. Reference verification (repo-wide ripgrep) and the non-Ruby refiners
  # all search `project_root`; when the analyzed code lives elsewhere, that search covers the
  # WRONG tree, so cross-file/cross-pack callers are never seen and live definitions are reported
  # as dead — a silent, high-impact false-positive source.
  #
  # The classic trigger: invoking the CLI from inside one git checkout while passing an absolute
  # path into a DIFFERENT checkout. The auto-detected git toplevel (the cwd's repo) becomes the
  # project root, so verification scans the cwd's repo instead of the code under analysis.
  #
  # Pure path logic (no IO), so it is unit-tested in isolation; the CLI turns a non-empty result
  # into a warning.
  module PathScope
    module_function

    # @param paths [Array<String>] the analysis target paths (relative or absolute)
    # @param project_root [String] the root used for reference verification / refiners
    # @return [Array<String>] the absolute analysis paths that fall OUTSIDE project_root
    #   (empty when every target is the root itself or nested under it).
    def paths_outside_root(paths, project_root)
      root = File.expand_path(project_root)
      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      Array(paths).map { |path| File.expand_path(path) }.reject do |abs|
        abs == root || abs.start_with?(prefix)
      end
    end
  end
end
