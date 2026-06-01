# Changelog

## Unreleased

### Fixed
- **`T::Enum` values are no longer reported dead** (#70) — enum values declared as
  `Active = new('active')` inside a `T::Enum` subclass's `enums do` block are reached via
  `.values` / `.deserialize(<string>)` / serialization, not by their Ruby constant, so they
  were false positives. The collector no longer records them as definitions. Plain constants
  inside an enum class, and `= new(...)` assignments outside a `T::Enum`, are unaffected.
  Handles both `< T::Enum` and `< ::T::Enum`.

### Changed
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
