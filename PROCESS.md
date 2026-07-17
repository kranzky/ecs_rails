# Start with an architecture document

Before writing any code, create a docs/architecture.md that defines the invariants of the system. This becomes the specification that every implementation task refers back to. The clearer these invariants are, the better the AI coding agent will perform.

For example:

```
An Entity:
- Has exactly one row in the entities table.
- Has immutable identity.
- Has a UUID primary key.
- Has no mutable fields.

A Component:
- Owns exactly one database table.
- Belongs to one entity.
- May have no database row.
- Has default values.
- May contain behaviour.

A System:
- Operates over one or more component types.
- Never requires knowledge of entity subclasses.
```

# Treat each feature as an RFC

Rather than asking for code directly, write a short design note for each feature. This keeps each task focused and makes it easier to review the generated code.

For example:

```
RFC 0007

Title:

Lazy Components

Goal:

A component should not require a database row if all values equal defaults.

Rules:
- entity.email always returns an Email instance.
- Missing rows produce an in-memory component.
- Saving persists only if values differ from defaults.
- Destroying resets to the virtual default state.

Non-goals:
- Query optimisation.
- Caching.
```

# Keep commits very small

I’d aim for commits like:

* Add ApplicationEntity
* Add entity migration generator
* Add component registry
* Add component DSL
* Add belongs_to :entity
* Delegate component methods
* Lazy component loading
* Merge validation errors
* Add query builder

Each commit should compile, pass tests, and represent a coherent piece of functionality.

# Write tests before asking for implementation

One workflow that works well is:

1. You write the desired API in tests.
2. The AI coding agent implements it.

This is an executable specification instead of an ambiguous prompt. For example:

```
describe "lazy components" do

  it "returns a virtual component when no row exists" do
    user = User.create!
    expect(user.email).to be_present
    expect(user.email).not_to be_persisted
  end

end
```

# Keep a design backlog

Maintain a list of future ideas without implementing them immediately.

Examples:

* Component queries
* Component scopes
* Component callbacks
* Systems
* Relationships
* Events
* Caching
* Component serialization

This helps avoid feature creep while giving you a roadmap.

# Build the bulletin board alongside the gem

Don’t wait until the gem is “finished.”

A good rhythm is:

1. Implement a feature in the gem.
2. Switch to the demo app.
3. Use the feature in the demo.
4. Note any friction.
5. Improve the gem.
6. Repeat.

If a feature feels awkward in the demo, it’s usually a sign that the API needs refinement.

# Preserve architectural decisions

Whenever you make an important decision, document it.

For example:

```
ADR 001

Component methods execute with self equal to the component, not the entity.

Reason:
Keeps components reusable and unaware of entity subclasses.

Consequences:
Components access the owning entity via #entity when needed.
```
