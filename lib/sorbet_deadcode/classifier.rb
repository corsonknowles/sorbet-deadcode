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
      keyword_init: true,
    )

    # Matches files under spec/ or test/ directories, or *_spec.rb / *_test.rb.
    SPEC_PATH = %r{(?:^|/)(?:spec|test)/|_(?:spec|test)\.rb$}

    def initialize(project_root:, exclude_paths: [], recent_within: nil)
      @project_root = File.expand_path(project_root)
      @exclude_paths = exclude_paths
      # When set (seconds), candidates whose definition line was introduced within the
      # window are flagged :recently_added and routed to review (issue #19).
      @recency = recent_within && Git::Recency.new(@project_root, recent_within)
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
      action = action_for(external_count, production_ruby, spec_refs, non_ruby, flags)

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
      )
    end

    def build_flags(definition, spec_refs, non_ruby, production_ruby)
      flags = []
      flags << :inline_constant if definition.co_located_names.any?
      flags << :spec_only if spec_refs.any? && production_ruby.empty? && non_ruby.empty?
      flags << :non_ruby_reference if non_ruby.any?
      flags << :live_reference if production_ruby.any?
      flags
    end

    def confidence_for(external_count, flags)
      return Analyzer::Confidence::HIGH if external_count.zero?
      return Analyzer::Confidence::LOW if flags.include?(:live_reference) || flags.include?(:non_ruby_reference)

      Analyzer::Confidence::MEDIUM # spec-only references
    end

    def action_for(external_count, production_ruby, spec_refs, non_ruby, flags)
      # Real production references → the candidate is actually used; keep it.
      return :keep if production_ruby.any?
      # Referenced from non-Ruby files (routes/YAML/ERB/.graphql) → needs a human look.
      return :review if non_ruby.any?
      # Only spec/test references → safe to delete along with the spec.
      return :delete_with_spec if spec_refs.any?
      # Inline constant side-effect (PARENT = [CHILD = ...]) → review removal carefully.
      return :review if flags.include?(:inline_constant)
      # No references anywhere outside the definition.
      external_count.zero? ? :safe_delete : :review
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
