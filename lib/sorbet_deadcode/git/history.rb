# frozen_string_literal: true

module SorbetDeadcode
  module Git
    # Annotates a candidate with the commit that introduced its definition (issue #135) — the
    # "when/where was this added" half of a dead-code write-up.
    #
    # Batched per FILE (issue #146): instead of a pickaxe per candidate (`git log -S name`, which
    # walks the file's whole history once *per name*), `prepare` runs ONE rename-aware
    # `git log --follow --reverse -p` per file and attributes every candidate name's introducing
    # commit in a single streaming pass — stopping early once all names for that file are found.
    #
    # Opt-in (the CLI wires it only under --history) and degrades to nil outside a checkout or on
    # any git error.
    class History
      # SOH (U+0001) prefix on each commit's --format line so it can't collide with diff content
      # (diff lines start with +/-/space/@/diff/index; source never starts a line with a control
      # char). NOT a NUL — an embedded NUL would truncate the --format argv on exec.
      COMMIT_MARKER = "\u0001"

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        # file (absolute) => { name => "<short-sha> <yyyy-mm-dd> <subject>" }
        @introductions = {}
      end

      # Precompute introducing commits for all definitions, one git pass per file.
      # @param definitions [Array<Definition>]
      # @return [self]
      def prepare(definitions)
        definitions.group_by { |definition| File.expand_path(definition.file.to_s) }.each do |file, defs|
          @introductions[file] = introductions(file, defs.map(&:name).uniq)
        end
        self
      end

      # @return [String, nil] "<short-sha> <yyyy-mm-dd> <subject>" of the commit that introduced the
      #   definition's name in its file, or nil when unavailable / not prepared.
      def added(definition)
        @introductions.dig(File.expand_path(definition.file.to_s), definition.name)
      end

      private

      # { name => introducing-commit-line } for the given names, from one --follow -p pass over the
      # file's history (oldest first), recording the first commit that adds each name.
      def introductions(file, names)
        pending = names.to_set
        result = {}
        current = nil

        each_log_line(file) do |line|
          if line.start_with?(COMMIT_MARKER)
            current = line.byteslice(COMMIT_MARKER.bytesize..).to_s.strip
          elsif current && added_line?(line)
            found = pending.select { |name| line.include?(name) }
            found.each do |name|
              result[name] = current
              pending.delete(name)
            end
            break if pending.empty?
          end
        end

        result
      end

      # A diff line that ADDS content (excluding the `+++ b/file` header).
      def added_line?(line)
        line.start_with?("+") && !line.start_with?("+++")
      end

      def each_log_line(file)
        IO.popen(
          ["git", "-C", @project_root, "log", "--follow", "--reverse",
           "--format=#{COMMIT_MARKER}%h %ad %s", "--date=short", "-p", "--", file],
          err: File::NULL,
        ) { |io| io.each_line { |line| yield(line) } }
      rescue StandardError
        nil
      end
    end
  end
end
