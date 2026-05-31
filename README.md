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
# Recommended: scan a pack with full cross-reference context and ripgrep verification
sorbet-deadcode packs/my_pack/ --reference-root packs/ --project-root .

# Scan the current directory (quick single-scope check)
sorbet-deadcode .

# Exclude specs from definitions (non-production dead code only)
sorbet-deadcode --no-specs packs/my_pack/

# Skip the ripgrep verification pass (faster, more false positives)
sorbet-deadcode --no-verify packs/my_pack/
```

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

# With: references from all 75K pack files are considered
sorbet-deadcode packs/my_pack/ --reference-root packs/ --project-root .
```

The `--project-root` enables automatic `config/routes.rb` scanning to keep
controller actions alive (see [Route Scanning](#route-scanning) below).

### Reference Root (scanning callers outside your definition path)

When analyzing a subdirectory (e.g. `lib/`), callers in other directories (e.g. `exe/`,
`spec/`, or other packs) are invisible to the analyzer, causing public API methods to
appear dead. Use `--reference-root` to scan a broader tree for *references only* — no
definitions are collected from those files.

```bash
# Definitions from lib/, references from the whole project
sorbet-deadcode lib/ --reference-root .

# In a monorepo: definitions from one pack, references from all packs
sorbet-deadcode packs/my_pack/ --reference-root packs/ --project-root .
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
```

`--report` skips analysis and verification (the index is already verified) but still
flows through classification and confidence scoring, so the index → classify workflow
works end to end.

### False-Positive Handling

`sorbet-deadcode` detects and suppresses several classes of dynamic dispatch that
would otherwise produce false positives:

| Pattern | Example | Handling |
|---------|---------|----------|
| Interpolated dispatch | `public_send("dump_#{type}")` | Keeps all `dump_*` methods alive |
| Variable dispatch | `__send__(method_name)` | Keeps all methods in the namespace alive |
| Inline constant nesting | `PARENT = [CHILD = 1]` | Never reports `PARENT` dead while `CHILD` is alive |
| Rails callbacks | `validate :check_name`, `before_save :normalize` | Keeps callback targets alive |
| `accepts_nested_attributes_for` | `accepts_nested_attributes_for :items` | Keeps `items_attributes=` overrides alive |
| `Prism::Visitor` subclasses | `class MyVisitor < Prism::Visitor` | Keeps all `visit_*` methods alive |
| Mailer previews | `class FooMailerPreview` | Keeps the class and all preview actions alive |
| Routed controller actions | `get '/x', to: 'widgets#index'` | Keeps routed actions alive (`--no-routes` to disable) |
| Framework YAML | `method: Foo::BarSanitizer.sanitize_x` | Keeps the YAML-referenced method + class alive (`--no-yaml` to disable) |
| ERB templates | `<%= widget.display_name %>` | Keeps template-referenced methods/constants alive (`--no-erb` to disable) |
| RABL templates | `attributes :display_name` / `node(:s) { \|w\| w.status }` | Keeps template-referenced methods/constants alive (`--no-rabl` to disable) |
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
