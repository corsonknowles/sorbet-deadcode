# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Refiners
    class YamlRefinerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write_yaml(rel, content)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      SANITIZER_CLASS = "Sanitizers::Helpers::WidgetSanitizer"
      SANITIZER = "method: #{SANITIZER_CLASS}.sanitize_widget\n"

      def make_def(name, kind: :method, owner: SANITIZER_CLASS)
        Definition.new(
          name: name, full_name: "#{owner}##{name}", kind: kind,
          location: "app/models/widget_sanitizer.rb:1", owner_name: owner,
        )
      end

      def refiner(**opts)
        YamlRefiner.new(@dir, **opts)
      end

      def test_removes_method_referenced_in_yaml
        write_yaml("config/widget.yml", SANITIZER)
        defn = make_def("sanitize_widget")
        assert_empty refiner.refine([defn])
      end

      def test_keeps_method_not_referenced_in_yaml
        write_yaml("config/widget.yml", SANITIZER)
        defn = make_def("genuinely_dead")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_qualified_match_is_owner_precise
        # `method: OtherLib::Geo.city` must NOT keep a dead City#city alive — the owner
        # differs, so name collisions across unrelated classes stay dead.
        write_yaml("config/seeds.yml", "method: OtherLib::Geo.city\n")
        defn = make_def("city", owner: "City")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_attr_reader_referenced_in_yaml_with_matching_owner
        write_yaml("config/widget.yml", "method: A::B.token\n")
        defn = make_def("token", kind: :attr_reader, owner: "A::B")
        assert_empty refiner.refine([defn])
      end

      def test_does_not_remove_unrelated_class
        write_yaml("config/widget.yml", SANITIZER)
        klass = Definition.new(name: "SomeService", full_name: "SomeService", kind: :class, location: "f:1")
        assert_equal [klass], refiner.refine([klass])
      end

      def test_removes_referenced_class_constant
        write_yaml("config/widget.yml", SANITIZER)
        klass = Definition.new(
          name: "WidgetSanitizer",
          full_name: SANITIZER_CLASS,
          kind: :class, location: "f:1",
        )
        assert_empty refiner.refine([klass])
      end

      def test_returns_unchanged_when_no_yaml_references
        write_yaml("config/widget.yml", "title: Something\n")
        defn = make_def("sanitize_widget")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_returns_empty_input_unchanged
        assert_equal [], refiner.refine([])
      end

      def test_honors_bare_keys
        write_yaml("config/a.yml", "sanitize_method: my_handler\n")
        defn = make_def("my_handler")
        assert_empty refiner(bare_keys: ["sanitize_method"]).refine([defn])
        # Default config has no bare keys, so the method stays.
        assert_equal [defn], refiner.refine([defn])
      end

      # ---- integration: full pipeline -----------------------------------

      def test_full_pipeline_keeps_yaml_referenced_method_and_class_alive
        FileUtils.mkdir_p(File.join(@dir, "app", "models"))
        write_yaml("config/widget.yml", "method: WidgetSanitizer.sanitize_widget\n")
        File.write(File.join(@dir, "app", "models", "widget_sanitizer.rb"), <<~RUBY)
          class WidgetSanitizer
            def self.sanitize_widget; end
            def truly_dead; end
          end
        RUBY

        candidates = SorbetDeadcode.analyze(File.join(@dir, "app"))
        refined = YamlRefiner.new(@dir).refine(candidates)
        names = refined.map(&:name)

        refute_includes names, "sanitize_widget"
        refute_includes names, "WidgetSanitizer"
        assert_includes names, "truly_dead"
      end

      def test_composes_with_analyze_and_refine
        FileUtils.mkdir_p(File.join(@dir, "app", "models"))
        write_yaml("config/widget.yml", "method: WidgetSanitizer.sanitize_widget\n")
        File.write(File.join(@dir, "app", "models", "widget_sanitizer.rb"), <<~RUBY)
          class WidgetSanitizer
            def self.sanitize_widget; end
            def truly_dead; end
          end
        RUBY

        results = SorbetDeadcode.analyze_and_refine(
          paths: [File.join(@dir, "app")],
          refiners: [YamlRefiner.new(@dir)],
        )
        names = results.map(&:name)

        refute_includes names, "sanitize_widget"
        assert_includes names, "truly_dead"
      end
    end
  end
end
