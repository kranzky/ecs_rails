# RFC-0007: Validation error merging

**Status:** Implemented
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

## Status: implemented

Landed. 43 examples. The RFC's own five example tests pass verbatim.

Scope was narrower than first written: RFC-0006 had already made the save/save!
contract correct and atomic, so this RFC only had to make `valid?` reflect
component validity and merge the errors, so the contract holds by `valid?`
failing *first* rather than by the cascade's `component.save!` raising.

Key decisions:
- `valid?` validates only the components already in the entity's memo (the ones
  read on this instance), and of those the dirty or persisted ones. It does not
  walk declared components — materialising an unread one would be a side effect
  and would validate something the caller never touched. A bad persisted row the
  caller has not loaded is therefore not validated by `valid?`; its own
  validations guard it at save time.
- The error key (`email.address`) and the full message (`Email address is
  invalid`) genuinely diverge, and ActiveModel couples them. Merged each error
  under the namespaced key, and overrode `human_attribute_name` to humanise the
  whole dotted key — `"email.address".tr(".", "_").humanize` → `"Email
  address"`. Deferring to the component's own `human_attribute_name` gives the
  wrong casing ("Email Address").

Found: the label guard must key on the **generated reader method**
(`method_defined?`), not the registry. The registry is a mutable process-wide
singleton the Railtie clears on reload; reading it from a hot method
(`human_attribute_name` runs per form field) is fragile in production, not just
in tests. This is the registry landmine surfacing a third time — now sealed
centrally by a snapshot/restore baseline in spec_helper.
