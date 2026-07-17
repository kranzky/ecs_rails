# ADR-0004: Delegation conflicts raise at declaration time

**Status:** Accepted
**Date:** 2026-07-17

## Context

`Name` defines `#title`. `Group` defines `#title`. A `User` declares both. What
does `user.title` do?

## Decision

The `component` DSL detects the clash when the entity class loads and raises
`EcsRails::DelegationConflict`, naming both components and the method.

```
EcsRails::DelegationConflict:
  #title is defined by both Name and Group on User.
  Disambiguate with `component Group, except: [:title]`
  or call user.group.title directly.
```

## Reason

The alternative — last declaration wins, like Ruby's module include order — is
predictable only if you know the rule and can see both components. In practice
the failure mode is: a component two repos away gains a method, and an unrelated
entity silently changes behaviour. That is action-at-a-distance on a codebase
whose entire premise is that components are shared and reused. The more
components are reused, the worse it gets — so the design must fail loudly.

## Consequences

- Adding a public method to a shared component can break an entity class at
  boot. This is a **feature**: it surfaces at load time, in CI, with both
  culprits named, rather than as a production behaviour change.
- The DSL needs `only:` and `except:` options from day one, not as a later
  addition — they are the sole escape hatch.
- Delegation must be generated eagerly at declaration time, into an included
  module. `method_missing` cannot detect conflicts up front and is therefore
  ruled out.
- Methods defined directly on the entity class always win over any delegated
  method, without raising. The entity is the more specific scope, and the
  generated methods live in an included module, so Ruby's own method lookup
  gives this for free.
