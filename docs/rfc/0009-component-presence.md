# RFC-0009: Component presence — add / has? / remove / predicate

**Status:** Implemented
**Depends on:** RFC-0004, RFC-0006
**Decision:** [ADR-0009](../adr/0009-component-presence.md)

## Goal

Make component presence a first-class operation, so marker components
(`Moderator`, `Administrator`) work and so `has?`/`remove` are available for
every component. Surfaced by the demo: the natural marker path
(`user.moderator; user.save!`) silently persists nothing.

## Rules

- `entity.add(ComponentClass)` — ensures a row exists for that component on the
  entity, and returns the (now persisted) component instance.
  - Persists **immediately**, not on the next `save`.
  - **Idempotent**: if a row already exists, returns it without inserting a
    second (the unique `entity_id` index would forbid one anyway) and without
    error.
  - **Validates**: uses `save!`, so `add` on a component with unmet validations
    raises `ActiveRecord::RecordInvalid`. `add(Moderator)` (no validations)
    always succeeds; `add(Email)` (address required) raises. This is correct —
    you cannot add an empty required component.
  - Only accepts a component the entity declares; otherwise
    `EcsRails::InvalidComponent`.
- `entity.has?(ComponentClass)` — `true` iff a row exists. Does not materialise
  or persist anything.
- `entity.remove(ComponentClass)` — destroys the row if present; idempotent (no
  error if absent). Resets the reader to a virtual default instance, exactly as
  `component.destroy` does in RFC-0006. Returns the entity.
- `entity.<reader>?` — a generated per-component predicate, equal to
  `has?(ThatComponent)`. `user.moderator?`, `user.email?`.
- `add`/`has?`/`remove` accept the component **class**, matching Flecs and the
  registry. (A symbol form is a possible later convenience; not in this RFC.)
- Presence reflects the database. `has?` and the predicate query unless the
  component is already loaded on this instance (then the memo answers). No query
  optimisation (architecture.md §7).

## Interaction with the memo (RFC-0006)

- `add` populates the entity's component memo with the persisted instance, so a
  subsequent `entity.moderator` returns it without a second query.
- `remove` resets the memo entry to a virtual instance, matching
  `component.destroy`.
- `has?` consults the memo first: a component dirtied-and-saved this instance is
  present without a fresh query; an untouched one is a `SELECT 1`-style
  existence check that must **not** load or dirty anything.

## Tests

```ruby
describe "component presence" do
  it "adds a marker that the save cascade never would" do
    user = User.create!
    expect { user.add(Moderator) }.to change { Moderator.where(entity_id: user.id).count }.by(1)
    expect(user.moderator?).to be true
    expect(user.has?(Moderator)).to be true
  end

  it "is idempotent" do
    user = User.create!
    user.add(Moderator)
    expect { user.add(Moderator) }.not_to change(Moderator, :count)
  end

  it "removes a marker and resets to virtual" do
    user = User.create!
    user.add(Moderator)
    user.remove(Moderator)
    expect(user.moderator?).to be false
    expect(user.moderator).not_to be_persisted
  end

  it "remove is idempotent when absent" do
    user = User.create!
    expect { user.remove(Moderator) }.not_to raise_error
  end

  it "validates on add" do
    user = User.create!
    expect { user.add(Email) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects a component the entity does not declare" do
    user = User.create!
    expect { user.add(PublishState) }.to raise_error(EcsRails::InvalidComponent)
  end

  it "has? does not materialise or dirty an untouched component" do
    user = User.create!
    expect { user.has?(Email) }.not_to change(Email, :count)
    # and issues no INSERT; a bare existence check
  end

  it "the predicate equals has?" do
    user = User.create!
    user.add(Moderator)
    expect(user.moderator?).to eq user.has?(Moderator)
  end
end
```

## Notes

- **`add` requires a persisted entity.** On a `User.new`, `id` is `nil` and the
  component's `NOT NULL entity_id` would fail. `add` is an imperative act on a
  saved entity; the tests `create!` first. A component row cannot point at an
  entity that does not exist yet.
- **Presence is per-instance, like every read.** `has?` and `add` answer from
  this instance's memo or a fresh query; a row inserted by another process after
  this instance read a virtual is the ordinary stale-memo situation `reload`
  cures everywhere else, not something specific to presence.

## Non-goals

- A `marker` DSL keyword — [ADR-0009](../adr/0009-component-presence.md) rejects
  it. A marker is an ordinary empty component.
- Deferred presence (`add` staged until `save`). `add` is immediate.
- Bulk `add([A, B, C])` / symbol arguments. Later, if wanted.
- `required: true` at declaration — still backlog (ADR-0003). Presence is
  imperative, not a declared invariant.
