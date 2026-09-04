# ECS Rails Architecture

This document defines the **invariants** of ECS Rails. It is the specification that
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
- Appears **at most once per `(entity, slot)`**, enforced by a unique index on
  `(entity_id, slot)`. A singular component is slot `""`; a *labelled* one
  (`component Address, prefix: :business`) is slot `"business"`, a singleton
  with its own reader. Multiplicity comes from naming slots, never from an
  anonymous collection. See [ADR-0005](adr/0005-one-component-per-entity.md)
  and [ADR-0015](adr/0015-plural-components-via-slot.md).
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
entities                    emails                        addresses
  id         UUID PK          id         UUID PK            id         UUID PK
  model      string           entity_id  UUID FK ┐          entity_id  UUID FK ┐
  created_at datetime         slot       string  ┘ UNIQUE   slot       string  ┘ UNIQUE
                              address    string             line1      string
                              verified   boolean            region     string
                              created_at                    created_at
                              updated_at                    updated_at
```

- Every component table has `entity_id UUID NOT NULL`, `slot string NOT NULL
  DEFAULT ''`, a **unique index on `(entity_id, slot)`**, and a foreign key to
  `entities(id)` with `ON DELETE CASCADE`. `slot` is identity, not state: it is
  never delegated and never makes a virtual component dirty.
- One more table is created at install and shared by every entity:

  ```
  relationships
    id           UUID PK
    entity_id    UUID FK ┐ UNIQUE         the owner (the Post)
    slot         string  ┘                the relationship name ("author")
    target_id    UUID FK, ON DELETE NULLIFY   the entity pointed at (the User)
    owner_model  string                   the owner's entities.model ("posts")
    exclusive    boolean                  written by `unique: true`
    created_at, updated_at
  INDEX  (target_id, slot)                            inverse lookups
  UNIQUE (target_id, slot, owner_model) WHERE exclusive   has_one, DB-enforced
  ```

  Every `relates_to` is a row here. See §5 and
  [ADR-0017](adr/0017-shared-relationships-table.md).
- And one for markers, likewise created at install and shared:

  ```
  markers
    id         UUID PK
    entity_id  UUID FK ┐ UNIQUE, ON DELETE CASCADE
    slot       string  ┘  the marker name ("moderator")
    created_at, updated_at
  ```

  `marker :moderator` is `component Marker, prefix: :moderator`; a user *is* a
  moderator exactly when the row exists. See
  [ADR-0018](adr/0018-catalogue-in-the-gem.md) §4 and
  [RFC-0016](rfc/0016-markers.md).
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
  component PublishState, prefix: false
end

user.email_address            # => delegates to user.email.address
user.email_send_welcome_email # => delegates to user.email.send_welcome_email
user.name_first               # => delegates to user.name.first
user.state                    # => delegates to user.publish_state.state (bare)
```

- The `component` DSL generates delegating methods on the entity class for each
  of the component's public instance methods and attribute accessors.
- **Delegated names are prefixed with the component's reader:**
  `#{reader}_#{method}`. The rule is uniform — attributes and behaviour alike —
  so two components can never collide on a shared attribute, and a reader is
  never shadowed by a delegated method. A verb that reads badly prefixed is
  reached through the reader (`user.email.send_welcome_email`) or renamed on
  the component. See [ADR-0016](adr/0016-prefixed-delegation-by-default.md).
- `prefix: false` restores bare delegation for one declaration, where the prefix
  would be redundant (`post.state`, not `post.publish_state_state`). A
  relationship's backing component is always bare, so `post.author` keeps its
  shape ([ADR-0013](adr/0013-relationship-dsl.md)).
- `prefix: :label` declares a **slot** ([RFC-0014](rfc/0014-plural-components.md)):
  reader `label_singular` (`business_address`), delegation prefixed with that
  reader (`business_address_line1`). `delegate: false` keeps the reader and
  predicate only. Extra keywords are per-slot options the component declared
  with `slot_option` (`component State, prefix: :order, states: %w[...]`).
- `marker :moderator` ([RFC-0016](rfc/0016-markers.md)) is `component Marker,
  prefix: :moderator, delegate: false` plus the bare `moderator?` predicate and
  a Boolean `moderator=`; `add`/`has?`/`remove` take the Symbol. Presence is
  [ADR-0009](adr/0009-component-presence.md)'s, unchanged.
- `only:` / `except:` name the **component's** methods (`except: [:title]`),
  never the prefixed entity-level name.
- Delegation is generated **at declaration time**, into a module included in the
  entity class — not via `method_missing`.
- If two components on the same entity would expose the same entity-level name,
  the `component` DSL **raises immediately** at class-load time. There is no
  silent winner. See [ADR-0004](adr/0004-delegation-conflicts-raise.md). With
  the prefix this takes two bare components (`prefix: false`), so it is a
  backstop, not a routine hurdle.
- Because the prefixed writers exist, ActiveRecord's mass assignment routes a
  flat hash for free: `User.create!(name_first: "Ada", email_address:
  "a@b.com")` dirties and persists exactly those components. Rails
  multiparameter form fields (`date_select`) route the same way.

---

## 5. Relationships

A cross-entity link is a labelled component whose one attribute is a target.
All of them are rows in the shared `relationships` table (§2); the slot is the
relationship name. Declaring one is pure Ruby — no table, no migration.

```ruby
class Post < ApplicationEntity
  relates_to :author, User
end

class Invoice < ApplicationEntity
  relates_to :order, Order, unique: true   # at most one Invoice per Order
end

post.author = user          # checked: must be a User (InvalidRelationship otherwise)
post.author                 # => the User, as its concrete subclass
post.author_id              # => the User's id
post.author_relationship    # => the backing Relationship row (slot "author")

Post.with_related(:author, user)      # query by name, entity-model scoped
Post.without_related(:author)
Post.includes_related(:author)        # preload the row and its target
```

- `relates_to :author, User` is `component Relationship, prefix: :author,
  delegate: false` — the same slot mechanism as any labelled component (§4) —
  plus the four accessors above, defined by the DSL. `Relationship` is the
  application's one-line catalogue class including
  `EcsRails::Catalogue::Relationship`, written by `ecs_rails:install`.
- The target type is enforced in Ruby against the declared class; the database
  enforces referential integrity against `entities`, never type.
- Destroying the **owner** cascades and removes the link. Destroying the
  **target** nullifies the link; the owner survives. Neither cascades to the
  other entity.
- `unique: true` stamps `exclusive` on the rows; the partial unique index then
  rejects a second owner of the same type pointing at the same target under
  the same name. One index, created at install, covers every exclusive
  relationship the application will ever declare.
- A link carries no data of its own. A link with data (a role, a position) is a
  join entity carrying two `relates_to`.
- The relationship name is reserved on the entity: a later component may not
  delegate `author`, `author=`, `author_id` or `author_id=`, and no two
  relationships share a name.

See [ADR-0017](adr/0017-shared-relationships-table.md) (storage),
[ADR-0013](adr/0013-relationship-dsl.md) (the API) and
[ADR-0014](adr/0014-relationship-name-query-sugar.md) (query by name). The
inverse side — `post.comments` — is [RFC-0015](rfc/0015-inverse-relationships.md).

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

- **Replacing ActiveRecord.** ECS Rails reorganises persistence around components.
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
   see [ADR-0008](adr/0008-subclass-resolution-on-read.md). `EcsRails::Entity`
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

8. **Do component destroy callbacks need to run on `entity.destroy`?**
   Currently **no**, and this is a real gap. §3 makes the cascade the database's
   (`ON DELETE CASCADE`), and RFC-0004 deliberately declines `dependent:
   :destroy` so that the two layers do not mask each other — `entity.destroy`
   issues no SQL against component tables at all. The cost is that a component's
   `before_destroy`/`after_destroy` never fire when its entity goes. If a
   component ever needs to clean up outside the database (a file, a remote
   object), that silently will not happen. Wants an ADR, not a `has_one` option
   smuggled in.

9. **How much private ActiveRecord API are we willing to depend on?**
   `EcsRails::Entity` overrides the private `instantiate_instance_of` — see the
   [ADR-0008 amendment](adr/0008-subclass-resolution-on-read.md#amendment).
   It is pinned by tests, so a Rails upgrade breaks loudly rather than silently.
   But it is a real coupling to internals, and it is worth deciding whether this
   is a one-off or a pattern we will accept again.
