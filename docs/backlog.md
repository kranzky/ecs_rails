# Design Backlog

Future ideas, deliberately **not** being implemented. This list exists to avoid
feature creep while keeping a roadmap. Nothing here is a commitment.

An item leaves this list only when the demo app produces concrete friction that
justifies it. "It's in the proposal" is not justification.

---

## Strong candidates — the demo will likely force these

| Idea | Why it's deferred | What would trigger it |
|---|---|---|
| **Cross-component queries** — `Post.with(PublishState)`, `User.without(Avatar)` | The hardest thing in the proposal: a cross-table query planner. Also the most compelling. | The demo needing "all published posts" and finding raw joins unbearable. |
| **Preloading** — `User.includes_components(:name, :email)` | v0.1 is N+1 by design (architecture.md open q. 1). | The demo's post index issuing 200 queries. |
| **Required components** — `component Email, required: true` | Directly in tension with [ADR-0003](adr/0003-virtual-components-skip-validation.md). | Repeatedly hand-writing the same entity-level presence validation. |
| **Relationship DSL** — Flecs-style pairs, `relates_to :author, User` | [ADR-0006](adr/0006-relationships-are-plain-components.md) — no evidence yet what it should look like. | Author/Parent/Group in the demo all reinventing the same boilerplate. |

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
