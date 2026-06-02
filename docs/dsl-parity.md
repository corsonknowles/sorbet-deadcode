# Rails / framework DSL coverage (parity with spoom)

`sorbet-deadcode` recognizes framework "references by convention" — methods/constants a framework
invokes by name with no explicit Ruby call site. This is the documented, complete list of supported
patterns, mapped against [spoom](https://github.com/Shopify/spoom)'s dead-code plugins (issue #98),
so coverage is tracked rather than rediscovered one false positive at a time.

Legend: ✅ parity · ➕ exceeds spoom (more precise / broader) · 🔁 different (more precise) mechanism.

## ActiveRecord (`active_record.rb`)
| spoom | ours | status |
|---|---|---|
| ignore `ActiveRecord::Migration` subclasses + `change`/`up`/`down` | `migration` convention (whole class) | ✅ |
| `table_name_prefix`, `to_param` always alive | `FRAMEWORK_HOOK_METHODS` | ✅ |
| callbacks `after_*`/`before_*`/`around_*` (incl. `after_touch`, `after_*_commit`) → symbol method refs | `VALIDATOR_DSL_METHODS` | ✅ |
| callback `if:`/`unless:` → method ref | `collect_validator_references` | ✅ |
| CRUD mass-assignment (`new`/`create`/`update`/`assign_attributes`/`insert`/`upsert`…) → `key=` | `MASS_ASSIGNMENT_METHODS` (+ `build`/`build_stubbed`/`update_columns`…) | ➕ |
| array writes (`insert_all`/`upsert_all`) → `key=` | `ARRAY_MASS_ASSIGNMENT_METHODS` | ✅ |

## ActiveModel (`active_model.rb`)
| spoom | ours | status |
|---|---|---|
| ignore `EachValidator` subclasses + `validate_each` | `each_validator` convention | ✅ |
| `persisted?` always alive | `FRAMEWORK_HOOK_METHODS` | ✅ |
| `attribute`/`attributes` → reader/writer refs | `collect_attribute_references` | ➕ (also emits `foo=`) |
| `validate`/`validates`/`validates!`/`validates_each` + `if:`/`unless:` + option → validator constant | `VALIDATOR_DSL_METHODS` + `collect_validator_references` | ➕ |
| `validates :name` positional → method ref | positional treated as **attribute**, not method | 🔁 (more precise — avoids masking a dead `name`) |
| `validates_with Foo` | constant pass catches the constant directly | ✅ |

## ActionPack / ActionMailer (`actionpack.rb`, `action_mailer.rb`)
| spoom | ours | status |
|---|---|---|
| ignore all methods of `ApplicationController` subclasses | route scanning keeps only **routed** actions | 🔁 (more precise) |
| all `*_action` callbacks (`before`/`after`/`around`/`prepend_`/`append_`/`skip_`) → method refs | `VALIDATOR_DSL_METHODS` | ✅ |
| mailer `*_action` callbacks → method refs | same | ✅ |
| `ActionMailer::Preview` actions | `mailer_preview` detection (whole namespace) | ✅ |

## ActiveJob (`active_job.rb`)
| spoom | ours | status |
|---|---|---|
| ignore `ApplicationJob` + `perform`/`build_enumerator`/`each_iteration` | `active_job` convention (also Sidekiq) | ➕ |
| enqueue/perform callbacks → method refs | `VALIDATOR_DSL_METHODS` | ✅ |

## ActiveSupport / Minitest (`active_support.rb`, `minitest.rb`)
| spoom | ours | status |
|---|---|---|
| ignore `ActiveSupport::TestCase`/`*Test` + lifecycle hooks | `minitest` convention | ✅ |
| `test_*` methods in test files | `test_` prefix (in test class) | ✅ |
| `setup`/`teardown` symbol args → method refs | `VALIDATOR_DSL_METHODS` | ✅ |
| `assert_predicate`/`refute_predicate` → predicate ref | `collect_assert_predicate_reference` | ✅ |

## GraphQL (`graphql.rb`)
| spoom | ours | status |
|---|---|---|
| ignore Object/Enum/Scalar/Union + `resolve`/`coerce_*`/`resolve_type`/… | `graphql` convention (also Mutation/Resolver/Interface/InputObject/Subscription) | ➕ |
| `field :x` + `resolver_method:` → method ref | `collect_graphql_references` (also `builds`/`argument`/`prepare`/`method:`/`loads:`) | ➕ |

## RuboCop (`rubocop.rb`)
| spoom | ours | status |
|---|---|---|
| ignore `on_send` in Cop subclasses | `rubocop_cop` convention keeps the whole `on_*` family + investigation lifecycle | ➕ |
| ignore `MSG`/`RESTRICT_ON_SEND` constants in cops | `rubocop_cop` `keep_constants` (owner-scoped) | ✅ |

## Thor (`thor.rb`)
| spoom | ours | status |
|---|---|---|
| ignore Thor subclass methods + `exit_on_failure?` | `generator` convention (whole class; also Rails generators) | ➕ |

## Ruby core (`ruby.rb`)
| spoom | ours | status |
|---|---|---|
| always-alive hooks: `==`, `included`, `extended`, `inherited`, `prepended`, `method_added`, `method_missing`, `respond_to_missing?`, `initialize`, `to_s` | `ALWAYS_ALIVE_METHODS` (+ `inspect`, `use_relative_model_naming?`) | ➕ |
| `send`/`__send__`/`try` symbol → method ref | `DYNAMIC_DISPATCH_METHODS` (+ `public_send`, interpolation prefixes/suffixes, finite symbol iteration) | ➕ |
| `alias_method` → original method ref | `collect_alias_method_reference` | ✅ |
| `method(:foo)` → method ref | `collect_method_handle_reference` | ✅ |
| `const_get`/`const_defined?`/`const_source_location` → constant ref | `collect_constant_reflection_references` | ✅ |

## Beyond spoom (no spoom plugin equivalent)
- `delegate :a, to:`, AASM events/callbacks, `accepts_nested_attributes_for`, `rescue_from … with:`,
  RSpec predicate matchers (`be_foo`/`have_foo`), `.descendants`/`.subclasses` subclass discovery,
  `T::Enum` values, and interpolated-name dynamic dispatch.
- Type-aware **owner scoping**: a name kept alive by a convention is scoped to the matching class,
  so a same-named method on an unrelated class is still analyzed (spoom's ignores are global).

## Deliberately not ported (niche)
- bin/boot constants `APP_PATH` / `ENGINE_PATH` / `ENGINE_ROOT` / `APP_RAKEFILE` — live in
  `bin/`/`config/` files normally outside analysis scope.
- `dup`/`clone` → `initialize_copy`/`initialize_dup`/`initialize_clone` — rare; revisit if it surfaces.
- Blanket helper-file ignore (`app/helpers/**`) — we instead keep only **view-referenced** helpers
  (ERB/RABL refiners), which is more precise. See #103.
