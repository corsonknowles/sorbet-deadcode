# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Fast project file discovery shared by the non-Ruby scanners.
    #
    # On a large monorepo `Dir.glob("**/*.ext")` is pathologically slow (tens of seconds)
    # and walks vendored/gitignored trees, so we prefer `git ls-files` (sub-second, already
    # respects .gitignore) when available and fall back to Dir.glob outside a git checkout.
    module FileFinder
      module_function

      # @param project_root [String]
      # @param globs [Array<String>] e.g. ["**/*.erb"]
      # @param exclude_dirs [Array<String>] directory names to skip on the glob fallback path
      # @return [Array<String>] absolute file paths
      def find(project_root, globs, exclude_dirs: [])
        root = File.expand_path(project_root)
        files = git_tracked(root, globs) || globbed(root, globs)
        files.reject { |path| excluded?(root, path, exclude_dirs) }.uniq
      end

      def git_tracked(root, globs)
        pathspecs = globs.map { |g| ":(glob)#{g}" }
        out = IO.popen(["git", "-C", root, "ls-files", "-z", "--", *pathspecs], err: File::NULL, &:read)
        return nil unless $?.success?

        out.split("\x00").reject(&:empty?).map { |rel| File.join(root, rel) }
      rescue StandardError
        nil
      end

      def globbed(root, globs)
        globs.flat_map { |g| Dir.glob(File.join(root, g)) }
      end

      def excluded?(root, path, exclude_dirs)
        rel = path.delete_prefix(root)
        exclude_dirs.any? { |dir| rel.include?("/#{dir}/") }
      end
    end
  end
end
