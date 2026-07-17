# RFC-0008: Install and component generators

**Status:** Ready
**Depends on:** RFC-0001, RFC-0003

## Goal

```
rails g rorecs:install
rails g rorecs:component Email address:string verified:boolean
```

Getting started must take one command, and the `entity_id` + unique index
invariant must be impossible to forget.

## Rules

### `rorecs:install`

- Emits a migration enabling `pgcrypto` and creating `entities`
  (`id` UUID PK default `gen_random_uuid()`, `model` string not-null indexed,
  `created_at`).
- Creates `app/models/application_entity.rb` and
  `app/models/application_component.rb`.

### `rorecs:component NAME [attributes]`

- Emits a migration creating the component table with:
  - UUID PK,
  - `entity_id` UUID **not-null**, `unique: true` index, FK to `entities(id)`
    `on_delete: :cascade`,
  - the given attributes, **each with an explicit default**,
  - timestamps.
- Creates `app/models/<name>.rb` subclassing `ApplicationComponent`.
- Creates an **RSpec** spec file. This is deliberate and not negotiable via
  `hook_for :test_framework` — RoRECS assumes RSpec. A minitest host app gets a
  stray `spec/` directory; that is a known, accepted limitation.
- The install migration is named `RorecsCreateEntities`, not `CreateEntities`,
  to avoid colliding with a host app's own migration.

### Per-type defaults

Every attribute gets an explicit default, because a virtual component reports
defaults (RFC-0006):

| Type | Default | Why |
|---|---|---|
| `boolean` | `default: false, null: false` | A virtual `user.email.verified` must read `false`, not `nil`. The default removes any reason for the column to be nullable. |
| everything else | `default: nil` | No defensible universal default. Inventing `0` or `""` would be worse. |

**`default: nil` is a no-op and this RFC does not pretend otherwise.**
`t.string :address, default: nil` produces a column byte-identical to omitting
`default:` entirely — `column_default` is `NULL` either way. This is a
**readability convention**, not an enforceable invariant: it can be verified
from the migration text, never from the database. It exists so the choice reads
as deliberate. Do not write a test that claims to verify it from the catalog.

## Tests

Generator specs asserting the emitted migration contains the unique index, the
cascade FK, and a default for every attribute.

```ruby
it "makes the entity_id index unique" do
  run_generator %w[Email address:string]
  expect(migration).to match(/add_index .*:emails, :entity_id, unique: true/)
end

it "cascades on delete" do
  expect(migration).to match(/on_delete: :cascade/)
end

it "gives every attribute an explicit default" do
  expect(migration).to match(/t\.string :address, default: nil/)
end
```

**Assert on the migration's structure, not on the absence of a word.** A naive
`expect(migration).not_to match(/updated_at/)` fails against a migration that
*comments* on why `updated_at` is absent. Assert on `t.datetime :updated_at`.

**Text assertions are not enough.** A migration that reads correctly but raises
is a failure. Generate into a tmp dir, run the migration against a scratch
schema, and assert on the **pg catalog** — then prove the invariants actually
bite: duplicate `entity_id` → `RecordNotUnique`, null → `NotNullViolation`,
orphan → `InvalidForeignKey`, `DELETE FROM entities` → cascade.

## Non-goals

- An entity generator. `class User < ApplicationEntity` needs no migration —
  that's the point.
- Migrations for removing a component — see architecture.md open question 3.
- Non-PostgreSQL adapters.
- Minitest support. See the RSpec note above.

## Notes

Generator files must **stand on their own requires**. Rails'
`rails/generators/active_record/migration` references `ActiveRecord::Migration`
without requiring `active_record`, and `GeneratedAttribute.parse` calls
`String#remove` (an ActiveSupport core ext) that neither `rails/generators` nor
`active_record` loads. Both gaps are invisible in a booted Rails app, and both
were initially masked in this gem's suite by an unrelated `require` in
`registry.rb`. A spec that shells out to a clean Ruby process is the only honest
way to catch this.

`enable_extension "pgcrypto"` is legacy on PostgreSQL 13+, where
`gen_random_uuid()` is built in. Harmless, and it mirrors the test schema. See
the open question below.

## Status: implemented

Landed. 49 examples, including execution of both generated migrations against a
real scratch schema. Corrections made above: the per-type default policy was
never stated; the `default: nil` rule was presented as an invariant when it is a
convention; the RSpec assumption was implicit; the migration class name was
unspecified.

**New open question:** is the PostgreSQL floor 13+? If so, drop `pgcrypto`.
