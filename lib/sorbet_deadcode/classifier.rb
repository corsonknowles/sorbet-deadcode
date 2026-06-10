# frozen_string_literal: true

module SorbetDeadcode
  # Post-processing classifier (issue #18). Annotates each dead-code candidate with
  # a confidence tier, a reference count, risk flags, and a suggested action — folding
  # the manual verification ritual (rg counts, spec-only detection, non-Ruby refs,
  # inline-constant side effects) into one composable pass.
  #
  # Unlike the RipgrepVerifier (which silently drops candidates), the Classifier keeps
  # every candidate and explains it, so downstream tooling can decide what to do.
  class Classifier
    Result = Struct.new(
      :definition,
      :confidence,            # :high / :medium / :low
      :reference_count,       # total rg occurrences of the name (incl. definition)
      :external_reference_count, # occurrences outside the definition file
      :flags,                 # Array<Symbol> risk markers
      :suggested_action,      # :safe_delete / :delete_with_spec / :review / :keep
      :added,                 # String|nil — introducing commit (with --history), else nil
      :dead_since,            # String|nil — when it became dead (with --dead-since), else nil
      keyword_init: true,
    )

    # Matches files under spec/ or test/ directories, or *_spec.rb / *_test.rb.
    SPEC_PATH = %r{(?:^|/)(?:spec|test)/|_(?:spec|test)\.rb$}

    # A setter method name: an identifier followed by a single trailing `=` (`foo=`,
    # `session_endpoint=`). Deliberately excludes operator methods that also end in `=`
    # (`==`, `<=`, `>=`, `!=`, `===`) and the index setter `[]=`, none of which are
    # mass-assignment targets.
    SETTER_NAME = /\A[A-Za-z_]\w*=\z/

    # Default public-surface path fragments. Packwerk exposes a pack's public API under
    # `app/public/`; definitions there may be consumed by other packs/services or at runtime
    # in ways the in-repo static graph can't see, so a zero-reference result is only a prompt
    # for review — never a safe delete.
    DEFAULT_PUBLIC_PATHS = ["/app/public/"].freeze

    def initialize(project_root:, exclude_paths: [], recent_within: nil, public_paths: DEFAULT_PUBLIC_PATHS,
                   history: false, dead_since: false)
      @project_root = File.expand_path(project_root)
      @exclude_paths = exclude_paths
      # When set (seconds), candidates whose definition line was introduced within the
      # window are flagged :recently_added and routed to review (issue #19).
      @recency = recent_within && Git::Recency.new(@project_root, recent_within)
      # Path fragments marking a public API surface (issue #138). Definitions there are
      # downgraded from safe_delete to review since external/runtime consumers are invisible.
      @public_paths = Array(public_paths)
      # When enabled, annotate each result with the commit that introduced it (`added:`) and, when
      # --dead-since is also on, when it became dead (`dead_since:`, repo-wide pickaxe) — issue #135.
      @history = Git::History.new(@project_root, dead_since: dead_since) if history || dead_since
    end

    # @param candidates [Array<Definition>]
    # @return [Array<Result>]
    def classify(candidates)
      return [] if candidates.empty?

      unless Ripgrep.available?
        $stderr.puts "[sorbet-deadcode] ripgrep (rg) not found — classifying without reference " \
                     "data. Install ripgrep for accurate flags/actions."
        return candidates.map { |defn| unverified_result(defn) }
      end

      # Precompute introducing commits once (batched per file) so classify_one can annotate
      # each result without a per-candidate git invocation (issue #146).
      @history&.prepare(candidates)

      refs = reference_files_by_name(candidates.map(&:name).uniq)
      candidates.map { |defn| classify_one(defn, refs[defn.name] || {}) }
    end

    private

    # Fallback annotation when ripgrep is unavailable: we can't count references, so
    # mark every candidate for manual review at low confidence.
    def unverified_result(definition)
      Result.new(
        definition: definition,
        confidence: Analyzer::Confidence::LOW,
        reference_count: nil,
        external_reference_count: nil,
        flags: [:ripgrep_unavailable],
        suggested_action: :review,
      )
    end

    def classify_one(definition, files_hash)
      defn_abs = File.expand_path(definition.file.to_s)
      external = files_hash.reject { |path, _| File.expand_path(path) == defn_abs }

      total = files_hash.values.sum
      external_count = external.values.sum

      production_ruby = external.keys.select { |f| f.end_with?(".rb") && !f.match?(SPEC_PATH) }
      spec_refs = external.keys.select { |f| f.match?(SPEC_PATH) }
      non_ruby = external.keys.reject { |f| f.end_with?(".rb") }

      flags = build_flags(definition, spec_refs, non_ruby, production_ruby)
      confidence = confidence_for(external_count, flags)
      action = action_for(production_ruby, spec_refs, non_ruby, flags)

      # A refiner in :report mode kept this candidate (referenced only from a non-Ruby
      # source it scans). Surface why, and downgrade to a low-confidence review.
      if definition.kept_by
        flags = [:"kept_by:#{definition.kept_by}", *flags]
        confidence = Analyzer::Confidence::LOW
        action = :review
      end

      # Recently-introduced definitions are risky to delete (possible in-flight work);
      # flag and route to review so they're excluded from the safe_delete actionable list.
      if @recency&.recently_added?(definition)
        flags = [:recently_added, *flags]
        confidence = Analyzer::Confidence::LOW
        action = :review
      end

      Result.new(
        definition: definition,
        confidence: confidence,
        reference_count: total,
        external_reference_count: external_count,
        flags: flags,
        suggested_action: action,
        added: @history&.added(definition),
        dead_since: @history&.dead_since(definition),
      )
    end

    def build_flags(definition, spec_refs, non_ruby, production_ruby)
      flags = []
      # A parent constant holding inline children, or an inline child itself, can only be
      # removed by editing the enclosing literal — route to review, never safe_delete.
      flags << :inline_constant if definition.co_located_names.any? || definition.inline_member
      flags << :spec_only if spec_refs.any? && production_ruby.empty? && non_ruby.empty?
      flags << :non_ruby_reference if non_ruby.any?
      flags << :live_reference if production_ruby.any?
      # Defined on a public API surface (e.g. Packwerk app/public/): external/runtime
      # consumers are invisible to in-repo analysis, so caution even at zero references.
      flags << :public_api if public_api?(definition)
      # One half of an `attr_accessor` whose other half is live: narrow the accessor, don't
      # delete the whole line (issue #137).
      flags << :partial_accessor if definition.partial_accessor
      # Removing this writer would leave the surviving reader's `@ivar` read-but-unassigned, which
      # Sorbet reports as an error: keep a typed declaration when narrowing (issue #137).
      flags << :ivar_hazard if definition.ivar_hazard
      # Became dead only after other dead code was (transitively) removed (issue #136, --cascade).
      flags << :cascaded if definition.cascaded
      # A setter (`foo=`) is the target of Rails mass-assignment (`Model.new(foo:)`,
      # `record.update!(foo:)`, `assign_attributes`, strong-params `permit(:foo)`). Those call
      # sites name the attribute as a symbol key (`foo:`), not the literal `foo=`, and may live
      # in another pack, an engine, or a hash built at runtime — i.e. outside the analyzed scope.
      # So an apparently-unreferenced writer is a mass-assignment hazard, never a safe delete.
      flags << :writer if writer?(definition)
      flags
    end

    # True for a setter method — hand-written (`def foo=`) or generated (`attr_writer` /
    # `attr_accessor`). See the :writer flag rationale in build_flags.
    def writer?(definition)
      return true if definition.kind == :attr_writer

      definition.kind == :method && SETTER_NAME.match?(definition.name.to_s)
    end

    # True when the definition lives on a configured public-API surface.
    def public_api?(definition)
      path = definition.file.to_s
      @public_paths.any? { |fragment| path.include?(fragment) }
    end

    def confidence_for(external_count, flags)
      # Public-API surface: never high confidence — a zero-reference result can't see
      # external/runtime consumers, so it's a review prompt, not a safe delete.
      return Analyzer::Confidence::LOW if flags.include?(:public_api)
      # Setter with no visible references: it may still be written via mass-assignment from a
      # caller outside the analyzed scope (another pack/engine, or a dynamically-built hash), so
      # the zero-reference reading is unreliable. Never high confidence.
      return Analyzer::Confidence::LOW if flags.include?(:writer) && external_count.zero?
      return Analyzer::Confidence::HIGH if external_count.zero?
      return Analyzer::Confidence::LOW if flags.include?(:live_reference) || flags.include?(:non_ruby_reference)

      Analyzer::Confidence::MEDIUM # spec-only references
    end

    def action_for(production_ruby, spec_refs, non_ruby, flags)
      # Real production references → the candidate is actually used; keep it.
      return :keep if production_ruby.any?
      # Referenced from non-Ruby files (routes/YAML/ERB/.graphql) → needs a human look.
      return :review if non_ruby.any?
      # Only spec/test references → safe to delete along with the spec.
      return :delete_with_spec if spec_refs.any?
      # Inline constant side-effect (PARENT = [CHILD = ...]) → review removal carefully.
      return :review if flags.include?(:inline_constant)
      # Public API surface with no in-repo references → review, never auto-delete: an
      # external pack/service or runtime consumer may use it where rg can't see.
      return :review if flags.include?(:public_api)
      # Narrowing this accessor would orphan the backing `@ivar` (Sorbet error) → review so a
      # human keeps a typed declaration rather than blindly deleting the writer.
      return :review if flags.include?(:ivar_hazard)
      # A setter with no references at all may still be reached by dynamic mass-assignment
      # (`update!(foo:)`, `assign_attributes`, strong-params) from a caller the static graph
      # can't see — a different pack, an engine, or a runtime-built attribute hash. Deleting it
      # risks a runtime `ActiveModel::UnknownAttributeError`, so route to review rather than
      # auto-deleting. Real callers in scope already keep it alive (returned :keep above).
      return :review if flags.include?(:writer)
      # No references anywhere outside the definition. Reaching here means production_ruby,
      # spec_refs and non_ruby are all empty; since every external file falls into exactly
      # one of those buckets, external_count is necessarily 0 here.
      :safe_delete
    end

    # Returns { name => { path => occurrence_count } } for all matching files.
    def reference_files_by_name(names)
      result = Hash.new { |h, k| h[k] = Hash.new(0) }
      Ripgrep.search(names, project_root: @project_root, exclude_paths: @exclude_paths, with_filename: true) do |line|
        path, token = split_match_line(line)
        next unless path && token

        result[token][path] += 1
      end
      result
    end

    # rg --with-filename -o emits `path:matched`. The matched token is a candidate
    # name, which for a compactly-defined class/module is the fully-qualified constant
    # (e.g. "A::B::C") and therefore *does* contain ':'. File paths don't, so we split
    # on the FIRST colon — splitting on the last would shear the token at its "::" and
    # re-key references under the wrong (short) name, hiding every cross-file reference
    # to a namespaced constant and mislabeling live code as safe_delete.
    def split_match_line(line)
      stripped = line.rstrip
      idx = stripped.index(":")
      return [nil, nil] unless idx

      [stripped[0...idx], stripped[(idx + 1)..]]
    end
  end
end
