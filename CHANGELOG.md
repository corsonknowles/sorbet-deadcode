# Changelog

## Unreleased

### Added
- **Recently-added code is flagged and routed to review** (#19, completes #62) — definitions
  introduced within a configurable git window (default **30 days**) are the riskiest to
  delete (possible in-flight work), so the Classifier now flags them `:recently_added`,
  downgrades them to low confidence, and routes them to `review` — keeping them out of the
  `safe_delete` actionable list. Recently-added files are found with a single batched
  `git log --since --diff-filter=A` query up front (file-level; fast even on deep-history
  monorepos), degrading gracefully outside a checkout. Configure with `--max-age`
  (`30d` / `2w` / `1m`); `--max-age 0` disables.

### Added
- **Strong-params `permit` keys are detected as writer references** (#81) — attribute
  writers set via `params.permit(...)` + mass-assignment (`assign_attributes`/`update`) were
  reported dead, because the attribute names appear only as `permit` symbol keys, never as a
  literal `foo=` or `Model.new(foo:)`. The collector now emits a `foo=` writer reference for
  every `permit` symbol key — positional (`permit(:foo)`) and hash-style at any nesting depth
  (`permit(apps: [{ category_slugs: [] }])` keeps `apps=` and `category_slugs=` alive), since
  Rails permits collections as `key: [{ nested_key: [] }]`. Bare symbols inside a value array
  (`baz: [:x]`) name nested scalar params, not setters, so they're left alone. Conservative:
  matching the bare `permit` name can only keep a setter alive.

### Fixed
- **Inline constants in a collection literal are treated as one cluster** (#88) — a constant
  assigned a collection that inline-assigns other constants (`PARENT = [CHILD = 'a'].freeze`,
  including through a `T.let([...], T::Array[...])` wrapper) is a single syntactic unit: Ruby
  evaluates the inner assignments as a side effect, so deleting any member rewrites the literal.
  The collector now also descends into call *arguments* (previously only the `.freeze` receiver),
  so `T.let`-wrapped collections record their children; and the analyzer keeps the whole cluster
  alive when any member is referenced — protecting both directions (a referenced child keeps the
  parent collection; a referenced parent keeps its inline children, e.g. SKU id constants inside
  a referenced `BLOCKED_IDS` array). A cluster with no referenced member is still reported (as a
  reviewable `inline_constant`), so a truly-unused block can be removed whole.
- **More AASM event callback keys are recognized** (#89) — `collect_aasm_references` handled
  `after`/`before`/`guard`/`after_commit`/`after_rollback`/`on_transition`/`error`, but a method
  dispatched only through `before_transaction`, `after_transaction`, `success`, `unless`, or
  `ensure` (e.g. `event :go, before_transaction: :set_remove_date`) was reported dead. These keys
  take a symbol or array of symbols like the others, so they now emit method references too.
- **A namespace that contains a live member is no longer reported dead** (#84) — a
  compact-defined namespace (`module Outer::Support`) is recorded under its fully-qualified
  name, so a relative reference to its child (`include Support::Cache` from inside `Outer`)
  never matches the namespace's own name, and it was reported `safe_delete` even though
  deleting it would delete the live child. The analyzer now keeps any class/module alive
  when it lexically encloses a directly-alive definition (computed in one non-recursive pass
  from the directly-alive set, mirroring the existing inline-constant containment rule).
  Genuinely-empty or fully-dead namespaces are still reported.
- **Transactional `after_*_commit` callbacks are now recognized** (#86) — `VALIDATOR_DSL_METHODS`
  handled `after_commit`/`after_rollback` but not the common `after_create_commit`,
  `after_update_commit`, `after_destroy_commit`, `after_save_commit`, or `before_commit`
  variants, so a method dispatched only through one of those (e.g.
  `after_create_commit :emit_created_event`) was reported dead. They take symbol method names
  exactly like the callbacks already handled, so they now emit method references too.
- **Classifier no longer mislabels referenced namespaced classes/constants as `safe_delete`** —
  `rg --with-filename -o` emits `path:matched`, and the matched token for a compactly-defined
  class/module is the fully-qualified constant (`A::B::C`), which itself contains `::`. The
  classifier split that line on the *last* colon, shearing the token (`A::B::C` → `C`) and
  re-keying references under the wrong short name, so every cross-file reference to a namespaced
  constant was lost and the (live) definition was reported `refs=0` → `safe_delete`. It now
  splits on the first colon (file paths don't contain `:`; the trailing token does). This is a
  correctness/safety fix: the default classified output could previously recommend deleting live
  cross-pack classes. The verifier (`--no-filename`) was unaffected.
- **YAML class-registry configs are now recognized** (#76) — `YamlScanner` only matched
  `key: Module::Class.method` values, so classes listed in registry configs (loaded via
  `constantize`) were reported dead, e.g. `- Demo::Scenarios::WithWidget` array items or
  `handler: My::Event::Handler` scalars. The scanner now emits a constant reference for a
  namespaced constant used as a YAML value or sequence item (a `::` is required so ordinary
  capitalized scalars like `state: California` aren't mistaken for class references).
- **`Index#intersect` is now owner-precise** (#33) — it keyed candidates on `[name, kind]`,
  so two unrelated `#foo` methods on different classes counted as the same definition,
  inflating the cross-tool agreement set. It now keys on `[full_name, kind]`.
- **`Definition` exposes `file` and `line` as fields** (#39) — the `"file:line"` location was
  parsed via `location.split(":").first` in the analyzer, classifier, refiners, and LSP
  finders, which is brittle on Windows drive-letter paths (`C:/x.rb:12`) and any path
  containing a colon. The location is now split once in the constructor using `rpartition`
  (last colon), and consumers read `definition.file` / `definition.line`. `location` is
  retained as the display string.

### Added
- **`--report-non-ruby` flag** (#61) — opt into reporting candidates that the route / YAML /
  ERB / RABL / GraphQL SDL refiners would otherwise hard-exclude. Instead of removing them,
  each refiner tags the candidate (`Definition#kept_by`) and the Classifier surfaces it as a
  low-confidence `review` candidate flagged with its source (e.g. `flags=kept_by:graphql_sdl`).
  Mirrors `--report-dynamic-dispatch` (#31); default behavior (hard-exclude) is unchanged.

### Fixed
- **Classes discovered via `.descendants` / `.subclasses` are no longer reported dead** (#69) —
  frameworks often enumerate subclasses with `Base.descendants` (or `T.unsafe(Base).descendants`)
  and invoke them by reflection, so no subclass is ever named in Ruby. The collector now emits a
  `:dynamic_subclasses` reference for such calls (unwrapping `T.unsafe`/`T.must`/`T.let`/`T.cast`),
  and the analyzer keeps every subclass of a reflected base alive — transitively, by demodulized
  superclass name. Requires the `.descendants` call site to be in the analyzed scope (or
  `--reference-root`).
- **`T::Enum` values are no longer reported dead** (#70) — enum values declared as
  `Active = new('active')` inside a `T::Enum` subclass's `enums do` block are reached via
  `.values` / `.deserialize(<string>)` / serialization, not by their Ruby constant, so they
  were false positives. The collector no longer records them as definitions. Plain constants
  inside an enum class, and `= new(...)` assignments outside a `T::Enum`, are unaffected.
  Handles both `< T::Enum` and `< ::T::Enum`.
- **RouteScanner now recognizes `controller:`/`action:` and hash-rocket route forms** (#67) —
  previously only `to: 'controller#action'` was parsed, so routes written as
  `get '/x', controller: 'admin/widgets', action: 'show'`, `get :show, controller: :widgets`,
  or `get '/x' => 'widgets#index'` (common in `draw`-ed split route files) were ignored and
  their controllers/actions reported dead. All three forms now emit the action + controller
  references.

### Changed
- **GraphQL SDL refiner is now directory-scoped** (#60) — each `.graphql` document's field
  names only keep resolver methods alive when those methods are defined at or below the
  document's directory (its subgraph root). Previously the field names from every schema
  were pooled into one repo-wide name set, so a generic field (`id`, `name`, `status`,
  `nodes`) in one subgraph could mask a same-named method in an unrelated directory. Legit
  per-subgraph suppression is unchanged.
- **Default output is now the classified, confidence/action-tiered view** (#62) — a no-flag
  run annotates each candidate with a suggested action (`safe_delete` / `delete_with_spec` /
  `review`) and confidence tier (`high` / `medium` / `low`), hiding live (`keep`) candidates.
  This makes the default safe to act on programmatically (auto-delete `safe_delete`/`high`,
  route the rest to review) and surfaces spec-only candidates that the previous verify-only
  default silently dropped. Classification runs over the pre-verify candidates (its own
  ripgrep pass supersedes the standalone verify). Use `--plain` for the old flat list;
  `--no-verify` (no ripgrep) implies `--plain`. `--only ACTION` no longer needs `--classify`.
- **Project root now defaults to the git toplevel** (#62) — previously `--project-root`
  defaulted to the current directory, so running from inside a pack/subdirectory scoped
  ripgrep verification and the non-Ruby refiners to that subtree and reported
  cross-pack-referenced methods as dead. The root is now auto-detected from the enclosing
  git repository, so a no-flag run verifies references repo-wide regardless of where it's
  invoked. Pass `--isolated` (or an explicit `--project-root`) to opt out; outside a git
  checkout it falls back to the current directory.

### Added
- **GraphQL SDL (`.graphql`) scanner/refiner** (#27, completes epic #4) — standalone
  `*.graphql` / `*.graphqls` schema documents (e.g. checked-in federation/subgraph
  schemas) name fields and arguments that map to Ruby resolver methods with no Ruby call
  site. A new `GraphqlScanner`/`GraphqlRefiner` parses those documents, maps camelCase
  field/argument names to snake_case (emitting both spellings, name-only), and keeps the
  backing resolver methods alive. Descriptions, inline strings, comments, directive names,
  and enum values are ignored. Runs by default across all analysis modes; disable with
  `--no-graphql`. (The graphql-ruby DSL written *in Ruby* — `field`/`argument`/`builds`/
  `prepare:`/`loads:` — was already handled by the ReferenceCollector.)

### Changed
- **Shared `Ripgrep` search helper** (#38) — the exclude-glob construction and the
  predicate-name (`?`/`!`/`=`) word-boundary vs. literal splitting were duplicated in
  `RipgrepVerifier` and `Classifier` and had to stay in sync for the predicate-name fix
  to hold. Both now go through a single `Ripgrep.search` (plus `glob_pattern` /
  `partition_by_predicate`), removing the drift risk. No behavior change.
- **Refiners now apply to every analysis mode** (#30) — the route / YAML / ERB / RABL
  refiners previously ran only on the default Prism path, so routed controllers and
  template-/config-referenced methods resurfaced as false positives under `--lsp`,
  `--hybrid`, and `--file-table`. Refiner application is now centralized after mode
  dispatch and runs for all modes (respecting `--no-routes`/`--no-yaml`/`--no-erb`/`--no-rabl`).
  `--reference-root` remains default-mode-only and now emits a warning instead of being
  silently ignored when combined with `--lsp`/`--hybrid`/`--file-table`.

### Fixed
- **graphql-ruby `loads:` loader methods** (#53) — an `argument :foo_id, loads: SomeType`
  causes graphql-ruby to invoke a `load_foo` method (the argument name with a trailing
  `_id` stripped, prefixed with `load_`). The collector now emits that reference so loader
  methods aren't reported dead. Also hardened the GraphQL option-key parsing to use
  `Prism::SymbolNode#unescaped` with a `SymbolNode` guard instead of
  `slice.delete_suffix(":")` (robust against quoted/interpolated keys).

### Fixed
- **Dynamic-namespace refs now use the fully-qualified name** — `mailer_preview` (and the new
  generator) detection emitted the dynamic-namespace reference using the class's *short* name
  (`node.constant_path.slice`), which never matched the fully-qualified `owner_name` recorded
  for nested method definitions. As a result, preview/generator methods inside a `module`
  were still reported dead. The reference now uses `current_namespace`, fixing mailer-preview
  false positives for nested classes.

### Added
- **`--report-dynamic-dispatch` CLI flag** (#31) — exposes the analyzer's
  `dynamic_dispatch: :report` mode (previously API-only). Instead of conservatively
  keeping every method in a namespace alive when it contains a fully-variable
  `send`/`__send__`/`public_send`, the flag reports those methods as low-confidence
  candidates. Applies to the default Prism path only; pair with `--classify` /
  `--confidence` to review the surfaced candidates.
- **Rails generator / Thor command detection** — classes inheriting from `Rails::Generators::Base`
  or `Rails::Generators::NamedBase` (and `Thor` / `Thor::Group`) invoke every public instance
  method as an ordered step/command via reflection. Their methods are now kept alive (the whole
  namespace is marked dynamically dispatched), matching the existing mailer-preview/visitor handling.

### Fixed
- **Setter false positives from non-`foo=` assignment forms** (#48) — a writer (`attr_writer`,
  the writer half of `attr_accessor`, or any `def foo=`) was reported dead when it was only
  ever invoked through a form whose source text doesn't contain the literal `foo=`:
  - operator-assignment to a receiver — `obj.foo ||= x`, `obj.foo &&= x`, `obj.foo += 1`
    (distinct Prism nodes from a plain `obj.foo = x` call); now emits read + `foo=` references.
  - keyword mass-assignment — `Model.new(foo: x)`, `record.update(foo: x)`, FactoryBot
    `build(:m, foo: x)`, `assign_attributes(foo: x)`, etc.; now emits a `foo=` reference per
    symbol key for those constructor/update entry points.
- **Suffix-interpolation dynamic dispatch** (#49) — methods reached via `public_send("#{x}_start_time")`
  (a dynamic prefix with a literal suffix) were reported dead because the assembled name never
  appears literally. The collector now emits a `:method_suffix` reference (mirroring `:method_prefix`),
  and any definition whose name ends with a dispatched suffix is kept alive. Combined
  prefix+suffix interpolation (`"a_#{x}_b"`) emits both. Local-variable-held interpolations
  (`m = "#{x}_at"; send(m)`) are tracked per-method without leaking across method bodies.

### Added
- **RABL template reference scanner** (#26, part of #4) — a second-pass refiner for `.rabl`
  view templates. Each `.rabl` is Ruby, so it is parsed once and walked twice: the existing
  Prism `ReferenceCollector` captures real method calls/constants (e.g. inside `node`/`child`
  blocks), and a small DSL visitor harvests the symbol arguments of `attributes`/`attribute`
  (model attributes) and `child`/`glue` (association sources) that aren't expressed as calls.
  `node(:key)` output keys and `object`/`collection` ivars are not treated as methods. Method
  matching is name-only (serialized receivers are untyped). Uses the shared `git ls-files`
  finder (sub-second across hundreds of templates). CLI applies it by default (opt out with
  `--no-rabl`).
- **YAML reference scanner** (#24, part of #4) — a second-pass refiner that scans framework
  YAML configs for keys whose value is a qualified `Module::Class.method_name` reference
  (default key: `method`) and keeps both the method and its owning constant alive. Matching is
  owner-precise, so an unrelated `method: OtherLib::Geo.city` cannot mask a genuinely dead
  `City#city`. A configurable `bare_keys` option additionally supports keys whose value is a
  bare method name. File discovery uses `git ls-files` (sub-second on large repos, vs. tens
  of seconds for `Dir.glob`) and falls back to globbing outside a git checkout; line-oriented
  matching tolerates ERB-embedded YAML. The CLI applies it by default (opt out with `--no-yaml`).
- **ERB template reference scanner** (#25, part of #4) — a second-pass refiner that extracts
  the Ruby out of `<% %>` / `<%= %>` tags (skipping `<%# %>` comments and `<%% %>` literals),
  joins it preserving block structure, and runs it through the existing Prism `ReferenceCollector`.
  Methods and constants used only from templates are kept alive. No new dependency (no Erubi):
  the snippet-join approach reuses the type-aware collector and sidesteps raw ERB/Prism parse
  warnings. Template receivers are untyped, so method matching is name-only. File discovery uses
  the shared `git ls-files`-based finder (sub-second across thousands of templates). CLI applies
  it by default (opt out with `--no-erb`).

### Removed
- **Dropped Ruby 3.3 support early** — minimum required Ruby is now 3.4. The reason is
  narrow and deliberate: the `--report`/`--index` path uses `Time#iso8601`, which needs
  `require "time"`. On Ruby 3.4+ `time` is already loaded in our runtime, but on 3.3 it is
  not, so a minimal `exe/` invocation raised `NoMethodError: undefined method 'iso8601'`.
  Rather than carry a defensive `require "time"` for one version, we dropped 3.3 from the
  supported set and the CI matrix (now 3.4 and 4.0). **Users who still need Ruby 3.3 can
  add `require "time"` themselves** (e.g. in their app boot) and the tool will work.

### Fixed
- **Mailer-preview detection too broad** (#32) — any class whose name merely ended in
  `Preview` (e.g. a `DataPreview` service) had all its methods marked alive, hiding genuinely
  dead code. Detection is now conservative: a class qualifies only if it inherits from a
  `*Preview` base, is named `*MailerPreview`, or is named `*Preview` and lives in a
  `mailer_previews` path (Rails convention).
- **ReferenceCollector method-local state leak** (#28) — interpolation-prefix and
  write-based type tracking were file-scoped, so `m = "dump_#{x}"` in one method
  leaked a `dump_` prefix into another method reusing the name `m`. These maps are
  now snapshot/restored around each method body, matching local-variable scoping.

### Changed
- **`--report` now combines with `--classify` / `--confidence`** (#37) — the load-index
  branch previously returned before the classify/confidence rendering, so a cached index
  could only be printed plainly. The report path now flows through the shared pipeline
  (skipping analysis, verification, and re-indexing), completing the index → classify
  workflow.
- **Dropped the `sorbet-runtime` runtime dependency** (#34) — the tool parses Sorbet
  `sig` annotations as source text via Prism and never calls the sorbet-runtime API, so
  the dependency was dead weight on installs. `prism` is now the only runtime dependency.
- **Graceful degradation when ripgrep is missing** (#29) — now that `--verify` is the
  default, a missing `rg` no longer crashes: the verifier returns candidates unverified
  and the classifier marks them `:review` / `:ripgrep_unavailable`, each with a clear
  message. Centralized in a new `SorbetDeadcode::Ripgrep.available?` helper.

### Added
- **`Classifier` post-processing step + `--classify` / `--only`** (closes #18) — annotates
  each candidate with a confidence tier, reference count, risk flags, and a suggested action,
  folding the manual verification ritual into one pass:
  - flags: `:live_reference`, `:spec_only`, `:non_ruby_reference`, `:inline_constant`
  - actions: `:keep` (real production caller), `:delete_with_spec` (spec-only refs),
    `:review` (non-Ruby ref / inline constant), `:safe_delete` (no references at all)
  - `--classify` prints the annotation per candidate; `--only ACTION` filters to one action.
- **Dynamic dispatch refinements** (closes #10) — narrows the conservative
  "exclude the whole namespace" behavior for variable-target `send`/`__send__`/`public_send`:
  - Interpolation prefix via local variable: `m = "dump_#{x}"; send(m)` emits a `dump_`
    method-prefix reference instead of excluding the namespace.
  - Finite symbol-list iteration: `[:a, :b].each { |m| send(m) }` and `METHODS.each { |m| send(m) }`
    (where `METHODS = [:a, :b].freeze`) resolve to the exact method names.
  - `dynamic_dispatch: :report` mode (opt-in): report otherwise-excluded namespace methods
    as `:low` confidence for review instead of keeping them alive. Default stays `:exclude`.
  - Validated that an LSP cross-check cannot replace the conservative exclusion: Sorbet's
    `textDocument/references` is static and cannot resolve `__send__(variable)` / interpolated
    dispatch, so deferring to it would reintroduce the `MemberSerializer#dump_*` false positive.
- **RSpec predicate matcher references** (closes #21) — `be_foo` / `be_a_foo` /
  `be_an_foo` now reference `foo?`, and `have_foo` references `has_foo?` / `have_foo?`.
  Predicate methods exercised only through a matcher (where the literal name never
  appears) are no longer reported dead. Discovered when `Cowork::InboundEvent::Type#task_run_execution?`
  was wrongly flagged dead because its only use was `be_task_run_execution` in a spec.

### Changed
- **`--verify` is now the default** — ripgrep verification runs automatically after every
  analysis pass. Use `--no-verify` to opt out. This eliminates the bulk of name-collision
  false positives with negligible overhead (~seconds on large repos).

### Added
- **Framework DSL plugins** (closes #3) — `delegate`, AASM events, and GraphQL mutations
  now emit method references so their callback targets and generated methods stay alive:
  - `delegate :foo, :bar, to: :target` keeps `foo` and `bar` alive
  - `delegate ... prefix: :scope` keeps `scope_foo` alive; `prefix: true` keeps `*_foo` variants alive
  - AASM `event :activate, after: [:notify], guard: :can_activate?` keeps all symbol callbacks alive
  - `error_on_all_events :handle_aasm_error` keeps the handler alive
  - GraphQL `builds :order` keeps `build_order` alive
  - GraphQL `argument :x, prepare: :load_x` and `field :x, method: :display` keep targets alive
- **Confidence tiers** (closes #5) — `SorbetDeadcode::Analyzer::Confidence.for(definition, ref_index)`
  returns `:high`, `:medium`, or `:low`; `--confidence` flag annotates CLI output with the tier
- **`Index` class + `--index` / `--report` / `--intersect` subcommands** (closes #9, #8):
  - `--index output.json` saves the full dead-code index for later querying
  - `--report index.json [paths...]` loads an index and filters to paths without re-analyzing
  - `--intersect other.json` narrows results to candidates appearing in both indexes (enables
    Spoom cross-comparison workflow)
  - `Index#filter_paths`, `Index#for_paths`, `Index#intersect` available as a Ruby API
- **Performance regression guard** (closes #6) — two benchmark specs ensure the liveness
  analysis stays O(N) on a 1000-definition synthetic codebase (< 5s threshold)

## Previously released (main)

### Added
- **Interpolated dynamic dispatch detector** — `public_send("dump_#{type}")` keeps all `dump_*` methods alive; `__send__(method_name)` (variable target) keeps every method in the enclosing namespace alive
- **Inline constant nesting detector** — `PARENT = [CHILD_A = 1, CHILD_B = 2]` never reports `PARENT` dead while a child constant is still referenced
- **`--reference-root DIR`** — scan a broader directory for references without collecting definitions from it; prevents public API methods from appearing dead when callers live outside the analyzed paths
- **Rails callback DSL** — `validate :method`, `before_save :hook`, `after_commit :flush`, and 16 other lifecycle hooks now emit method references so callback targets stay alive
- **`accepts_nested_attributes_for`** — emits a method-prefix reference so `_attributes=` overrides are kept alive
- **Mailer preview detection** — classes inheriting from `ActionMailer::Preview` or named `*MailerPreview` are marked dynamically dispatched (invoked by the Rails preview router)
- **`Prism::Visitor` protocol** — classes inheriting from a `*Visitor` base emit a `visit_` prefix reference, keeping all `visit_*` methods alive
- **`ALWAYS_ALIVE_METHODS`** — `initialize`, `respond_to_missing?`, `method_missing`, `use_relative_model_naming?`, `to_s`, `inspect` are never reported dead
- **Multi-file namespace deduplication** — a module opened in 2+ files is treated as a shared namespace and never reported dead
- **Constant-path prefix tracking** — `A::B::C` now emits references for `A`, `A::B`, and `A::B::C`, keeping ancestor modules alive
- **SimpleCov** — 100% line and branch coverage enforced on every commit
- **`name_alive?` mixed-evidence fix** — when both typed and untyped references exist for a name, untyped references are no longer suppressed

### Fixed
- **Ripgrep verifier `?`/`!` bug** — method names ending in `?` or `!` were treated as regex quantifiers, causing every boolean predicate to appear dead regardless of actual usage. Fixed by adding `-F` (fixed-strings) to the `rg` command
- **`close_streams` extracted from `shutdown`** for testability; removed structurally-dead `return nil unless content_length` guard in `read_message`
- **`visit_def_node` param cleanup** — param types were erroneously cleared for the wrong method name after a nested def

### Internal
- `ALWAYS_ALIVE_METHODS` constant replaces scattered individual checks
- `compute_multi_file_namespaces` pre-indexes at run time rather than per-check
- `dynamically_dispatched?` unified for both method-prefix and namespace-level exclusions
