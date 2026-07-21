# ADR-0014: Query and preload relationships by name

**Status:** Accepted
**Date:** 2026-07-21
**Surfaced by:** the full demo UI (docs/friction-log.md)

## Context

[RFC-0012](../rfc/0012-relationship-dsl.md) deferred relationship-name query
sugar to the backlog. Building the full UI made the case concrete: every
relationship query names the *backing* component and its raw FK column —

```ruby
Comment.with_component(Comment::PostRelationship, post_id: post.id)   # comments on a post
Post.with_component(Post::AuthorRelationship, author_id: user.id)     # a user's posts
Membership.with_component(Membership::GroupRelationship, group_id: g.id)
```

The whole point of `relates_to` was to hide the backing component. Queries
re-expose it, and the developer has to know that `:author` becomes
`Post::AuthorRelationship` with an `author_id` column. The abstraction leaks
exactly where it is used most.

## Decision

Add relationship-name equivalents of the component query/preload verbs:

```ruby
Post.with_related(:author, user)          # posts whose :author is this user
Post.with_related(:author)                # posts that have any author set
Comment.with_related(:post, post)         # comments on this post
Post.without_related(:author)             # posts with no author
Post.includes_related(:author)            # preload the relationship (backing + target)
```

- **`with_related(name, target = :any)`** filters entities whose `name`
  relationship points at `target`. With no `target`, it filters to entities that
  have the relationship set at all. `target` may be an entity or a bare id.
- **`without_related(name)`** — entities with no backing row for that
  relationship.
- **`includes_related(*names)`** preloads each relationship's backing component
  *and its target*, so `entity.author` costs no extra query.
- All are thin sugar over the component verbs, resolving `name` to the backing
  class and FK via relationship metadata recorded by `relates_to`.

## How the metadata is found

`relates_to` records, per relationship name, the backing class name, the FK
column, and the target class name. The record is stored the same reload-safe way
the component registry is (by *name*, resolved via `constantize` on read), and
walked across the entity's ancestry so subclasses inherit relationships.

Rejected deriving the backing class from a naming convention at query time
(`"#{self.name}::#{name.to_s.camelize}Relationship".constantize`). It works, but
it duplicates `relates_to`'s naming logic in a second place, so a change to one
silently breaks the other. One source of truth, recorded at declaration.

## Reason

`Post.with_related(:author, ada)` reads as what it means — "posts related to Ada
as author" — and the developer never learns the backing class exists. The verbs
mirror `with_component` / `without_component` / `includes_components` exactly, so
there is one query vocabulary with a `_related` variant for the relationship
case.

## Consequences

- `with_related` is sugar: `with_related(:author, user)` compiles to
  `with_component(Post::AuthorRelationship, author_id: user.id)`, inheriting its
  correlated-`EXISTS` compilation ([ADR-0011](0011-component-query-dsl.md)).
  Note the entity-model scope is **belt-and-braces** here, not the defence:
  relationship backing tables are *owner-scoped by construction*
  ([ADR-0013](0013-relationship-dsl.md)) — `post_authors` and `comment_authors`
  are disjoint — so a relationship query is leak-proof regardless. Unlike a
  *shared* component table (`names`, on both User and Post), where the model
  scope is the only thing preventing a leak, there is no shared-table leak here
  to protect against. The scope stays because the sugar rides `with_component`;
  it just isn't doing load-bearing work in this case.
- **`includes_related(:author)` preloads one hop** — the backing component and
  its target entity — so `entity.author` is free. It does **not** preload the
  target's own components (`author.name`); that stays an explicit nested
  `preload`, or a later enhancement. Named as a non-goal so it does not surprise.
- An unknown relationship name raises `EcsRails::InvalidRelationship`, naming the
  relationship and listing the entity's declared relationships — the same
  fail-loud, component-shaped stance as the rest of the DSL.
- The demo's controllers lose every mention of a `*Relationship` backing class.
