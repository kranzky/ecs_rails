# RFC-0001: ApplicationEntity and the entities table

**Status:** Ready
**Depends on:** nothing

## Goal

An entity is an immutable identity row. Nothing more.

## Rules

- `Rorecs::Entity` subclasses `ActiveRecord::Base`, `self.abstract_class = true`,
  `self.table_name = "entities"`.
- Host apps subclass it as `ApplicationEntity`.
- The `entities` table has exactly `id` (UUID PK), `model` (string, indexed),
  `created_at`. No `updated_at` — entities never change.
- `model` is set on create from the subclass's `model_name.plural`.
- **The abstract base declares one `default_scope`** that resolves the plural per
  queried class. Do *not* add a scope per subclass via an `inherited` hook:
  `default_scopes` accumulates, so `Admin < User` would filter
  `model = 'users' AND model = 'admins'` and be permanently empty.
- `ApplicationEntity` itself (the abstract base) applies no filter — it can
  query across all entities. `build_default_scope` returns early for abstract
  classes, so this is free.
- `id` and `model` are `attr_readonly` **and** writing them after create raises.
  In Rails 8 these are **two separate requirements**: `attr_readonly` only
  installs a raising guard when `ActiveRecord.raise_on_assign_to_attr_readonly`
  is true, which defaults to `false`, and a host app's setting is applied by the
  railtie *after* this file is required. The raise must be implemented directly.
  Guard both `#write_attribute` and `#_write_attribute` — the public one does not
  call the internal one.
- The discriminator is derived from the class and never supplied by the caller.
  Stamp it unconditionally rather than relying on `default_scope`'s
  `scope_for_create` leak, so that `User.unscoped.create!` works and
  `User.create!(model: "posts")` still yields a user.

## Tests

```ruby
it "stamps the model discriminator on create" do
  expect(User.create!.model).to eq "users"
end

it "scopes queries to the subclass" do
  User.create!; Post.create!
  expect(User.all.count).to eq 1
end

it "has an immutable identity" do
  user = User.create!
  expect { user.update!(model: "posts") }
    .to raise_error(ActiveRecord::ReadonlyAttributeError)
end

it "does not accumulate scopes on a subclass of a subclass" do
  expect(Admin.all.to_sql).to include("'admins'")
  expect(Admin.all.to_sql).not_to include("'users'")
end

it "queries across all entities from the abstract base" do
  User.create!; Post.create!
  expect(ApplicationEntity.all.count).to eq 2
end

it "does not track updated_at" do
  expect(User.column_names).not_to include "updated_at"
end
```

## Non-goals

- Component declaration (RFC-0004).
- Preloading, eager loading, query optimisation.
- Renaming/backfilling `model` — see architecture.md open question 4.
- **Resolving `model` back to a subclass on read.** `ApplicationEntity.find(id)`
  returns an `ApplicationEntity`, not a `User`. See architecture.md open
  question 5 — RFC-0003 forces this.

## Status: implemented

Landed. 28 examples. Two spec defects were found and corrected above: the
`attr_readonly` conflation, and the per-subclass `default_scope` wording that
invited an accumulating-scopes bug.

## Notes

Enabling `pgcrypto` / `gen_random_uuid()` is the host app's job; the generator
(RFC-0008) emits the migration.
