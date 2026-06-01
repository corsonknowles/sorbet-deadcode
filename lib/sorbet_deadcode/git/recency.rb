# frozen_string_literal: true

require "time"

module SorbetDeadcode
  module Git
    # Determines whether a definition was introduced recently.
    #
    # Recently-added code is the riskiest to report dead: it may be in-flight work (behind a
    # flag, a caller in an unmerged PR, scaffolding). The Classifier uses this to flag such
    # candidates `:recently_added` and route them to review instead of safe_delete.
    #
    # The set of recently-added files is computed with a SINGLE batched git query up front
    # (`git log --since --diff-filter=A --name-only`), so `recently_added?` is an O(1) lookup
    # — per-candidate `git log -L` was prohibitively slow on deep-history monorepos. This is
    # file-level (a method added to a much older file isn't flagged); a fast, conservative
    # approximation that targets the common "new feature = new files" case. Degrades to "not
    # recent" outside a git checkout or on any git error.
    class Recency
      def initialize(project_root, window_seconds)
        @project_root = File.expand_path(project_root)
        @recent_files = recent_files(window_seconds)
      end

      # definition.file is relative to the cwd (where analysis ran); git paths are relative
      # to the repo root. Expanding both to absolute lets them match.
      def recently_added?(definition)
        @recent_files.include?(File.expand_path(definition.file))
      end

      private

      def recent_files(window_seconds)
        out = git_added_since((Time.now - window_seconds).utc.iso8601)
        return Set.new unless out

        out.split("\n").reject(&:empty?)
           .map { |rel| File.expand_path(rel, @project_root) }
           .to_set
      end

      # Paths of files added in commits since `since` (ISO-8601), or nil on git failure.
      def git_added_since(since)
        out = IO.popen(
          ["git", "-C", @project_root, "log", "--since=#{since}",
           "--diff-filter=A", "--name-only", "--pretty=format:"],
          err: File::NULL, &:read
        )
        $?.success? ? out : nil
      rescue StandardError
        nil
      end
    end
  end
end
