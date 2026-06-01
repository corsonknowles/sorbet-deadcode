# frozen_string_literal: true

require "time"

module SorbetDeadcode
  module Git
    # Determines whether a definition was introduced recently, via git line history.
    #
    # Recently-added code is the riskiest to report dead: it may be in-flight work (behind
    # a flag, a caller in an unmerged PR, scaffolding). The Classifier uses this to flag
    # such candidates `:recently_added` and route them to review instead of safe_delete.
    #
    # Line-level (`git log -L <line>,<line>:<file>`) is more accurate than file-level for
    # large files. Degrades gracefully (returns false) outside a git checkout, for untracked
    # files, or on any git error.
    class Recency
      def initialize(project_root, window_seconds)
        @project_root = File.expand_path(project_root)
        @cutoff = Time.now - window_seconds
        @cache = {}
      end

      # True if the definition's line was introduced after the cutoff.
      def recently_added?(definition)
        return false unless definition.file && definition.line

        introduced = introduced_at(definition.file, definition.line)
        introduced ? introduced > @cutoff : false
      end

      private

      def introduced_at(file, line)
        key = "#{file}:#{line}"
        return @cache[key] if @cache.key?(key)

        @cache[key] = compute_introduced_at(File.expand_path(file), line)
      end

      def compute_introduced_at(abs_file, line)
        out = git_line_log(abs_file, line)
        return nil unless out

        # `git log -L` lists commits newest-first; the oldest is when the line first appeared.
        date = out.split("\n").reject(&:empty?).last
        date && Time.parse(date)
      end

      # Raw `git log -L` output for a single line, or nil outside a checkout / on error /
      # for untracked files.
      def git_line_log(abs_file, line)
        out = IO.popen(
          ["git", "-C", @project_root, "log", "-L", "#{line},#{line}:#{abs_file}", "-s", "--format=%aI"],
          err: File::NULL, &:read
        )
        $?.success? ? out : nil
      rescue StandardError
        nil
      end
    end
  end
end
