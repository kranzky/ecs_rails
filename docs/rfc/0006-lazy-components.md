# RFC-0006: Lazy components

**Status:** Implemented
**Depends on:** RFC-0004

## Goal

A component should not require a database row if all values equal defaults.

## Rules

- `entity.email` always returns an `Email` instance, never `nil`.
- A missing row produces an in-memory component with every attribute at its
  default and `entity_id` set.
- Saving persists a component **only if** it is dirty — at least one attribute
  differs from its default. **Corrected while implementing:** *state* attributes
  only. The primary key and `entity_id` are excluded — see "Status" below.
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

## Status: implemented

Landed. 73 examples; 297 across the suite. The feature works and the API reads
the way the proposal promised. Four corrections, all found by implementing:

**1. "At least one attribute differs from its default" is false as written, and
the two dirty definitions do not coincide for a new record.** Both claims above
rest on the same wrong assumption. Building a virtual component sets
`entity_id`, and that differs from its column default (`nil`) — so *every*
virtual component is dirty under this RFC's literal rule, and every read would
insert a row. ActiveModel agrees, for the same reason: `user.email.changed?` is
`true`, with `changes == {"entity_id" => [nil, user.id]}`, on a component nobody
has touched. So the two definitions diverge immediately rather than only after a
destroy-then-reset, and both fail in the direction that guts the feature. The
rule needs the concept the RFC never names: the foreign key and the primary key
are *identity*, not state, and only state can dirty a component.

**2. "Differs from default" is only correct while there is no row.** Once the
row exists the question really is ActiveModel's, because there is now a saved
value to differ from: `user.name.first = nil` on a persisted `Name` is an UPDATE
back to the column default, and "differs from default" answers "not dirty" and
silently discards it. The rule is per-state: no row → compare to defaults; row →
`changed?`. The RFC presents one rule for both.

**3. The RFC's own destroy example passes without the reset it specifies.** It
reloads (`user.reload.email`) before asserting, and reload rebuilds everything
regardless — so it tests nothing about resetting. architecture.md §3 is the
stricter and correct statement: `entity.email` returns a virtual instance
*immediately* after `entity.email.destroy`, no reload. That needs real work
(ActiveRecord leaves the destroyed object frozen and still holding its values,
and the has_one is still caching it); an `after_destroy` on the component tells
the entity to drop both caches. Pinned without a reload in `lazy_spec.rb`.

**4. Failure handling was unspecified, and every obvious option is wrong.**
"Saves itself and every dirty component, in one transaction" says nothing about
a component that will not save. `throw :abort` escapes an `after_save` as an
`UncaughtThrowError` (after-callbacks cannot halt a chain). ActiveRecord's own
autosave idiom, `raise ActiveRecord::Rollback`, is swallowed by the transaction
`save` itself opened — making **`entity.save!` return `nil` and raise nothing**,
a silent failure to write. The cascade therefore calls `component.save!`.

Verified end state (the report earlier in this file overstated the wart):
`entity.save` returns `false`, `entity.save!` raises `RecordInvalid`, and a new
entity with an invalid component writes **zero** rows — the whole cascade is
atomic. The save/save! contract is already correct.

**The real remaining gap is narrower, and is exactly RFC-0007's job:**
`entity.valid?` still returns `true` for an entity whose dirty component is
invalid, and no errors are merged. So the contract currently holds *by accident*
— the `after_save` cascade's `component.save!` raises, and `save` rescues it —
rather than by `valid?` failing first. **RFC-0007 must make `valid?` reflect
component validity and merge the errors**, so `save` returns `false` *before*
the cascade runs rather than by catching an exception thrown deep inside it, and
`entity.errors` reads naturally in a form. The bang then becomes belt-and-braces,
exactly as ActiveRecord's autosave is.

**Test-harness bug, fixed in passing.** `spec_helper.rb` wrapped each example in
a *joinable* transaction, so any transaction opened inside an example merged
into it instead of taking a savepoint, and rollbacks were silently swallowed —
rows survived. Every atomicity assertion in this suite would have passed whether
the code rolled back or not. Now `joinable: false`, which is what Rails'
`use_transactional_tests` sets, for exactly this reason.
