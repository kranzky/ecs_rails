# ADR-0009: Component presence is explicit; markers work through it

**Status:** Accepted
**Date:** 2026-07-18
**Surfaced by:** the demo (docs/friction-log.md)

## Context

The proposal's "No STI" claim rests on **marker components**: `Moderator` and
`Administrator` carry no data, and a user *is* a moderator exactly when a
`moderators` row exists for that entity.

But a marker has no state — only `entity_id`, which the dirty rule
([ADR-0003](0003-virtual-components-skip-validation.md#amendment)) excludes as
identity. So a marker is never `ecs_dirty?`, and [RFC-0006](../rfc/0006-lazy-components.md)'s
cascade never persists it. The natural code silently does nothing:

```ruby
user.moderator      # a virtual Moderator
user.save!          # writes no moderators row
user.moderator.persisted?   # => false, forever
```

There is no verb for "this entity has this component", and for a marker that
presence *is* the whole meaning.

## Decision

**Component presence is an explicit, first-class operation, separate from the
lazy read/save cycle.** A component is present when its row exists; you make it
so, ask about it, and undo it directly:

```ruby
user.add(Moderator)      # persist the row (idempotent)
user.has?(Moderator)     # => true — a row exists
user.moderator?          # => true — the same question, per-component sugar
user.remove(Moderator)   # destroy the row (idempotent)
```

The API and its edge cases are specified in [RFC-0009](../rfc/0009-component-presence.md).

## Reason

**Presence cannot be inferred from lazy state, and shouldn't be.** Reading
`user.moderator` must stay free (RFC-0006) — it cannot also mean "make this user
a moderator", or every presence check would mutate. And a marker has no
attribute to dirty, so the save cascade can never be the path. Presence has to
be its own verb.

**Explicit is right regardless of markers.** `entity.has?(Email)` (does a row
exist?) and `entity.remove(Avatar)` (drop it) are useful for *every* component,
not just empty ones. Markers are just the case where presence is the only state,
so they expose the need most sharply. Building a general presence API serves
both.

**`add`/`has?`/`remove` mirror Flecs**, whose Entity–Component vocabulary this
gem already borrows. Developers coming from ECS will reach for exactly these.

Rejected: a distinct `marker` DSL keyword. It forks the model into two concepts
the developer must choose between up front, when the truth is simpler — a marker
is an ordinary component that happens to be empty, and presence is a property
every component has.

## Consequences

- **`add` persists immediately and validates.** `user.add(Moderator)` inserts a
  row now, not on the next `save`. For a marker that always succeeds; for a
  component with required attributes, `user.add(Email)` raises
  `RecordInvalid` — you cannot add an empty required email, which is correct.
  `add` is therefore most useful for markers and optional components; stateful
  components are normally persisted by the dirty-save path instead.
- **`entity.<reader>?` is generated for every component**, not just markers.
  Unlike the reader, the predicate **defers silently** rather than raising: if
  the generated module already owns `<reader>?` (a component's hand-written
  `def foo?` delegated where a sibling's reader is `foo`), the delegated method
  wins and no predicate is generated. This is *not* the reader-collision rule —
  that rule reserves reader names only, and does not look at predicate names.
  (An earlier draft of this ADR wrongly said predicates raise "the same way";
  implementing RFC-0009 corrected it.) Silent deference is right here: the
  predicate is sugar, not structural like the reader, and the collision is
  near-impossible — AR-generated attribute predicates (`verified?`) are already
  outside the delegable set, so only a deliberately hand-written `def foo?`
  matching a sibling reader could trip it. Losing the auto-predicate in that one
  case costs nothing; `has?(Component)` is always available.
- Presence is a persistence fact (row exists), so `has?` and `<reader>?` hit the
  database unless the component is already loaded. This is consistent with the
  rest of the gem issuing a query per component (architecture.md §7 non-goal:
  query optimisation).
- This is the first gem feature the demo *added* rather than corrected — the
  proposal named marker components but never said how presence is set. The demo
  is doing its job.
