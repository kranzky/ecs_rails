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
- Creates a spec file.
- Every attribute must have a default, because a virtual component reports
  defaults (RFC-0006). A column with no default gets `default: nil` written
  explicitly, so the choice is visible in the migration rather than implied.

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

## Non-goals

- An entity generator. `class User < ApplicationEntity` needs no migration —
  that's the point.
- Migrations for removing a component — see architecture.md open question 3.
- Non-PostgreSQL adapters.
