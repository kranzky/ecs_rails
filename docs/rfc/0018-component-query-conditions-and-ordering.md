# RFC-0018: Component query — conditions beyond equality, and ordering

**Status:** Implemented (2026-09-04, Linear ECS-5)
**Depends on:** [RFC-0010](0010-component-query-dsl.md) (the query DSL), [RFC-0014](0014-plural-components.md) (slots, primary attributes)
**Decision:** [ADR-0011](../adr/0011-component-query-dsl.md), amended

## Goal

Two things a marketplace listing needs that RFC-0010 left out: filtering a
component beyond hash equality ("under $50", "four stars or more", "matching
this search"), and **ordering** entities by a component's value ("cheapest
first"). The second is a different mechanism from the first.

```ruby
Product.listed
       .with_component(Money, prefix: :price) { where("amount_cents < ?", 5000) }
       .with_component(Rating, "stars >= ?", 4)
       .order_by_component(Money, :amount_cents, prefix: :price)
```

## Rules

### Filtering beyond equality

- `with_component` takes, in addition to the hash conditions of RFC-0010:
  - **a block**, `instance_exec`'d on the component's relation, so `where`,
    `where.not`, and the component's own scopes and class methods read
    naturally (`{ tagged("ruby") }`, `{ matching(q) }`); it must return a
    relation of that component, or `ArgumentError`;
  - **positional `where`-style conditions** — a SQL fragment with binds
    (`"stars >= ?", 4`) or an array of them — applied through the component
    relation's `where`, so binds are sanitised.
- All three combine, and land inside the same correlated `EXISTS` subquery:
  one `EXISTS` per call, no duplicate rows, the entity-model scope untouched,
  `prefix:` scoping as before.
- `without_component` still takes no conditions (RFC-0010's non-goal stands).

### Ordering by a component column

- `Entity.order_by_component(Component, column = nil, direction = :asc,
  prefix: nil, nulls: :last)` appends a **correlated scalar subquery** to
  `ORDER BY`:

  ```sql
  ORDER BY (SELECT "monies"."amount_cents" FROM "monies"
            WHERE "monies"."slot" = 'price' AND "monies"."entity_id" = "entities"."id"
            LIMIT 1) ASC NULLS LAST
  ```

  No join, no alias, cannot duplicate rows, composes with every filter and
  with `limit`, `count`, `reorder`; several calls order by several components
  in turn.
- `column` may be omitted for a component with a **primary attribute**
  (`order_by_component(Counter, prefix: :likes, direction: :desc)`); a
  component without one demands a column. The column is validated against the
  component's real columns, because it is interpolated into SQL.
- `prefix:` names ONE slot (default `""`): ordering needs one row per entity,
  so "any slot" has no meaning here, unlike `with_component`.
- Entities without the row sort **last** in either direction; `nulls: :first`
  flips that. `direction` is `:asc` or `:desc`, positional or as `direction:`.
- The entity-model scope is untouched: the subquery correlates on the
  relation's own rows.

### Why a scalar subquery and not a join (ADR-0011, amended)

A `LEFT JOIN` per component would need an alias per call, changes what
`count` and `distinct` mean, and cannot be added without knowing every earlier
join's alias. A scalar subquery in `ORDER BY` is self-contained: it reads the
one row `(entity_id, slot)` addresses, on the unique index every component
table has. At this gem's scale that is the right trade; if a hot listing ever
needs the join, it is a local optimisation, not a change of API.

## Tests

`spec/querying_spec.rb`, "beyond equality" and "order_by_component": block
refinements including `where.not` and component scopes, positional binds,
combination with equality and `prefix:`, one `EXISTS` with the model scope,
bind sanitisation, the non-relation block error; ordering asc/desc, nulls
placement, the primary-attribute default, slot selection, composition with
`with_component`/`limit`/`count`, a chained tiebreak, the model scope and row
count, and the rejections (unknown column, bad direction, non-component).

## Non-goals

- `OR` across components (RFC-0010's non-goal stands).
- Ordering by a relationship's target (`order_by_related`): the inverse
  associations (RFC-0015) are the Rails way to reach that.
- Query optimisation.

**Demo verdict.** The forum's posts index gained a search box
(`with_component(SearchVector) { matching(q) }`, fed by an entity-blind
`Demo::Indexer` over every entity's `Text` slots) and a "most liked" sort
(`order_by_component(Counter, prefix: :likes, direction: :desc)`). See the
[friction log](../friction-log.md).
