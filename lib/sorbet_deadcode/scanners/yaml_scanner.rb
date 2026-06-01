# frozen_string_literal: true

module SorbetDeadcode
  module Scanners
    # Scans framework YAML configs for keys whose value names a Ruby method invoked
    # reflectively by the framework, never from a Ruby call site.
    #
    # A common shape: a config key maps to a fully-qualified class method, e.g.
    #
    #   some_field:
    #     sanitizer:
    #       method: Sanitizers::WidgetSanitizer.sanitize_widget
    #
    # The referenced class and its method have no Ruby caller, so the type-aware pass
    # reports them dead. This scanner harvests both the method name and the owning
    # constant so a refiner can keep them alive.
    #
    # Detection is line-oriented (not a full YAML parse) on purpose: Rails YAML frequently
    # embeds ERB (`<%= %>`), which trips structured parsers, and we only care about a small
    # allowlist of `key: value` scalars.
    class YamlScanner
      # Keys whose scalar value is a fully-qualified `Module::Class.method_name` reference.
      DEFAULT_KEYS = %w[method].freeze

      # Keys whose scalar value is a bare method name (no receiver), e.g. `sanitize_method: foo`.
      # Empty by default; configurable for frameworks that use this shape.
      DEFAULT_BARE_KEYS = [].freeze

      DEFAULT_GLOBS = ["**/*.yml", "**/*.yaml"].freeze

      # Directories never worth scanning (vendored / generated / VCS noise) on the Dir.glob
      # fallback path. The git path already honors .gitignore.
      DEFAULT_EXCLUDE_DIRS = %w[node_modules vendor tmp log coverage .git].freeze

      # A fully-qualified constant-method reference: `A::B::C.method_name`.
      QUALIFIED = /\A(?<receiver>[A-Z]\w*(?:::[A-Z]\w*)*)\.(?<method>[a-z_]\w*[?!]?)\z/
      # A bare Ruby method name.
      BARE = /\A(?<method>[a-z_]\w*[?!]?)\z/

      # A bare, namespaced constant used as a YAML value or sequence item, e.g.
      #   - My::Scenario
      #   handler: My::Event::Handler
      # Common in class-registry configs (demo scenarios, event consumers) that the
      # framework loads via constantize. Requires a `::` so ordinary capitalized scalars
      # (`state: California`) aren't mistaken for class references.
      CONSTANT_VALUE = %r{^\s*(?:-\s*|[\w/.]+\s*:\s*)["']?(?<const>[A-Z]\w*(?:::[A-Z]\w*)+)["']?\s*(?:#.*)?$}

      def initialize(project_root, keys: DEFAULT_KEYS, bare_keys: DEFAULT_BARE_KEYS,
                     globs: DEFAULT_GLOBS, exclude_dirs: DEFAULT_EXCLUDE_DIRS)
        @project_root = File.expand_path(project_root)
        @keys = keys
        @bare_keys = bare_keys
        @globs = globs
        @exclude_dirs = exclude_dirs
        @qualified_matcher = build_line_matcher(keys)
        @bare_matcher = build_line_matcher(bare_keys)
      end

      # Returns an Array of Reference objects: typed method references plus the owning
      # constant for qualified values, and name-only method references for bare keys.
      def references
        refs = []
        yaml_files.each do |path|
          location = path
          text = safe_read(path)
          next unless text

          text.each_line do |line|
            collect_qualified(line, location, refs)
            collect_bare(line, location, refs)
            collect_constant(line, location, refs)
          end
        end
        refs
      end

      private

      def collect_qualified(line, location, refs)
        return if @keys.empty?

        m = @qualified_matcher.match(line)
        return unless m

        value = unquote(m[:value])
        q = QUALIFIED.match(value)
        return unless q

        refs << Reference.new(name: q[:method], location: location, kind: :method, receiver_type: q[:receiver])
        refs << Reference.new(name: q[:receiver], location: location, kind: :constant)
        refs << Reference.new(name: q[:receiver].split("::").last, location: location, kind: :constant)
      end

      def collect_bare(line, location, refs)
        return if @bare_keys.empty?

        m = @bare_matcher.match(line)
        return unless m

        value = unquote(m[:value])
        b = BARE.match(value)
        refs << Reference.new(name: b[:method], location: location, kind: :method) if b
      end

      # A namespaced constant named as a YAML value/array item keeps that class/module alive.
      def collect_constant(line, location, refs)
        m = CONSTANT_VALUE.match(line)
        return unless m

        const = m[:const]
        refs << Reference.new(name: const, location: location, kind: :constant)
        refs << Reference.new(name: const.split("::").last, location: location, kind: :constant)
      end

      def unquote(value)
        value.sub(/\A['":]/, "").sub(/['"]\z/, "")
      end

      def yaml_files
        files = git_tracked_files || globbed_files
        files.reject { |path| excluded?(path) }.uniq
      end

      # On a large monorepo `Dir.glob("**/*.yml")` is pathologically slow (tens of seconds)
      # and walks vendored/gitignored trees, so prefer `git ls-files` (sub-second, already
      # respects .gitignore) when available, falling back to Dir.glob outside a git checkout.
      def git_tracked_files
        pathspecs = @globs.map { |g| ":(glob)#{g}" }
        out = IO.popen(["git", "-C", @project_root, "ls-files", "-z", "--", *pathspecs], err: File::NULL, &:read)
        return nil unless $?.success?

        out.split("\x00").reject(&:empty?).map { |rel| File.join(@project_root, rel) }
      rescue StandardError
        nil
      end

      def globbed_files
        @globs.flat_map { |g| Dir.glob(File.join(@project_root, g)) }
      end

      def excluded?(path)
        rel = path.delete_prefix(@project_root)
        @exclude_dirs.any? { |dir| rel.include?("/#{dir}/") }
      end

      def safe_read(path)
        File.read(path)
      rescue StandardError
        nil
      end

      # Matches `  some_key: value` with optional trailing comment, capturing the raw value.
      def build_line_matcher(keys)
        return /(?!)/ if keys.empty? # never matches

        alternation = keys.map { |k| Regexp.escape(k) }.join("|")
        /^\s*(?:#{alternation})\s*:\s*(?<value>[^#\s][^#\n]*?)\s*(?:#.*)?$/
      end
    end
  end
end
