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

Option A. `EcsRails::Entity` resolves `model` → subclass via
`discriminate_class_for_record`, and derives the discriminator from
`model_name.collection`.

> **Amended 2026-07-17, during RFC-0003.** As originally written this decision
> was wrong on two counts, both found by implementing it. See
> [Amendment](#amendment) below. The decision — Option A over B and C — stands;
> the mechanism and the discriminator derivation both changed.

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

- **Be honest: the clean fix for "No STI" is STI's own hook.** ECS Rails uses the
  same resolution mechanism Rails uses for STI, on a column that is not
  `inheritance_column`. What ECS Rails still avoids is STI's *pathology* — the wide
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

---

## Amendment

Implementing this ADR falsified two of its claims. Both are recorded here rather
than silently edited away, because the *reasoning* that produced them is the
thing worth not repeating.

### 1. The mechanism: `discriminate_class_for_record` alone is dead code

This ADR said the hook could be applied "to a column that is *not*
`inheritance_column`", taking "the one piece of machinery we want and none of
the rest". **Rails does not offer that separation.** From
`ActiveRecord::Querying#_load_from_sql` (8.1):

```ruby
if result_set.includes_column?(inheritance_column)
  rows.map { |r| instantiate(r, ...) }                    # calls the hook
else
  rows.map { |r| instantiate_instance_of(self, r, ...) }  # never calls it
end
```

`inheritance_column` is `"type"`; `entities` has no `type` column; so every
entity read takes the second branch and the hook never fires. Option A as
written required the gate that only Option B opens. Verified empirically, not
reasoned about.

**Resolution:** `EcsRails::Entity` also overrides the private
`instantiate_instance_of` to route through `discriminate_class_for_record`. Both
AR callers funnel through it — the fast path above, and `instantiate`, which
eager loading uses — so every read path resolves, `inheritance_column` is left
alone, and `discriminate_class_for_record` remains the single decision point
this ADR intended.

**Cost:** `instantiate_instance_of` is private ActiveRecord API and may change
across Rails versions. This is real fragility. It is pinned by tests so a break
is loud rather than silent, and architecture.md §7 already scopes us to
PostgreSQL — but it is a genuine coupling to Rails internals, and it is the
price of Option A. Option B remains the escape hatch if the private API moves.

### 2. The risk: irregular inflections are a non-issue; namespacing is total

This ADR led with irregular inflections and treated namespacing as a co-equal
aside. **It is the reverse.** Observed:

| Class | `.plural` | round-trips? |
|---|---|---|
| `User`, `Person`, `Datum`, `Equipment`, `Series`, `Analysis` | `users`, `people`, `data`, … | ✅ all |
| **`Blog::Post`** | **`blog_posts`** | ❌ → `BlogPost` |

Rails' inflector is bidirectional for its irregular and uncountable rules. Every
one tried round-trips. The worry was misplaced.

Namespacing is the real break, and worse than described. `model_name.plural` is
**not** `"blog/posts"` — it is built from `param_key`, which underscores the
whole constant path, destroying the separator *before the inflector is ever
consulted*. So this ADR's suggested remedy — "either a custom inflection or an
explicit override" — is **half unavailable**: no inflection rule can fix it,
because the information is already gone.

Worse still, **the mapping is not injective**: `Blog::Post` and `BlogPost` both
produce `"blog_posts"`. No inverse function, however perfect, can separate them.
A namespaced entity could be written but never read back as itself.

**Resolution:** derive the discriminator from `model_name.collection`, not
`model_name.plural`.

| Class | `.plural` | `.collection` | `collection⁻¹` |
|---|---|---|---|
| `Blog::Post` | `blog_posts` | `blog/posts` | `Blog::Post` ✅ |
| `BlogPost` | `blog_posts` | `blog_posts` | `BlogPost` ✅ |
| `User` | `users` | `users` | `User` ✅ |

`.collection` is **identical to `.plural` for every non-namespaced class**, so
this needed no data migration and no change to any existing discriminator. Both
`stamp_model` and the `default_scope` in RFC-0001 were changed together — they
must use the same derivation, or entities become unfindable by the very scope
meant to select them.

This also makes the separate-column fallback below unnecessary. It was heavier
than the problem required.

**Consequence for architecture.md §2:** a namespaced entity's discriminator
contains a slash (`"blog/posts"`). Cosmetically odd, functionally fine.

### What this says about the process

Both errors came from reasoning about Rails' behaviour instead of running it.
The ADR was internally coherent and wrong. Neither error would have been caught
by review — only by execution.
