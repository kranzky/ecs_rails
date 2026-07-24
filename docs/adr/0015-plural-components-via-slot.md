# ADR-0015: Plural components via a slot discriminator

**Status:** Accepted
**Date:** 2026-07-24
**Amends:** [ADR-0005](0005-one-component-per-entity.md)
**Surfaced by:** the standard-component-library brainstorm — `Phone` (mobile/work), `PostalAddress` (billing/shipping) and `Token` (by purpose) are all naturally multi-role, and modelling each role as a separate entity is wrong.

## Context

[ADR-0005](0005-one-component-per-entity.md) made a component appear at most once
per entity, enforced by a unique index on `entity_id`, and closed by predicting
it would "be the one most likely revisited." A survey of universal, standard-backed
components to ship as generators is what revisited it: the most common ones —
a person's mobile *and* work phone, a customer's billing *and* shipping address,
a reset *and* an invite token — are naturally plural.

ADR-0005's stated escape hatch, "model collections as separate entities," is right
for genuine collections (a `Membership` join entity) but wrong here. A billing
address is not an entity with its own identity and lifecycle; it is a
**role-tagged value** on one entity. Forcing it into a separate entity buys the
join-entity's ceremony for none of its benefit.

The naive alternative — a plural `component Phone, many: true` returning a
collection — is exactly what ADR-0005 rejected, and rightly: it forks delegation
("delegate to which instance?"), laziness ("is an empty collection virtual?") and
validation-error keys, and it dissolves the unique-index invariant.

## Decision

**Generalize the one-per-entity rule from `entity_id` to `(entity_id, slot)`.**

Every component table carries a `slot` string column, and the unique index moves
from `entity_id` to `(entity_id, slot)`. A **singular component is the default
case** — `slot = ""` — with no change to existing declarations or reads. A
**labelled component** declares a non-empty slot and gets its own prefixed reader:

```ruby
class User < ApplicationEntity
  component PostalAddress                      # slot ""         → user.postal_address
  component PostalAddress, prefix: :business   # slot "business" → user.business_address
  component Phone,         prefix: :mobile     # slot "mobile"   → user.mobile_phone
  component Phone,         prefix: :work       # slot "work"     → user.work_phone
end

user.business_address.line1 = "1 St Georges Tce"
user.mobile_phone.e164       = "+61412345678"
user.save!                   # two addresses rows, two phones rows — one per slot
```

Each `(entity, slot)` is still exactly one instance. So a labelled component is a
**singleton per slot**, and inherits the whole singular stack unchanged: the lazy
virtual reader (RFC-0006), the `?` presence predicate (RFC-0009), delegation
(RFC-0005), and one unambiguous row. Multiplicity comes from *naming* the slots,
never from an anonymous collection.

The detailed DSL, schema and migration are [RFC-0014](../rfc/0014-plural-components.md).

## Reason

**Every fork ADR-0005 feared only happens for anonymous collections — which this
does not add.** Because each slot resolves to a single instance:

- **Delegation** is unambiguous: `user.business_address` is one `PostalAddress`.
  Labelled delegated methods are prefixed (`business_address_line1`) so two slots
  of the same component don't collide — the [ADR-0004](0004-delegation-conflicts-raise.md)
  machinery already detects the collision; prefixing resolves it, and a
  declaration may opt out with `delegate: false` (reader-only).
- **Laziness** is per slot: `user.business_address` is virtual until dirtied,
  exactly as a singular component is.
- **Validation keys** are per reader: `errors[:"business_address.line1"]`.
- **The unique invariant survives**, generalized. `(entity_id, slot)` is unique;
  the singular `entity_id`-unique index is the `slot = ""` special case of it.

**Querying gains nothing to design.** `slot` is an ordinary column, so
`with_component(PostalAddress, slot: "business", region: "WA")` is the existing
hash-equality path (RFC-0010), correctly scoped by the entity model and compiled
to `EXISTS` (ADR-0011). No new query surface.

**This is the Flecs pairing model.** Flecs has no plural components either; it
expresses multiplicity as pairs — `(Address, Home)`, `(Address, Business)`. A
slot *is* that pair's second element for a value component. It is also the exact
symmetry of what `relates_to` already does for entity links: two `relates_to` to
the same target under different **names** (`author`, `editor`) already produce
two labelled backings. ADR-0015 brings the same labelling to value components,
keyed by **prefix** instead of relationship name.

## Consequences

- **Uniform schema.** Every component table gets `slot :string, null: false,
  default: ""`, so singular is a genuine special case of one code path, not a
  separate one. The cost is one extra column on every component table; the
  benefit is that "any component can be plural" with no per-component opt-in and
  no branching in the reader/lazy/query machinery. This trade — uniformity over a
  slot-column-only-when-plural split — was chosen deliberately.
- **The registry keys by `(entity, component, slot)`** (RFC-0002), so the same
  component declared under two slots is not a `DuplicateComponent`; the same slot
  twice still is.
- **ADR-0005 stands, generalized.** Its core guarantee — one unambiguous
  component instance per addressable unit — is preserved; the addressable unit is
  now `(entity, slot)` rather than `entity`. Its "collections are separate
  entities" consequence still holds for the case it was meant for.
- **Unbounded-N is still a join entity.** Slots must be *named* at declaration
  time, so they cover fixed roles (billing/shipping) and small enumerable sets
  (phone kinds) — not a contact with forty arbitrary numbers. That tail remains a
  has-many to child entities, i.e. a relationship (RFC-0012), unchanged. The
  anonymous-collection `many: true` idea is therefore **rejected outright**, not
  deferred: labelled components plus relationships cover the space between them.
- **A migration is required for existing component tables** (add `slot`, swap the
  unique index). Trivial for shipped data — every existing row is the single
  `slot = ""`. See the RFC.
