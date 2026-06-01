# frozen_string_literal: true

require_relative "../../spec_helper"

module SorbetDeadcode
  module Scanners
    class RouteScannerSpec < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(@dir, "config"))
      end

      def teardown
        FileUtils.remove_entry(@dir)
      end

      def write_routes(content)
        File.write(File.join(@dir, "config", "routes.rb"), content)
        RouteScanner.new(@dir).references
      end

      # ---- to: 'controller#action' ----------------------------------------

      def test_get_to_emits_typed_method_reference
        refs = write_routes(<<~RUBY)
          Rails.application.routes.draw do
            get '/widgets', to: 'widgets#index'
          end
        RUBY

        ref = refs.find { |r| r.kind == :method && r.name == "index" }
        assert ref, "expected a method reference for 'index'"
        assert_equal "WidgetsController", ref.receiver_type
      end

      def test_post_to_emits_reference
        refs = write_routes("post '/widgets', to: 'widgets#create'")
        assert(refs.any? { |r| r.name == "create" && r.receiver_type == "WidgetsController" })
      end

      def test_namespaced_controller_in_to_string
        refs = write_routes("get '/admin/widgets', to: 'admin/widgets#index'")
        ref = refs.find { |r| r.name == "index" }
        assert_equal "Admin::WidgetsController", ref.receiver_type
      end

      def test_to_emits_constant_reference_for_controller_class
        refs = write_routes("get '/widgets', to: 'widgets#index'")
        const_names = refs.select { |r| r.kind == :constant }.map(&:name)
        assert_includes const_names, "WidgetsController"
      end

      def test_symbol_to_value
        refs = write_routes("get '/status', to: :'health#check'")
        assert(refs.any? { |r| r.name == "check" && r.receiver_type == "HealthController" })
      end

      # ---- resources / resource -------------------------------------------

      def test_resources_emits_all_crud_actions
        refs = write_routes("resources :widgets")
        action_names = refs.select { |r| r.kind == :method }.map(&:name)
        %w[index show new create edit update destroy].each do |a|
          assert_includes action_names, a
        end
      end

      def test_resource_singular_omits_index
        refs = write_routes("resource :profile")
        action_names = refs.select { |r| r.kind == :method }.map(&:name)
        refute_includes action_names, "index"
        assert_includes action_names, "show"
      end

      def test_resources_only_limits_actions
        refs = write_routes("resources :widgets, only: [:index, :show]")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "WidgetsController" }.map(&:name)
        assert_includes action_names, "index"
        assert_includes action_names, "show"
        refute_includes action_names, "create"
      end

      def test_resources_except_excludes_actions
        refs = write_routes("resources :widgets, except: [:destroy]")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "WidgetsController" }.map(&:name)
        refute_includes action_names, "destroy"
        assert_includes action_names, "index"
      end

      def test_resources_with_explicit_controller
        refs = write_routes("resources :things, controller: :widgets")
        ref = refs.find { |r| r.name == "index" }
        assert_equal "WidgetsController", ref.receiver_type
      end

      def test_resources_with_module_option
        refs = write_routes("resources :widgets, module: :admin")
        ref = refs.find { |r| r.name == "index" }
        assert_equal "Admin::WidgetsController", ref.receiver_type
      end

      # ---- namespace / scope ----------------------------------------------

      def test_namespace_prefixes_controller_class
        refs = write_routes(<<~RUBY)
          namespace :admin do
            get '/companies', to: 'companies#index'
          end
        RUBY

        ref = refs.find { |r| r.name == "index" }
        assert_equal "Admin::CompaniesController", ref.receiver_type
      end

      def test_scope_module_prefixes_controller_class
        refs = write_routes(<<~RUBY)
          scope module: 'admin' do
            get '/companies', to: 'companies#index'
          end
        RUBY

        ref = refs.find { |r| r.name == "index" }
        assert_equal "Admin::CompaniesController", ref.receiver_type
      end

      def test_nested_namespace
        refs = write_routes(<<~RUBY)
          namespace :api do
            namespace :v1 do
              get '/users', to: 'users#index'
            end
          end
        RUBY

        ref = refs.find { |r| r.name == "index" }
        assert_equal "Api::V1::UsersController", ref.receiver_type
      end

      def test_namespace_with_resources
        refs = write_routes(<<~RUBY)
          namespace :admin do
            resources :companies
          end
        RUBY

        ref = refs.find { |r| r.name == "index" }
        assert_equal "Admin::CompaniesController", ref.receiver_type
      end

      # ---- controller block -----------------------------------------------

      def test_controller_block_not_crash
        refs = write_routes(<<~RUBY)
          controller :widgets do
            get '/special', to: 'widgets#special'
          end
        RUBY

        assert_kind_of Array, refs
      end

      # ---- no routes.rb ---------------------------------------------------

      def test_handles_unreadable_routes_file_gracefully
        File.write(File.join(@dir, "config", "routes.rb"), "get '/health', to: 'health#check'")
        File.chmod(0o000, File.join(@dir, "config", "routes.rb"))
        assert_empty RouteScanner.new(@dir).references
      rescue Errno::EPERM
        # Some systems (e.g. running as root) can't restrict read access — skip.
        skip "Cannot restrict file permissions on this system"
      ensure
        begin
          File.chmod(0o644, File.join(@dir, "config", "routes.rb"))
        rescue StandardError
          nil
        end
      end

      def test_returns_empty_when_no_routes_file
        scanner = RouteScanner.new(@dir) # no config/routes.rb written
        assert_empty scanner.references
      end

      # ---- split route files ----------------------------------------------

      def test_scans_routes_subdirectory
        FileUtils.mkdir_p(File.join(@dir, "config", "routes"))
        File.write(File.join(@dir, "config", "routes.rb"), "")
        File.write(File.join(@dir, "config", "routes", "admin.rb"),
                   "get '/admin', to: 'admin/dashboard#index'")

        refs = RouteScanner.new(@dir).references
        assert(refs.any? { |r| r.name == "index" && r.receiver_type == "Admin::DashboardController" })
      end

      # ---- edge cases -----------------------------------------------------

      def test_handles_invalid_ruby_gracefully
        File.write(File.join(@dir, "config", "routes.rb"), "class Broken\n  def oops(\nend")
        assert_empty RouteScanner.new(@dir).references
      end

      def test_namespace_without_block_does_not_crash
        refs = write_routes("namespace :admin")
        assert_kind_of Array, refs
      end

      def test_scope_without_module_option_does_not_crash
        refs = write_routes("scope '/api' do\n  get '/health', to: 'health#check'\nend")
        assert(refs.any? { |r| r.name == "check" })
      end

      def test_resources_with_string_only
        refs = write_routes("resources :widgets, only: 'index'")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "WidgetsController" }.map(&:name)
        assert_includes action_names, "index"
      end

      def test_resources_with_string_except
        refs = write_routes("resources :widgets, except: 'destroy'")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "WidgetsController" }.map(&:name)
        refute_includes action_names, "destroy"
      end

      def test_resources_without_only_except_emits_all_crud
        refs = write_routes("resources :orders")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "OrdersController" }.map(&:name)
        assert_equal 7, action_names.size
      end

      def test_to_without_hash_symbol_ignored
        # `to:` value is a proc/lambda — should not crash
        refs = write_routes("get '/ping', to: -> (env) { [200, {}, ['ok']] }")
        refute(refs.any? { |r| r.name == "ping" })
      end

      def test_route_method_with_no_to_key_is_skipped
        refs = write_routes("get '/widgets'")
        assert_kind_of Array, refs
      end

      def test_resources_with_string_name
        refs = write_routes("resources 'widgets'")
        assert(refs.any? { |r| r.name == "index" && r.receiver_type == "WidgetsController" })
      end

      def test_resources_with_unknown_keyword_option_ignored
        refs = write_routes("resources :widgets, shallow: true")
        action_names = refs.select { |r| r.kind == :method && r.receiver_type == "WidgetsController" }.map(&:name)
        assert_equal 7, action_names.uniq.size
      end

      def test_to_string_without_hash_emits_no_reference
        refs = write_routes("get '/health', to: 'healthcheck'")
        refute(refs.any? { |r| r.kind == :method && r.name == "healthcheck" })
      end

      def test_controller_class_name_already_ending_in_controller
        collector = RouteReferenceCollector.new("test.rb")
        name = collector.send(:controller_class_name, "widgets_controller", namespace: [])
        assert_equal "WidgetsController", name
      end

      def test_keyword_arg_value_with_no_arguments
        collector = RouteReferenceCollector.new("test.rb")
        result = Prism.parse("namespace")
        call = result.value.statements.body.first
        assert_nil collector.send(:keyword_arg_value, call, "module")
      end

      def test_keyword_arg_value_with_hash_splat
        # **opts in keyword hash produces AssocSplatNode, not AssocNode — should skip
        refs = write_routes("scope **route_options do\n  get '/foo', to: 'foo#index'\nend")
        assert_kind_of Array, refs
      end

      def test_resources_first_arg_nil_is_skipped
        refs = write_routes("resources")
        assert_empty(refs.select { |r| r.kind == :method })
      end

      def test_camelize_handles_single_word
        collector = RouteReferenceCollector.new("test.rb")
        assert_equal "Admin::WidgetsController",
                     collector.send(:controller_class_name, "admin/widgets", namespace: [])
      end

      def test_controller_block_without_arg_does_not_crash
        refs = write_routes(<<~RUBY)
          controller do
            get '/foo', to: 'foo#index'
          end
        RUBY

        assert_kind_of Array, refs
      end

      def test_namespace_without_segment_uses_existing_namespace
        refs = write_routes(<<~RUBY)
          namespace do
            get '/foo', to: 'foo#index'
          end
        RUBY

        # no segment pushed, controller class should be FooController (no prefix)
        ref = refs.find { |r| r.name == "index" }
        assert_equal "FooController", ref.receiver_type if ref
      end

      def test_keyword_arg_value_returns_nil_when_key_absent
        collector = RouteReferenceCollector.new("test.rb")
        result = Prism.parse("resources :widgets, only: [:index]")
        call = result.value.statements.body.first
        assert_nil collector.send(:keyword_arg_value, call, "nonexistent_key")
      end

      def test_extract_symbol_array_returns_nil_for_other_node_types
        collector = RouteReferenceCollector.new("test.rb")
        int_node = Prism.parse("42").value.statements.body.first
        assert_nil collector.send(:extract_symbol_array, int_node)
      end

      def test_symbol_or_string_returns_nil_for_non_string_symbol
        collector = RouteReferenceCollector.new("test.rb")
        int_node = Prism.parse("42").value.statements.body.first
        assert_nil collector.send(:symbol_or_string, int_node)
      end
    end
  end
end
