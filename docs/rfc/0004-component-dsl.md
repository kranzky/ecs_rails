# RFC-0004: The `component` DSL

**Status:** Ready
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
  `Rorecs::Entity`.
- It registers the declaration (RFC-0002) and defines a reader named after the
  component's `model_name.singular` — `component Email` → `#email`.
- The reader returns the component instance, materialising it lazily (RFC-0006).
- It sets up the underlying `has_one` against the component class with
  `dependent: :destroy` and `inverse_of: :entity`.
- `only:` and `except:` restrict which methods get delegated (RFC-0005). They do
  **not** affect the reader — `user.group` always exists even with
  `except: [:title]`.
- `only:` and `except:` are mutually exclusive; passing both raises
  `ArgumentError`.
- Declaring a non-`Rorecs::Component` raises `Rorecs::InvalidComponent`.
- Declaring the same component twice raises `Rorecs::DuplicateComponent`
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
  expect(User.create!.email).to be_an Email
end

it "rejects a non-component" do
  stub_const("Thing", Class.new(ApplicationEntity))
  expect { Thing.component String }.to raise_error(Rorecs::InvalidComponent)
end

it "rejects only: and except: together" do
  stub_const("Thing", Class.new(ApplicationEntity))
  expect { Thing.component Email, only: [:a], except: [:b] }
    .to raise_error(ArgumentError)
end

it "keeps the reader even when methods are excluded" do
  expect(User.create!.group).to be_a Group
end

it "inherits declarations from the superclass" do
  expect(Rorecs.registry.components_for(Moderator)).to include(...)
end
```

## Non-goals

- `required: true` — see [ADR-0003](../adr/0003-virtual-components-skip-validation.md).
- Plural components — see [ADR-0005](../adr/0005-one-component-per-entity.md).
- Conditional/polymorphic declaration.
