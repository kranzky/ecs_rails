# RFC-0014: Labelled (plural) components

**Status:** Proposed
**Depends on:** RFC-0002 (registry), RFC-0004 (component DSL), RFC-0005 (delegation), RFC-0006 (lazy components), RFC-0008 (generators), RFC-0009 (presence), RFC-0010 (query)
**Decision:** [ADR-0015](../adr/0015-plural-components-via-slot.md)

## Goal

Let a component type be declared more than once on an entity under distinct
labels, each label a singleton with its own prefixed reader — without weakening
any singular guarantee. Unlocks the naturally multi-role components from the
standard-library survey (`Phone`, `PostalAddress`, `Token`, …).

```ruby
class User < ApplicationEntity
  component PostalAddress                      # user.postal_address
  component PostalAddress, prefix: :business   # user.business_address
  component Phone,         prefix: :mobile     # user.mobile_phone
  component Phone,         prefix: :work       # user.work_phone
end
```

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
    names get long (`business_address_postal_code`). The default slot keeps
    today's unprefixed delegation (`postal_address` → `line1`), unchanged.
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
- **Delegated-name shape.** Reader-prefixed (`business_address_line1`, used here)
  vs label-prefixed (`business_line1`). Reader-prefixed keeps the component type
  legible in the method name; it is longer, which is exactly what `delegate:
  false` answers.
- **Default slot value.** `""` (used here) vs the component's own singular name.
  `""` keeps the default reader at exactly `postal_address` with zero prefix
  logic and removes any chance of a label colliding with the component's own
  name.

## Follow-on

Once shipped, the standard-library generators (`Phone`, `PostalAddress`, `Token`)
can assume labelled use. Add a demo entity that exercises two slots of one
component (a `User` with `postal_address` + `business_address`) so the friction
log has a real verdict on prefixed delegation.
