# ECS Rails Documentation

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Rails.

## Read in this order

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

## RFCs — the v0.1 build order

Each RFC is one commit. Each commit compiles and passes tests.

| # | Feature | Depends on |
|---|---|---|
| [0001](rfc/0001-application-entity.md) | ApplicationEntity + entities table | — ✅ |
| [0002](rfc/0002-component-registry.md) | Component registry | — ✅ |
| [0003](rfc/0003-application-component.md) | ApplicationComponent | 0001 ✅ |
| [0004](rfc/0004-component-dsl.md) | The `component` DSL | 0002, 0003 ✅ |
| [0005](rfc/0005-method-delegation.md) | Method delegation | 0004 |
| [0006](rfc/0006-lazy-components.md) | Lazy components | 0004 |
| [0007](rfc/0007-validation-error-merging.md) | Validation error merging | 0006 |
| [0008](rfc/0008-generators.md) | Install + component generators | 0001, 0003 ✅ |

RFC-0001 and 0002 are independent and can be built in parallel. 0005 and 0006
both depend on 0004 and are independent of each other.

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
