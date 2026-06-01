# frozen_string_literal: true

require_relative "../spec_helper"

module SorbetDeadcode
  class ClassifierSpec < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    def write(rel, contents)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    def defn(name, kind: :method, location:, owner_name: "Foo", co_located_names: [])
      Definition.new(name: name, full_name: "#{owner_name}##{name}", kind: kind,
                     location: location, owner_name: owner_name, co_located_names: co_located_names)
    end

    def classify_one(candidate)
      Classifier.new(project_root: @dir).classify([candidate]).first
    end

    def test_kept_by_marks_low_confidence_review_with_source_flag
      path = write("app/foo.rb", "class Foo\n  def kept_method\n  end\nend\n")
      candidate = defn("kept_method", location: "#{path}:2")
      candidate.kept_by = :graphql_sdl

      result = classify_one(candidate)

      assert_equal Analyzer::Confidence::LOW, result.confidence
      assert_equal :review, result.suggested_action
      assert_includes result.flags, :"kept_by:graphql_sdl"
    end

    def test_no_external_references_is_safe_delete_high
      path = write("app/foo.rb", "class Foo\n  def truly_dead\n  end\nend\n")
      result = classify_one(defn("truly_dead", location: "#{path}:2"))

      assert_equal :safe_delete, result.suggested_action
      assert_equal Analyzer::Confidence::HIGH, result.confidence
      assert_equal 0, result.external_reference_count
    end

    def test_production_reference_is_keep
      path = write("app/foo.rb", "class Foo\n  def used_method\n  end\nend\n")
      write("app/caller.rb", "Foo.new.used_method\n")
      result = classify_one(defn("used_method", location: "#{path}:2"))

      assert_equal :keep, result.suggested_action
      assert_equal Analyzer::Confidence::LOW, result.confidence
      assert_includes result.flags, :live_reference
    end

    def test_spec_only_reference_is_delete_with_spec
      path = write("app/foo.rb", "class Foo\n  def tested_only\n  end\nend\n")
      write("spec/foo_spec.rb", "Foo.new.tested_only\n")
      result = classify_one(defn("tested_only", location: "#{path}:2"))

      assert_equal :delete_with_spec, result.suggested_action
      assert_equal Analyzer::Confidence::MEDIUM, result.confidence
      assert_includes result.flags, :spec_only
    end

    def test_non_ruby_reference_is_review
      path = write("app/foo.rb", "class Foo\n  def yaml_referenced\n  end\nend\n")
      write("config/thing.yml", "method: yaml_referenced\n")
      result = classify_one(defn("yaml_referenced", location: "#{path}:2"))

      assert_equal :review, result.suggested_action
      assert_equal Analyzer::Confidence::LOW, result.confidence
      assert_includes result.flags, :non_ruby_reference
    end

    def test_inline_constant_is_review
      path = write("app/config.rb", "class Config\n  PARENT = [CHILD = 1].freeze\nend\n")
      result = classify_one(
        defn("PARENT", kind: :constant, location: "#{path}:2", owner_name: "Config", co_located_names: ["CHILD"]),
      )

      assert_includes result.flags, :inline_constant
      assert_equal :review, result.suggested_action
    end

    def test_predicate_method_reference_counts
      path = write("app/foo.rb", "class Foo\n  def ready?\n  end\nend\n")
      write("app/caller.rb", "Foo.new.ready?\n")
      result = classify_one(defn("ready?", location: "#{path}:2"))

      # ready? matched literally despite the trailing ? (special-name path)
      assert_equal :keep, result.suggested_action
    end

    def test_empty_candidates_returns_empty
      assert_equal [], Classifier.new(project_root: @dir).classify([])
    end

    def test_degrades_gracefully_when_ripgrep_missing
      path = write("app/foo.rb", "class Foo\n  def thing\n  end\nend\n")
      candidate = defn("thing", location: "#{path}:2")

      out = capture_stderr do
        SorbetDeadcode::Ripgrep.stub(:available?, false) do
          @result = Classifier.new(project_root: @dir).classify([candidate])
        end
      end

      assert_match(/ripgrep .* not found/, out)
      assert_equal 1, @result.size
      assert_equal :review, @result.first.suggested_action
      assert_includes @result.first.flags, :ripgrep_unavailable
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    def test_exclude_paths_drops_spec_reference
      path = write("app/foo.rb", "class Foo\n  def excluded_check\n  end\nend\n")
      write("spec/foo_spec.rb", "Foo.new.excluded_check\n")

      # With spec/ excluded from the rg search, the only spec reference disappears
      # → the method looks fully dead (safe_delete).
      classifier = Classifier.new(project_root: @dir, exclude_paths: ["spec/"])
      result = classifier.classify([defn("excluded_check", location: "#{path}:2")]).first

      assert_equal :safe_delete, result.suggested_action
      assert_equal 0, result.external_reference_count
    end

    def test_split_match_line_returns_nils_without_colon
      classifier = Classifier.new(project_root: @dir)
      assert_equal [nil, nil], classifier.send(:split_match_line, "no-colon-here\n")
    end

    def test_classifies_multiple_candidates
      path = write("app/foo.rb", <<~RUBY)
        class Foo
          def dead_one
          end

          def alive_one
          end
        end
      RUBY
      write("app/caller.rb", "Foo.new.alive_one\n")

      results = Classifier.new(project_root: @dir).classify([
        defn("dead_one", location: "#{path}:2"),
        defn("alive_one", location: "#{path}:5"),
      ])

      by_name = results.to_h { |r| [r.definition.name, r.suggested_action] }
      assert_equal :safe_delete, by_name["dead_one"]
      assert_equal :keep, by_name["alive_one"]
    end

    def test_reference_count_includes_definition
      path = write("app/foo.rb", "class Foo\n  def counted\n  end\nend\n")
      write("app/caller.rb", "Foo.new.counted\n")
      result = classify_one(defn("counted", location: "#{path}:2"))

      assert_equal 2, result.reference_count        # definition + 1 caller
      assert_equal 1, result.external_reference_count
    end
  end
end
