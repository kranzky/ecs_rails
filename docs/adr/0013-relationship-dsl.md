# ADR-0013: Relationship DSL — relates_to

**Status:** Accepted — storage superseded by [ADR-0017](0017-shared-relationships-table.md); the `relates_to` API stands
**Date:** 2026-07-20
**Surfaced by:** the demo — `Authorship`, `MemberUser`, `MemberGroup` all reinvent the same `belongs_to`-in-a-component boilerplate.
**Supersedes the deferral in:** [ADR-0006](0006-relationships-are-plain-components.md)

> **Superseded in part, 2026-09-02.** [ADR-0017](0017-shared-relationships-table.md)
> replaces the per-relationship backing table (`post_authors`, the dynamic
> `Post::AuthorRelationship` class, the `ecs_rails:relationship` generator) with
> one shared `relationships` table keyed by `(entity_id, slot)`, so that a
> `relates_to` needs no migration. Everything about the *API* below — one line on
> the entity, no component file, `post.author` / `post.author=`, the asymmetric
> cascade/nullify foreign keys, `optional: true`, join entities for many-to-many
> — is unchanged. The "Naming: owner-scoped" section's rejection of a shared
> table considered only a *relationship-named* one (`authorships`); the
> slot-keyed table it did not consider is collision-free because the owner's
> discriminator (`owner_model`) and the entity-model scope do the work the table
> name did.

## Context

[ADR-0006](0006-relationships-are-plain-components.md) made cross-entity links
plain components with a hand-written `belongs_to`, and deferred a real DSL "until
the demo showed what it should look like." It now has: three components
(`Authorship`, `MemberUser`, `MemberGroup`) that are *nothing but* a
`belongs_to`, each also needing a `component X` declaration and a migration.

## Decision

Add `relates_to` as an entity-level declaration:

```ruby
class Post < ApplicationEntity
  relates_to :author, User
end

class Membership < ApplicationEntity
  relates_to :user, User
  relates_to :group, Group
  component Role
end
```

```ruby
post.author = user       # writer
post.author              # => the User
membership.user          # => the User
membership.group         # => the Group
```

**No relationship component file.** `relates_to` defines the backing component
dynamically — verified to work with the full stack (registry, lazy reader,
delegation, `with_component`, presence, `includes_components`).

### How it works

`relates_to :author, User` on `Post`:

1. Dynamically defines a backing component class `Post::AuthorRelationship`
   (a real, named constant — registry-safe), with:
   - `self.table_name = "post_authors"` (set explicitly, so the class name and
     table name are decoupled),
   - `belongs_to :author, class_name: "User", foreign_key: :author_id, optional: true`.
2. Declares it: `component Post::AuthorRelationship`.

Delegation then surfaces the `belongs_to`: `post.author` / `post.author=`. The
backing component's own reader is `post.author_relationship` (its singular) —
de-emphasised but present, and the key for preloading. There is no reader
collision, because the component is named for the relationship and the
association for the target — exactly the rule the
[ADR-0006 amendment](0006-relationships-are-plain-components.md#amendment)
arrived at the hard way.

> **Load-bearing detail, found in implementation.** The reader is
> `author_relationship` only if the backing class's `model_name` is pinned to the
> demodulized element. The DSL derives the reader, the `has_one` name, and the
> preload key from `component_class.model_name.singular`, and for the *nested*
> constant `Post::AuthorRelationship` that naively resolves to
> **`post_author_relationship`** — the namespace leaks in and the owner name is
> doubled. `relates_to` sets `model_name` to `AuthorRelationship` (singular
> `author_relationship`) so every derivation agrees. Without this, the reader,
> `has_one`, and the `preload(author_relationship: …)` key silently disagree.

### Naming: owner-scoped

The backing table is `#{entity.singular}_#{relation.plural}` — `post_authors`,
`membership_users`, `membership_groups`. The backing class is
`Entity::RelationRelationship` (`Post::AuthorRelationship`).

Owner-scoped, so it is **collision-free by construction**: `relates_to :author,
User` on `Post` and on `Comment` produce `post_authors` and `comment_authors`,
two independent tables. The alternative — a shared, relationship-named table
(`authorships`) — saves a table but guesses the name from `:author` and lets two
entities relating to *different* targets collide on one table. Rejected.

### The generator emits only the migration

`rails g ecs_rails:relationship Post author:User` emits the migration for
`post_authors` (uuid PK; `entity_id` not-null, unique, cascade FK to `entities`;
`author_id` uuid with an index and a `nullify` FK to `entities`). It does **not**
write a component file — the DSL defines the component. It prints a reminder to
add `relates_to :author, User` to the entity.

## Consequences

- The demo loses three component files and their declarations; `Membership`
  becomes three lines. This is the cleanup that motivated the feature.
- **The target FK is `nullify`, not `cascade`.** Deleting the target entity
  (a `User`) nullifies the relationship, it does not destroy the owner (the
  `Post`). The owner's own components still cascade on the owner's deletion
  (architecture.md §3), which is a separate FK (`entity_id`).
- `belongs_to` is `optional: true`: a post with no author yet, or a nullified
  one, is valid. Requiring an author is the entity's business, not the
  relationship's (consistent with [ADR-0003](0003-virtual-components-skip-validation.md)).
- The backing component is a normal component, so `with_component`, `has?`,
  `includes_components` all work through the backing class. A
  relationship-name-based query/preload sugar (`with_related(:author)`,
  `includes_related(:author)`) is deferred — backlog, once the demo shows it's
  wanted.
- Many-to-many stays a join *entity* ([ADR-0005](0005-one-component-per-entity.md)):
  `Membership` with two `relates_to`. `relates_to` makes that join entity cheap
  to write, which is the right level to solve it.
- Dynamic class definition interacts with Zeitwerk reloading. The backing class
  is defined in the entity's class body, so it is recreated on each reload and
  the registry (keyed by name) resolves to the new constant — the same
  reload-safety every component already relies on. Verified under eager loading.
