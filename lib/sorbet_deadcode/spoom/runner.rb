# frozen_string_literal: true

module SorbetDeadcode
  module Spoom
    # Live adapter around Shopify's `spoom` dead-code engine (its Ruby API), exposing the result
    # as a SorbetDeadcode::Index for `--spoom` intersection — no intermediate file or fragile
    # text-output parsing. spoom is an OPTIONAL dependency: it is required lazily here, so users
    # who don't use `--spoom` never need it installed.
    #
    # This file mirrors `spoom deadcode`'s own CLI flow (FileCollector -> plugins -> Model/Index
    # -> index_file -> select(&:dead?)). It is excluded from unit coverage because it can only run
    # with a live spoom install against a real project context; the pure row->Index mapping it
    # delegates to (Spoom::Converter) is unit-tested.
    module Runner
      module_function

      DEFAULT_EXTENSIONS = [".rb", ".erb", ".gemspec"].freeze
      DEFAULT_MIME_TYPES = ["text/x-ruby", "text/x-ruby-script"].freeze

      # spoom's dead-code Ruby API is internal and may shift between releases. We pin the range
      # this adapter is tested against and warn (don't fail) outside it, so a spoom upgrade that
      # changes the API surfaces a clear hint rather than a cryptic NoMethodError. The
      # spoom-integration CI lane runs the real adapter so drift is caught up front.
      TESTED_SPOOM_REQUIREMENT = Gem::Requirement.new(">= 1.7", "< 2.0")

      # @return [SorbetDeadcode::Index] spoom's dead set for `paths`, as our Index.
      def dead_index(paths, project_root: ".", exclude_paths: [])
        Converter.index_from_rows(dead_rows(paths, project_root: project_root, exclude_paths: exclude_paths), paths: paths)
      end

      # @return [Array<Hash>] rows of { full_name:, kind:, file:, line: } for spoom's dead candidates.
      def dead_rows(paths, project_root: ".", exclude_paths: [])
        require_spoom!
        paths = Array(paths)

        context = ::Spoom::Context.new(File.expand_path(project_root))
        files = collect_files(paths, exclude_paths)
        index = build_index(context, files)

        index.definitions.values.flatten.select(&:dead?).map do |definition|
          location = definition.location
          { full_name: definition.full_name, kind: definition.kind.serialize, file: location.file, line: location.start_line }
        end
      end

      def require_spoom!
        require "spoom"
        # spoom's gemfile-lock plugin loader references the Bundler constant directly.
        require "bundler"
        warn_if_untested_spoom_version
      rescue ::LoadError
        raise SorbetDeadcode::Error,
              "spoom is not installed. Add `gem \"spoom\"` to your Gemfile (or `gem install spoom`) to use --spoom."
      end

      def warn_if_untested_spoom_version
        return unless defined?(::Spoom::VERSION)
        return if TESTED_SPOOM_REQUIREMENT.satisfied_by?(Gem::Version.new(::Spoom::VERSION))

        $stderr.puts "[sorbet-deadcode] warning: spoom #{::Spoom::VERSION} is outside the tested " \
                     "range (#{TESTED_SPOOM_REQUIREMENT}); --spoom may need updating if it errors."
      end

      def collect_files(paths, exclude_paths)
        exclude_patterns = paths.flat_map do |path|
          exclude_paths.map { |ex| File.join(path, ex, "**") }
        end
        collector = ::Spoom::FileCollector.new(
          allow_extensions: DEFAULT_EXTENSIONS,
          allow_mime_types: DEFAULT_MIME_TYPES,
          exclude_patterns: exclude_patterns,
        )
        collector.visit_paths(paths)
        collector.files.sort
      end

      def build_index(context, files)
        plugin_classes = framework_plugins(context)
        model = ::Spoom::Model.new
        index = ::Spoom::Deadcode::Index.new(model)
        plugins = plugin_classes.map { |plugin| plugin.new(index) }

        files.each do |file|
          index.index_file(file, plugins: plugins)
        rescue StandardError
          next # skip files spoom can't parse/index, like its own CLI does
        end

        model.finalize!
        index.apply_plugins!(plugins)
        index.finalize!
        index
      end

      # spoom selects framework plugins (rails/activerecord/graphql/...) from the project's
      # Gemfile.lock. If that can't be resolved, fall back to no framework plugins — spoom then
      # over-reports, but the intersection with our (precise) set stays conservative.
      def framework_plugins(context)
        classes = ::Spoom::Deadcode.plugins_from_gemfile_lock(context)
        classes.merge(::Spoom::Deadcode.load_custom_plugins(context))
        classes
      rescue StandardError
        Set.new
      end
    end
  end
end
