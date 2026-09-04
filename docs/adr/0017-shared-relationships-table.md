# ADR-0017: One shared `relationships` table

**Status:** Accepted — implemented 2026-09-04 (Linear ECS-15; see [RFC-0012's amendment](../rfc/0012-relationship-dsl.md#amendment-the-shared-relationships-table-adr-0017))
**Date:** 2026-09-02
**Supersedes the storage model of:** [ADR-0013](0013-relationship-dsl.md) (the `relates_to` API is unchanged)
**Amends:** [ADR-0014](0014-relationship-name-query-sugar.md) (its "leak-proof by construction" argument)
**Surfaced by:** the v2 goal — *after `rails g ecs_rails:install` and one `db:migrate`, building an application requires no further migrations* (Linear ECS-14). See [ADR-0018](0018-catalogue-in-the-gem.md) for the goal itself.

## Context

Under [ADR-0013](0013-relationship-dsl.md) every `relates_to` owns a table.
`relates_to :author, User` on `Post` dynamically defines a backing component
class, pins its `model_name` so the reader and preload key derive correctly,
points it at an owner-scoped table `post_authors`, and declares it as a
component. The `ecs_rails:relationship` generator emits the migration.

That costs **one migration per relationship**. The
[marketplace design](../design/marketplace-demo.md) declares twelve
relationships on top of the forum's five: seventeen tables and seventeen
migrations before a single value component. Every non-trivial domain is mostly
relationships, so if each one costs a migration the zero-migrations claim fails
on the second entity a developer writes.

The two designs compared here are **equivalent in what the Ruby developer can
express, in what the database enforces, and in query shape.** They differ in
one dimension only: the current design costs a migration per relationship and
the shared one costs none.

## Decision

**All relationships are rows in one `relationships` table, created once by the
install migration.** A relationship is a labelled component whose single
attribute is a target; the slot ([ADR-0015](0015-plural-components-via-slot.md))
is the relationship name.

```sql
relationships (
  id           uuid PRIMARY KEY,
  entity_id    uuid NOT NULL,          -- the owner (the Post)
  slot         string NOT NULL,        -- the relationship name ("author")
  target_id    uuid,                   -- the pointed-at entity (the User)
  owner_model  string NOT NULL,        -- entities.model of the owner ("posts")
  exclusive    boolean NOT NULL DEFAULT false,
  created_at, updated_at
)
UNIQUE (entity_id, slot)                               -- one target per name (ADR-0005 / ADR-0015)
INDEX  (target_id, slot)                               -- inverse lookups (RFC-0015)
UNIQUE (target_id, slot, owner_model) WHERE exclusive  -- has_one, DB-enforced, no per-relationship index
FOREIGN KEY entity_id REFERENCES entities ON DELETE CASCADE
FOREIGN KEY target_id REFERENCES entities ON DELETE NULLIFY
```

**The public API does not change.** `relates_to :author, User`, `post.author`,
`post.author=`, `with_related`, `without_related` and `includes_related` keep
their signatures and semantics ([RFC-0012](../rfc/0012-relationship-dsl.md),
[RFC-0013](../rfc/0013-relationship-name-query-sugar.md)).

### Mechanism

- One catalogue component, `Relationship`
  ([ADR-0018](0018-catalogue-in-the-gem.md)), with
  `belongs_to :target, class_name: <entity base>, optional: true`.
  [ADR-0008](0008-subclass-resolution-on-read.md) read-time resolution returns
  the concrete subclass, so `post.author` is a `User`.
- `relates_to :author, User` declares a **slot-scoped `has_one`** over
  `Relationship` — `has_one :author_relationship, -> { where(slot: "author") },
  class_name: "Relationship", foreign_key: :entity_id` — the same mechanism
  [RFC-0014](../rfc/0014-plural-components.md) builds for every labelled
  component, and delegates `author` / `author=` through it to `target`. The
  lazy reader ([RFC-0006](../rfc/0006-lazy-components.md)) presets `slot`,
  `owner_model` (= the owner's `model_name.collection`) and `exclusive` on the
  virtual row, so a first write lands in the right slot.
- **`relates_to :order, Order, unique: true`** writes `exclusive = true` on
  that relationship's rows. The partial unique index then rejects a second
  owner of the same model pointing at the same target under the same slot:
  at most one `Invoice` per `Order`. This is what `has_one` on the parent side
  ([RFC-0015](../rfc/0015-inverse-relationships.md)) requires, and it needs no
  index of its own.
- **Target class is validated in Ruby.** Today `belongs_to :author, class_name:
  "User"` makes `post.author = company` raise an ActiveRecord type mismatch.
  With a generic target the gem performs that check itself against the declared
  target class and raises `InvalidRelationship`. The database never enforced
  target *type* under ADR-0013 either — the foreign key points at `entities`,
  not at a per-type table — so this is not a regression, but the Ruby check is
  mandatory, not optional.
- `with_related(:author, x)` compiles to
  `with_component(Relationship, slot: "author", target_id: x.id)` and so
  inherits the correlated-`EXISTS` compilation and the entity-model scope of
  [ADR-0011](0011-component-query-dsl.md). `includes_related(:author)` preloads
  the slot-scoped `has_one` and its target.
- The dynamic backing class, the `model_name` pinning, the owner-scoped
  table-name derivation, and the `ecs_rails:relationship` generator are all
  **deleted**.

## Reason

1. **It is the only way `relates_to` becomes pure Ruby.** Nothing else on the
   roadmap is blocked by this; the thesis is.
2. **It is [ADR-0015](0015-plural-components-via-slot.md) applied
   consistently.** One rule — `(entity_id, slot)` is unique — now governs value
   components, markers ([ADR-0018](0018-catalogue-in-the-gem.md)) and
   relationships alike. It is also the Flecs model exactly: a Flecs relationship
   *is* a pair `(Relation, Target)` stored uniformly, never a table per relation.
3. **Rails core already does this.** Active Storage keeps every attachment in
   one `active_storage_attachments` table keyed by record, name and blob, with a
   unique index across them; Action Text keeps every rich text in
   `action_text_rich_texts` keyed by record and name. A name-slotted shared link
   table is the pattern Rails chose for exactly this shape of problem.
4. **It is not a polymorphic association in the bad sense.** Rails polymorphic
   associations cannot carry a foreign key because the target table varies.
   Here every target is a row in `entities`, so the foreign key is real and
   `ON DELETE NULLIFY` is enforced by the database, as today.
5. **Inverse relationships get simpler and more capable.**
   [RFC-0015](../rfc/0015-inverse-relationships.md) becomes one `has_many
   :through` shape with a slot condition instead of one per backing class, and
   the shared table makes the Flecs wildcard query expressible — "everything
   that points at this entity", regardless of relationship name — which a safe
   destroy check and an orphan audit both want and which per-relationship tables
   cannot answer without enumerating every table.
6. **`has_one` uniqueness stays in the database.** The partial unique index is
   created once at install. A shared table *without* it would have made
   one-invoice-per-order a validation, which is not acceptable for a
   transactional demo and would have put a footnote on the zero-migrations
   claim.

## Alternatives rejected

- **Keep per-relationship tables.** Fails the goal; see Context.
- **Per-relationship partial unique index for `unique: true`.** A migration per
  `has_one`. Fails the goal for exactly the relationships the marketplace cares
  most about.
- **Uniqueness by validation only.** Rejected for the reason in Reason 6; a
  race between two checkouts would issue two invoices.
- **A second `unique_relationships` table** for `unique: true` relationships.
  Storage would then depend on a declaration flag, flipping the flag would move
  rows between tables, and the wildcard query would have to union two tables.
  The `exclusive` column and partial index buy the same guarantee inside one
  table.
- **Relationship-named shared tables** (`authorships`, the middle option
  [ADR-0013](0013-relationship-dsl.md) rejected). Still one table per
  relationship *name*, still a migration each, and it inherits ADR-0013's
  collision objection for free.

## Consequences

- **Raw SQL is less readable.** The column is `target_id` under `slot =
  'author'`, not `author_id` in `post_authors`. Anyone reading the database
  directly loses a name. The Rails API is unaffected.
- **[ADR-0014](0014-relationship-name-query-sugar.md)'s argument changes, its
  behaviour does not.** Relationship queries now rely on the slot plus the
  entity-model scope, exactly as shared component tables already do. The scope
  it called "belt-and-braces" is now load-bearing. Since `with_related` already
  rode `with_component`, which already applied the scope, the generated SQL
  shape is unchanged. Amended in that ADR.
- **`owner_model` is a denormalised copy of `entities.model`.** It exists so
  that the exclusivity index is per owner type — an `Invoice` and an `OrderItem`
  both pointing at an `Order` under slot `order` must not collide — and it
  makes the inverse `has_many` scope cheap
  ([RFC-0015](../rfc/0015-inverse-relationships.md)). It is the same trade
  [ADR-0002](0002-single-entities-table.md) already made with the discriminator.
- **One hot table.** Every link in the application lives in one table. For the
  phase this gem is for (see [ADR-0018](0018-catalogue-in-the-gem.md)) that is
  irrelevant; at scale it is a large, well-indexed join table, the profile of
  `active_storage_attachments` or a taggings table. If a hot path ever needs its
  own table, an opt-in `relates_to :x, Y, table: true` is a clean later escape
  hatch, mirroring the component generator's role for bespoke components. Not
  built until asked for.
- **Flipping `unique: true` on a relationship with data needs a backfill** of
  `exclusive`, and the data must already satisfy the constraint. Adding a unique
  index today has the same precondition. The `ecs_rails:upgrade` generator owns
  this.
- **No per-link columns.** A link cannot carry a position or a role. That was
  already the rule — a link with data is a join entity (`Membership`,
  `Employment`) — and the shared table makes it structural rather than
  conventional.
- **A breaking storage change, pre-1.0.** The `ecs_rails:upgrade` generator
  emits a data-moving migration for existing per-relationship tables (copy rows
  into `relationships` with `slot` = relationship name, `owner_model` = the
  owner's discriminator, then drop). The demo resets hourly, so for us it is a
  clean cut.
- `architecture.md` §2 (schema) and §5 (relationships) were rewritten when this
  was implemented (Linear ECS-15).

## Implementation notes (2026-09-04, ECS-15)

- `Relationship` is the application's one-line class including
  `EcsRails::Catalogue::Relationship` — the first catalogue entry in
  [ADR-0018](0018-catalogue-in-the-gem.md)'s shape — written by install and
  found by name via `EcsRails.config.relationship_class_name`.
- `owner_model` and `exclusive` are stamped in `before_save`, not preset on the
  virtual row as the Mechanism section says: a preset would differ from the
  column defaults and make every untouched virtual relationship dirty
  (RFC-0006). The effect is the same at the only time it matters.
- The relationship name reserves `author`, `author=`, `author_id`, `author_id=`
  on the entity, so later bare delegations cannot take them.
- `ecs_rails:upgrade` creates the table for a pre-0.3 application and moves
  each ADR-0013 backing table into it, recognised by shape and name; the
  developer reviews the generated list before running it.
