# RoRECS Architecture

This document defines the **invariants** of RoRECS. It is the specification that
every RFC and every implementation task refers back to. If an implementation
conflicts with this document, the implementation is wrong — or this document
must be changed first, via an ADR.

Terminology follows Flecs (Entity, Component, System), but the persistence model
is ordinary ActiveRecord.

---

## 1. Invariants

### An Entity

- Has exactly one row in the `entities` table.
- Has a UUID primary key.
- Has immutable identity: `id` and `model` never change after creation.
- Has no mutable domain fields. `entities` holds `id`, `model`, `created_at` only.
- Is described by a `model` discriminator string (e.g. `"users"`), which names
  the entity subclass that created it. See [ADR-0002](adr/0002-single-entities-table.md).
  It resolves back to that subclass on read, so `ApplicationEntity.find(id)`
  returns a `User`. See [ADR-0008](adr/0008-subclass-resolution-on-read.md).
- Carries no state of its own. All state lives in components.

### A Component

- Owns exactly one database table.
- Belongs to exactly one entity, via a non-null `entity_id` UUID FK.
- Appears **at most once** per entity, enforced by a unique index on
  `entity_id`. See [ADR-0005](adr/0005-one-component-per-entity.md).
- May have **no database row**. A component with no row is *virtual*.
- Has a default value for every attribute. A virtual component reports those
  defaults.
- May contain behaviour. Its methods execute with `self` bound to the
  component, never the entity. See [ADR-0001](adr/0001-component-method-binding.md).
- Is an ordinary `ActiveRecord::Base` subclass. Scopes, validations,
  callbacks, and associations all work as normal.
- Knows nothing about entity subclasses. A component must never reference
  `User`, `Post`, or any other entity class.

### A System

- Is a plain Ruby object. The gem provides no base class in v0.1.
- Operates over one or more component types.
- Never requires knowledge of entity subclasses.
- Reaches the owning entity, when it must, via `component.entity`.

---

## 2. Schema

```
entities                    emails                     names
  id         UUID PK          id         UUID PK         id         UUID PK
  model      string           entity_id  UUID FK UNIQUE  entity_id  UUID FK UNIQUE
  created_at datetime         address    string          first      string
                              verified   boolean         last       string
                              created_at                 created_at
                              updated_at                 updated_at
```

- Every component table has `entity_id UUID NOT NULL` with a **unique index**
  and a foreign key to `entities(id)` with `ON DELETE CASCADE`.
- Component tables are named by the Rails plural of the component class.
- `entities.model` is indexed; `User.all` compiles to
  `SELECT * FROM entities WHERE model = 'users'`.
- `model` is derived from `model_name.collection`, so a namespaced entity's
  discriminator contains a slash: `Blog::Post` → `"blog/posts"`. Identical to
  the plural for every non-namespaced class. See
  [ADR-0008](adr/0008-subclass-resolution-on-read.md) for why not `.plural`.

---

## 3. Lifecycle

### Creation

```ruby
user = User.create!
```

1. Inserts one row into `entities` with `model = 'users'`.
2. Inserts **no** component rows.

A newly created entity has zero component rows. This is the normal case, not an
edge case.

### Reading

```ruby
user.email            # => #<Email address: nil, verified: false>
user.email.persisted? # => false
```

`entity.email` **always** returns an `Email` instance, never `nil`. If no row
exists, an in-memory instance is built with all attributes at their defaults and
`entity_id` set. See [RFC-0006](rfc/0006-lazy-components.md).

### Writing

```ruby
user.email.address = "a@b.com"
user.save!
```

A component row is inserted **only if** the component is dirty — that is, at
least one attribute differs from its default. Reading a virtual component, or
assigning an attribute a value equal to its default, never causes an insert.

### Validation

A virtual, non-dirty component is **not validated**. `User.create!` succeeds
even though `Email` validates presence of `:address`. Once a component is
dirtied, it validates normally and its errors merge onto the entity under the
`email.address` key. See [ADR-0003](adr/0003-virtual-components-skip-validation.md)
and [RFC-0007](rfc/0007-validation-error-merging.md).

### Destruction

- `entity.destroy` cascades to every component row (DB-level `ON DELETE CASCADE`).
- `entity.email.destroy` deletes the row and **resets the component to its
  virtual default state**. `entity.email` still returns an instance afterwards.

---

## 4. Delegation

```ruby
class User < ApplicationEntity
  component Name
  component Email
end

user.address            # => delegates to user.email.address
user.send_welcome_email # => delegates to user.email.send_welcome_email
```

- The `component` DSL generates delegating methods on the entity class for each
  of the component's public instance methods and attribute accessors.
- Delegation is generated **at declaration time**, into a module included in the
  entity class — not via `method_missing`.
- If two components on the same entity expose the same method name, the
  `component` DSL **raises immediately** at class-load time. There is no silent
  winner. See [ADR-0004](adr/0004-delegation-conflicts-raise.md).
- Conflicts are resolved explicitly: `component Group, except: [:title]`.

---

## 5. Relationships

Cross-entity links are ordinary components holding a UUID column. The gem
provides no relationship machinery in v0.1.

```ruby
class Author < ApplicationComponent
  belongs_to :author, class_name: "User", foreign_key: :author_id
end
```

```
authors
  entity_id  UUID UNIQUE   ← the Post that has this component
  author_id  UUID          → the User being pointed at
```

See [ADR-0006](adr/0006-relationships-are-plain-components.md). A first-class
relationship DSL is on the backlog, deliberately.

---

## 6. Scope of v0.1

The v0.1 milestone tests one hypothesis: **is modelling a real Rails app out of
components actually pleasant?** Everything not needed to answer that is out.

**In scope**

- `ApplicationEntity`, `ApplicationComponent`
- Component registry
- `component` DSL
- Method delegation
- Lazy / virtual components
- Validation error merging
- Migration generators

**Out of scope** — see [backlog.md](backlog.md)

- Systems (plain POROs; no gem code required)
- The `.with` / `.without` cross-component query DSL
- Component callbacks, events, caching, serialization
- Relationship DSL

---

## 7. Non-goals

- **Replacing ActiveRecord.** RoRECS reorganises persistence around components.
  Components remain ordinary AR models and the whole Rails ecosystem must keep
  working on them.
- **Query optimisation.** v0.1 will issue more queries than a hand-tuned
  equivalent. Correctness and API feel first; the query planner is a later,
  separate problem.
- **Databases other than PostgreSQL.** UUID PKs and `ON DELETE CASCADE` are
  assumed.
- **A general-purpose ECS.** This is a persistence architecture, not a game
  engine. There is no tick loop, no archetype storage, no cache-locality goal.

---

## 8. Open questions

Tracked, not yet decided. Each will become an ADR when it's forced.

1. **Does `User.all` preload declared components?** Currently no — N+1 by
   default. The demo will tell us how bad this is.
2. **Can one component be shared by two entities?** Currently no
   (`entity_id` is unique and singular). "Shared Components" in the proposal
   means *shared component types*, not shared rows.
3. **What happens when a component is removed from an entity class that has
   live rows?** Currently undefined. Probably a generator-produced migration.
4. **Is `entities.model` ever backfilled or migrated** when an entity class is
   renamed? Currently undefined.

5. ~~**Does `model` resolve back to a subclass on read?**~~ **Decided** —
   see [ADR-0008](adr/0008-subclass-resolution-on-read.md). `Rorecs::Entity`
   overrides `discriminate_class_for_record` to `classify.constantize` the
   `model` column, so `ApplicationEntity.find(id)` returns a `User`.

6. **What does subclassing a concrete entity mean?** `Admin < User` currently
   works and filters on `'admins'` — making `Admin` a *sibling* of `User`, not a
   kind of it. `User.all` does not return admins; under STI it would. Neither
   reading is written down. Either decide it in an ADR or forbid subclassing a
   concrete entity outright.

7. **Is the PostgreSQL floor 13+?** The install generator emits
   `enable_extension "pgcrypto"`, which is legacy on PG 13+ where
   `gen_random_uuid()` is built in. Harmless but redundant. Raised by RFC-0008.

8. **How much private ActiveRecord API are we willing to depend on?**
   `Rorecs::Entity` overrides the private `instantiate_instance_of` — see the
   [ADR-0008 amendment](adr/0008-subclass-resolution-on-read.md#amendment).
   It is pinned by tests, so a Rails upgrade breaks loudly rather than silently.
   But it is a real coupling to internals, and it is worth deciding whether this
   is a one-off or a pattern we will accept again.
