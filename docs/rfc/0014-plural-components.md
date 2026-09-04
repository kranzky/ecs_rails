# RFC-0014: Labelled (plural) components

**Status:** Implemented (2026-09-04, Linear ECS-4) — see [the amendment](#amendment-as-implemented)
**Depends on:** RFC-0002 (registry), RFC-0004 (component DSL), RFC-0005 (delegation), RFC-0006 (lazy components), RFC-0008 (generators), RFC-0009 (presence), RFC-0010 (query)
**Decision:** [ADR-0015](../adr/0015-plural-components-via-slot.md)

## Goal

Let a component type be declared more than once on an entity under distinct
labels, each label a singleton with its own prefixed reader — without weakening
any singular guarantee. Unlocks the naturally multi-role components from the
standard-library survey (`Phone`, `PostalAddress`, `Token`, …).

```ruby
class User < ApplicationEntity
  component Address                      # user.address
  component Address, prefix: :business   # user.business_address
  component Phone,   prefix: :mobile     # user.mobile_phone
  component Phone,   prefix: :work       # user.work_phone
end
```

> The component is `Address`, not `PostalAddress`: the reader rule is
> `#{prefix}_#{singular}`, so only the short name yields `business_address`.
> [ADR-0016](../adr/0016-prefixed-delegation-by-default.md) freed that name
> (`Email#address` delegates as `email_address`), and the catalogue takes it.

## Rules

- **`component ComponentClass, prefix: :label`** declares the component into a
  named **slot**. The stored slot value is `label.to_s`. No `prefix:` means the
  default slot, `""`.
  - **Reader:** `#{prefix}_#{component.model_name.singular}` — `business_address`,
    `mobile_phone`. The default slot's reader is the bare singular,
    `postal_address` — identical to today, so existing code is untouched.
  - `prefix` must be a valid method-name segment. A reader that collides with an
    existing reader or delegated method raises the reader-collision error
    (RFC-0005) — including declaring the same `(component, prefix)` pair twice.
- **Schema.** Every component table carries `slot :string, null: false, default:
  ""`, with a unique index on `(entity_id, slot)` **replacing** the `entity_id`
  unique index (architecture.md §2 / [ADR-0015](../adr/0015-plural-components-via-slot.md)).
- **The reader is a slot-scoped `has_one`.** For `prefix: :business` the DSL
  generates, over the *same* `PostalAddress` class:

  ```ruby
  has_one :business_address, -> { where(slot: "business") },
          class_name: "PostalAddress", foreign_key: :entity_id, inverse_of: :entity
  ```

  The lazy reader (RFC-0006) overrides it and, when no row exists, builds a
  virtual instance with `slot` **preset** to `"business"`, so a first write
  persists into the right slot. `add` (RFC-0009) presets `slot` the same way.
  This differs from `relates_to`, which defines a *new* backing class per name;
  here the class is shared and the slot scope does the discriminating.
- **Delegation is prefixed by default.** `PostalAddress#line1` under `prefix:
  :business` is delegated as `business_address_line1`, routed through the
  `business_address` reader. Prefixing is what keeps two slots of one component
  from colliding on `line1` — the [ADR-0004](../adr/0004-delegation-conflicts-raise.md)
  conflict check already catches the collision; prefixing is the resolution.
  - **Opt-out: `component PostalAddress, prefix: :business, delegate: false`** —
    no delegated methods at all; reach attributes through the reader
    (`user.business_address.line1`). This is the escape valve for when prefixed
    names get long (`business_address_postal_code`).
  - **The default (unlabelled) slot is *also* prefixed by default** as of
    [ADR-0016](../adr/0016-prefixed-delegation-by-default.md) — `component Email`
    delegates `email_address`, not `address`. Pass **`prefix: false`** to restore
    bare delegation (`component PublishState, prefix: false` → `post.state`) where
    the prefix is redundant. This makes the singular and labelled cases one rule:
    delegated name = `#{reader}_#{attribute}`.
- **Presence (RFC-0009)** gains an optional label: `add(PostalAddress, prefix:
  :business)`, `has?(PostalAddress, prefix: :business)`, `remove(...)`. The
  per-slot predicate `user.business_address?` is generated like any reader's.
- **Query (RFC-0010)** needs no new surface: `slot` is a column, so
  `with_component(PostalAddress, slot: "business", region: "WA")` already works.
  Optional sugar `prefix: :business` may alias `slot: "business"` for symmetry
  with the DSL.
- **Preload (RFC-0011)** keys by reader/slot as today; `includes_components`
  preloads each declared slot's `has_one`.
- **Registry (RFC-0002)** keys declarations by `(entity_class, component_class,
  slot)`. `Registry::Declaration` gains a `slot`. The same component under two
  slots is two declarations; the same slot twice is a `DuplicateComponent`.
- **Inheritance & reload.** Slots are declared in the entity body exactly like
  components, inherited by subclasses, and survive reload — slots are strings, no
  new reload hazard.

## Generator

`rails g ecs_rails:component Phone e164:string extension:string` emits, in the
migration:

- `slot :string, null: false, default: ""`,
- `add_index :phones, [:entity_id, :slot], unique: true` (instead of the
  `entity_id`-only unique index),
- otherwise unchanged (uuid PK, `entity_id` FK `on_delete: :cascade`, timestamps).

The generator does **not** take the slot — slots are a call-site concern
(`component Phone, prefix: :mobile`), not a schema one. One `phones` table serves
every slot.

### Upgrading existing component tables

A one-off migration per existing table:

```ruby
add_column :emails, :slot, :string, null: false, default: ""
remove_index :emails, :entity_id
add_index    :emails, [:entity_id, :slot], unique: true
```

Safe on shipped data: every existing row is the single `slot = ""`, so the new
composite index admits exactly the rows the old one did. Ship an
`ecs_rails:upgrade_slots` generator that emits one such migration per component
table it finds.

## Tests

```ruby
describe "labelled components" do
  it "reads and writes each slot independently" do
    u = User.create!
    u.business_address.line1 = "1 St Georges Tce"
    u.postal_address.line1   = "10 Marine Pde"
    u.save!
    expect(u.reload.business_address.line1).to eq "1 St Georges Tce"
    expect(u.postal_address.line1).to eq "10 Marine Pde"
  end

  it "keeps each slot lazy until dirtied" do
    expect(User.create!.business_address.persisted?).to be false
  end

  it "generates a per-slot presence predicate" do
    u = User.create!; u.add(PostalAddress, prefix: :business)
    expect(u.business_address?).to be true
    expect(u.postal_address?).to  be false
  end

  it "prefixes delegated methods" do
    u = User.create!
    u.business_address_line1 = "1 St Georges Tce"     # delegated
    expect(u.business_address.line1).to eq "1 St Georges Tce"
  end

  it "omits delegation when delegate: false" do
    expect(Supplier.new).not_to respond_to(:remit_address_line1)
  end

  it "filters by slot through with_component" do
    perth = User.create!; perth.business_address.region = "WA"; perth.save!
    expect(User.with_component(PostalAddress, slot: "business", region: "WA"))
      .to include(perth)
  end

  it "treats the same slot twice as a duplicate" do
    k = stub_const("Dup", Class.new(ApplicationEntity))
    k.component PostalAddress, prefix: :business
    expect { k.component PostalAddress, prefix: :business }
      .to raise_error(EcsRails::DuplicateComponent)
  end

  it "leaves singular components byte-identical (default slot)" do
    u = User.create!; u.email.address = "a@b.com"; u.save!
    expect(u.reload.email.address).to eq "a@b.com"     # RFC-0006 unchanged
  end
end
```

## Non-goals

- **Anonymous unbounded collections** (`component Phone, many: true`, returning a
  collection). Rejected by [ADR-0015](../adr/0015-plural-components-via-slot.md),
  not deferred. Forty arbitrary numbers is a has-many to child entities — a
  relationship (RFC-0012) — not a labelled component.
- **Runtime/dynamic slots** not declared on the class. Slots are declared like
  components; you cannot invent `user.holiday_address` at runtime.
- **Cross-slot query sugar** beyond equality (`every PostalAddress on the entity`).
  Reach for the component (`with_component(PostalAddress)` matches any slot) or
  wait for a real need.
- **Per-slot delegation renaming** (mapping `business_address_line1` to a custom
  name). `delegate: false` plus the reader covers the ergonomic escape; a rename
  map is scope creep.

## Open questions

- **Keyword name.** `prefix:` (reads as "prefix the reader", the user-facing
  effect) vs `slot:` (matches the column) vs `as:`. This RFC uses **`prefix:`**
  in the DSL and stores it to the `slot` column — naming the knob for its effect,
  the column for its storage. Confirm before implementing.
  [ADR-0016](../adr/0016-prefixed-delegation-by-default.md) reinforces `prefix:`:
  the same keyword now also carries the bare opt-out (`prefix: false`), reading
  uniformly as "how are these methods prefixed?".
- ~~**Delegated-name shape.**~~ **Resolved** by
  [ADR-0016](../adr/0016-prefixed-delegation-by-default.md): reader-prefixed
  (`business_address_line1`), and applied to the default slot too
  (`email_address`), with `prefix: false` for the bare opt-out. Reader-prefixed
  keeps the component type legible in the method name; the length is exactly what
  `delegate: false` (drop) and `prefix: false` (bare) answer.
- **Default slot value.** `""` (used here) vs the component's own singular name.
  `""` keeps the default reader at exactly `postal_address` with zero prefix
  logic and removes any chance of a label colliding with the component's own
  name.

## Follow-on

Once shipped, the standard-library generators (`Phone`, `PostalAddress`, `Token`)
can assume labelled use. Add a demo entity that exercises two slots of one
component (a `User` with `postal_address` + `business_address`) so the friction
log has a real verdict on prefixed delegation.

## Amendment: as implemented

*2026-09-04, Linear ECS-4.* Built on top of ADR-0016's delegation map. The RFC's
rules stand; these are the decisions it left open or implied, and one
correction.

- **Correction — the component is `Address`.** The examples above originally
  read `PostalAddress` → `business_address`, which the reader rule
  (`#{prefix}_#{model_name.singular}`) does not produce; it produces
  `business_postal_address`. The rule is right and the examples were loose.
  Rewritten to `Address`, the name ADR-0016 freed and the catalogue uses. The
  gem's fixture is `Address` too.
- **Keyword `prefix:`, default slot `""`.** Confirmed as the RFC's answers. One
  keyword carries three meanings with no ambiguity: `true`/omitted and `false`
  are the default slot (prefixed or bare delegation, ADR-0016); a Symbol or
  String is a slot label. A label must be a method-name segment
  (`/\A[a-z_][a-z0-9_]*\z/`) and may not be `""`; anything else raises.
- **Every `has_one` is slot-scoped, the default slot included** —
  `has_one :address, -> { where(slot: "") }`. Not only when a component is
  declared twice: with two slots of `Address` on one entity, an unscoped default
  reader would return whichever row the database offered. The cost is one
  `AND slot = ''` per component read. Uniform, per ADR-0015's own argument.
- **`slot` is identity, not state.** The lazy reader presets it on a virtual
  (`user.business_address.slot == "business"` before any write), the dirty rule
  skips it (a preset slot must not make an untouched virtual look dirty), and it
  is never delegated — `user.business_address_slot` does not exist.
- **The registry keys by `(entity, component, slot)`.** `Declaration` gains
  `slot`, `reader_name`, `prefix` and `slot_options`. `Entity.components` lists
  a type once however many slots it has; `component_declarations` lists each
  slot. New: `Entity.declaration_for(Address, prefix: :business)`.
- **Reader collisions now run both ways.** The new reader may not be a name the
  entity already answers (a sibling's reader or delegated method): `component
  Address, prefix: :business` beside a `BusinessAddress` component raises. The
  same `(component, slot)` twice stays a `DuplicateComponent`.
- **`delegate: false`** generates the reader and predicate only. It is recorded
  as `delegate: false` in the declaration's options and rejects `only:`/`except:`
  alongside it (nothing to select from).
- **Presence takes `prefix:`** — `add(Address, prefix: :business)`, `has?`,
  `remove` — and `has?` is slot-scoped in SQL. An undeclared slot is
  `InvalidComponent`, naming the slot. The per-slot predicate
  `user.business_address?` is generated as before.
- **Queries take `prefix:` as sugar for `slot:`** on both `with_component` and
  `without_component`; `with_component(Address)` with no prefix matches any
  slot, as the RFC said. Nothing else changed: slot is a column.
- **Preloading follows declarations.** `includes_components(Address)` preloads
  every slot's `has_one`, one query per slot; the no-argument form preloads
  every declaration. Validation keys are per reader
  (`errors[:"business_address.postcode"]`, "Business address postcode is
  invalid") with no change to RFC-0007.
- **`relates_to` is unaffected**: its backing component sits in the default
  slot with `prefix: false`, so `post.author` is as it was. Backing tables gain
  the `slot` column like every component table, until ADR-0017 retires them.
- **Slot configuration — the one decision ADR-0018 needed.** A component
  declares the options it accepts with `slot_option :name, default:`; the
  declaration site passes them as extra keywords on `component`
  (`component State, prefix: :order, states: %w[pending paid]`); the instance
  reads them back through a generated method (`order_state.states`) or
  `slot_options`. Options are **declared, not inferred**: an unknown keyword on
  `component` raises at declaration time listing the accepted ones, and a
  `slot_option` that would shadow a method or column raises when declared. The
  value resolves through the *owning entity's* declaration, because the same
  class is configured differently on different entities (`State` on an `Order`
  vs on a `Post`) — so there is no class-level answer. Reached through the lazy
  reader, a relationship or a preload, the entity is already in hand and it
  costs nothing; a component loaded standalone (`State.where(...)`) loads its
  entity, one query, which a system that needs options should preload.
- **Generators.** `ecs_rails:component` and `ecs_rails:relationship` emit the
  `slot` column and the `(entity_id, slot)` unique index. The upgrade is
  **`rails g ecs_rails:upgrade`** (not `upgrade_slots`): ADR-0018 makes it the
  only migration a user ever runs after install, and adding slots is its first
  job. It finds component tables by inspecting the database for an `entity_id`
  column and no `slot` column — the registry is empty when a generator runs —
  and writes one migration for all of them, or nothing if every table is
  current. Proven against a real 0.2.x-shaped table in the migration-execution
  spec.
- **Runtime slot accessor: still no.** `Klass.find_or_initialize_by(entity_id:,
  slot:)` at the component-table level is the ECS-shaped answer, as ECS-4
  decided.

**Demo verdict.** The forum's `Group` now declares `Description` twice — a
description and, in the `:rules` slot, house rules — with one `descriptions`
table. `group.rules_description_text` reads fine in the view and the form; the
prefixed slot name is long but says exactly what it is. The 17 existing
component tables were upgraded by one generated migration. See the
[friction log](../friction-log.md).
