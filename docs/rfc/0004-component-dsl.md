# RFC-0004: The `component` DSL

**Status:** Implemented
**Depends on:** RFC-0002, RFC-0003

## Goal

```ruby
class User < ApplicationEntity
  component Name
  component Email
  component Group, except: [:title]
end
```

Declare which components an entity is composed from.

## Rules

- `component(klass, only: nil, except: nil)` is a class method on
  `EcsRails::Entity`.
- It registers the declaration (RFC-0002) and defines a reader named after the
  component's `model_name.singular` — `component Email` → `#email`.
- **The reader is the plain `has_one` reader and returns `nil` when no row
  exists.** Making it always return an instance is [RFC-0006](0006-lazy-components.md),
  which is a sibling of RFC-0005 on top of this RFC and therefore cannot be
  depended on here. **Between RFC-0004 and RFC-0006 landing, the gem knowingly
  violates architecture.md §3** ("always returns an instance, never `nil`").
  That is a staging cost, accepted deliberately.
- **The seam for RFC-0006** is `generated_component_methods` — a module included
  into the entity class *after* AR's `GeneratedAssociationMethods`, so it sits
  closer to the class and wins. RFC-0006 defines the reader there and calls
  `super` to reach the `has_one` reader underneath. Nothing else moves.
- It sets up the underlying `has_one` against the component class with
  `inverse_of: :entity` and an explicit `foreign_key: :entity_id`.
- **No `dependent: :destroy`.** architecture.md §3 is binding: the cascade is the
  database's (`ON DELETE CASCADE`). Two layers doing one job means the AR layer
  masks the DB layer — drop the FK and every test would still pass, so the
  invariant stops being tested. `entity.destroy` must issue **no SQL against
  component tables at all**; pin that.
- Declaring an abstract component (e.g. `ApplicationComponent`) raises
  `EcsRails::InvalidComponent`. An abstract component owns no table, so its
  `has_one` could never resolve.
- **Inheritance walks, it does not copy.** The registry keeps exactly what each
  class declared; `Entity.components` walks the superclass chain on read.
  Copying at `inherited` would double-count tables in `entities_for` (breaking
  RFC-0008's generator), miss anything a parent declares after the subclass is
  defined, and duplicate a name-keyed store whose whole purpose is not holding
  stale copies. So `registry.components_for(Admin)` returns only Admin's own —
  `Admin.components` is the question callers actually mean.
- A subclass re-declaring a component its parent already declares raises
  `EcsRails::DuplicateComponent`. ADR-0005 is per entity, and a subclass is an
  entity — it would be a second `has_one` over the same unique `entity_id` row.
- `only:` and `except:` restrict which methods get delegated (RFC-0005). They do
  **not** affect the reader — `user.group` always exists even with
  `except: [:title]`.
- `only:` and `except:` are mutually exclusive; passing both raises
  `ArgumentError`.
- Declaring a non-`EcsRails::Component` raises `EcsRails::InvalidComponent`.
- Declaring the same component twice raises `EcsRails::DuplicateComponent`
  (RFC-0002).
- Subclasses inherit their parent's declarations.
- **Entity classes must be named.** The registry keys by class name, so
  `Class.new(ApplicationEntity) { component Email }` raises `ArgumentError`.
  Specs must use `stub_const` rather than anonymous classes — the example tests
  below are written that way for exactly this reason. If deferring registration
  to `inherited`/`const_added` would lift this restriction, that is a design
  option worth weighing, not a given.

## Tests

```ruby
it "defines a reader named for the component" do
  expect(User.new).to respond_to :email
end

# Not `be_an Email` — a fresh entity has no rows, and returning an instance
# anyway is RFC-0006's job. RFC-0006 must consciously delete this example.
it "returns nil until RFC-0006 lands" do
  expect(User.create!.email).to be_nil
end

it "rejects a non-component" do
  stub_const("Thing", Class.new(ApplicationEntity))
  expect { Thing.component String }.to raise_error(EcsRails::InvalidComponent)
end

it "rejects an abstract component" do
  stub_const("Thing", Class.new(ApplicationEntity))
  expect { Thing.component ApplicationComponent }
    .to raise_error(EcsRails::InvalidComponent)
end

it "rejects only: and except: together" do
  stub_const("Thing", Class.new(ApplicationEntity))
  expect { Thing.component Email, only: [:a], except: [:b] }
    .to raise_error(ArgumentError)
end

it "keeps the reader even when methods are excluded" do
  expect(User.new).to respond_to :group
end

it "uses entity_id, not the inferred user_id, as the foreign key" do
  expect(User.reflect_on_association(:email).foreign_key).to eq "entity_id"
end

# Walks, does not copy — so ask the class, not the registry.
it "inherits declarations from the superclass" do
  expect(Admin.components).to include Email
  expect(EcsRails.registry.components_for(Admin)).to be_empty
end

it "issues no SQL against component tables on destroy" do
  # The DB cascade owns this. If AR also destroys them, dropping the FK
  # would go unnoticed.
end
```

## Non-goals

- `required: true` — see [ADR-0003](../adr/0003-virtual-components-skip-validation.md).
- Plural components — see [ADR-0005](../adr/0005-one-component-per-entity.md).
- Conditional/polymorphic declaration.

## Status: implemented

Landed. 68 examples. Corrections made above, all found by implementing:

- The reader's return value was specified as RFC-0006's behaviour. Two of this
  RFC's own example tests were RFC-0006's tests, filed under the wrong RFC, and
  could not pass here.
- `dependent: :destroy` contradicted architecture.md §3 and would have masked
  the DB cascade. Dropped; the callback gap it leaves is now open question 8.
- The inheritance test presumed the registry copies declarations. It walks.
- Abstract components were unspecified; they now raise.
