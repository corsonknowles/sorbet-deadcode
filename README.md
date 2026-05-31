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
# Analyze current directory
sorbet-deadcode .

# Exclude specs (find production-only dead code)
sorbet-deadcode --no-specs .

# Exclude specific paths
sorbet-deadcode -x vendor/ -x tmp/ .

# Analyze specific directories
sorbet-deadcode app/ lib/
```

### Verified Mode (Prism + ripgrep)

By default, `sorbet-deadcode` uses Prism-based static analysis only. Add `--verify`
to run a follow-up ripgrep pass that checks whether each candidate's name actually
appears elsewhere in the codebase. This eliminates false positives much faster than
individual searches.

```bash
# Fast mode (Prism only)
sorbet-deadcode .

# Verified mode (Prism + ripgrep confirmation)
sorbet-deadcode --verify .

# Verified mode with project root and exclusions
sorbet-deadcode --verify --project-root /path/to/project -x vendor/ app/ lib/
```

The `--verify` flag works with all analysis modes (`--lsp`, `--hybrid`, `--file-table`).
It requires `rg` (ripgrep) to be installed on your system.

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
