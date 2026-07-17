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
class Author < ApplicationComponent
  belongs_to :author, class_name: "User", foreign_key: :author_id
end
```

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
