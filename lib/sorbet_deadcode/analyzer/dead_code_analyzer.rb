# frozen_string_literal: true

module SorbetDeadcode
  module Analyzer
    class DeadCodeAnalyzer
      # Methods that are called by frameworks/Ruby internals and never appear as
      # explicit call sites in user code. Reporting them dead is always wrong.
      ALWAYS_ALIVE_METHODS = Set.new(%w[
        initialize
        respond_to_missing?
        method_missing
        use_relative_model_naming?
        to_s
        inspect
        ==
        extended
        included
        inherited
        method_added
        prepended
      ]).freeze

      # Framework convention hooks: methods a gem/framework invokes *by name* (reflection /
      # convention), so they have no explicit Ruby call site. Reporting them dead is wrong even
      # though nothing references them. These names are distinctive enough that a user method of
      # the same name is overwhelmingly the framework hook. (A configurable plugin API — see the
      # ReferenceCollector DSL refactor — will let projects register their own framework hooks,
      # e.g. base-class-scoped conventions like RuboCop cops' `on_*`; this built-in set covers
      # the unambiguous, widely-used ones.)
      FRAMEWORK_HOOK_METHODS = Set.new(%w[
        sidekiq_unique_context
        sidekiq_retries_exhausted
        sidekiq_retry_in
        persisted?
        to_param
        table_name_prefix
      ]).freeze

      attr_reader :definitions, :references, :type_resolver

      # reference_paths: additional paths to scan for *references only* (no definitions
      # are collected from them). Use this to include exe/, spec/, or any other directory
      # that calls into the definitions under @paths — so public API methods are not
      # falsely reported as dead just because callers live outside the definition scope.
      # dynamic_dispatch controls how variable-target send/__send__/public_send is handled:
      #   :exclude (default) — methods in a namespace containing such a call are kept
      #     alive (conservative, zero false positives).
      #   :report — those methods are NOT kept alive by the namespace fallback; they
      #     are reported as dead but the Confidence classifier marks them :low so the
      #     user can review. Use with caution (may include false positives).
      # Precisely-resolved dispatch (literal symbols, interpolation prefixes, and finite
      # symbol-list iteration) always keeps the targeted methods alive regardless of mode.
      # File extensions (without the dot) scanned for definitions/references. Defaults to Ruby
      # source; a project with e.g. .rake tasks or .ru files can widen it via --extensions.
      DEFAULT_EXTENSIONS = ["rb"].freeze

      def initialize(paths:, exclude_paths: [], reference_paths: nil, dynamic_dispatch: :exclude,
                     conventions: nil, extensions: nil, cascade: false)
        @paths = Array(paths)
        @exclude_paths = Array(exclude_paths)
        @reference_paths = reference_paths ? Array(reference_paths) : []
        @dynamic_dispatch = dynamic_dispatch
        # When true, iterate liveness to a fixpoint: drop references that originate inside an
        # already-dead method, recompute, and repeat — surfacing transitively-dead code (issue #136).
        @cascade = cascade
        @extensions = Array(extensions).map { |ext| ext.to_s.delete_prefix(".") }.reject(&:empty?)
        @extensions = DEFAULT_EXTENSIONS if @extensions.empty?
        # Base-class-scoped framework conventions consulted by the ReferenceCollector. Defaults to
        # the built-ins; a project can pass a registry extended via config (see Conventions::Registry).
        @conventions = conventions || Conventions::Registry.default
        @definitions = []
        @references = []
        @type_resolver = Resolver::TypeResolver.new
      end

      def run
        def_files = collect_files
        index_files(def_files)

        # Collect references (but not definitions) from the extra reference paths.
        unless @reference_paths.empty?
          ref_only_files = collect_reference_only_files(def_files)
          ref_only_files.each { |file| index_file_references_only(file) }
        end

        # Pre-compute which class/module full_names appear in multiple files.
        # A module reopened in 2+ files is a shared namespace — always alive.
        @multi_file_namespaces = compute_multi_file_namespaces

        dead_definitions
      end

      def dead_definitions
        dead = compute_dead(@references)
        dead = cascade(dead) if @cascade
        mark_partial_accessors(dead, @ref_index)
        dead
      end

      # The dead set implied by a given reference list. Recomputed per cascade iteration with a
      # shrinking reference set; stores @ref_index for downstream annotators (partial-accessor).
      def compute_dead(references)
        @ref_index = build_reference_index(references)
        # A namespace that lexically contains a live definition must not be reported dead —
        # removing it would remove the live member. Computed from "directly alive" members
        # (everything except this containment rule), so it's a single non-recursive pass.
        @namespaces_with_live_members = compute_namespaces_with_live_members(@ref_index)
        # An inline-constant cluster (`PARENT = [CHILD = ...]`) is one syntactic unit: if any
        # member is referenced, none can be deleted without rewriting the literal, so keep them
        # all alive. Computed once, up front.
        @alive_inline_constants = compute_alive_inline_constants(@ref_index)
        @definitions.reject { |d| alive?(d, @ref_index) }
      end

      # Iterate to a fixpoint: references that originate inside an already-dead METHOD vanish when
      # that method is removed, which can make the method's exclusive callees dead in turn. Drop
      # those references, recompute, and repeat until the dead set stops growing. Conservative:
      # only method bodies (with a known line span) attribute references; the newly-dead are flagged
      # `cascaded` (pairs well with `--verify-with-sorbet`). Dropping references can only ADD to the
      # dead set, so the loop is monotonic and terminates.
      def cascade(dead)
        base = dead
        loop do
          ranges = dead_method_ranges(dead)
          break if ranges.empty?

          live_references = @references.reject { |reference| reference_within?(reference, ranges) }
          grown = compute_dead(live_references)
          break if grown.size == dead.size

          dead = grown
        end
        (dead - base).each { |definition| definition.cascaded = true }
        dead
      end

      # { file => [line-range, ...] } for dead methods. Collected method definitions always carry a
      # line and end_line (the collector records the body span), so no nil guard is needed here.
      def dead_method_ranges(dead)
        ranges = Hash.new { |hash, key| hash[key] = [] }
        dead.each do |definition|
          next unless definition.kind == :method

          ranges[definition.file] << (definition.line..definition.end_line)
        end
        ranges
      end

      # True when a reference originates within one of the dead-method line ranges in its file.
      # Reference locations are always "file:line"; a colon-less location yields file "" (no ranges).
      def reference_within?(reference, ranges)
        file, _sep, line = reference.location.to_s.rpartition(":")
        ranges.fetch(file, []).any? { |range| range.cover?(line.to_i) }
      end

      # Mark a dead `attr_reader`/`attr_writer` whose complementary half on the same owner is
      # LIVE — i.e. an `attr_accessor` where only one direction is dead. The actionable fix is to
      # narrow the accessor (`attr_accessor` → `attr_reader`/`attr_writer`), not delete the line.
      def mark_partial_accessors(dead, ref_index)
        accessors = @definitions.select { |d| d.kind == :attr_reader || d.kind == :attr_writer }
        return if accessors.empty?

        by_key = accessors.each_with_object({}) { |d, h| h[[d.owner_name, d.kind, d.name.chomp("=")]] = d }
        dead.each do |defn|
          next unless defn.kind == :attr_reader || defn.kind == :attr_writer

          sibling = sibling_accessor(defn, by_key)
          next unless sibling && alive?(sibling, ref_index)

          defn.partial_accessor = true
          defn.ivar_hazard = true if ivar_hazard?(defn, ref_index)
        end
      end

      # Removing the writer half of an attr_accessor is a Sorbet hazard when the backing `@ivar` is
      # not assigned anywhere else in source: the surviving reader then reads an ivar that is never
      # written, which Sorbet reports as an error. Only the writer-removal direction is risky (the
      # reader-removal direction leaves the writer assigning `@ivar`, so it stays typed).
      def ivar_hazard?(defn, ref_index)
        return false unless defn.kind == :attr_writer

        base = defn.name.chomp("=")
        !ref_index[:ivar_writes].fetch(defn.owner_name) { Set.new }.include?(base)
      end

      # The complementary accessor half (reader<->writer) for the same attribute on the same owner.
      def sibling_accessor(defn, by_key)
        sibling_kind = defn.kind == :attr_reader ? :attr_writer : :attr_reader
        by_key[[defn.owner_name, sibling_kind, defn.name.chomp("=")]]
      end

      # The set of files that will be analyzed for definitions (after exclusions). Exposed so the
      # CLI's --show-files can report exactly what gets scanned without running the full analysis.
      def source_files
        collect_files
      end

      private

      # Glob suffix for the configured extensions: "*.rb" for one, "*.{rb,rake}" for several.
      def extension_glob
        @extensions.length == 1 ? "*.#{@extensions.first}" : "*.{#{@extensions.join(',')}}"
      end

      def collect_files
        @paths.flat_map { |path|
          if File.file?(path)
            [path]
          else
            Dir.glob(File.join(path, "**", extension_glob))
          end
        }.reject { |f|
          @exclude_paths.any? { |ep| f.include?(ep) }
        }.sort
      end

      # Files in @reference_paths that aren't already in the definition set.
      # Note: exclude_paths is NOT applied here — the whole purpose of reference_paths
      # is to find callers in directories (e.g. spec/, exe/) that are intentionally
      # excluded from definition scanning. We only skip files already analysed above.
      def collect_reference_only_files(def_files)
        def_set = Set.new(def_files.map { |f| File.expand_path(f) })
        @reference_paths.flat_map { |path|
          if File.file?(path)
            [path]
          else
            Dir.glob(File.join(path, "**", extension_glob))
          end
        }.reject { |f|
          def_set.include?(File.expand_path(f))
        }.sort
      end

      def index_file_references_only(file)
        source = File.read(file)
        result = Prism.parse(source)
        return unless result.success?

        node = result.value
        extract_type_info(node, file)
        ref_collector = Collector::ReferenceCollector.new(file, type_resolver: @type_resolver, conventions: @conventions)
        ref_collector.visit(node)
        @references.concat(ref_collector.references)
      end

      def index_files(files)
        files.each { |file| index_file(file) }
      end

      def index_file(file)
        source = File.read(file)
        result = Prism.parse(source)
        return unless result.success?

        node = result.value

        def_collector = Collector::DefinitionCollector.new(file)
        def_collector.visit(node)
        @definitions.concat(def_collector.definitions)

        extract_type_info(node, file)

        ref_collector = Collector::ReferenceCollector.new(file, type_resolver: @type_resolver, conventions: @conventions)
        ref_collector.visit(node)
        @references.concat(ref_collector.references)
      end

      def extract_type_info(node, file)
        SigExtractor.new(file, @type_resolver).visit(node)
      end

      def compute_multi_file_namespaces
        # Count how many distinct source files each class/module full_name appears in.
        file_counts = Hash.new { |h, k| h[k] = Set.new }
        @definitions.each do |d|
          next unless d.kind == :class || d.kind == :module

          file = d.file
          file_counts[d.full_name] << file
        end
        Set.new(file_counts.select { |_, files| files.size > 1 }.keys)
      end

      # Determine if a definition is alive based on references. A namespace is also alive
      # if it lexically contains a live member (containment rule, computed separately).
      def alive?(definition, ref_index)
        return true if directly_alive?(definition, ref_index)

        (definition.kind == :class || definition.kind == :module) &&
          (@namespaces_with_live_members || Set.new).include?(definition.full_name)
      end

      # Liveness from direct evidence only (references, dispatch, types) — excludes the
      # namespace containment rule so it can be used to compute that rule without recursion.
      def directly_alive?(definition, ref_index)
        case definition.kind
        when :class, :module
          # A module/class opened in multiple files is a shared namespace; always live.
          (@multi_file_namespaces || Set.new).include?(definition.full_name) ||
            ref_index[:constants].include?(definition.name) ||
            ref_index[:constants].include?(definition.full_name) ||
            # Referenced by a relative path (e.g. a nested `T::Enum` used as `Mid::Enum::Value`
            # from a sibling that shares the outer namespace) — see #referenced_by_relative_path?.
            referenced_by_relative_path?(definition.full_name, ref_index) ||
            # A class/module explicitly marked as dynamic_namespace (e.g. MailerPreview)
            # is alive — its class definition should not be reported dead any more than
            # its methods would be.
            ref_index[:dynamic_namespaces].include?(definition.name) ||
            ref_index[:dynamic_namespaces].include?(definition.full_name) ||
            # A subclass of a base reflected over via `.descendants` / `.subclasses` is
            # discovered and used at runtime, so its class definition isn't dead.
            ref_index[:reflected_subclasses].include?(definition.full_name)
        when :constant
          ref_index[:constants].include?(definition.name) ||
            ref_index[:constants].include?(definition.full_name) ||
            referenced_by_relative_path?(definition.full_name, ref_index) ||
            (@alive_inline_constants || Set.new).include?(definition.full_name)
        when :method, :attr_reader, :attr_writer
          # Ruby/Rails protocol methods that are never called directly.
          # initialize: .new → constant reference, not method reference.
          # respond_to_missing?: called by respond_to? / method_missing internally.
          # use_relative_model_naming?: called by ActiveModel::Naming.
          ALWAYS_ALIVE_METHODS.include?(definition.name) ||
            FRAMEWORK_HOOK_METHODS.include?(definition.name) ||
            dynamically_dispatched?(definition, ref_index) ||
            typed_alive?(definition, ref_index) ||
            name_alive?(definition, ref_index)
        else
          false
        end
      end

      # A constant/namespace referenced by a RELATIVE path (omitting a shared enclosing
      # namespace) appears in the reference set as a `::`-suffix of its full name — e.g. a
      # definition `A::B::C` referenced from inside `module A` as `B::C`. The collector emits the
      # path prefixes it observes (`B`, `B::C`), so we match any proper trailing-segment suffix of
      # the definition's full name against the referenced constants. This is the common Ruby case
      # for a nested `T::Enum` accessed via its values (`Mid::Enum::Value`); without it the enum
      # class is reported dead even though it's used everywhere (issue #156). Erring toward "alive"
      # is the safe direction and mirrors the demodulized matching used for receivers and reflected
      # subclasses. The full name itself (i == 0) is covered by the exact-match guards.
      def referenced_by_relative_path?(full_name, ref_index)
        segments = full_name.split("::")
        return false if segments.size < 2

        (1...segments.size).any? { |i| ref_index[:constants].include?(segments[i..].join("::")) }
      end

      # full_names of class/module namespaces that lexically enclose at least one
      # directly-alive definition. Such a namespace can't be dead: deleting it would delete
      # the live member. Single pass — for each directly-alive definition we mark all of its
      # enclosing namespaces. This also keeps a namespace alive when it's referenced only by a
      # relative path (e.g. `include Foo::Bar` from inside `module Outer`, where the
      # fully-qualified container `Outer::Foo` never appears literally).
      def compute_namespaces_with_live_members(ref_index)
        result = Set.new
        @definitions.each do |definition|
          next unless directly_alive?(definition, ref_index)

          enclosing_namespaces(definition).each { |ns| result << ns }
        end
        result
      end

      # full_names of the namespaces that lexically enclose a definition (excluding the
      # definition itself). For a method/attr/constant this is every prefix of its owner; for
      # a class/module it's every prefix of its parent namespace. e.g. a method on
      # `A::B::C` yields ["A", "A::B", "A::B::C"]; a module `A::B::C` yields ["A", "A::B"].
      def enclosing_namespaces(definition)
        container = case definition.kind
        when :class, :module
          definition.full_name.split("::")[0...-1].join("::")
        else
          definition.owner_name.to_s
        end
        return [] if container.empty?

        parts = container.split("::")
        (1..parts.size).map { |i| parts[0, i].join("::") }
      end

      # full_names of *parent* constants whose inline-constant cluster has at least one
      # referenced member. A cluster is a parent constant assigned a collection literal that
      # inline-assigns other constants (`PARENT = [CHILD_A = 'a', CHILD_B = 'b'].freeze`, also
      # through a `T.let(...)` wrapper). Ruby evaluates those inner assignments as a side effect,
      # so the parent decl can't be deleted while a member is referenced — keep it alive.
      #
      # Children are intentionally NOT kept alive here: a referenced child is already alive via
      # the normal name check, and an *unreferenced* inline child stays reported so the Classifier
      # can surface it as a low-actionability `inline_constant` review (it may be removable, but
      # only together with its element in the literal — never an automatic safe_delete). A cluster
      # with no referenced member at all keeps nothing, so a truly-unused block is fully reported.
      def compute_alive_inline_constants(ref_index)
        by_full = @definitions.each_with_object({}) do |d, h|
          h[d.full_name] = d if d.kind == :constant
        end

        alive = Set.new
        @definitions.each do |definition|
          next unless definition.kind == :constant && definition.co_located_names.any?

          # Nested inline constants are always collected (with the same owner as the parent),
          # so every lookup resolves; filter_map drops any (structurally-unexpected) miss
          # without an unreachable nil-guard branch.
          child_members = definition.co_located_names.filter_map do |child|
            child_full = definition.owner_name ? "#{definition.owner_name}::#{child}" : child
            by_full[child_full]
          end
          members = [definition, *child_members]

          next unless members.any? { |m| ref_index[:constants].include?(m.name) || ref_index[:constants].include?(m.full_name) }

          alive << definition.full_name # keep only the parent decl
        end
        alive
      end

      # Conservatively keep methods reachable through dynamic dispatch alive:
      # - their name starts with a collected interpolation prefix (`dump_#{x}`), or
      # - their owning namespace contains a non-literal send/__send__/public_send.
      def dynamically_dispatched?(definition, ref_index)
        # Precise prefix/suffix resolution always keeps a method alive (interpolated
        # dispatch and finite symbol-list resolution produce these).
        return true if ref_index[:method_prefixes].any? { |p| definition.name.start_with?(p) }
        return true if ref_index[:method_suffixes].any? { |s| definition.name.end_with?(s) }

        # Namespace-level fallback for unresolvable variable dispatch. In :report
        # mode we don't exclude here — the method is reported but downgraded to
        # :low confidence by the Confidence classifier instead.
        return false if @dynamic_dispatch == :report

        !!definition.owner_name && ref_index[:dynamic_namespaces].include?(definition.owner_name)
      end

      # Type-aware liveness: if ANY typed reference for this name specifies
      # this definition's owner type, it's alive. O(1) hash lookup + small
      # set scan on same-name typed refs only.
      def typed_alive?(definition, ref_index)
        return false unless definition.owner_name

        typed_refs = ref_index[:typed_by_name][definition.name]
        return false unless typed_refs

        owner = definition.owner_name
        typed_refs.any? { |receiver_type| receiver_type_matches?(receiver_type, owner) }
      end

      # Whether a typed reference's receiver type identifies this definition's owner.
      # Exact match is the precise case. An UNQUALIFIED constant receiver (`Foo.bar`, no
      # `::`) is written relative to its lexical scope, so the collector records the bare
      # name `Foo` even though the call resolves to a namespaced `A::B::Foo` (e.g. a nested
      # or sibling class calling its enclosing class). Match such a bare receiver to a
      # namespaced owner by demodulized suffix. Restricted to unqualified receivers so a
      # fully-qualified call (`A::Foo.bar`) stays precisely scoped; erring toward "alive" is
      # the safe direction for a dead-code tool and matches the demodulized-name matching
      # used elsewhere (e.g. reflected subclasses).
      def receiver_type_matches?(receiver_type, owner_name)
        receiver_type == owner_name ||
          (!receiver_type.include?("::") && owner_name.end_with?("::#{receiver_type}"))
      end

      # Name-based liveness: fallback when typed evidence is inconclusive.
      # - If ONLY typed references exist for this name (no untyped call-sites),
      #   and none matched our owner, the definition is dead.
      # - If any untyped call-site exists alongside typed ones, we can't safely
      #   conclude which owner it targets, so we keep the definition alive.
      def name_alive?(definition, ref_index)
        has_typed = ref_index[:typed_by_name].key?(definition.name)
        has_untyped = ref_index[:untyped_methods].include?(definition.name)

        if has_typed && !has_untyped
          # All call-sites are typed and none matched this owner → dead.
          false
        else
          has_untyped
        end
      end

      # Pre-index all references into hash-based lookups for O(1) access.
      def build_reference_index(references = @references)
        untyped_methods = Set.new
        constants = Set.new
        typed_by_name = {}
        method_prefixes = Set.new
        method_suffixes = Set.new
        dynamic_namespaces = Set.new
        dynamic_subclasses = Set.new
        ivar_writes = Hash.new { |hash, key| hash[key] = Set.new }

        references.each do |ref|
          case ref.kind
          when :method
            if ref.typed?
              (typed_by_name[ref.name] ||= Set.new) << ref.receiver_type
            else
              untyped_methods << ref.name
            end
          when :constant
            constants << ref.name
          when :method_prefix
            method_prefixes << ref.name
          when :method_suffix
            method_suffixes << ref.name
          when :dynamic_namespace
            dynamic_namespaces << ref.name
          when :dynamic_subclasses
            dynamic_subclasses << ref.name
          when :ivar_write
            ivar_writes[ref.receiver_type] << ref.name
          end
        end

        {
          untyped_methods: untyped_methods,
          constants: constants,
          typed_by_name: typed_by_name,
          method_prefixes: method_prefixes,
          method_suffixes: method_suffixes,
          dynamic_namespaces: dynamic_namespaces,
          # full_names of classes kept alive via .descendants/.subclasses (computed below).
          reflected_subclasses: reflected_subclasses(dynamic_subclasses),
          # owner full_name => Set of ivar base names assigned directly in source (`@foo = …`).
          ivar_writes: ivar_writes,
        }
      end

      # Transitive closure of subclasses of any base reflected over via .descendants /
      # .subclasses. Walks the (short-name) superclass → children map so that a subclass of
      # a subclass is also kept alive. Matching is by demodulized name (the analyzer doesn't
      # fully resolve constants), consistent with the other name-based liveness checks.
      def reflected_subclasses(base_names)
        return Set.new if base_names.empty?

        children = Hash.new { |h, k| h[k] = [] }
        @definitions.each do |d|
          children[d.superclass_name] << d if d.kind == :class && d.superclass_name
        end

        alive = Set.new
        queue = base_names.to_a
        until queue.empty?
          base = queue.shift
          children[base].each do |child|
            next unless alive.add?(child.full_name)

            queue << child.name # a kept subclass is itself a base for its own subclasses
          end
        end
        alive
      end
    end

    # Extracts type information from Sorbet sig blocks
    class SigExtractor < Prism::Visitor
      def initialize(file_path, type_resolver)
        super()
        @file_path = file_path
        @type_resolver = type_resolver
        @namespace_stack = []
        @pending_sig = nil
      end

      def visit_class_node(node)
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_module_node(node)
        @namespace_stack.push(node.constant_path.slice)
        super
        @namespace_stack.pop
      end

      def visit_call_node(node)
        if node.receiver.nil? && node.name.to_s == "sig"
          @pending_sig = extract_sig_info(node)
        end
        super
      end

      def visit_def_node(node)
        if @pending_sig && current_namespace
          @type_resolver.register_method(
            owner: current_namespace,
            method_name: node.name.to_s,
            return_type: @pending_sig[:returns],
            param_types: @pending_sig[:params],
          )
        end
        @pending_sig = nil
        super
      end

      private

      def current_namespace
        return nil if @namespace_stack.empty?

        @namespace_stack.join("::")
      end

      def extract_sig_info(sig_node)
        info = { params: {}, returns: nil }

        block = sig_node.block
        return info unless block.respond_to?(:body) && block.body

        visit_sig_chain(block.body, info)
        info
      end

      def visit_sig_chain(node, info)
        case node
        when Prism::StatementsNode
          node.body.each { |n| visit_sig_chain(n, info) }
        when Prism::CallNode
          case node.name.to_s
          when "returns"
            arg = node.arguments&.arguments&.first
            info[:returns] = extract_type_name(arg) if arg
          when "params"
            extract_params(node, info)
          end
          visit_sig_chain(node.receiver, info) if node.receiver
        end
      end

      def extract_type_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          node.slice
        when Prism::CallNode
          # T.nilable(Foo) etc — extract the inner type
          if node.receiver&.slice == "T"
            arg = node.arguments&.arguments&.first
            return extract_type_name(arg) if arg
          end
          node.slice
        else
          node.slice
        end
      end

      def extract_params(node, info)
        node.arguments&.arguments&.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)

            param_name = assoc.key.slice.delete_suffix(":")
            param_type = extract_type_name(assoc.value)
            info[:params][param_name] = param_type
          end
        end
      end
    end
  end
end
