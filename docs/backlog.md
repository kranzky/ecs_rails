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
| ~~**Non-equality query conditions**~~ — `with_component(Counter, prefix: :likes) { where("count > ?", 5) }`, and `order_by_component` | ✅ **Shipped** (2026-09-04) — [RFC-0018](rfc/0018-component-query-conditions-and-ordering.md). | fired — the marketplace's filters and sorting (Linear ECS-5). |
| **Required components** — `component Email, required: true` | **Not built.** In tension with [ADR-0003](adr/0003-virtual-components-skip-validation.md). | Repeatedly hand-writing the same entity-level presence validation. |
| ~~**Relationship DSL**~~ | ✅ **Shipped** — `relates_to`, [ADR-0013](adr/0013-relationship-dsl.md) / [RFC-0012](rfc/0012-relationship-dsl.md). | fired |
| ~~**Plural components (labelled)**~~ — `component Address, prefix: :business` → `business_address` | ✅ **Shipped** (2026-09-04) — [ADR-0015](adr/0015-plural-components-via-slot.md) / [RFC-0014](rfc/0014-plural-components.md). `(entity_id, slot)` unique index, slot-scoped `has_one`, `delegate: false`, `slot_option`, `rails g ecs_rails:upgrade`. | fired |
| ~~**Inverse relationships (`has_many` / `has_one`)**~~ — the parent side of `relates_to`: `post.comments`, `order.invoice` | ✅ **Shipped** (2026-09-04) — [RFC-0015](rfc/0015-inverse-relationships.md). Native `has_many :through` over the shared table with `via:`, `dependent:` on the link rows, `has_one` gated on `unique: true`, `entity.referrers`. | fired |
| ~~**Shared `relationships` table**~~ — every `relates_to` a row, no migration | ✅ **Shipped** (2026-09-04) — [ADR-0017](adr/0017-shared-relationships-table.md). `relates_to ..., unique: true`, `EcsRails::Catalogue::Relationship`, the data move in `ecs_rails:upgrade`. | fired |
| ~~**The catalogue in the gem**~~ — standard components as concerns, one install migration, `ecs_rails:upgrade` | ✅ **Shipped** (2026-09-04) — [ADR-0018](adr/0018-catalogue-in-the-gem.md) / [RFC-0017](rfc/0017-catalogue.md): 25 components in `core` + `commerce`, `--sets`, `--rename`, install renders every table from the declarations, upgrade diffs them. The forum rebuild (ECS-17) is the first real use. | fired |
| **Component-driven UI** — catalogue components ship a display partial and a form field, so a page composes from the entity's declarations (`render_component post, :title`, `f.component_field :price`) | **Not built** — Linear [ECS-21](https://linear.app/future-factory/issue/ECS-21). The same argument as the zero-migrations thesis, one layer up: if the components are standard, their UI can be too. Lean helpers + overridable partials, no new dependency. | ECS-17 (the forum on the catalogue) is where it would first pay off; decide after it. Raised by the user 2026-09-04. |
| **Reader renaming for generic components** — `component Text, prefix: :title, as: :title` | **Not built.** RFC-0014 rejected per-slot renaming as scope creep. | The forum rebuilt on the catalogue (Linear ECS-17) — if `post.title_text` reads badly in real views and forms. |
| **Per-relationship table opt-in** — `relates_to :x, Y, table: true` for a hot path | **Not built.** [ADR-0017](adr/0017-shared-relationships-table.md) names it as the escape hatch. | A profiled hot path on the shared table. Not before. |

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
- **Component serialization.** `entity.as_json` walking components. Specced
  in Linear ECS-2; out of the v2 launch scope.
- **Archetypes.** `archetype :moderator, [Name, Email, Moderator]` — reusable
  component bundles. Suspiciously close to reinventing inheritance; be careful.
- **Shared component rows.** Two entities pointing at one row. Currently
  forbidden by [ADR-0005](adr/0005-one-component-per-entity.md).
- **Non-PostgreSQL adapters.**
- **Component removal migrations.** architecture.md open question 3.

## Rejected

| Idea | Why |
|---|---|
| ~~Plural components~~ → **reconsidered** | Was rejected under [ADR-0005](adr/0005-one-component-per-entity.md). The *anonymous-collection* form (`many: true`) stays rejected — it forks delegation/laziness. The *labelled* form is now planned: [ADR-0015](adr/0015-plural-components-via-slot.md) / [RFC-0014](rfc/0014-plural-components.md). |
| Anonymous plural components — `component Phone, many: true` returning a collection | [ADR-0015](adr/0015-plural-components-via-slot.md) — forks delegation, laziness and error keys. Unbounded-N is a join entity; fixed roles are labelled slots. |
| `method_missing` delegation | [ADR-0004](adr/0004-delegation-conflicts-raise.md) — cannot detect conflicts eagerly. |
| One table per `relates_to` | Was [ADR-0013](adr/0013-relationship-dsl.md)'s storage; superseded by [ADR-0017](adr/0017-shared-relationships-table.md) — a migration per relationship defeats the zero-migrations goal. The API is unchanged. |
| Standard components as per-component generators | Superseded by [ADR-0018](adr/0018-catalogue-in-the-gem.md) — a migration per component defeats the goal; the catalogue ships in the gem. |
| Uniqueness for `has_one` by validation only | [ADR-0017](adr/0017-shared-relationships-table.md) — two concurrent checkouts would issue two invoices. The partial unique index keeps it in the database. |
| A single `values` table (entity–attribute–value) | [ADR-0018](adr/0018-catalogue-in-the-gem.md) — catalogue tables are typed per shape with real FKs, indexes and validations. No values blob. |
| Pure ECS identity (no `model` column) | [ADR-0002](adr/0002-single-entities-table.md) — every query becomes a join. |
