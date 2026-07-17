# RFC-0002: Component registry

**Status:** Ready
**Depends on:** nothing

## Goal

A process-wide record of which components exist and which entities declare them,
so that generators, delegation, and (later) systems can introspect the model
without loading the whole app graph.

## Rules

- `Rorecs.registry` returns a singleton `Rorecs::Registry`.
- `registry.register(entity_class:, component_class:, options:)` records one
  declaration. Called by the `component` DSL (RFC-0004).
- `registry.components_for(entity_class)` returns the declarations for that
  entity, in declaration order.
- `registry.entities_for(component_class)` returns every entity class declaring
  it. This is what makes "which entities use `Likes`?" answerable.
- Registration is idempotent per `(entity_class, component_class)` pair.
  Declaring the same component twice on one entity raises
  `Rorecs::DuplicateComponent`.
- The registry is reset between tests via `registry.clear!`.
- Must survive Rails development-mode class reloading: key entries by class
  **name** (string), not by the class object, and resolve lazily via
  `constantize`. Holding class objects across a reload leaks the old constants.

## Tests

```ruby
it "records declarations in order" do
  expect(Rorecs.registry.components_for(User).map(&:component_class))
    .to eq [Name, Email]
end

it "answers the reverse question" do
  expect(Rorecs.registry.entities_for(Likes)).to contain_exactly(Post, Comment)
end

it "rejects a duplicate declaration" do
  expect {
    Class.new(ApplicationEntity) { component Email; component Email }
  }.to raise_error(Rorecs::DuplicateComponent)
end

it "survives a class reload" do
  # entries keyed by name, not by object identity
end
```

## Non-goals

- Persisting the registry.
- Detecting components with no entity.
- Systems.
