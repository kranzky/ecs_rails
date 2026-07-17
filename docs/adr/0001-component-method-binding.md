# ADR-0001: Component methods bind `self` to the component

**Status:** Accepted
**Date:** 2026-07-17

## Decision

Component methods execute with `self` equal to the component, not the entity.
Delegation from the entity forwards the call; it does not rebind or `instance_exec`.

## Reason

Keeps components reusable and unaware of entity subclasses. A `Likes` component
used by both `Post` and `Comment` must behave identically in both, which is only
possible if it never sees the entity's class.

## Consequences

- Components access the owning entity via `#entity` when they need it.
- A component method cannot call a sibling component's method directly. It must
  go through `entity.other_component`. This is intentional friction: it makes
  inter-component coupling visible.
- `self.class` inside a component method is the component class, so
  `Email.pending.find_each { |e| e.send_welcome_email }` and
  `user.send_welcome_email` execute identical code.
