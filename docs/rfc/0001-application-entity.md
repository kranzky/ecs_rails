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
- `model` is set on create from the subclass's `model_name.plural`, and is
  `attr_readonly`.
- A default scope on each subclass filters `where(model: <plural>)`.
- `ApplicationEntity` itself (the abstract base) applies no filter — it can
  query across all entities.
- Attempting to write `id` or `model` after create raises.

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

it "does not track updated_at" do
  expect(User.column_names).not_to include "updated_at"
end
```

## Non-goals

- Component declaration (RFC-0004).
- Preloading, eager loading, query optimisation.
- Renaming/backfilling `model` — see architecture.md open question 4.

## Notes

Enabling `pgcrypto` / `gen_random_uuid()` is the host app's job; the generator
(RFC-0008) emits the migration.
