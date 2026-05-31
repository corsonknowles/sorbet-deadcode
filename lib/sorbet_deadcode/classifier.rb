# frozen_string_literal: true

require "shellwords"
require "tempfile"

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

    def initialize(project_root:, exclude_paths: [])
      @project_root = File.expand_path(project_root)
      @exclude_paths = exclude_paths
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
      defn_abs = File.expand_path(definition.location.split(":").first.to_s)
      external = files_hash.reject { |path, _| File.expand_path(path) == defn_abs }

      total = files_hash.values.sum
      external_count = external.values.sum

      production_ruby = external.keys.select { |f| f.end_with?(".rb") && !f.match?(SPEC_PATH) }
      spec_refs = external.keys.select { |f| f.match?(SPEC_PATH) }
      non_ruby = external.keys.reject { |f| f.end_with?(".rb") }

      flags = build_flags(definition, spec_refs, non_ruby, production_ruby)
      confidence = confidence_for(external_count, flags)
      action = action_for(external_count, production_ruby, spec_refs, non_ruby, flags)

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
      normal, special = names.partition { |n| !n.match?(/[?!=]$/) }
      result = Hash.new { |h, k| h[k] = Hash.new(0) }
      collect_matches(normal, word_bounded: true, into: result)
      collect_matches(special, word_bounded: false, into: result)
      result
    end

    def collect_matches(names, word_bounded:, into:)
      return if names.empty?

      pattern_file = write_pattern_file(names)
      cmd = ["rg", "-F", "-f", pattern_file, "--with-filename", "-o"]
      cmd << "-w" if word_bounded
      @exclude_paths.each { |ep| cmd += ["--glob", "!#{glob_pattern(ep)}"] }
      cmd << @project_root

      IO.popen(cmd, err: File::NULL) do |io|
        io.each_line do |line|
          path, token = split_match_line(line)
          next unless path && token

          into[token][path] += 1
        end
      end
    ensure
      File.delete(pattern_file) if pattern_file && File.exist?(pattern_file)
    end

    # rg --with-filename -o emits `path:matched`. Candidate names are simple
    # identifiers (optionally ending in ?/!/=) and never contain ':', so the last
    # colon reliably separates path from token.
    def split_match_line(line)
      stripped = line.rstrip
      idx = stripped.rindex(":")
      return [nil, nil] unless idx

      [stripped[0...idx], stripped[(idx + 1)..]]
    end

    def write_pattern_file(names)
      file = Tempfile.new(["sorbet_deadcode_classify", ".txt"])
      file.write(names.join("\n") + "\n")
      file.close
      file.path
    end

    def glob_pattern(path)
      return path if path.include?("*")

      "**/#{path}**"
    end
  end
end
