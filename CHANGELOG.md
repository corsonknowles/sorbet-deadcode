# Changelog

## Unreleased

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
