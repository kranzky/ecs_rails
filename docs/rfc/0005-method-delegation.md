# RFC-0005: Method delegation

**Status:** Implemented
**Depends on:** RFC-0004, RFC-0006

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
- `only:` restricts the set; `except:` subtracts from it. **Naming an attribute
  covers its whole accessor pair** — `except: [:title]` removes both `title` and
  `title=`. Without this, `except: [:title]` would leave a `title=` clash and the
  conflict would still raise; `models.rb`'s own `component Group, except:
  [:title]` could not load, and neither could the RFC's own resolution test.
- **An unknown name in `only:`/`except:` raises `ArgumentError` at declaration
  time.** A mistyped `except:` silently fails to resolve a real conflict, and a
  mistyped `only:` silently delegates nothing — both are exactly the silent
  action-at-a-distance ADR-0004 forbids. In v0.1 a component is a single shared
  class with a fixed method set, so the "method exists only on some versions"
  case cannot arise. Excepting an identity column also raises — it is not
  delegable.
- If two components on one entity would delegate the same name, raise
  `EcsRails::DelegationConflict` at declaration time, naming both components, the
  method, and the `except:` fix. Detection runs **before** registration, so a
  rejected declaration leaves the class untouched — no half-registered reader.
  (A component must be explicitly excluded from conflicting with itself, or a
  duplicate declaration reports a self-conflict instead of the
  `DuplicateComponent` ADR-0005 wants.)
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

Computing "methods the component itself declares" is the fiddly part, and the
formula this RFC originally suggested — `Email.instance_methods -
EcsRails::Component.instance_methods` plus `attribute_names` — is a **trap**. It
is clean only *before* AR lazily generates a component's attribute methods; once
those exist it also yields `address_was`, `address_changed?`,
`saved_change_to_address?` and ~140 more, every one of which would become a
delegated method on the entity.

The working shape is a **union, not a subtraction**:

```
behaviour = component.public_instance_methods(true)
          - EcsRails::Component.public_instance_methods(true)
          - component.generated_attribute_methods.instance_methods(false)
accessors = attribute_names.flat_map { |a| [a, :"#{a}="] }
delegated = (behaviour + accessors) - never_delegated
```

where `never_delegated` is the primary key, `entity_id`, `created_at`,
`updated_at` (with writers), and `entity`/`entity=`. Pin the exact resulting set
with a test, and include a component with a method from an *included module* —
`instance_methods(false)` would miss it.

## Status: implemented

Landed. 42 examples; 339 across the suite. The sugar works and reads the way the
proposal promised — `user.send_welcome_email` and `user.address = "x"` both go
straight through to the component. Corrections and decisions, all forced by
implementing:

**1. `only:`/`except:` must be attribute-aware — and the RFC's own resolution
test is what forces it.** The RFC describes `except:` as subtracting names from
the set, which reads as a literal filter. It cannot be one. `Name` and `Group`
both carry a `title` *column*, so each delegates `#title` **and** `#title=`. A
literal `except: [:title]` removes only the reader, leaving `#title=` still
clashing — so the RFC's own "lets except: resolve a conflict" test
(`component Group, except: [:title]`, no error) would *raise*, and worse, the
host app's `class User` in models.rb would fail to load for the same reason. So
naming an attribute in `only:`/`except:` covers its whole accessor pair. This is
load-bearing and was unstated; it is now the behaviour and is pinned.

**2. Unknown `only:`/`except:` names raise, at declaration time.** The RFC handed
this decision to the implementer. Raising is the only choice consistent with
ADR-0004: a mistyped `except: [:titel]` that silently does nothing fails to
resolve a real conflict, and a mistyped `only:` silently delegates nothing —
both are exactly the silent action-at-a-distance ADR-0004 exists to forbid. In
v0.1 a component is a single shared class with a fixed method set, so an unknown
name is always a mistake. Excepting an identity column (`entity_id`) raises too:
it is not in the delegable set, so naming it is meaningless.

**3. The delegable set is a union, not a subtraction, because AR's dirty-tracking
helpers poison the subtraction.** `Email.instance_methods -
EcsRails::Component.instance_methods` is clean *only until* ActiveRecord lazily
generates a component's attribute methods — after which it also yields
`address_was`, `address_changed?`, `saved_change_to_address?` and ~140 more, all
of which would become delegated methods on the entity. The set is computed as
behaviour (instance methods, minus Component's, minus the AR-generated attribute
module) ∪ explicit accessors from `attribute_names`. Reading the generated
attribute module is private AR API, in the same bargain as ADR-0008: pinned by
the exact-set tests, so a Rails upgrade fails loudly rather than silently
widening the surface.

**4. A component does not conflict with itself.** Conflict detection runs before
registration (so a clash leaves the class untouched), which means declaring the
same component twice would report "#address is defined by both Email and Email"
instead of the `DuplicateComponent` (ADR-0005) the registry raises a line later.
The same-component case is skipped in conflict detection so the duplicate check
owns it.

**On the API feel.** `user.send_welcome_email` delivers exactly the headline
sugar, and `self` staying the component (ADR-0001) means `Email.pending.each(&:
send_welcome_email)` and `user.send_welcome_email` run identical code. The
conflict-raises-loudly behaviour feels protective rather than annoying *because*
the escape hatch is one word (`except: [:title]`) and the message names the fix
verbatim — the cost of a clash is a one-line edit at the declaration, paid once,
in CI, with both culprits named.
