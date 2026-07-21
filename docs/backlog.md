# Design Backlog

Future ideas, deliberately **not** being implemented. This list exists to avoid
feature creep while keeping a roadmap. Nothing here is a commitment.

An item leaves this list only when the demo app produces concrete friction that
justifies it. "It's in the proposal" is not justification.

---

## Strong candidates — the demo will likely force these

**The demo forced the first two.** Both are now confirmed needs, not
speculation — see [friction-log.md](friction-log.md).

| Idea | Status / why deferred | Trigger |
|---|---|---|
| ~~**Cross-component queries**~~ | ✅ **Shipped** — `with_component`/`without_component`, [ADR-0011](adr/0011-component-query-dsl.md) / [RFC-0010](rfc/0010-component-query-dsl.md). | fired |
| ~~**Preloading**~~ | ✅ **Shipped** — `includes_components`, [ADR-0012](adr/0012-component-preloading.md) / [RFC-0011](rfc/0011-component-preloading.md). Native AR `preload` already worked; this is the ergonomic wrapper. | fired |
| ~~**Relationship-name query/preload sugar**~~ | ✅ **Shipped** — `with_related`/`without_related`/`includes_related`, [ADR-0014](adr/0014-relationship-name-query-sugar.md) / [RFC-0013](rfc/0013-relationship-name-query-sugar.md). | fired |
| **Non-equality query conditions** — `with_component(Likes) { where("count > ?", 5) }` | **Not built.** RFC-0010 ships hash equality only; ranges/comparisons need a block or relation arg. | Not yet — the demo only needed equality. |
| **Required components** — `component Email, required: true` | **Not built.** In tension with [ADR-0003](adr/0003-virtual-components-skip-validation.md). | Repeatedly hand-writing the same entity-level presence validation. |
| ~~**Relationship DSL**~~ | ✅ **Shipped** — `relates_to`, [ADR-0013](adr/0013-relationship-dsl.md) / [RFC-0012](rfc/0012-relationship-dsl.md). | fired |

### Hard requirements the demo handed the query DSL

When the cross-component query RFC is written, it must:

1. **Not reuse `.with`** — that is ActiveRecord's CTE method (Rails 7.1+), and
   `Post.respond_to?(:with)` is already `true`. Pick a different verb
   (`with_component`, `having_component`, …) or a namespace
   (`Post.components.with(…)`).
2. **Apply the entity-model scope itself.** A component table is shared across
   entity types (PublishState on Post *and* Group), so a component query is blind
   to entity type. The hand-rolled `Post.published` is correct only because the
   outer `Post.where` contributes `model = 'posts'`; drop that and it leaks
   Groups. The DSL must scope by the entity's model without the caller knowing,
   or every query is a latent cross-entity leak.

## Speculative

- **Systems base class.** v0.1 says systems are POROs and need no gem code.
  Revisit only if a real pattern emerges — scheduling, batching, idempotency.
- **Component scopes promoted to the entity.** `User.verified` →
  `Email.verified`. Attractive; interacts badly with delegation conflicts.
- **Component callbacks.** `after_component_added`, `after_component_removed`.
- **Events.** Publish on component change. Probably belongs in the host app.
- **Caching.** Explicitly a non-goal until profiled.
- **Component serialization.** `entity.as_json` walking components.
- **Archetypes.** `archetype :moderator, [Name, Email, Moderator]` — reusable
  component bundles. Suspiciously close to reinventing inheritance; be careful.
- **Shared component rows.** Two entities pointing at one row. Currently
  forbidden by [ADR-0005](adr/0005-one-component-per-entity.md).
- **Non-PostgreSQL adapters.**
- **Component removal migrations.** architecture.md open question 3.

## Rejected

| Idea | Why |
|---|---|
| Plural components | [ADR-0005](adr/0005-one-component-per-entity.md) — doubles the gem's surface area. |
| `method_missing` delegation | [ADR-0004](adr/0004-delegation-conflicts-raise.md) — cannot detect conflicts eagerly. |
| Pure ECS identity (no `model` column) | [ADR-0002](adr/0002-single-entities-table.md) — every query becomes a join. |
