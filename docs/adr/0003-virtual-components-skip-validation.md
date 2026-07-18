# ADR-0003: Virtual components are not validated until dirtied

**Status:** Accepted (amended 2026-07-17)
**Date:** 2026-07-17

> **Amended during RFC-0006.** The decision stands. Its final consequence —
> "this follows ActiveModel's existing dirty-tracking semantics rather than
> inventing new ones" — is **provably false**, and deferring to ActiveModel does
> the exact thing this ADR exists to prevent. See the last bullet under
> Consequences. This is the second ADR falsified by its own dependency, after
> [ADR-0008](0008-subclass-resolution-on-read.md#amendment); both assumed "Rails
> already does this for us", and neither did.

## Context

`Email` validates presence of `:address`. A freshly created `User` has no email
row. Is that user valid?

If every declared component always validates, then `User.create!` raises, and a
component with any required attribute can never be lazy. That guts the lazy
component feature entirely — the two features are in direct conflict.

## Decision

A component is validated only once it is **dirty** — at least one attribute
differs from its default. An untouched virtual component is skipped entirely.

Component validations therefore mean: *"if this row exists, it must be
well-formed"* — not *"this row must exist"*.

## Reason

Lazy components are only free if reading one costs nothing and having one costs
nothing. Validating a component the developer never touched would make
`component Email` a breaking change to every existing `User.create!` call, which
defeats the composability the gem exists to provide.

## Consequences

- `User.create!` succeeds with no email row. `user.valid?` is `true`.
- `user.email.address = "nope"; user.valid?` is `false`.
- **Presence of a component cannot be expressed by the component itself.** If an
  entity genuinely requires an email, that is the *entity's* invariant, and the
  entity must declare it. A `component Email, required: true` option is on the
  backlog; it is deliberately not in v0.1 until the demo proves it's needed.
- Assigning an attribute its exact default value does not dirty the component,
  and so does not trigger validation or an insert. ~~This follows ActiveModel's
  existing dirty-tracking semantics rather than inventing new ones.~~
  **Amended by RFC-0006's implementation:** the behaviour holds, but the stated
  reason is wrong. "Dirty" here is *not* ActiveModel's, and cannot be. A virtual
  component has `entity_id` set, which ActiveModel counts as a change, so
  `user.email.changed?` is `true` for a component nobody has touched — deferring
  to ActiveModel would validate and insert every component ever read, which is
  precisely what this ADR exists to prevent. The gem defines its own rule
  (`EcsRails::Lazy::Component#ecs_dirty?`): while there is no row, at least one
  *state* attribute — excluding the primary key and `entity_id`, which are
  identity — differs from its column default; once there is a row, it is
  ActiveModel's, because a saved value now exists to differ from. This is a new
  semantic, deliberately, and it is the one the decision above depends on.
