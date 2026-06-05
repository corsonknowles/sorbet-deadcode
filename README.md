# sorbet-deadcode

Type-aware dead code detection for Ruby, using Sorbet's type information to resolve method calls to specific classes.

## Why?

Existing tools like [Spoom](https://github.com/Shopify/spoom) use **name-based** dead code detection: if a method named `display_name` is called *anywhere*, every definition of `display_name` across all classes is marked alive. This produces false negatives (genuinely dead `Report#display_name` kept alive because `Company#display_name` is called) and requires plugins for every framework DSL.

`sorbet-deadcode` uses **type-aware** analysis: by parsing Sorbet `sig` annotations, it knows that `company.display_name` calls `Company#display_name`, not `Report#display_name`. This means:

- Fewer false negatives from name collisions
- Fewer false positives from dynamic dispatch (`send`, `public_send`)
- No need for framework-specific plugins for code with type annotations

## Installation

Requires Ruby >= 3.4.

```bash
gem install sorbet-deadcode
```

Or add to your Gemfile:

```ruby
gem "sorbet-deadcode", group: :development
```

The `spoom` gem is an **optional** dependency, required only for `--spoom`, `--verify-with-sorbet`,
and `--remove` (syntax-aware removal). Install it when you reach for those flags.

## Quick start

```bash
# Scan a directory. The project root is auto-detected from the git toplevel, so ripgrep
# verification and the non-Ruby refiners run repo-wide even from inside a subdirectory.
sorbet-deadcode packs/my_pack/

# Show only the candidates that are safe to delete automatically
sorbet-deadcode packs/my_pack/ --only safe_delete

# Detect → remove loop: preview a diff, then write it
sorbet-deadcode packs/my_pack/ --remove safe_delete          # dry-run diff
sorbet-deadcode packs/my_pack/ --remove safe_delete --apply  # write edits
```

The default run is fast (seconds to about a minute) and biased conservative — the `safe_delete`
tier is meant to be acted on directly. Reach for the heavier flags (below) when you want maximum
confidence or richer annotations; see [Performance](#performance) for the cost of each.

## Usage

```bash
# Scan a pack
sorbet-deadcode packs/my_pack/

# Add type-aware cross-reference context for extra precision in a monorepo
sorbet-deadcode packs/my_pack/ --reference-root packs/

# Scan the current directory
sorbet-deadcode .

# Scope verification/refiners to the cwd instead of the git root (or outside a repo)
sorbet-deadcode packs/my_pack/ --isolated

# Only print the auto-deletable candidates
sorbet-deadcode packs/my_pack/ --only safe_delete

# Old-style flat list (no confidence/action tiers); --no-verify implies --plain
sorbet-deadcode packs/my_pack/ --plain
```

### Default vs. preferred (accuracy/speed trade-off)

There are two recommended ways to run, depending on how much time you have:

**Default (fast — routine, CI, agents):**

```bash
sorbet-deadcode packs/my_pack/
```

The no-flag run is already the optimal *fast* pipeline: type-aware Prism analysis, **repo-wide
ripgrep verification** (project root auto-detected from the git toplevel), all non-Ruby
refiners (routes / YAML / ERB / RABL / GraphQL SDL), confidence/action tiers, and a
recently-added downgrade. It returns in seconds-to-about-a-minute and biases conservative
(favors false negatives over false positives), so the `safe_delete` list is safe to act on.
The verification pass catches cross-pack callers **by name**.

**Preferred (most accurate — a thorough audit before bulk deletion):**

```bash
sorbet-deadcode packs/my_pack/ --reference-root .
```

Adds **type-aware** cross-reference resolution: it parses the *entire* reference root so a
method called on a known receiver type in another pack (or reached only from a `.descendants`
call site elsewhere) is matched precisely, not just by name. This is the most accurate mode
but parses the whole tree, so it takes **minutes** on a large monorepo (see [Performance](#performance)).

`--reference-root` is **opt-in by design** — auto-enabling it would make the default slow,
and the name-based verification pass already covers the common cross-pack case. Reach for it
when you're about to delete in bulk and want maximum confidence. For repeated slicing, run it
once with `--index tmp/deadcode.json` and `--report` against the cached index.

### Default output: confidence/action tiers

By default, each candidate is annotated with a **suggested action** and **confidence tier**
so the output is safe to act on programmatically (auto-delete the high-confidence ones,
route the rest to review). Live candidates (action `keep`) are hidden.

```
  [safe_delete] [high] method Widget#unused_helper (refs=0)
    app/models/widget.rb:42
  [delete_with_spec] [medium] class Widget::LegacyThing (refs=1 flags=spec_only)
    app/models/widget/legacy_thing.rb:3
```

| Action | Meaning |
|--------|---------|
| `safe_delete` | No references outside the definition — safe to remove |
| `delete_with_spec` | Referenced only from specs/tests — remove along with its spec |
| `review` | Referenced from non-Ruby files, an inline-constant side effect, a public-API surface, or an ivar hazard — needs a human |
| `keep` | Real production references exist — not dead (hidden unless `--only keep`) |

Each candidate may also carry **risk flags** that explain the action:

| Flag | Meaning |
|------|---------|
| `spec_only` | Referenced only from spec/test files |
| `non_ruby_reference` | Referenced from a non-Ruby file (route/YAML/ERB/RABL/GraphQL) |
| `live_reference` | Has production references (paired with `keep`) |
| `inline_constant` | A `PARENT = [CHILD = …]` member — can only be removed by editing the literal |
| `public_api` | Lives on a public-API surface (see [`--public-paths`](#public-api-surface---public-paths)) |
| `partial_accessor` | One dead half of an `attr_accessor` whose other half is live — narrow, don't delete the line |
| `ivar_hazard` | Removing this writer would orphan the backing `@ivar` (a Sorbet error) — keep a typed declaration |
| `cascaded` | Became dead only after other dead code was (transitively) removed (`--cascade`) |
| `recently_added` | Introduced recently (see `--max-age`) — likely in-flight work |
| `kept_by:<source>` | Kept alive only by a non-Ruby source (with `--report-non-ruby`) |

Definitions introduced within the last **30 days** (per git line history) are flagged
`recently_added`, downgraded to low confidence, and routed to `review` — they're likely
in-flight work, not dead. Tune with `--max-age 2w` / `1m`, or `--max-age 0` to disable.

Use `--only ACTION` to filter (e.g. `--only safe_delete`), or `--plain` for a flat list.

### Filtering by kind (`--kind`)

By default the report shows **dead methods only** — the highest-value, lowest-risk target and the
one the type-aware engine is built for (receiver resolution). Use `--kind` to widen or change that:

```bash
sorbet-deadcode packs/my_pack/                       # methods only (default)
sorbet-deadcode packs/my_pack/ --kind all             # every kind
sorbet-deadcode packs/my_pack/ --kind constant,class  # just constants and classes
```

`--kind` accepts a comma-separated list of `method`, `constant`, `class`, `module`, `attr_reader`,
`attr_writer` (singular/plural both work), or `all`. Filtering happens before verification, so
ripgrep only runs on the selected candidates. Constants and classes carry more review overhead
(`inline_constant`, public-API surfaces, DB-serialized values) — reach for them deliberately with
`--kind`.

### Output formats (`--format`)

The classified view renders as human-readable text (default), a PR-ready markdown table, or
machine-readable JSON. The summary line goes to **stderr**, so stdout stays clean for piping.

```bash
sorbet-deadcode packs/my_pack/ --format text       # default tiered list
sorbet-deadcode packs/my_pack/ --format markdown    # grouped-by-action tables for a PR body
sorbet-deadcode packs/my_pack/ --format json | jq   # machine-readable
```

Markdown groups candidates under `### <action> (n)` headings with `kind | name | location | refs |
flags | added | dead_since` columns (the `added`/`dead_since` columns populate with `--history` /
`--dead-since`).

### Ripgrep verification (default)

`sorbet-deadcode` runs a ripgrep second pass by default to confirm each candidate
appears ≤1 time in the codebase (i.e. only at its definition). This eliminates the
bulk of name-collision false positives and is very fast (~seconds even on large repos).

Use `--no-verify` to skip it (e.g. for a quick exploratory scan or if `rg` is not installed).

```bash
# Default: Prism analysis + ripgrep verification (recommended)
sorbet-deadcode packs/my_pack/

# Skip verification for speed
sorbet-deadcode --no-verify packs/my_pack/
```

### Cross-reference context (`--reference-root`)

The most impactful flag for accuracy in a monorepo. Tells the tool to scan a broader
directory for *references only* (no definitions are collected from those files) so that
methods called from outside the analyzed path are not falsely reported as dead. This adds
**type-aware** cross-references (precise receiver matching) on top of the name-based
verification pass.

```bash
# Without: only references from within packs/my_pack/ are considered
sorbet-deadcode packs/my_pack/

# Definitions from one pack, references from all packs
sorbet-deadcode packs/my_pack/ --reference-root packs/

# Definitions from lib/, references from the whole project
sorbet-deadcode lib/ --reference-root .
```

The repo-wide ripgrep verification pass (on by default, scoped to the auto-detected git root)
already catches the *name-based* cross-pack case, so `--reference-root` is a precision add-on
rather than a correctness requirement. It parses the whole reference tree, so it's slow on a
large monorepo — see [Performance](#performance).

### Sorbet verification (`--verify-with-sorbet`)

The strongest precision guarantee: trial-remove the candidates, run `srb tc`, and drop any whose
removal **breaks the typecheck** (i.e. it was still referenced somewhere static analysis couldn't
see). It snapshots and restores the edited files, so your tree is left untouched.

```bash
sorbet-deadcode packs/my_pack/ --verify-with-sorbet
```

Requires a **clean** baseline `srb tc` (otherwise pre-existing errors can't be attributed, and the
flag is skipped with a warning) and the optional `spoom` gem (for syntax-aware removal). It runs a
full typecheck, so it costs whatever `srb tc` costs on your project — see [Performance](#performance).

### Transitive dead code (`--cascade`)

After finding the first round of dead code, `--cascade` drops references that originate *inside*
those dead methods and recomputes — to a fixpoint. This surfaces transitively-dead code: e.g. a
private helper that was only ever called by a method that just turned out to be dead. Newly-dead
definitions are flagged `cascaded`.

```bash
sorbet-deadcode packs/my_pack/ --cascade --verify-with-sorbet
```

**`--cascade` implies `--reference-root`** (defaulting to the project root). Dropping references that
originate in dead methods is only sound with a **cross-pack reference graph**: without one, an entry
point that's consumed from *another* pack looks unused, so its entire helper tree cascades to a
false positive. To stay correct, `--cascade` therefore parses the whole reference tree by default
(which makes it slower — see [Performance](#performance)). Pass an explicit `--reference-root DIR` to
narrow it; passing both flags is fine. Best paired with `--verify-with-sorbet`, since cascaded
removals are larger and worth confirming.

### Git history annotations (`--history`, `--dead-since`)

Automates the per-method "why is this dead?" archaeology you'd otherwise do by hand for a removal PR.

```bash
# Annotate each candidate with the commit that introduced it
sorbet-deadcode packs/my_pack/ --history
#   [safe_delete] [high] method Widget#unused_helper (refs=0)
#     app/models/widget.rb:42
#     added: a1b2c3d 2023-04-01 Add unused_helper

# Also annotate WHEN it became dead (implies --history)
sorbet-deadcode packs/my_pack/ --dead-since
#     added: a1b2c3d 2023-04-01 Add unused_helper
#     dead_since: dead since e4f5g6h 2024-08-09 Remove last caller
```

`--history` is **cheap**: one rename-aware `git log` pass per *file*, batched. `dead_since`
distinguishes **dead-on-arrival** (the name's repo-wide reference count never changed after it was
introduced) from **orphaned** (it names the most recent commit that changed the count ≈ when the
last caller was removed).

> ⚠️ `--dead-since` is **expensive**: it runs a **repo-wide** `git log -S` pickaxe once per unique
> candidate name. On a large/deep-history monorepo each pickaxe can take seconds-to-minutes, so it
> prints a loud upfront warning and live per-name progress. Scope it to a small candidate set (one
> pack/file). See [Performance](#performance).

### Public API surface (`--public-paths`)

Zero-reference definitions on a public-API surface (default: paths containing `app/public/`) are
flagged `public_api` and routed to `review` instead of `safe_delete` — external packs or runtime
consumers can call them where ripgrep can't see.

```bash
# Treat additional path fragments as public API
sorbet-deadcode packs/my_pack/ --public-paths app/public/,lib/api/

# Disable the public-API caution entirely
sorbet-deadcode packs/my_pack/ --public-paths none
```

### Index & report (analyze once, slice many times)

A full-repo analysis can take minutes. Run it **once**, save the result to a JSON
index, then `--report` against that index instantly — optionally filtering to specific
paths or annotating with `--classify` / `--confidence` without re-analyzing:

```bash
# Analyze the whole repo once and save a reusable index
sorbet-deadcode . --reference-root . --index tmp/deadcode.json

# Report instantly from the cached index (already verified)
sorbet-deadcode --report tmp/deadcode.json

# Slice the cached index to one pack
sorbet-deadcode --report tmp/deadcode.json packs/my_pack/

# Classify the cached index (confidence, ref counts, suggested actions)
sorbet-deadcode --report tmp/deadcode.json --classify

# Cross-compare the cached index against another tool's index (e.g. Spoom)
sorbet-deadcode --report tmp/deadcode.json --intersect tmp/spoom.json
```

`--report` skips analysis and verification (the index is already verified) but still
flows through classification and confidence scoring, so the index → classify workflow
works end to end.

### Intersecting with Spoom (`--spoom`)

[Spoom](https://github.com/Shopify/spoom) and `sorbet-deadcode` are complementary: Spoom is
name-based and broad (it blanket-keeps whole framework categories alive — fewer false positives,
more false *negatives*), while `sorbet-deadcode` is type-aware and precise. Their **intersection**
— definitions both tools call dead — is the highest-confidence set.

```bash
# Intersect with Spoom directly, in one pass — no intermediate file
sorbet-deadcode app/ --spoom
```

`--spoom` runs Spoom's dead-code engine (via its Ruby API) on the same paths and keeps only the
candidates that appear in both, keyed on `[full_name, kind]` (Spoom reports the same `kind`
vocabulary). Spoom is an **optional dependency** — only required when you pass `--spoom`
(`gem install spoom` or add it to your Gemfile).

### Removing dead code (`--remove`)

Once you trust a tier, `--remove` deletes it for you, closing the detect → remove loop:

```bash
# Dry run: print a unified diff of what would be removed (nothing is written)
sorbet-deadcode app/ --remove safe_delete

# Write the edits
sorbet-deadcode app/ --remove safe_delete --apply

# Only remove what BOTH sorbet-deadcode and Spoom call dead (maximum safety)
sorbet-deadcode app/ --remove safe_delete --spoom --apply
```

`TIER` is a classifier action: `safe_delete`, `delete_with_spec`, `review`, or `all` (every
actionable tier). Removal **leverages Spoom's** syntax-aware remover, so deleting a method/class
also removes its attached comments and Sorbet `sig`s. Beyond Spoom's one-location-at-a-time
`spoom deadcode remove`, we remove a whole tier in one pass, default to a dry-run diff, and skip
(reporting, never aborting) any location Spoom can't remove. Methods, classes, modules, and
constants are supported today; `attr_reader`/`attr_writer` and inline-constant members are skipped
and reported. Like `--spoom`, this needs the optional `spoom` gem.

### Framework conventions & custom config (`--config`)

Frameworks invoke methods *by name* with no explicit Ruby call site (`perform` on a job, `on_send`
in a RuboCop cop, `resolve` on a GraphQL type). `sorbet-deadcode` keeps these alive with
**base-class-scoped conventions** — scoped to the framework classes that use them, so a same-named
method on an unrelated class is still analyzed (unlike a global name allow-list). Built-ins cover
Prism visitors, graphql-ruby types, ActiveJob/Sidekiq jobs, RuboCop cops (`on_*`), Minitest,
`EachValidator`, migrations, Rails/Thor generators, and ActiveAdmin registrations.

To cover in-house base classes, register your own conventions in a `.sorbet-deadcode.yml` at the
project root (auto-loaded), or point at one with `--config FILE`:

```yaml
conventions:
  - name: event_consumer
    superclass: EventConsumer     # Regexp string matched against the superclass
    keep_methods: [consume]       # kept alive, scoped to matching classes
  - name: karafka_consumer
    includes: [Karafka::Consumer] # match classes that `include` this module
    keep_namespace: true          # keep the whole class (reflection-driven)
```

A class matches if its `superclass` matches, it `includes` one of the listed modules, or its name
ends with `name_suffix` (optionally gated by `path_includes`). Keep directives: `keep_methods`
(owner-scoped names), `keep_prefixes` (e.g. `on_`), `keep_constants` (e.g. a cop's `MSG`), or
`keep_namespace` (the whole class).

For receiver-less DSL methods (callbacks/validations and your own in-house DSLs), register a
**send-handler** so a call's symbol arguments are kept alive:

```yaml
send_handlers:
  - name: event_tracking
    methods: [track_event, log_event]   # `track_event :handle_order` keeps `handle_order` alive
    positional: methods                 # symbol args are method names (default); `attributes` = column names
    conditional_options: true           # if:/unless: values are guard-method references
```

The complete list of built-in framework/DSL conventions and send-handlers — and how it maps to
spoom's plugins — is documented in [`docs/dsl-parity.md`](docs/dsl-parity.md).

### Introspection & sorting

```bash
sorbet-deadcode app/ --sort location   # order the report by file:line (or --sort name)
sorbet-deadcode app/ --extensions rb,rake   # scan additional file extensions (default: rb)

sorbet-deadcode app/ --show-files     # files that would be analyzed
sorbet-deadcode app/ --show-plugins   # active framework conventions (built-in + configured)
sorbet-deadcode app/ --show-defs      # every definition collected
sorbet-deadcode app/ --show-refs      # every reference collected
```

The `--show-*` flags print what was indexed and exit, mirroring `spoom deadcode`'s introspection.

### Reporting dynamic dispatch (`--report-dynamic-dispatch`)

By default, a method is conservatively kept alive when its namespace contains a
fully-variable `send`/`__send__`/`public_send` (e.g. `__send__(method_name)`) whose
target can't be resolved — zero false positives, but it can hide genuinely dead methods.
`--report-dynamic-dispatch` opts out of that namespace fallback: such methods are
*reported* instead of suppressed, surfacing as **low-confidence** candidates. Pair it
with `--classify` or `--confidence` to review them:

```bash
# Surface namespace-dispatched methods for review, with reference counts and actions
sorbet-deadcode packs/my_pack/ --reference-root packs/ --report-dynamic-dispatch --classify
```

Precisely-resolved dispatch (literal symbols, interpolation prefixes/suffixes, and
finite symbol-list iteration) always keeps the targeted methods alive regardless of this
flag. It applies to the default Prism path only (not `--lsp`/`--hybrid`/`--file-table`).

### Reporting non-Ruby references (`--report-non-ruby`)

By default the route / YAML / ERB / RABL / GraphQL SDL refiners **hard-exclude** any
candidate they match (it's referenced from a non-Ruby source, so it isn't dead).
`--report-non-ruby` instead **reports** those candidates as low-confidence `review`
items, tagged with the source that kept them alive — useful for auditing the broad,
name-only matches:

```bash
sorbet-deadcode packs/my_pack/ --report-non-ruby --only review
#   [review] [low] method Widget#display_name (refs=0 flags=kept_by:graphql_sdl)
```

### False-positive handling

`sorbet-deadcode` detects and suppresses several classes of dynamic dispatch and framework
convention that would otherwise produce false positives:

| Pattern | Example | Handling |
|---------|---------|----------|
| Interpolated dispatch | `public_send("dump_#{type}")` | Keeps all `dump_*` methods alive |
| Variable dispatch | `__send__(method_name)` | Keeps all methods in the namespace alive |
| Subclass discovery | `Base.descendants` / `T.unsafe(Base).subclasses` | Keeps every (transitive) subclass of `Base` alive |
| Inline constant nesting | `PARENT = [CHILD = 1]` | Never reports `PARENT` dead while `CHILD` is alive |
| Rails callbacks | `validate :check_name`, `before_save :normalize` | Keeps callback targets alive |
| Validation conditionals | `validates :x, exclusion: { in: [...], unless: :skip? }` | Keeps `if:`/`unless:` guards alive, including nested hash options |
| AASM transitions | `transitions from: :a, to: :b, after: :cb, guard: :ok?` | Keeps callback/guard targets alive |
| `accepts_nested_attributes_for` | `accepts_nested_attributes_for :items` | Keeps `items_attributes=` overrides alive |
| `delegate ..., to:` | `delegate :to_s, to: :writer` | Keeps the delegation target (`writer`) alive |
| `Prism::Visitor` subclasses | `class MyVisitor < Prism::Visitor` | Keeps all `visit_*` methods alive |
| Mailer previews | `class FooMailerPreview` | Keeps the class and all preview actions alive |
| ActiveAdmin registrations | `ActiveAdmin.register Widget do … end` | Keeps the page's DSL methods alive |
| Routed controller actions | `get '/x', to: 'widgets#index'` | Keeps routed actions alive (`--no-routes` to disable) |
| Framework YAML | `method: Foo::BarSanitizer.sanitize_x` | Keeps the YAML-referenced method + class alive (`--no-yaml` to disable) |
| ERB templates | `<%= widget.display_name %>` | Keeps template-referenced methods/constants alive (`--no-erb` to disable) |
| RABL templates | `attributes :display_name` / `node(:s) { \|w\| w.status }` | Keeps template-referenced methods/constants alive (`--no-rabl` to disable) |
| GraphQL SDL (`.graphql`) | `type User { fullName: String }` | Keeps the resolver method (`full_name`) alive (`--no-graphql` to disable) |
| Always-alive methods | `initialize`, `respond_to_missing?`, etc. | Never reported dead |

## Workflow patterns

Recommended recipes, from cheapest/most-routine to most-thorough:

**1. Routine sweep (CI, agents, a quick pack audit).** The fast default; act on `safe_delete`.

```bash
sorbet-deadcode packs/my_pack/ --only safe_delete
```

**2. Detect → remove loop.** Preview, then write.

```bash
sorbet-deadcode packs/my_pack/ --remove safe_delete           # dry-run diff
sorbet-deadcode packs/my_pack/ --remove safe_delete --apply   # write it
```

**3. Confident bulk audit before deleting a lot.** Add type-aware cross-refs and a Sorbet oracle.

```bash
sorbet-deadcode packs/my_pack/ --reference-root . --verify-with-sorbet
```

**4. Highest-confidence set.** Keep only what both tools agree is dead.

```bash
sorbet-deadcode packs/my_pack/ --spoom --only safe_delete
```

**5. Transitive cleanup.** Remove a dead method *and* the helpers only it called.

```bash
sorbet-deadcode packs/my_pack/ --cascade --verify-with-sorbet
```

**6. Writing the removal PR.** A paste-ready table plus git archaeology. Run `--dead-since` only on
the final, small candidate set (it's the expensive flag):

```bash
sorbet-deadcode packs/my_pack/ --only safe_delete --history --format markdown
sorbet-deadcode packs/my_pack/ --only safe_delete --dead-since --format markdown
```

**7. Big repo, repeated slicing.** Analyze once, report instantly many times.

```bash
sorbet-deadcode . --reference-root . --index tmp/deadcode.json   # minutes, once
sorbet-deadcode --report tmp/deadcode.json packs/my_pack/ --classify   # instant
```

### Tips

- **Start narrow, then verify.** Get a small candidate list with the fast default, *then* apply
  expensive confirmation (`--verify-with-sorbet`, `--dead-since`) to just those survivors.
- **Run from anywhere.** The project root auto-detects from the git toplevel, so verification is
  repo-wide even when you scan a subdirectory. Use `--isolated` to deliberately limit scope.
- **Register in-house DSLs once.** A `.sorbet-deadcode.yml` at the repo root is auto-loaded; use it
  to teach the tool your base classes and DSLs instead of re-triaging the same false positives.
- **Pipe JSON for tooling.** `--format json` keeps stdout clean (the summary goes to stderr).

## Performance

The default run is fast — Prism analysis + repo-wide ripgrep + the non-Ruby refiners return in
**seconds to about a minute**. The optional flags trade time for precision or annotation. Rough
cost ladder, cheapest to most expensive:

| Flag | Extra cost | When to use |
|------|-----------|-------------|
| `--no-verify` | **Negative** (skips ripgrep) | Quick exploratory scan; `rg` not installed |
| *(default)* | Seconds–~1 min | Routine sweeps, CI, agents |
| `--history` | One `git log` pass per **file** (batched, cheap) | Annotating a removal PR |
| `--reference-root .` | Parses the **whole tree** for refs — **minutes** on a monorepo | Bulk-delete audits needing type-aware cross-refs |
| `--spoom` | Runs Spoom's full engine on the same paths | Highest-confidence intersection |
| `--verify-with-sorbet` | One full `srb tc` (+ trial edits) | Final confirmation before deleting |
| `--cascade` | Implies `--reference-root` (whole-tree parse, **minutes**) + a few fixpoint passes | Transitive dead-code cleanup |
| `--dead-since` | ⚠️ A **repo-wide** `git log -S` pickaxe **per unique candidate name** | Last — only on a small, final candidate set |

### The expensive one: `--dead-since`

`--dead-since` is in a class of its own. Unlike `--history` (file-scoped, batched per file), it runs
a **repo-wide** `git log -S <name>` pickaxe **once per unique candidate name**. On a large,
deep-history monorepo a single pickaxe can take **minutes**, so the total scales with the number of
candidates. The tool therefore:

- makes it **strictly opt-in**,
- prints a **loud warning the moment the flag is seen** (before analysis) and again before the
  pickaxe loop, and
- prints **live per-name progress** (`dead-since pickaxe 3/40: foo`) so a long run is visibly
  progressing rather than appearing hung.

**Always scope `--dead-since` to a small candidate set** — e.g. filter to `--only safe_delete` for a
single pack first, then re-run with `--dead-since` on just those.

### Other heavy flags

- **`--reference-root .`** parses the entire reference tree (not just your `--paths`), so it's the
  main source of slowness for accuracy work. For repeated runs, build an `--index` once and
  `--report` against it — reporting skips analysis/verification entirely.
- **`--verify-with-sorbet`** costs one full `srb tc`. It needs a clean baseline; if `srb tc` is slow
  on your project, so is this flag. It snapshots/restores files, so it's safe to interrupt.
- **`--spoom`** runs Spoom's own analysis on the same paths in addition to ours.
- **`--cascade`** recomputes the dead set to a fixpoint — a handful of extra analysis passes over
  the already-collected definitions — but it **implies `--reference-root`** (defaulting to the
  project root) for correctness, so it inherits that whole-tree parse cost. Pass an explicit
  `--reference-root DIR` to narrow the scope.

## How It Works

1. **Parse** all Ruby files with [Prism](https://github.com/ruby/prism)
2. **Collect definitions** — classes, modules, methods, constants, accessors
3. **Collect references** — method calls, constant lookups, dynamic dispatch (`send`/`public_send`/`try`)
4. **Extract type info** — parse Sorbet `sig` blocks to determine return types
5. **Resolve types** — when a reference has a known receiver type, match it to the specific class
6. **Report dead code** — definitions with no matching references

### Type-Aware vs Name-Based

```ruby
class Company
  sig { returns(String) }
  def display_name = name.upcase
end

class Report
  sig { returns(String) }
  def display_name = "Report: #{title}"
end

class Service
  sig { params(company: Company).returns(String) }
  def show(company)
    company.display_name  # Type-aware: only Company#display_name is alive
  end
end
```

| Tool | Company#display_name | Report#display_name |
|------|---------------------|-------------------|
| Name-based (Spoom) | Alive | Alive (false negative) |
| Type-aware (this gem) | Alive | **Dead** |

### Graceful Degradation

When type information is unavailable (no `sig`, untyped code), `sorbet-deadcode` falls back to name-based matching — the same behavior as Spoom. This means it works on any Ruby codebase, with increasing precision as more code is typed.

## Development

```bash
bundle install
bundle exec rake test
```

The suite enforces **100% line and branch coverage** (SimpleCov) and RuboCop cleanliness.

## License

MIT
