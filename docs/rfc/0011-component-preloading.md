# RFC-0011: Component preloading — includes_components

**Status:** Implemented
**Depends on:** RFC-0004, RFC-0006
**Decision:** [ADR-0012](../adr/0012-component-preloading.md)

## Goal

Batch component loads so a list view issues a bounded number of queries instead
of one per component per row. Surfaced by the demo: the 2-post index fired 14
queries.

## The finding this RFC rests on

ActiveRecord's native `preload` **already works** with the lazy reader (each
component is a `has_one`, and RFC-0006's reader calls `super`). `includes_components`
is a thin, discoverable wrapper — see [ADR-0012](../adr/0012-component-preloading.md).
Half of this RFC's job is regression tests that pin the native path.

## Rules

- `Entity.includes_components(*component_classes)` preloads the given components
  and returns a chainable relation.
- **No arguments preloads every declared component** of the entity (walking the
  inherited declarations, RFC-0004).
- Takes component **classes** (`includes_components(Name, Email)`), consistent
  with `with_component` / `add` / `has?`.
- Uses `preload` (separate queries), not `includes`/`eager_load`.
- Each class must be a component **declared on the entity**; otherwise
  `EcsRails::InvalidComponent`, naming the component — not AR's
  `AssociationNotFoundError`.
- A preloaded component with no row still reads as a **virtual** instance through
  the lazy reader (RFC-0006), never `nil`.
- Composes with `with_component`, `where`, `order`, and further chaining.

## Tests

```ruby
describe "includes_components" do
  # Regression: the native path this wraps must keep working.
  it "native preload batches and still returns virtuals" do
    3.times { |i| u = User.create!; u.name.first = "U#{i}"; u.save! }
    User.create! # no name row
    expect { User.all.preload(:name).each { |u| u.name.first } }
      .to issue_queries(2)                    # users + names, not 5
    novirtual = User.all.preload(:name).detect { |u| u.name.first.nil? }
    expect(novirtual.name).to be_a(Name)
    expect(novirtual.name).not_to be_persisted
  end

  # NB: in the gem fixtures User declares Name, Email, Group, Moderator — NOT
  # Avatar (that's Post's). Read only User's own components here.
  it "preloads all declared components with no args" do
    2.times { |i| u = User.create!; u.name.first = "U#{i}"; u.email.address = "e#{i}@x.com"; u.save! }
    rel = User.all.includes_components
    expect { rel.each { |u| [u.name.first, u.email.address, u.group.title, u.moderator?] } }
      .to issue_queries(1 + User.components.size)   # users + one per declared component
  end

  it "preloads a named subset" do
    2.times { |i| u = User.create!; u.name.first = "U#{i}"; u.email.address = "e#{i}@x.com"; u.save! }
    expect { User.all.includes_components(Name, Email).each { |u| [u.name.first, u.email.address] } }
      .to issue_queries(3)                    # users + names + emails
  end

  it "rejects a real component the entity does not declare" do
    # Avatar is a real component, but declared on Post, not User.
    expect { User.includes_components(Avatar) }
      .to raise_error(EcsRails::InvalidComponent, /Avatar/)
  end

  it "rejects a component declared on no entity" do
    expect { User.includes_components(PublishState) }
      .to raise_error(EcsRails::InvalidComponent, /PublishState/)
  end

  it "rejects a non-component" do
    expect { User.includes_components(String) }.to raise_error(EcsRails::InvalidComponent)
  end

  it "composes with with_component" do
    u = User.create!; u.name.first = "Ada"; u.email.address = "a@b.com"; u.save!
    expect { User.with_component(Name).includes_components(Name, Email).each { |x| [x.name.first, x.email.address] } }
      .to issue_queries(3)
  end

  it "is chainable and returns a relation" do
    expect(User.all.includes_components(Name)).to be_a ActiveRecord::Relation
  end
end
```

(`issue_queries(n)` is a thin sql.active_record-counting matcher; define it in
the spec support if not already present — the query-counting helper already used
elsewhere can be promoted.)

## Non-goals

- **Nested relationship preloading.** `post.author.name` (author reached through
  the `Authorship` relationship component) is two hops out; the no-arg form does
  not chase it. Use standard AR nesting (`preload(authorship: { author: :name })`).
  A relationship-aware nested preloader is a later item, paired with the
  relationship DSL.
- **`includes`/`eager_load` (JOIN) semantics.** Deliberately `preload` only.
  Developers wanting a JOIN call `eager_load` on the association names directly.
- **Query optimisation** (architecture.md §7). Bounded query *count*, not tuning.
- **Auto-preloading** (declaring some components always-preloaded). Explicit only.

## Follow-on

The demo's posts index gains `.includes_components` (its own components), and the
author-name hop is handled with a nested `preload`. Confirm the index query count
drops from 14 to a bounded handful, and record it in the friction log.
