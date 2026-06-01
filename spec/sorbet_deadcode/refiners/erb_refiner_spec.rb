# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Refiners
    class ErbRefinerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write_erb(rel, content)
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      def make_def(name, kind: :method, owner: "Widget")
        Definition.new(
          name: name, full_name: "#{owner}##{name}", kind: kind,
          location: "app/models/widget.rb:1", owner_name: owner
        )
      end

      def refiner
        ErbRefiner.new(@dir)
      end

      def test_removes_method_referenced_in_template
        write_erb("app/views/show.erb", "<%= widget.display_name %>\n")
        defn = make_def("display_name")
        assert_empty refiner.refine([defn])
      end

      def test_keeps_method_not_referenced_in_template
        write_erb("app/views/show.erb", "<%= widget.display_name %>\n")
        defn = make_def("genuinely_dead")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_method_matching_is_name_only_across_owners
        # ERB receivers are untyped, so a template reference keeps any same-named method
        # alive regardless of owner.
        write_erb("app/views/show.erb", "<%= thing.display_name %>\n")
        defn = make_def("display_name", owner: "SomeOtherClass")
        assert_empty refiner.refine([defn])
      end

      def test_removes_constant_referenced_in_template
        write_erb("app/views/show.erb", "<%= Formatter.format(x) %>\n")
        klass = Definition.new(name: "Formatter", full_name: "Formatter", kind: :class, location: "f:1")
        assert_empty refiner.refine([klass])
      end

      def test_keeps_unreferenced_constant
        write_erb("app/views/show.erb", "<%= Formatter.format(x) %>\n")
        klass = Definition.new(name: "OtherClass", full_name: "OtherClass", kind: :class, location: "f:1")
        assert_equal [klass], refiner.refine([klass])
      end

      def test_returns_unchanged_when_template_has_no_references
        write_erb("app/views/static.erb", "<h1>static</h1>\n")
        defn = make_def("display_name")
        assert_equal [defn], refiner.refine([defn])
      end

      def test_returns_empty_input_unchanged
        assert_equal [], refiner.refine([])
      end

      # ---- integration: full pipeline -----------------------------------

      def test_full_pipeline_keeps_template_method_alive
        FileUtils.mkdir_p(File.join(@dir, "app", "models"))
        write_erb("app/views/widget/show.erb", "<%= Widget.new.display_name %>\n")
        File.write(File.join(@dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget
            def display_name; end
            def truly_dead; end
          end
        RUBY

        candidates = SorbetDeadcode.analyze(File.join(@dir, "app", "models"))
        refined = ErbRefiner.new(@dir).refine(candidates)
        names = refined.map(&:name)

        refute_includes names, "display_name"
        assert_includes names, "truly_dead"
      end

      def test_composes_with_analyze_and_refine
        FileUtils.mkdir_p(File.join(@dir, "app", "models"))
        write_erb("app/views/widget/show.erb", "<%= Widget.new.display_name %>\n")
        File.write(File.join(@dir, "app", "models", "widget.rb"), <<~RUBY)
          class Widget
            def display_name; end
            def truly_dead; end
          end
        RUBY

        results = SorbetDeadcode.analyze_and_refine(
          paths: [File.join(@dir, "app", "models")],
          refiners: [ErbRefiner.new(@dir)]
        )
        names = results.map(&:name)

        refute_includes names, "display_name"
        assert_includes names, "truly_dead"
      end
    end
  end
end
