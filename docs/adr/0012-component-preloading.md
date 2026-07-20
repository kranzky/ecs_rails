# ADR-0012: Preloading is ergonomics over native ActiveRecord preload

**Status:** Accepted
**Date:** 2026-07-19
**Surfaced by:** the demo (docs/friction-log.md — the 2-post index issued 14 queries)

## Context

Reading N components across M entities issues M×N queries. The demo's posts
index (2 posts) fired 14. This is architecture.md open question 1 (no
preloading), and it makes any real list view untenable.

## The key finding: native preload already works

Each component is a `has_one` association ([RFC-0004](../rfc/0004-component-dsl.md)),
and the lazy reader ([RFC-0006](../rfc/0006-lazy-components.md)) overrides it but
calls `super`, reaching the has_one underneath. So ActiveRecord's own
`preload` / `includes` / `eager_load` already batch component loads — verified:

- `User.all.preload(:name)` — 2 queries instead of 5, and the lazy reader still
  returns a **virtual** `Name` for a user with no row (the has_one preloads to
  nil-and-loaded, and the lazy reader builds the virtual).
- Composes with `with_component`: `User.with_component(Name).preload(:name,
  :email)` — 3 queries.
- `eager_load` (a `LEFT JOIN`) works too.

So this ADR is **not** about building preload machinery. It exists to (a)
guarantee that native path keeps working — the lazy-reader/preload interaction
is subtle enough to regress silently — and (b) add a thin, discoverable,
component-named entry point.

## Decision

Add `Entity.includes_components(*component_classes)`:

```ruby
Post.published.includes_components                    # all declared components
User.includes_components(Name, Email)                 # a named subset
Post.with_component(PublishState).includes_components(Title, Body, Likes)
```

- **Takes component classes**, not association symbols — consistent with
  `with_component`, `add`, `has?`, `remove`, which all take a class.
- **No arguments preloads every declared component** of the entity. The
  convenience the raw `preload(:a, :b, :c)` can't offer.
- **Uses `preload` semantics** (separate queries), not `includes`. `preload` is
  predictable — always one extra query per component, never a surprise JOIN that
  changes row identity or interacts with `with_component`'s `EXISTS`. Developers
  who want a JOIN can still call `eager_load`/`includes` on the association names
  directly.
- **Validates that each class is a declared component** on the entity, raising
  `EcsRails::InvalidComponent` with a message naming the component — better than
  ActiveRecord's `AssociationNotFoundError`, which leaks the has_one abstraction
  ("association `name`") that the gem otherwise hides.
- Returns an `ActiveRecord::Relation`, chainable.

## Reason

The raw path works but is undiscoverable (a developer has to know components are
has_one associations) and can't express "all components". `includes_components`
is a one-method affordance that reads in the gem's own vocabulary, defaults to
the common case, and fails with a component-shaped error. It is deliberately
thin: under the hood it is `preload(*association_names)`.

## Consequences

- Closes architecture.md open question 1 for the entity's *own* components.
- **Nested relationship components are not covered by the no-arg form.** The
  demo's remaining N+1 is the author's name: `post.author` is a `User` reached
  through the `Authorship` relationship component, so its `Name` is two hops out.
  `includes_components` preloads Post's own components; the nested hop uses
  standard AR nesting — `preload(authorship: { author: :name })`. A
  relationship-aware nested preloader is possible later (it pairs with the
  relationship-DSL backlog item) but is out of scope here.
- Still no query *optimisation* promise (architecture.md §7) — this is about
  issuing a bounded number of queries, not tuning them.
- The regression guarantee matters most: tests pin that native `preload` yields
  the batched-plus-virtual behaviour, so a future change to the lazy reader that
  broke preload would fail loudly.
