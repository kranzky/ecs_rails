# RFC-0006: Lazy components

**Status:** Ready
**Depends on:** RFC-0004

## Goal

A component should not require a database row if all values equal defaults.

## Rules

- `entity.email` always returns an `Email` instance, never `nil`.
- A missing row produces an in-memory component with every attribute at its
  default and `entity_id` set.
- Saving persists a component **only if** it is dirty — at least one attribute
  differs from its default.
- Reading a virtual component never inserts a row.
- Assigning an attribute a value equal to its default does not dirty it.
- The same instance is returned on repeated reads within one entity instance
  (memoised), so `user.email.address = "x"; user.save!` works.
- `entity.save` cascades: it saves itself and every dirty component, in one
  transaction.
- `component.destroy` deletes the row and resets the component to virtual
  default state. `entity.email` still returns an instance afterwards, and
  `persisted?` is `false`.
- `entity.destroy` removes all component rows via DB cascade.
- Defaults come from the database column defaults, so `Email.new.address` and a
  virtual `user.email.address` agree by construction.

## Tests

```ruby
describe "lazy components" do
  it "returns a virtual component when no row exists" do
    user = User.create!
    expect(user.email).to be_present
    expect(user.email).not_to be_persisted
  end

  it "does not insert a row on read" do
    user = User.create!
    expect { user.email.address }.not_to change(Email, :count)
  end

  it "inserts a row once dirtied and saved" do
    user = User.create!
    user.email.address = "a@b.com"
    expect { user.save! }.to change(Email, :count).by(1)
  end

  it "does not insert when assigned the default value" do
    user = User.create!
    user.email.verified = false   # false is the default
    expect { user.save! }.not_to change(Email, :count)
  end

  it "memoises within one entity instance" do
    user = User.create!
    expect(user.email).to equal user.email
  end

  it "reverts to virtual after destroy" do
    user = User.create!
    user.email.update!(address: "a@b.com")
    user.email.destroy
    expect(user.reload.email).not_to be_persisted
    expect(user.email.address).to be_nil
  end
end
```

## Non-goals

- Query optimisation. Reading N components issues N queries; the demo will tell
  us if that's intolerable.
- Caching.
- Preloading declared components on `User.all`.

## Notes

**The seam already exists.** RFC-0004 includes `generated_component_methods`
into the entity class *after* AR's `GeneratedAssociationMethods`, so it sits
closer to the class and wins. Define the reader there and call `super` to reach
the `has_one` reader underneath. Nothing else moves, and RFC-0005 delegates into
the same module.

**Delete RFC-0004's placeholder.** It pins `expect(User.create!.email).to
be_nil`, which is the *inverse* of this RFC's first rule. RFC-0004 knowingly
violates architecture.md §3 in the interim; landing this RFC is what closes that
gap, and removing that example is how you prove it.

The dirty check must be "differs from default", not ActiveModel's "differs from
the last saved value" — for a new record those coincide, but after
`destroy`-then-reset they do not. Pin this with a test.
