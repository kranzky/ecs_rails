# ADR-0006: Relationships are plain components in v0.1

**Status:** Accepted
**Date:** 2026-07-17

## Context

`Post` has an `Author`. `Comment` has a `Parent`. These point at other entities.
Flecs models this with first-class relationship pairs.

## Decision

For v0.1, a relationship is an ordinary component with a UUID column and a normal
`belongs_to`. The gem provides no relationship machinery.

```ruby
class Authorship < ApplicationComponent
  belongs_to :author, class_name: "User", foreign_key: :author_id
end
```

so that `post.author` returns the User, via delegation of the `author`
association. **Do not name the component the same as its association** — see the
amendment; the original version of this ADR did, and it recursed infinitely.

## Reason

It costs zero gem code and it already works — `belongs_to` against
`entities.id` is just ActiveRecord. A relationship DSL is a large feature, and
we have no evidence yet about what it should look like. Building it now means
designing it from the proposal's imagination rather than the demo's experience.

## Consequences

- The demo will build `Author`, `Parent`, and `Group` this way, and we log the
  friction. That friction is the input to the relationship RFC.
- Relationship components are the one place a component legitimately names an
  entity class (`class_name: "User"`), which bends the "components know nothing
  about entity subclasses" invariant in
  [architecture.md](../architecture.md). Accepted for now, and a strong hint
  that a real DSL belongs here eventually.
- Because components are singular ([ADR-0005](0005-one-component-per-entity.md)),
  a post has exactly one author. Many-to-many needs a join entity.

---

## Amendment (demo, 2026-07-18)

The original example named the component `Author` **and** its association
`author`. Building the demo showed that combination is broken: `component Author`
generates a reader `post.author` returning the Author component, while delegation
([RFC-0005](../rfc/0005-method-delegation.md)) also delegates the `author`
association method to `post.author`. The two collided, the delegated method
silently overwrote the reader, and calling `post.author` recursed into itself —
`SystemStackError`. The gem's own worked example was a landmine.

Two things changed.

1. **The gem now raises a reader collision at declaration time** rather than
   recursing (a delegated method may not take a component reader's name). This is
   the same fail-loud stance as [ADR-0004](0004-delegation-conflicts-raise.md).

2. **Name the association for its target, not the component.** `Authorship` with
   `belongs_to :author` gives the reading you actually want:

   | Expression | Is |
   |---|---|
   | `post.authorship` | the Authorship component (the reader) |
   | `post.author` | the User it points at (delegated association) |

   This is strictly nicer than the original — `post.author` returning a User is
   what a developer expects — so the collision was pointing at a better model all
   along. The guidance: a relationship component is named for the *relationship*
   (`Authorship`, `Membership`), and its association is named for the *target*
   (`author`, `member`).

This is friction feeding design, exactly as the "Consequences" above predicted —
just sooner and sharper than expected.
