# Changelog

## Unreleased

### Added
- **YAML reference scanner** (#24, part of #4) — a second-pass refiner that scans framework
  YAML configs for keys whose value is a qualified `Module::Class.method_name` reference
  (default key: `method`) and keeps both the method and its owning constant alive. Matching is
  owner-precise, so an unrelated `method: OtherLib::Geo.city` cannot mask a genuinely dead
  `City#city`. A configurable `bare_keys` option additionally supports keys whose value is a
  bare method name. File discovery uses `git ls-files` (sub-second on large repos, vs. tens
  of seconds for `Dir.glob`) and falls back to globbing outside a git checkout; line-oriented
  matching tolerates ERB-embedded YAML. The CLI applies it by default (opt out with `--no-yaml`).

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
