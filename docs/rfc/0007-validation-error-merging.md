# RFC-0007: Validation error merging

**Status:** Ready
**Depends on:** RFC-0006

## Goal

`user.valid?` reflects its components' validity, and `user.errors` reads
naturally in a Rails form.

## Rules

- A **non-dirty virtual** component is not validated at all
  ([ADR-0003](../adr/0003-virtual-components-skip-validation.md)).
- A dirty or persisted component is validated when the entity is validated.
- Component errors merge onto the entity namespaced by the component reader:
  `user.errors[:"email.address"]`.
- `user.errors.full_messages` produces readable text — `"Email address can't be
  blank"`, not `"Email.address can't be blank"`.
- `user.save` returns `false` and inserts nothing if any validated component is
  invalid. The whole cascade is one transaction.
- `user.valid?` must not have side effects — it must not insert rows or dirty
  anything.

## Tests

```ruby
it "is valid with an untouched virtual component" do
  expect(User.create!).to be_valid
end

it "is invalid once a component is dirtied badly" do
  user = User.create!
  user.email.address = "not-an-email"
  expect(user).not_to be_valid
  expect(user.errors[:"email.address"]).to be_present
end

it "produces readable full messages" do
  expect(user.errors.full_messages).to include("Email address is invalid")
end

it "rolls back the whole cascade on failure" do
  user = User.new
  user.email.address = "bad"
  expect { user.save }.not_to change(ApplicationEntity, :count)
end

it "has no side effects" do
  user = User.create!
  expect { user.valid? }.not_to change(Email, :count)
end
```

## Non-goals

- `accepts_nested_attributes_for`.
- Custom error key formats.
- Validating that a component *exists* — that's an entity-level concern.
