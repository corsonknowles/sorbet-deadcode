# Technical Investment Plan — sorbet-deadcode

Derived from a real-world campaign running `sorbet-deadcode` (and Spoom) against a
46K-file Rails monolith: ~120 candidates investigated, ~40 confirmed dead and removed,
and a large catalog of false positives discovered the hard way (via CI failures on
deletion PRs). This plan turns those lessons into prioritized engineering work.

## Guiding insight

There are two failure modes for dead-code detection:

- **Name-based tools (Spoom)** are *over-permissive*: a method named `process` is kept
  alive if the string `process` is referenced anywhere. Few false positives, many
  false negatives. Misses class-specific dead code hidden behind common names.
- **Type-aware (this tool)** can be *over-aggressive*: without framework awareness it
  flagged ~107K candidates vs Spoom's ~8.8K. Precise dispatch resolution is powerful
  but useless if drowned in framework-invoked methods.

**The high-signal product is the intersection of independent approaches + cheap
verification passes.** The roadmap below is organized around making each layer
(static, type-aware, framework-aware, verification) pull its weight.

---

## Theme 1 — Eliminate the false-positive classes we hit (highest priority)

Every item below caused a real broken PR. Ranked by frequency/severity observed.

### 1.1 Dynamic dispatch with interpolated method names  ⚠️ severity: critical
`__send__("dump_#{member.class.name.demodulize.underscore}", member)` invoked three
serializer methods that no tool can see — the symbol is built from a class name at
runtime. Removing them broke serialization app-wide (372-failure cascade).
- **Investment:** heuristic detector — when a file contains `send`/`__send__`/
  `public_send` with a *non-literal* (interpolated/variable) argument, mark all
  methods matching a prefix/pattern in the same class/module as "ambiguously
  dispatched" and exclude them (or flag as low-confidence). Pair with a
  `dump_*`-style prefix-family detector.
- **Effort:** M. **Impact:** prevents the worst, hardest-to-debug breakages.

### 1.2 Inline constant assignment in array/hash literals  ⚠️ severity: critical
`PARENT = [CHILD_A = 'a', CHILD_B = 'b'].freeze` defines `CHILD_A`/`CHILD_B` as side
effects. Deleting `PARENT` silently removes the children → boot-time `NameError`.
- **Investment:** in the definition collector, detect assignment nodes nested inside
  array/hash literals and record the child constants as *co-located* with the parent;
  never report a parent whose deletion would remove referenced children.
- **Effort:** S. **Impact:** prevents boot-breaking constant removals.

### 1.3 Framework DSL symbol references (extend the plugin surface)
Confirmed-live methods referenced only through DSLs:
- **AASM**: `error_on_all_events :m`, `guard: :m`, `after: [:m]`, `before: :m`
- **Rails `delegate :m, to: :target`**
- **`validates ..., inclusion: { in: :m }`** (nested option hashes; also numericality
  `less_than:`/`greater_than:`/`equal_to:`/etc., `format: { with: :m }`)
- **GraphQL**: `field`/`argument`/`builds`/`prepare:`/`method:`/`implements`
- **Sidekiq batch callbacks**: `batch.on(:death, Klass, ...)` → `Klass#on_death`
- **DSL option-hash dispatch**: `has_pdf_attachment validates_attachment: { unencrypted: true }`
  → `validates_attachment_unencrypted`
- **`inherited_resources` overrides**: `resource_request_name`, etc.
- **Investment:** a plugin API mirroring Spoom's (we already upstreamed `public_send`,
  nested `validates`, and GraphQL `argument/builds/prepare` to Spoom — ports #930/#931/#932).
  Build the same hook model here so the type-aware core can be taught DSLs.
- **Effort:** L (ongoing). **Impact:** the bulk of false positives.

### 1.4 Non-Ruby reference sources
Methods/constants referenced from files we don't parse:
- **ArDoc `*.yml`** sanitizer method names
- **`.rabl`** view templates (constants + methods)
- **`.erb`** templates (SmartText interpolation, view helpers)
- **`config/routes*`** → controller actions (Panda/ActiveAdmin/Rails resourceful routes)
- **GraphQL `.graphql` schema** / frontend queries
- **Investment:** pluggable "reference scanners" for non-Ruby files (YAML/ERB/RABL/route
  DSL/graphql). Even a coarse string-grep scanner over these file types, feeding the
  reference index, removes a whole class of false positives.
- **Effort:** M. **Impact:** high (routes + RABL + ArDoc each broke PRs).

### 1.5 Contract-defining definitions
Some "dead" symbols define an API/fixture contract: removing them is a *breaking
change*, not dead-code cleanup (e.g. a method-name list driving `public_send` that is
also serialized into an API response; a constant whose value is asserted by a fixture).
- **Investment:** flag definitions that are members of a collection iterated by
  `public_send`/`index_with`/serialization, and definitions referenced by fixture/spec
  golden files, as "contract — review before removing."
- **Effort:** M. **Impact:** medium; prevents silent API breakage.

---

## Theme 2 — Scope & correctness of analysis

### 2.1 Whole-repo indexing by default (avoid cross-pack false positives)
Pack-scoped runs reported ~3,293 candidates vs ~516 real, because callers in other
packs were invisible. **Always index the full reference graph; filter only the
*reporting* set by path/team.**
- **Effort:** S (already mostly there). **Impact:** high.

### 2.2 Spec-aware liveness modes
A method referenced only by its own unit spec is "dead in production." Provide explicit
modes: `--include-specs` (default off), and a "test-only" classification (alive in
specs, dead in prod) rather than binary dead/alive. When removing a method whose only
references are specs, the spec must be cleaned up too — surface that.
- **Effort:** S. **Impact:** medium.

### 2.3 Self-reference & recursion handling
Don't count a definition's own body / recursive calls as keeping it alive. Audit the
reference collector for this (we saw "only in Spoom" discrepancies suggesting
inconsistent self-reference handling).
- **Effort:** S. **Impact:** medium (precision).

---

## Theme 3 — Performance & scale

### 3.1 Keep all liveness O(N) (done — protect it)
The initial `dead_definitions` was O(N·M) (scan all references per definition) and
hung for hours on the full repo. Fixed by pre-indexing references into hash buckets
(`untyped_methods`, `constants`, `typed_by_name`); full repo now ~80s. **Add a perf
regression guard / benchmark so this never regresses.**
- **Effort:** S. **Impact:** existential for large repos.

### 3.2 LSP mode: batch, don't serialize
Per-definition `textDocument/references` is ~20+ hours for 11.5K defs. Built `--parallel`
and `--hybrid` (Prism-first, LSP-validate candidates only). Next: prefer
`--print=symbol-table-json` / file-table dumps over per-call LSP round-trips; cache via
`tmp/cache/sorbet`. Also: per-definition error resilience (an invalid LSP position must
skip, not abort the whole run — already fixed).
- **Effort:** M. **Impact:** makes the precise mode usable at scale.

### 3.3 Bulk ripgrep verification pass (`--verify`)
A single `rg -f patterns.txt -w` pass over the repo verified 318 constants in ~17s vs
2.5–5 hrs of per-symbol searches. Keep this as the fast, cheap false-positive filter
layered after the static pass. Watch the gotchas we hit: write the pattern file outside
the repo (else rg matches itself) and use `**` globs for recursive excludes.
- **Effort:** done; harden. **Impact:** high ROI.

---

## Theme 4 — Workflow & trust

### 4.1 Confidence tiers instead of binary dead/alive
Emit `high` (no refs anywhere, simple method), `medium` (type-resolved dead but common
name), `low` (matches a known dynamic-dispatch/DSL/contract heuristic → needs human
review). Most damage came from treating low-confidence as high.

### 4.2 Cross-tool intersection report as a first-class output
The intersection of Spoom (name-based) and sorbet-deadcode (type-aware) was the
highest-signal artifact (the items both agreed on were almost all truly dead). Ship a
built-in "agreement" report.

### 4.3 Per-team / per-pack reporting + ownership integration
Group candidates by `package.yml` owner / CODEOWNERS so teams get only their slice
(the original `script/deadcode_by_team.rb` use case). Generalize into the tool.

### 4.4 "Removal safety" preflight
Before suggesting removal, run the cheap checks automatically: full-repo rg, non-Ruby
scan, and the heuristic detectors from Theme 1. Output a removal-readiness verdict.

---

## Suggested sequencing

1. **Now (prevents breakage):** 1.1 interpolated dispatch, 1.2 inline constants, 3.1
   perf guard, 4.1 confidence tiers.
2. **Next (kills most FPs):** 1.3 DSL plugin API, 1.4 non-Ruby scanners, 3.3 harden `--verify`.
3. **Then (scale + trust):** 2.x scope/spec modes, 3.2 LSP batching, 4.2 intersection report.
4. **Ongoing:** grow the plugin/heuristic catalog; upstream generally-useful fixes to Spoom.

## Appendix — false-positive catalog (field-tested)

| # | Pattern | Example | Detectable statically? |
|---|---------|---------|------------------------|
| 1 | Interpolated dynamic dispatch | `__send__("dump_#{type}")` | No — build a heuristic |
| 2 | Inline constant in literal | `P = [A = 1, B = 2]` | Yes — collector change |
| 3 | AASM callbacks/guards | `guard: :m`, `after: [:m]` | Plugin |
| 4 | Rails `delegate` | `delegate :m, to: :x` | Plugin |
| 5 | Nested `validates` options | `inclusion: { in: :m }` | Plugin (upstreamed to Spoom #931) |
| 6 | `public_send(:literal)` | `obj.public_send(:m)` | Plugin (upstreamed #930) |
| 7 | GraphQL DSL | `builds :x`, `prepare: :m` | Plugin (upstreamed #932) |
| 8 | Routes → controller actions | `resources :x` | Non-Ruby scanner |
| 9 | ArDoc YAML method refs | `sanitize_method: m` | Non-Ruby scanner |
| 10 | RABL / ERB references | `proxy.public_send(field)` in .erb | Non-Ruby scanner |
| 11 | Sidekiq batch callbacks | `batch.on(:death, K)` | Plugin |
| 12 | DSL option-hash dispatch | `validates_attachment: { unencrypted: true }` | Plugin |
| 13 | `inherited_resources` overrides | `resource_request_name` | Plugin/ignore-list |
| 14 | Contract/method-name lists | `DATE_CONSTANT_METHODS` + `public_send` + API | Heuristic + review tier |
| 15 | Cross-pack callers | caller in another pack | Whole-repo indexing |
| 16 | Spec-only references | only used in `*_spec.rb` | Spec-aware mode |
