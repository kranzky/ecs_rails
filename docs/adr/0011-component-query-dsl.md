# ADR-0011: Component query DSL — with_component / without_component

**Status:** Accepted
**Date:** 2026-07-19
**Surfaced by:** the demo (docs/friction-log.md — "all published posts")

## Context

The proposal writes cross-component queries as `Post.with(PublishState)` and
`User.without(Avatar)`: "entities that have / don't have this component". The
demo confirmed this is the single most-needed missing feature — every list view
hand-rolls it — and handed down two hard constraints.

### The proposal's verbs are all taken by ActiveRecord

Probed on a real entity relation:

| Verb | Already on `ActiveRecord::Relation`? |
|---|---|
| `.with` | **yes** — Common Table Expressions (Rails 7.1+) |
| `.without` | **yes** — alias of `excluding` (Rails 7+) |
| `.composed_of` | **yes** — aggregations |
| `with_component` / `without_component` | no — free |

So the proposal's syntax cannot be implemented as written without shadowing core
ActiveRecord. This is not a naming preference; it is a hard collision.

### A component query is blind to entity type

Component tables are shared across entity types (PublishState on Post *and*
Group). `PublishState.where(state: "published")` returns rows for every entity
that has one. The demo's hand-rolled `Post.published` is correct only because the
*outer* `Post.where` contributes `model = 'posts'`; drop that and it leaks
Groups (demonstrated). Any DSL must apply the entity-model scope itself.

## Decision

Add two class/relation methods, `with_component` and `without_component`:

```ruby
Post.with_component(PublishState, state: "published")   # posts that have a
                                                        # published PublishState
User.without_component(Avatar)                          # users with no avatar row
Post.with_component(Likes).with_component(PublishState) # AND — chainable
```

- **Verbs** are `with_component` / `without_component`. Free, parallel, and they
  say exactly what they do. Rejected `.with`/`.without` (taken), a `.components`
  namespace (`Post.components.with(…)` — an extra concept and indirection), and
  `having_component` (reads like SQL HAVING, which it is not).
- **Presence means a row exists**, consistent with the presence API
  ([ADR-0009](0009-component-presence.md)): `with_component` = has a row,
  `without_component` = has no row. A lazy/virtual component (no row) counts as
  absent, which is the intuitive reading of "without".
- **Optional attribute conditions**: `with_component(PublishState, state:
  "published")` filters to entities whose component row *also* matches those
  conditions. Hash conditions only in v1 (what the demo needs); a block or a
  relation for `count > 5`-style predicates is a later convenience.
- **Filter only, never preload.** These narrow which entities come back; they do
  not load the component data. Preloading is a separate backlog item that
  composes on top.
- **Returns an `ActiveRecord::Relation`**, so it chains with `where`, `order`,
  `limit`, and further `with_component` calls. Multiple calls AND together.

## Implementation: `EXISTS`, not `JOIN`

Each `with_component` compiles to a correlated subquery:

```sql
-- Post.with_component(PublishState, state: "published")
SELECT "entities".* FROM "entities"
WHERE "entities"."model" = 'posts'          -- from Post's default_scope, ADR-0002
  AND EXISTS (SELECT 1 FROM "publish_states"
              WHERE "publish_states"."entity_id" = "entities"."id"
                AND "publish_states"."state" = 'published')
```

`without_component` uses `NOT EXISTS`.

`EXISTS` over `JOIN` because:
- **No duplicate rows.** A join can multiply the entity by matching component
  rows; `EXISTS` matches once. (With the unique `entity_id` index this can't
  duplicate today, but `EXISTS` keeps it robust and reads as the presence check
  it is.)
- **Composes cleanly.** N `with_component` calls are N independent `AND EXISTS`
  clauses; joins would need aliasing to avoid table-name clashes when the same
  component is queried twice.
- **`NOT EXISTS` is the natural, index-friendly form of "without"** — a
  `LEFT JOIN … WHERE … IS NULL` is clumsier and easy to get wrong.

The entity-model scope is *not* added by the DSL directly — it falls out of the
method running on the entity class's own relation, which already carries
`model = 'posts'` (ADR-0002). The DSL only adds the `EXISTS` clause. Pinned by a
test that a shared component does not leak across types — the exact bug the
hand-rolled query risked. (In the gem's fixtures `Name` is the shared component,
on both `User` and `Post`; in the demo it is `PublishState`.)

### Implementation trade-off, recorded honestly

The subquery is built as
`component.where(conditions).where(<Arel correlation>).select("1")`, then its
`to_sql` is embedded into a `"EXISTS (...)"` / `"NOT EXISTS (...)"` string.
Conditions therefore go through ActiveRecord's `where`, which quotes the values
(verified injection-safe: a `'`-bearing value is escaped to `''` and compared as
data). The correlation is an Arel column comparison, so it renders as quoted
identifiers, not a hand-built string.

The *cleaner* path — `relation.where(subquery.arel.exists)` — preserves bind
parameters (better statement-cache reuse) but renders the negation as
`NOT (EXISTS (...))`, with a paren between `NOT` and `EXISTS`. That is fine SQL,
but it means the two forms are not symmetric and any `/NOT EXISTS/` assertion has
to allow the paren. We embed `to_sql` instead, accepting **inlined literals (no
bind reuse)** in exchange for symmetric, readable SQL. This is consistent with
architecture.md §7 (no query-optimisation promise); if bind reuse ever matters,
switch to the Arel form and loosen the assertion.

### `with_component` on an undeclared component does *not* raise

`Post.with_component(Avatar)` when `Post` does not declare `Avatar` is a valid,
(usually) empty query — not an `InvalidComponent`. A component table can hold a
row for any entity_id regardless of what the entity class declares, so the query
is meaningful. This keeps the DSL registry-free.

**This is deliberately asymmetric with the presence API**
([ADR-0009](0009-component-presence.md)): `entity.has?(Avatar)` on an undeclared
component *does* raise `InvalidComponent`. The reason: `has?`/`add`/`remove` are
structural operations on one entity's declared composition, where naming an
undeclared component is a programming error; `with_component` is a raw
cross-table query, where it is just a filter that happens to match nothing. Both
are individually right; the asymmetry is real and named here so it does not
surprise. (An abstract component — `ApplicationComponent` — *does* raise from
`with_component`, since it owns no table to query.)

## Consequences

- v0.1's "no query optimisation" non-goal (architecture.md §7) still holds: this
  is about *expressiveness and correctness*, not speed. `EXISTS` on an indexed
  `entity_id` is reasonable, but nobody is promising a planner.
- The demo's `Post.published` is rewritten in terms of `with_component`, removing
  the hand-rolled subquery and its implicit-scope trap.
- Attribute conditions beyond equality (ranges, comparisons) are a known gap,
  deferred deliberately.
- This does not touch the lazy/virtual model: it queries rows, and a virtual
  component has no row, so "with/without" line up with presence exactly.
