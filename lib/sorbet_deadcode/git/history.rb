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

      # @param dead_since [Boolean] also compute the (expensive, repo-wide) `dead_since:` annotation
      #   — see #prepare_dead_since for the cost. Off by default; the CLI gates it behind --dead-since.
      def initialize(project_root, dead_since: false)
        @project_root = File.expand_path(project_root)
        # file (absolute) => { name => "<short-sha> <yyyy-mm-dd> <subject>" }
        @introductions = {}
        @dead_since_enabled = dead_since
        # name => "dead-on-arrival (...)" | "dead since <commit>" | nil
        @dead_since = {}
      end

      # Precompute introducing commits for all definitions, one git pass per file. When
      # --dead-since is enabled, ALSO precompute the repo-wide "dead_since" annotation (one pickaxe
      # per unique name — slow; see #prepare_dead_since).
      # @param definitions [Array<Definition>]
      # @return [self]
      def prepare(definitions)
        definitions.group_by { |definition| File.expand_path(definition.file.to_s) }.each do |file, defs|
          @introductions[file] = introductions(file, defs.map(&:name).uniq)
        end
        prepare_dead_since(definitions) if @dead_since_enabled
        self
      end

      # @return [String, nil] "<short-sha> <yyyy-mm-dd> <subject>" of the commit that introduced the
      #   definition's name in its file, or nil when unavailable / not prepared.
      def added(definition)
        @introductions.dig(File.expand_path(definition.file.to_s), definition.name)
      end

      # @return [String, nil] "dead-on-arrival (<commit>)" when the name's reference count never
      #   changed after it was introduced (no caller ever shipped), or "dead since <commit>" naming
      #   the most recent commit that changed the name's repo-wide reference count (≈ when the last
      #   caller was removed). nil unless --dead-since was enabled.
      def dead_since(definition)
        @dead_since[definition.name]
      end

      private

      # ⚠️ EXPENSIVE. Unlike `added` (file-scoped, batched per file), `dead_since` needs a REPO-WIDE
      # pickaxe (`git log -S name` over all paths) once per unique name to find when the name's last
      # reference disappeared. On large/deep-history repos each pickaxe can take seconds to minutes,
      # so this loop can run for a long time — hence opt-in only, a loud upfront warning, and live
      # per-name progress so a long run is visible rather than a silent hang.
      def prepare_dead_since(definitions)
        names = definitions.map(&:name).uniq
        warn_dead_since_cost(names.size)
        names.each_with_index do |name, index|
          $stderr.puts "[sorbet-deadcode] dead-since pickaxe #{index + 1}/#{names.size}: #{name}"
          @dead_since[name] = compute_dead_since(name)
        end
      end

      def warn_dead_since_cost(count)
        $stderr.puts <<~WARNING
          [sorbet-deadcode] ⚠️  --dead-since runs a REPO-WIDE git pickaxe (git log -S) once per unique
          [sorbet-deadcode]     candidate name (#{count} here). On large/deep-history repos each pickaxe
          [sorbet-deadcode]     can take seconds-to-minutes, so this may run for a LONG time. Scope it to
          [sorbet-deadcode]     a small candidate set (one pack/file) and prefer plain --history for fast,
          [sorbet-deadcode]     file-scoped `added:` annotations.
        WARNING
      end

      # The newest pickaxe commit ≈ when the name's reference count last changed. A single entry
      # means the count never changed after introduction → dead on arrival; otherwise the name was
      # orphaned and the newest commit is approximately when it died.
      def compute_dead_since(name)
        lines = pickaxe_commit_lines(name)
        return nil if lines.empty?
        return "dead-on-arrival (#{lines.last})" if lines.length == 1

        "dead since #{lines.first}"
      end

      # Repo-wide `git log -S name` commit lines, newest first. No `-p`, so output is one
      # "<short-sha> <yyyy-mm-dd> <subject>" line per commit that changed the count of `name`.
      def pickaxe_commit_lines(name)
        lines = []
        IO.popen(
          ["git", "-C", @project_root, "log", "-S", name,
           "--format=%h %ad %s", "--date=short"],
          err: File::NULL,
        ) { |io| io.each_line { |line| lines << line.strip } }
        lines
      rescue StandardError
        []
      end

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
