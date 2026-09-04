# ADR-0016: Delegation is component-prefixed by default

**Status:** Accepted — implemented 2026-09-04 (Linear ECS-12)
**Date:** 2026-07-28
**Amends:** [ADR-0004](0004-delegation-conflicts-raise.md); resolves the
delegated-name-shape open question in [RFC-0014](../rfc/0014-plural-components.md),
and revises the delegation naming of [RFC-0005](../rfc/0005-method-delegation.md).

## Decision

A component's delegated methods are named **`#{reader}_#{attribute}`** — prefixed
with the component's reader name — by default. The component *reader* is
unchanged (`user.email`, `user.address`); only the delegated attribute and
behaviour methods gain the prefix.

```ruby
class User < ApplicationEntity
  component Name       # user.name_first, user.name_last      (reader: user.name)
  component Email      # user.email_address, user.email_verified (reader: user.email)
  component Address    # user.address_line1, user.address_postcode (reader: user.address)
end
```

Opt out per declaration with **`prefix: false`**, which restores bare delegation
for that component's default slot:

```ruby
component PublishState, prefix: false   # post.state, not post.publish_state_state
```

This unifies the default (unlabelled) case with the labelled/slot case of
[RFC-0014](../rfc/0014-plural-components.md), where the delegated name is already
`#{reader}_#{attribute}` (with `reader` = `business_address`). The single rule is:

> **delegated name = `#{reader}_#{attribute}`**; `prefix: false` drops the prefix
> on the default slot.

The `prefix:` keyword therefore reads uniformly as "how are these methods
prefixed?":

| Declaration | Slot | Reader | Delegated field |
|---|---|---|---|
| `component Email` | default | `email` | `email_address` |
| `component Email, prefix: false` | default | `email` | `address` |
| `component PostalAddress, prefix: :business` | `business` | `business_address` | `business_address_line1` |

`prefix: :label` (a Symbol) is always reader-prefixed — bare would collide across
slots; use `delegate: false` to drop delegation entirely when the prefixed names
get long.

## Reason

Bare delegation put every component's fields into one flat namespace on the
entity, which forced two workarounds and one naming contortion:

1. **Attribute collisions.** `Title#text` and `Body#text` on one entity collide,
   raising per [ADR-0004](0004-delegation-conflicts-raise.md), and must be
   resolved with `except: [:text]` — which *drops* the delegation, so you fall
   back to `post.title.text`.
2. **Reader-vs-field collisions force awkward names.** `Email#address` delegates
   to `user.address`, which collides with the *reader* of a component named
   `Address`. The only escape was to name it `PostalAddress`. Prefixing frees the
   namespace: `Email#address` becomes `user.email_address`, leaving `user.address`
   for the `Address` reader — so a best-of-breed component can take the obvious
   short name.
3. **Ambiguity.** `user.verified` doesn't say which component owns it;
   `user.email_verified` does.

Prefixing by default makes delegation collisions structurally almost impossible:
two distinct component types cannot share a prefixed name, and two slots of one
type are disambiguated by the slot label. [ADR-0004](0004-delegation-conflicts-raise.md)'s
raise becomes a rare backstop rather than a routine hurdle. The cost is verbosity
and the loss of the "reads like a wide-table column" feel — `person.name_first`
over `person.first` — which `prefix: false` buys back exactly where an author
judges the bare form clearer and unambiguous.

## Consequences

- **`except:` becomes niche.** It still exists (drop specific delegations), but
  collisions rarely arise, so it is no longer a routine tool. The demo's
  `component Title, except: [:text]` / `component Body, except: [:text]` become
  plain `component Title` / `component Body`, yielding `post.title_text` /
  `post.body_text`.
- **Standard components take short names.** `Address`, `Phone`, `Money`,
  `State` — no need to disambiguate against unrelated fields.
- **`prefix: false` is the escape valve** for components whose prefixed name is
  redundant (`publish_state_state`) or where the bare form is genuinely clearer.
- **Existing entities change.** Every bare delegation becomes
  `entity.component_attr` unless `prefix: false` is set (methods defined directly
  on the entity are unaffected — ADR-0004 still gives them precedence). A breaking
  change, acceptable pre-1.0, applied when implemented; `architecture.md` §4 is
  updated then.
- **Reinforces `prefix:` as the DSL keyword** (RFC-0014 open question #1): it now
  carries both the slot label (a Symbol) and the bare opt-out (`false`).
- **Best paired with the delegation seam of RFC-0014.** Both change the same
  generated-methods module, so the prefixing default should land with — or just
  before — plural components.

## Implementation notes (2026-09-04, ECS-12)

Decisions taken while implementing, recorded here because the ADR left them
open or implied them without saying so:

1. **The prefix is uniform: behaviour is prefixed exactly as attributes are.**
   The alternative — prefix attributes only, leave verbs bare — reads better
   for `user.send_welcome_email` but needs a heuristic for what counts as an
   attribute and reopens the verb collisions this ADR exists to close. Decided
   for uniform. An ugly prefixed verb is reached through the reader
   (`user.email.send_welcome_email`) or renamed on the component.
2. **`prefix: true` is accepted as the explicit default** and is not recorded in
   the registry, so a plain `component Email` compares equal before and after
   this ADR. `prefix: false` is recorded, so conflict detection re-derives the
   same bare names for a sibling or a subclass.
3. **A Symbol raises until RFC-0014 lands.** `prefix: :business` is the slot
   label; treating it as truthy today would silently generate unprefixed
   methods for a declaration whose author asked for a slot.
4. **`only:`/`except:` name the component's methods**, not the entity-level
   name. `except: [:group_title]` is the natural mistake and raises the usual
   unknown-name error.
5. **`relates_to` is bare** (`prefix: false` on the backing component), so
   `post.author` keeps its shape.
6. **Flat mass assignment falls out** and is pinned — `User.create!(name_first:
   "Ada", email_address: "a@b.com")` — including Rails multiparameter form
   fields, which the issue suspected would not route. They do.

The demo verdict is in [RFC-0005's amendment](../rfc/0005-method-delegation.md#amendment-reader-prefixed-names-adr-0016)
and the [friction log](../friction-log.md).
