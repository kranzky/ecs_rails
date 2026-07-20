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

---

## Controllers & views

### 🟠 No component query DSL, and `.with` is already taken — 2026-07-18

The first thing a controller needs is "all published posts". The proposal writes
this as `Post.with(PublishState)`. Two problems:

1. **There is no query DSL** — `.with` / `.without` are backlog, not built. So
   the query is hand-rolled across the entity/component split:

   ```ruby
   ids = PublishState.where(state: "published").pluck(:entity_id)
   Post.where(id: ids)
   ```

   Two queries and a manual `pluck`. Workable, and encapsulating it in a
   `Post.published` scope-like class method hides it — but it is exactly the
   boilerplate the proposal's `.with` was meant to remove, and every list view
   needs it.

2. **`Post.with` already exists and means something else.** `ActiveRecord::Relation#with`
   is Common Table Expressions (Rails 7.1+). `Post.respond_to?(:with)` is `true`
   today. So the proposal's headline query syntax **collides with ActiveRecord**
   — a component query DSL cannot reuse `.with` without shadowing CTE support.
   The eventual RFC needs a different verb (`having_component`, `with_component`,
   `composed_of`… tbd) or a scoped namespace (`Post.components.with(...)`).

3. **The hand-rolled query is correct only by accident of the entity's
   default_scope — a real trap.** `PublishState.where(state: "published")` is
   blind to entity type: it matches published PublishStates on *any* entity that
   has one, and the proposal shares PublishState with Group. `Post.published`
   still returns only posts, but purely because the outer `Post.where(id: …)`
   contributes `model = 'posts'` (ADR-0002). Demonstrated: a published Group's
   `entity_id` is in the inner result, yet `Post.published` excludes it. Refactor
   to `ApplicationEntity.where(id:)` or call `Post.unscoped.published` and it
   silently leaks Groups. So a hand-rolled cross-component query is not just
   verbose — its correctness reasoning is non-obvious and easy to break.

**Design requirement this hands the query DSL:** `with_component(PublishState,
state: "published")` (or whatever the verb) must apply the entity-model scope
*itself*, so the caller never has to know the outer scope is load-bearing. Get
this wrong and every such query is a latent cross-entity leak.

This is the single strongest pull toward building the query DSL, and it's the
proposal's hardest feature (a cross-table planner). Logged as the top backlog
item; building the vertical slice with the hand-rolled workaround for now so the
friction is concrete before designing the DSL.

**Resolved (2026-07-19) — [ADR-0011](adr/0011-component-query-dsl.md) /
[RFC-0010](rfc/0010-component-query-dsl.md).** Added `with_component` /
`without_component`:

```ruby
def self.published
  with_component(PublishState, state: "published").order(created_at: :desc)
end
```

Both concerns are handled: the verbs avoid AR's `.with`/`.without` (both taken),
and the entity-model scope is applied automatically — the DSL compiles to a
correlated `EXISTS` on the entity's own default-scoped relation, so the shared
PublishState can't leak from Group into `Post.published`. Verified in the demo:
the index renders the two published posts, excludes the draft, and a published
Group does not leak in. The hand-rolled subquery and its implicit-scope trap are
gone.

### 🟢 app/entities layout — 2026-07-19

Not friction — a proactive layout improvement. Moved entities to `app/entities`
and components to `app/entities/components`, leaving `app/models` for ordinary
Rails models. Cost: one `collapse` line in a generated initializer. Verified
under eager loading; zero runtime change (class names unchanged, so the registry
and discriminator don't notice). Now the gem default —
[ADR-0010](adr/0010-entity-component-directory-layout.md). Confirms the gem is
genuinely layout-agnostic: where a class lives is purely organisational.

### 🟠 N+1 by default in list views — 2026-07-19

The posts index (2 published posts) issued **14 queries**: each post separately
loads Title, Body, Authorship, the author User, its Name, and Likes. This is
architecture.md open question 1 (no preloading) made concrete, and it is very
visible — a component-per-row list view fans out one query per component per
row. For a real feed this is untenable without preloading
(`includes_components`), which is backlog. The single strongest case for it
after the query DSL.

**Resolved (2026-07-20) — [ADR-0012](adr/0012-component-preloading.md) /
[RFC-0011](rfc/0011-component-preloading.md).** The finding that made this cheap:
components are `has_one` associations, and the lazy reader calls `super`, so
**ActiveRecord's native `preload` already works** — a preloaded no-row component
still reads as a virtual. `includes_components` is a thin, component-named
wrapper (preload all declared components, or a named subset; validated, chainable).

The demo's index now preloads its own components plus the nested author-name hop
(`preload(authorship: { author: :name })`, standard AR nesting for a component
reached through a relationship). The payoff is the whole point of preloading —
it is **bounded, not just smaller**:

| Published posts | N+1 | Preloaded |
|---|---|---|
| 2 | 13 | 6 |
| 22 | 93 | 6 |

The real HTTP index request dropped from 14 queries to 8, constant in the number
of posts.

### 🟡 Building an entity from form params is manual — 2026-07-19

A normal Rails controller does `Post.new(post_params)`. With components there is
no mass-assignment across the split, so `create` assigns component by component:

```ruby
post.title.text = post_params[:title]
post.body.text  = post_params[:body]
post.author     = author
post.publish_state.state = ...
```

Delegation helps where an attribute is delegated (`post.author =`), but any
component reached via `except:` (Title/Body's `text`) is hand-assigned. Workable
and explicit, but it's boilerplate Rails developers won't expect, and strong
params (`permit(:title, :body)`) no longer line up 1:1 with the model. A
`post.assign_components(title: {text: ...}, ...)` helper or nested-attributes
support is a plausible future convenience. Logged, not urgent.

### 🟢 The full request cycle works — 2026-07-19

Index (cross-component query), show (delegated reads), new/create (params →
components, validation error merging in the form), and like (component behaviour
`likes.increment!` through a button) all work end to end against a running
server. The gem holds up in a real Rails request cycle, not just in the console.
