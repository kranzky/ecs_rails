# RFC-0002: Component registry

**Status:** Implemented
**Depends on:** nothing

## Goal

A process-wide record of which components exist and which entities declare them,
so that generators, delegation, and (later) systems can introspect the model
without loading the whole app graph.

## Rules

- `EcsRails.registry` returns a singleton `EcsRails::Registry`.
- `registry.register(entity_class:, component_class:, options:)` records one
  declaration. Called by the `component` DSL (RFC-0004).
- `registry.components_for(entity_class)` returns the declarations for that
  entity, in declaration order.
- `registry.entities_for(component_class)` returns every entity class declaring
  it. This is what makes "which entities use `Likes`?" answerable.
- Declaring the same component twice on one entity raises
  `EcsRails::DuplicateComponent`. Registration is **not** idempotent — a duplicate
  is an error, never a silent no-op. (ADR-0004 sets the precedent that
  declaration-time conflicts never pick a silent winner, and "idempotent" has no
  answer when the same pair arrives with different `options:`.)
- A declaration is a value object exposing `entity_class`, `component_class`,
  and `options`, with `==`/`hash` so it is usable in `contain_exactly`.
- `options` is stored opaquely and frozen. Validating it is RFC-0004's job.
- The registry is reset between tests via `registry.clear!`.
- Must survive Rails development-mode class reloading: key entries by class
  **name** (string), not by the class object, and resolve lazily via
  `constantize`. Holding class objects across a reload leaks the old constants.
- **Anonymous classes cannot be registered.** `Class.new(...)` has `name == nil`,
  so there is nothing to key by. Raise `ArgumentError` rather than falling back
  to object identity — that fallback is exactly the leak name-keying exists to
  prevent. **This constrains RFC-0004**: DSL specs must use named classes
  (`stub_const`), not anonymous ones.
- A registered name that no longer resolves **fails loudly** (`NameError`).
  Silently dropping it would make the generator emit an incomplete schema and
  delegation quietly stop working. Because resolution is lazy this asymmetry
  follows: `components_for` never raises, but `.component_class` on the returned
  declaration does; `entities_for` resolves eagerly and so raises directly.

## Tests

```ruby
it "records declarations in order" do
  expect(EcsRails.registry.components_for(User).map(&:component_class))
    .to eq [Name, Email]
end

it "answers the reverse question" do
  expect(EcsRails.registry.entities_for(Likes)).to contain_exactly(Post, Comment)
end

it "rejects a duplicate declaration" do
  EcsRails.registry.register(entity_class: User, component_class: Email)
  expect { EcsRails.registry.register(entity_class: User, component_class: Email) }
    .to raise_error(EcsRails::DuplicateComponent)
end

it "rejects an anonymous class" do
  expect { EcsRails.registry.register(entity_class: Class.new, component_class: Email) }
    .to raise_error(ArgumentError, /anonymous/)
end

it "resolves to the reloaded constant, not the orphaned one" do
  original = Object.const_get(:Email)
  EcsRails.registry.register(entity_class: User, component_class: original)

  # What Rails actually does: remove the constant, autoload a NEW object.
  Object.send(:remove_const, :Email)
  Object.const_set(:Email, Class.new(ApplicationComponent))

  resolved = EcsRails.registry.components_for(User).first.component_class
  expect(resolved).to equal Object.const_get(:Email)  # identity, not ==
  expect(resolved).not_to equal original              # or the test is vacuous
end
```

Note the reload test asserts **both** directions. Without the second assertion
it would still pass against a registry that stored class objects, if the
simulation ever stopped producing a distinct object.

## Non-goals

- Persisting the registry.
- Detecting components with no entity.
- Systems.
- The `component` DSL (RFC-0004). Test `register` directly.

## Status: implemented

Landed. 23 examples. Three spec defects were found and corrected above: the
idempotent-vs-raises contradiction, the anonymous-class impossibility (the
RFC's own duplicate test could not pass under the RFC's own reload rule), and
the unspecified behaviour for names that stop resolving.
