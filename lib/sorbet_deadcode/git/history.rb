# frozen_string_literal: true

module SorbetDeadcode
  module Git
    # Annotates a candidate with the commit that introduced its definition (issue #135) — the
    # "when/where was this added" half of a dead-code write-up.
    #
    # Uses a rename-aware, FILE-SCOPED pickaxe (`git log --follow -S <name> -- <file>`), so each
    # lookup walks only one file's history. The complementary "dead since / last caller removed"
    # archaeology needs a whole-repo pickaxe per name, which is prohibitively slow on deep-history
    # monorepos (the same reason Recency batches), so it's intentionally not done here.
    #
    # Opt-in (the CLI wires it only under --history) and degrades to nil outside a checkout or on
    # any git error.
    class History
      def initialize(project_root)
        @project_root = File.expand_path(project_root)
      end

      # @return [String, nil] "<short-sha> <yyyy-mm-dd> <subject>" of the oldest commit that
      #   introduced the definition's name in its file, or nil when unavailable.
      def added(definition)
        out = git_log_introduced(definition.name, File.expand_path(definition.file))
        return nil unless out

        # Oldest commit touching the name is last in reverse-chronological log output
        # (nil when the name was never introduced in that file's tracked history).
        out.split("\n").reject(&:empty?).last
      end

      private

      def git_log_introduced(name, file)
        out = IO.popen(
          ["git", "-C", @project_root, "log", "--follow", "-S", name,
           "--format=%h %ad %s", "--date=short", "--", file],
          err: File::NULL, &:read
        )
        $?.success? ? out : nil
      rescue StandardError
        nil
      end
    end
  end
end
