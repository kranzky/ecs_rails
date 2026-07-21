# ECS Rails Documentation

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Rails.

## Read in this order

0. **[retrospective-v0.1.md](retrospective-v0.1.md)** — what v0.1 is, what the
   demo found, and where it goes next. The story, in one page.
1. **[architecture.md](architecture.md)** — the invariants. The specification
   every task refers back to. Start here.
2. **[adr/](adr/)** — why the design is the way it is. Read before proposing a
   change.
3. **[rfc/](rfc/)** — what gets built, one feature at a time.
4. **[backlog.md](backlog.md)** — what deliberately isn't being built.

## Architecture Decision Records

| # | Decision |
|---|---|
| [0001](adr/0001-component-method-binding.md) | Component methods bind `self` to the component |
| [0002](adr/0002-single-entities-table.md) | A single `entities` table with a `model` discriminator |
| [0003](adr/0003-virtual-components-skip-validation.md) | Virtual components are not validated until dirtied |
| [0004](adr/0004-delegation-conflicts-raise.md) | Delegation conflicts raise at declaration time |
| [0005](adr/0005-one-component-per-entity.md) | Exactly one component instance per entity |
| [0006](adr/0006-relationships-are-plain-components.md) | Relationships are plain components in v0.1 |
| [0007](adr/0007-monorepo-and-licensing.md) | Monorepo now, split at publish; MIT licence |
| [0008](adr/0008-subclass-resolution-on-read.md) | Resolve `model` to a subclass via `discriminate_class_for_record` |
| [0009](adr/0009-component-presence.md) | Component presence is explicit; markers work through it |
| [0010](adr/0010-entity-component-directory-layout.md) | Entities in app/entities, components in app/entities/components |
| [0011](adr/0011-component-query-dsl.md) | Component query DSL — with_component / without_component |
| [0012](adr/0012-component-preloading.md) | Preloading is ergonomics over native ActiveRecord preload |
| [0013](adr/0013-relationship-dsl.md) | Relationship DSL — relates_to |
| [0014](adr/0014-relationship-name-query-sugar.md) | Query and preload relationships by name |

## RFCs — the v0.1 build order

Each RFC is one commit. Each commit compiles and passes tests.

| # | Feature | Depends on |
|---|---|---|
| [0001](rfc/0001-application-entity.md) | ApplicationEntity + entities table | — ✅ |
| [0002](rfc/0002-component-registry.md) | Component registry | — ✅ |
| [0003](rfc/0003-application-component.md) | ApplicationComponent | 0001 ✅ |
| [0004](rfc/0004-component-dsl.md) | The `component` DSL | 0002, 0003 ✅ |
| [0006](rfc/0006-lazy-components.md) | Lazy components | 0004 ✅ |
| [0005](rfc/0005-method-delegation.md) | Method delegation | 0004, **0006** ✅ |
| [0007](rfc/0007-validation-error-merging.md) | Validation error merging | 0006 ✅ |
| [0008](rfc/0008-generators.md) | Install + component generators | 0001, 0003 ✅ |
| [0009](rfc/0009-component-presence.md) | Component presence (add/has?/remove) | 0004, 0006 ✅ |
| [0010](rfc/0010-component-query-dsl.md) | Component query DSL (with_component/without_component) | 0001, 0003 ✅ |
| [0011](rfc/0011-component-preloading.md) | Component preloading (includes_components) | 0004, 0006 ✅ |
| [0012](rfc/0012-relationship-dsl.md) | Relationship DSL (relates_to) | 0004, 0005, 0008 ✅ |
| [0013](rfc/0013-relationship-name-query-sugar.md) | Relationship query sugar (with_related/includes_related) | 0010, 0011, 0012 ✅ |

RFC-0001 and 0002 are independent and can be built in parallel.

**0005 depends on 0006, not just on 0004.** An earlier version of this index
called them independent siblings; that was wrong. Delegation writers
(`user.address = "x"` → `user.email.address = "x"`) need `user.email` to be an
instance, and RFC-0004's reader returns `nil` — so delegation would raise
`NoMethodError` on nil. They also both target the same
`generated_component_methods` seam. Build 0006 first.

## Layout

```
gem/    the ecs_rails gem (MIT, extracted to its own repo at publish)
demo/   the bulletin board app (private, uses gem via path:)
docs/   this directory
```

## Process

See [../PROCESS.md](../PROCESS.md). In short: architecture first, one RFC per
feature, tests before implementation, tiny commits, and build the demo
*alongside* the gem — friction in the demo is the signal that the gem's API is
wrong.
