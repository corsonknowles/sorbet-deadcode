# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Refiners
    class RouteRefinerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(@dir, "config"))
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def make_def(name, kind: :method, owner: "WidgetsController")
        Definition.new(
          name: name, full_name: "#{owner}##{name}", kind: kind,
          location: "app/controllers/widgets_controller.rb:1",
          owner_name: owner,
        )
      end

      def refiner
        RouteRefiner.new(@dir)
      end

      def write_routes(content)
        File.write(File.join(@dir, "config", "routes.rb"), content)
      end

      def test_removes_routed_controller_action
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = make_def("index")
        result = refiner.refine([defn])
        assert_empty result
      end

      def test_keeps_unrouted_action
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = make_def("orphan_action")
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_keeps_action_from_different_controller
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = make_def("index", owner: "OtherController")
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_removes_controller_class_referenced_from_routes
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = Definition.new(
          name: "WidgetsController", full_name: "WidgetsController",
          kind: :class, location: "f:1",
        )
        result = refiner.refine([defn])
        assert_empty result
      end

      def test_does_not_remove_unrelated_class
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = Definition.new(
          name: "SomeService", full_name: "SomeService",
          kind: :class, location: "f:1",
        )
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_returns_unchanged_when_routes_file_is_empty
        write_routes("")   # parses fine but emits no references → routed set empty
        defn = make_def("index")
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_attr_reader_not_removed_unless_routed
        write_routes("get '/widgets', to: 'widgets#index'")
        defn = Definition.new(
          name: "title", full_name: "WidgetsController#title",
          kind: :attr_reader, location: "f:1", owner_name: "WidgetsController",
        )
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_returns_all_when_no_routes_file
        defn = make_def("index")
        result = refiner.refine([defn])
        assert_equal [defn], result
      end

      def test_returns_empty_input_unchanged
        assert_equal [], refiner.refine([])
      end

      def test_does_not_affect_constants
        write_routes("get '/widgets', to: 'widgets#index'")
        const_def = Definition.new(
          name: "MY_CONST", full_name: "WidgetsController::MY_CONST",
          kind: :constant, location: "f:1", owner_name: "WidgetsController",
        )
        result = refiner.refine([const_def])
        assert_equal [const_def], result
      end

      def test_resources_routes_remove_all_crud_actions
        write_routes("resources :orders")
        defs = %w[index show new create edit update destroy].map do |a|
          make_def(a, owner: "OrdersController")
        end + [make_def("custom_action", owner: "OrdersController")]

        result = refiner.refine(defs)
        remaining_names = result.map(&:name)
        assert_equal ["custom_action"], remaining_names
      end

      # ---- integration: full pipeline -----------------------------------

      def test_full_pipeline_removes_controller_actions_from_dead_list
        FileUtils.mkdir_p(File.join(@dir, "app", "controllers"))
        write_routes("get '/widgets', to: 'widgets#index'")
        File.write(File.join(@dir, "app", "controllers", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController
            def index; end
            def dead_action; end
          end
        RUBY

        candidates = SorbetDeadcode.analyze(File.join(@dir, "app"))
        refined = RouteRefiner.new(@dir).refine(candidates)
        names = refined.map(&:name)

        refute_includes names, "index"
        assert_includes names, "dead_action"
      end

      def test_analyze_and_refine_convenience_method
        FileUtils.mkdir_p(File.join(@dir, "app", "controllers"))
        write_routes("get '/widgets', to: 'widgets#index'")
        File.write(File.join(@dir, "app", "controllers", "widgets_controller.rb"), <<~RUBY)
          class WidgetsController
            def index; end
            def dead_action; end
          end
        RUBY

        results = SorbetDeadcode.analyze_and_refine(
          paths: [File.join(@dir, "app")],
          refiners: [RouteRefiner.new(@dir)],
        )
        names = results.map(&:name)

        refute_includes names, "index"
        assert_includes names, "dead_action"
      end
    end
  end
end
