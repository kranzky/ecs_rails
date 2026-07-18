# Demo Friction Log

The v0.1 hypothesis is: **is modelling a real Rails app out of components
actually pleasant?** This log is the answer, recorded while building the
bulletin-board demo against the finished gem (PROCESS.md's loop: model a slice →
feel the API → note friction → fix the gem → repeat).

Each entry is dated, rated, and says whether it was fixed, deferred to the
backlog, or accepted as a known cost. "Friction" includes pleasant surprises —
they are evidence too.

Rating: 🟢 pleasant · 🟡 papercut · 🟠 real friction · 🔴 blocker

---

## Setup

### 🟢 `ecs_rails:install` — 2026-07-18

One command, three files, ran without incident on the first real Rails app (not
the test harness). The migration is heavily commented with links back to the
architecture doc, which is the right call for a generated file someone will read
once and wonder about. No notes.

### 🟢 `ecs_rails:component`, including a zero-attribute marker — 2026-07-18

`rails g ecs_rails:component Moderator` (no attributes) produces a valid table —
`entity_id` + timestamps, unique index, cascade FK. The generator does not choke
on an empty attribute list. Good.

---

## Modelling

### 🔴 Marker components cannot be persisted — 2026-07-18

**The proposal's headline example does not work.** From `proposal.html`:

> Administrator and Moderator become marker components. No STI required.

A marker component has no state — only `entity_id`, which the dirty rule
([ADR-0003](adr/0003-virtual-components-skip-validation.md#amendment)) excludes
as identity. So a marker is **never `ecs_dirty?`**, and RFC-0006's cascade never
persists it. The meaning of a marker is *the row existing* ("this user is a
moderator"), and the row can never come to exist through the natural path:

```ruby
user.moderator      # read it
user.save!          # writes nothing — no moderators row
user.moderator.persisted?   # => false, forever
```

**Worst of all, it fails silently.** No error; the marker just never sticks.

Workarounds that do work, neither discoverable:
- `user.moderator.save!` — saving the component directly bypasses the cascade's
  dirty check.
- `Moderator.create!(entity: user)` — plain ActiveRecord.

There is no presence API: no `user.has?(Moderator)`, no `user.add(Moderator)`,
no `user.moderator?`. For a marker, presence *is* the data, and the gem has no
verb for it.

**This needs a design decision, not just a patch** — the shape of a
presence/membership API is a real fork. Gathering the rest of the sharp-case
friction first, then taking the options to the user. Tracked as the top item for
the next RFC.

**Resolved (2026-07-18) — [ADR-0009](adr/0009-component-presence.md) /
[RFC-0009](rfc/0009-component-presence.md).** Presence is now a first-class,
explicit operation:

```ruby
user.add(Moderator)      # persist the row (idempotent, immediate)
user.moderator?          # => true
user.has?(Moderator)     # => true
user.remove(Moderator)   # destroy it
```

Verified in the demo: `user.moderator?` / `user.administrator?` toggle correctly,
markers persist and clear, and `add` validates (so you cannot `add` an empty
required component). The proposal's "No STI" claim now actually works — a user is
a moderator exactly when the row exists, no `type` column, no subclass hierarchy.
The demo *added* a feature the proposal implied but never specified, which is the
loop working as intended.

### 🟠 Attribute auto-delegation collides constantly — 2026-07-18

Modelling `Post` from the proposal (Title, Body, Author, PublishState, Likes)
raises at boot:

```
EcsRails::DelegationConflict: #text is defined by both Title and Body on Post.
```

`Title` has `text:string`, `Body` has `text:text` — both perfectly natural — and
[RFC-0005](rfc/0005-method-delegation.md) delegates every attribute accessor to
the entity, so both want `post.text`. The conflict detection
([ADR-0004](adr/0004-delegation-conflicts-raise.md)) is doing exactly its job,
and catching this at boot is genuinely good.

But it exposes a design tension the proposal glosses over: **attribute names
collide far more readily than method names.** Behaviour methods
(`send_welcome_email`) are distinctive; attribute names are generic — `text`,
`name`, `title`, `body`, `count`, `state`, `url`. Auto-delegating all of them
means any two components sharing an obvious attribute name cannot sit on one
entity without an `except:`. In a component-first design, that collision is the
common case, not the edge case.

The `except:` escape hatch works, but resolving `Title`+`Body` this way is
asymmetric and ugly — `component Body, except: [:text]` makes `post.text` mean
the *title's* text while the body's is reachable only via `post.body.text`. The
clean resolution is to except `:text` on *both*, forcing `post.title.text` /
`post.body.text` — which is arguably how it should read anyway.

**Second design decision for the batch:** should attribute delegation be
opt-in rather than automatic? Behaviour-only delegation by default would make
`post.title.text` the norm and `post.text` something you ask for. Logged; taking
it to the user with the marker decision.

Resolved for now by excepting `:text` on both Title and Body.

**Decision (2026-07-18): keep attribute delegation automatic.** `user.address`
is a headline DX feature and worth the collision cost. Collisions already raise
loudly at boot (ADR-0004), never silently — so the failure mode is acceptable,
and being forced to name a top-level accessor deliberately (`except:` on both)
is arguably healthy. This becomes a **documentation** matter, not a gem change:
the docs will teach `except:`-on-both as the standard pattern for two components
that share an attribute name. No RFC.

### 🔴→🟢 Relationship component recursed infinitely; fixed, and the fix is nicer — 2026-07-18

Modelling `Author` exactly as [ADR-0006](adr/0006-relationships-are-plain-components.md)
wrote it:

```ruby
class Author < ApplicationComponent
  belongs_to :author, class_name: "User", foreign_key: :author_id
end

class Post < ApplicationEntity
  component Author   # ...
end
```

`post.author` raised `SystemStackError` — **infinite recursion**. `component
Author` generates a reader `author` (returns the Author component), and RFC-0005
delegates Author's `belongs_to :author` method, *also* `author`, into the same
module — silently overwriting the reader with a method that then calls the
reader, i.e. itself. The gem's own worked ADR example was a landmine.

Two fixes:

1. **Gem (fixed now):** a component reader name is reserved. A delegated method
   colliding with it raises `DelegationConflict` at declaration time — the same
   fail-loud stance as [ADR-0004](adr/0004-delegation-conflicts-raise.md) —
   instead of overwriting and recursing. Regression tests added (a `Sponsor`
   fixture with the collision), 386 green. ADR-0006 amended.

2. **Modelling (nicer):** name the component for the *relationship* and the
   association for the *target* — `Authorship` with `belongs_to :author`. Then:

   | Expression | Is |
   |---|---|
   | `post.authorship` | the Authorship component |
   | `post.author` | **the User** (delegated) |
   | `post.author = user` | sets it (delegated writer) |

   `post.author` returning a User is exactly what you'd want — so the collision
   was pointing at a better design all along. Verified end to end.

### 🟢 Shared component types and behaviour — 2026-07-18

`Likes` on both `Post` and `Comment`, `Name` on both `User` and `Group`,
`Authorship` on `Post` and `Comment`. All work, same class and same behaviour
(`likes.increment!`) on every host. This is the proposal's central claim —
reuse without inheritance — and it holds cleanly. No friction.

### 🟢 Join entity (Membership) — 2026-07-18

The proposal models many-to-many as a join *entity*, forced by ADR-0005 (one
component instance per entity). It works cleanly:

```ruby
class Membership < ApplicationEntity
  component MemberUser    # belongs_to :user
  component MemberGroup   # belongs_to :group
  component Role
end

m = Membership.create!
m.user  = alice           # delegated
m.group = rubyists        # delegated
m.role.name = "admin"
m.save!
m.user.name.first         # => "Alice"
```

### 🟡 The proposal's "Membership = User, Group, Role" can't be literal — 2026-07-18

The proposal lists Membership as composed of `User`, `Group`, `Role`. But `User`
and `Group` are entity *classes* — a component cannot share their names. So the
relationship components need distinct names (`MemberUser`, `MemberGroup`), and
the `Authorship` naming rule from ADR-0006 applies: name the association for the
target so `membership.user` / `membership.group` still read naturally. A
papercut in translating the proposal, not a gem problem — worth a note in the
eventual relationship-DSL RFC, which could let `relates_to :user, User` hide it.
