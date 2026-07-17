# ADR-0005: Exactly one component instance per entity

**Status:** Accepted
**Date:** 2026-07-17

## Decision

A component type appears at most once per entity. Enforced by a unique index on
`entity_id` in every component table.

## Reason

This is what Flecs does, and it is what makes `user.email` unambiguous. The
moment a component can be plural, `user.email` might be an `Email` or an array,
and every downstream feature forks:

- Delegation — delegate to which instance?
- Laziness — is an empty collection virtual, or is each member?
- Validation merging — what's the error key?
- The unique index invariant disappears.

Supporting both singular and plural components roughly doubles the gem's surface
area, for a case the proposal already models a better way.

## Consequences

- Collections are modelled as **separate entities**, exactly as the proposal
  does with `Membership`: a `Membership` entity composed of `User`, `Group`, and
  `Role` components, rather than a `Group` holding many memberships.
- This is the single biggest modelling constraint ECS Rails imposes, and the demo's
  main job is to find out whether it's liberating or infuriating. Expect this
  ADR to be the one most likely revisited.
- "Shared Components" in the proposal means shared component *types*, not shared
  rows. Two entities never point at the same component row.
