# RFC-0005: Method delegation

**Status:** Ready
**Depends on:** RFC-0004

## Goal

```ruby
user.address            # → user.email.address
user.send_welcome_email # → user.email.send_welcome_email
```

Component methods are callable on the entity.

## Rules

- Delegation is generated **eagerly at declaration time**, into a module that is
  included in the entity class. Not `method_missing`
  ([ADR-0004](../adr/0004-delegation-conflicts-raise.md)).
- The delegated set is the component's public instance methods **and** its
  attribute accessors (readers and writers), minus everything defined by
  `EcsRails::Component` and its ancestors. Only methods the component itself
  declares are delegated.
- `entity_id`, `entity`, `id`, and `created_at`/`updated_at` are never
  delegated.
- `only:` restricts the set; `except:` subtracts from it.
- If two components on one entity would delegate the same name, raise
  `EcsRails::DelegationConflict` at declaration time, naming both components, the
  method, and the `except:` fix.
- A method defined directly on the entity class **wins silently** — no conflict.
  The generated module is included, so Ruby's own lookup handles this.
- Delegation forwards `*args`, `**kwargs`, and `&block`.
- `self` inside the method is the component
  ([ADR-0001](../adr/0001-component-method-binding.md)).

## Tests

```ruby
it "delegates a component method" do
  expect(user.send_welcome_email).to eq :sent
end

it "binds self to the component, not the entity" do
  expect(user.who_am_i).to be_an Email
end

it "delegates attribute writers" do
  user.address = "a@b.com"
  expect(user.email.address).to eq "a@b.com"
end

it "raises on a conflict at declaration time" do
  stub_const("Clash", Class.new(ApplicationEntity))
  Clash.component Name
  expect { Clash.component Group }
    .to raise_error(EcsRails::DelegationConflict, /#title.*Name.*Group/)
end

it "lets except: resolve a conflict" do
  stub_const("Resolved", Class.new(ApplicationEntity))
  Resolved.component Name
  Resolved.component Group, except: [:title]
  expect(Resolved.new.title).to eq "from Name"
end

it "prefers a method defined on the entity itself" do
  expect(user.address).to eq "entity wins"
end

it "does not delegate ActiveRecord plumbing" do
  expect(user.method(:save).owner).not_to be Email
end
```

## Non-goals

- Delegating class methods or scopes.
- Renaming on delegation (`as:`).
- Delegating private methods.

## Notes

**Anonymous classes are unusable here.** RFC-0004's registry keying makes
`Class.new(ApplicationEntity) { component Name }` raise `ArgumentError` — the
class has no name at the moment the block runs. Every example above therefore
uses `stub_const` plus a separate `.component` call. This is a tax paid entirely
in test code; the real API is unaffected.

**Generate into `generated_component_methods`**, the module RFC-0004 already
includes into the entity class after AR's `GeneratedAssociationMethods`. It is
the same seam RFC-0006 uses. Do not create a second one.

**`except:`/`only:` are currently inert and unvalidated.** RFC-0004 checks their
shape but not that the named methods exist — `except: [:titel]` registers
happily and silently does nothing. Validating the names is this RFC's job, since
this is where the method set is finally computed. Decide whether an unknown name
raises or is ignored, and say which.

Computing "methods the component itself declares" is the fiddly part.
`Email.instance_methods(false)` misses methods from modules the component
includes and misses AR-generated attribute methods. Expect to need
`Email.instance_methods - EcsRails::Component.instance_methods` combined with
`Email.attribute_names`, and to have a test pinning the exact resulting set.
