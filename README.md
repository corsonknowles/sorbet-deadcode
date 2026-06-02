# sorbet-deadcode

Type-aware dead code detection for Ruby, using Sorbet's type information to resolve method calls to specific classes.

## Why?

Existing tools like [Spoom](https://github.com/Shopify/spoom) use **name-based** dead code detection: if a method named `display_name` is called *anywhere*, every definition of `display_name` across all classes is marked alive. This produces false negatives (genuinely dead `Report#display_name` kept alive because `Company#display_name` is called) and requires plugins for every framework DSL.

`sorbet-deadcode` uses **type-aware** analysis: by parsing Sorbet `sig` annotations, it knows that `company.display_name` calls `Company#display_name`, not `Report#display_name`. This means:

- Fewer false negatives from name collisions
- Fewer false positives from dynamic dispatch (`send`, `public_send`)
- No need for framework-specific plugins for code with type annotations

## Installation

```bash
gem install sorbet-deadcode
```

Or add to your Gemfile:

```ruby
gem "sorbet-deadcode", group: :development
```

## Usage

```bash
# Scan a pack. The project root is auto-detected from the git toplevel, so ripgrep
# verification and the non-Ruby refiners run repo-wide even from inside a subdirectory.
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
but parses the whole tree, so it takes **minutes** on a large monorepo.

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
| `review` | Referenced from non-Ruby files or an inline-constant side effect — needs a human |
| `keep` | Real production references exist — not dead (hidden unless `--only keep`) |

Definitions introduced within the last **30 days** (per git line history) are flagged
`recently_added`, downgraded to low confidence, and routed to `review` — they're likely
in-flight work, not dead. Tune with `--max-age 2w` / `1m`, or `--max-age 0` to disable.

Use `--only ACTION` to filter (e.g. `--only safe_delete`), or `--plain` for a flat list.

### Ripgrep Verification (Default)

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

### Cross-Reference Context (`--reference-root`)

The most impactful flag for accuracy in a monorepo. Tells the tool to scan a broader
directory for *references only* so that methods called from outside the analyzed pack
are not falsely reported as dead.

```bash
# Without: only references from within packs/my_pack/ are considered
sorbet-deadcode packs/my_pack/

# With: references from all pack files are considered
sorbet-deadcode packs/my_pack/ --reference-root packs/
```

`--reference-root` adds *type-aware* cross-references (precise receiver matching). The
repo-wide ripgrep verification pass (on by default, scoped to the auto-detected git root)
already catches the *name-based* case, so `--reference-root` is a precision add-on rather
than a correctness requirement.

### Reference Root (scanning callers outside your definition path)

When analyzing a subdirectory (e.g. `lib/`), callers in other directories (e.g. `exe/`,
`spec/`, or other packs) are invisible to the analyzer, causing public API methods to
appear dead. Use `--reference-root` to scan a broader tree for *references only* — no
definitions are collected from those files.

```bash
# Definitions from lib/, references from the whole project
sorbet-deadcode lib/ --reference-root .

# In a monorepo: definitions from one pack, references from all packs
sorbet-deadcode packs/my_pack/ --reference-root packs/
```

### Index & Report (analyze once, slice many times)

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

# Or intersect with Spoom directly, in one pass — no intermediate file
sorbet-deadcode app/ --spoom
```

### Intersecting with Spoom (`--spoom`)

[Spoom](https://github.com/Shopify/spoom) and `sorbet-deadcode` are complementary: Spoom is
name-based and broad (it blanket-keeps whole framework categories alive — fewer false positives,
more false *negatives*), while `sorbet-deadcode` is type-aware and precise. Their **intersection**
— definitions both tools call dead — is the highest-confidence set.

`--spoom` runs Spoom's dead-code engine (via its Ruby API) on the same paths and keeps only the
candidates that appear in both, keyed on `[full_name, kind]` (Spoom reports the same `kind`
vocabulary). Spoom is an **optional dependency** — only required when you pass `--spoom`
(`gem install spoom` or add it to your Gemfile).

`--report` skips analysis and verification (the index is already verified) but still
flows through classification and confidence scoring, so the index → classify workflow
works end to end.

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
`EachValidator`, migrations, and Rails/Thor generators.

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

The complete list of built-in framework/DSL conventions — and how it maps to spoom's plugins — is
documented in [`docs/dsl-parity.md`](docs/dsl-parity.md).

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

### False-Positive Handling

`sorbet-deadcode` detects and suppresses several classes of dynamic dispatch that
would otherwise produce false positives:

| Pattern | Example | Handling |
|---------|---------|----------|
| Interpolated dispatch | `public_send("dump_#{type}")` | Keeps all `dump_*` methods alive |
| Variable dispatch | `__send__(method_name)` | Keeps all methods in the namespace alive |
| Subclass discovery | `Base.descendants` / `T.unsafe(Base).subclasses` | Keeps every (transitive) subclass of `Base` alive |
| Inline constant nesting | `PARENT = [CHILD = 1]` | Never reports `PARENT` dead while `CHILD` is alive |
| Rails callbacks | `validate :check_name`, `before_save :normalize` | Keeps callback targets alive |
| `accepts_nested_attributes_for` | `accepts_nested_attributes_for :items` | Keeps `items_attributes=` overrides alive |
| `Prism::Visitor` subclasses | `class MyVisitor < Prism::Visitor` | Keeps all `visit_*` methods alive |
| Mailer previews | `class FooMailerPreview` | Keeps the class and all preview actions alive |
| Routed controller actions | `get '/x', to: 'widgets#index'` | Keeps routed actions alive (`--no-routes` to disable) |
| Framework YAML | `method: Foo::BarSanitizer.sanitize_x` | Keeps the YAML-referenced method + class alive (`--no-yaml` to disable) |
| ERB templates | `<%= widget.display_name %>` | Keeps template-referenced methods/constants alive (`--no-erb` to disable) |
| RABL templates | `attributes :display_name` / `node(:s) { \|w\| w.status }` | Keeps template-referenced methods/constants alive (`--no-rabl` to disable) |
| GraphQL SDL (`.graphql`) | `type User { fullName: String }` | Keeps the resolver method (`full_name`) alive (`--no-graphql` to disable) |
| Always-alive methods | `initialize`, `respond_to_missing?`, etc. | Never reported dead |

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

## License

MIT
