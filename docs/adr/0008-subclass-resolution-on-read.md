# ADR-0008: Resolve `model` to a subclass via `discriminate_class_for_record`

**Status:** Accepted
**Date:** 2026-07-17
**Supersedes:** architecture.md open question 5

## Context

RFC-0001 landed and exposed a hole. `ApplicationEntity.find(id)` returns an
`ApplicationEntity`, not a `User`. Because ActiveRecord instantiates rows via
`allocate`, it bypasses the abstract-class guard entirely: you hold an instance
of a class whose `.new` raises `NotImplementedError`, which carries no
components and can do nothing domain-specific.

This directly undercuts [ADR-0002](0002-single-entities-table.md), which
justified the `model` discriminator on the grounds that it "keeps the entity
subclass a real, answerable question". Nothing on the read path answered it.

[RFC-0003](../rfc/0003-application-component.md) forces the issue: it requires
`component.entity` to return the owning entity as its actual subclass.

Three options were considered.

**A. Override `discriminate_class_for_record`.** Keep `model` as plurals; hook
Rails' own STI resolution to map `"users"` → `User`.

**B. Store class names and set `inheritance_column = "model"`.** Change `model`
to hold `"User"`. Rails then does everything natively, with no custom code.

**C. Don't resolve.** Leave `find` returning the base class; have
`component.entity` do its own lookup.

## Decision

Option A. `Rorecs::Entity` overrides `discriminate_class_for_record` to
`classify.constantize` the `model` column.

## Reason

Option C leaves the hole open for anyone calling `find` directly, and pushes a
workaround into RFC-0003 that every future read path would have to repeat. It
treats a symptom.

Option B is the least code, but it is a trap. Setting `inheritance_column`
doesn't just buy resolution — it opts into Rails' entire STI apparatus
wholesale, including subclass scoping semantics we have deliberately built
ourselves ([RFC-0001](../rfc/0001-application-entity.md) uses a `default_scope`
that resolves per queried class, which is *not* how `sti_column` behaves). It
would also change the schema in architecture.md §2, and make `Admin < User`
silently inherit STI's "subclass rows appear in the parent's query" behaviour —
the exact question architecture.md open question 6 has not yet decided.

Option A takes the one piece of machinery we want and none of the rest.

## Consequences

- **Be honest: the clean fix for "No STI" is STI's own hook.** RoRECS uses the
  same resolution mechanism Rails uses for STI, on a column that is not
  `inheritance_column`. What RoRECS still avoids is STI's *pathology* — the wide
  sparse table, the state-bearing hierarchy — not its class-resolution
  machinery. [ADR-0002](0002-single-entities-table.md) already made this
  concession; this ADR extends it. The README and any marketing must not claim
  more than this.
- `model` values must round-trip: `User.model_name.plural.classify.constantize`
  must return `User`. This holds for ordinary names but **not** universally —
  irregular inflections and namespaced classes (`Blog::Post`) are where it will
  break. RFC-0003 must test the round-trip explicitly, and a class whose plural
  does not invert cleanly needs either a custom inflection or an explicit
  override. If that proves common, the answer is to store the class name in a
  separate column rather than to fight the inflector.
- An unresolvable `model` (class deleted or renamed) will raise `NameError` at
  instantiation. Consistent with the registry's fail-loudly stance
  ([RFC-0002](../rfc/0002-component-registry.md)); architecture.md open question
  4 (backfilling on rename) becomes more pressing, not less.
- Option B remains available if the inflection round-trip turns out to be a
  recurring source of pain.
