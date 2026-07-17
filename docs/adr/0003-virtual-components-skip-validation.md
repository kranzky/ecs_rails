# ADR-0003: Virtual components are not validated until dirtied

**Status:** Accepted
**Date:** 2026-07-17

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
  and so does not trigger validation or an insert. This follows ActiveModel's
  existing dirty-tracking semantics rather than inventing new ones.
