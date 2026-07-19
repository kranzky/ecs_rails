# RFC-0010: Component query DSL — with_component / without_component

**Status:** Implemented
**Depends on:** RFC-0001, RFC-0003
**Decision:** [ADR-0011](../adr/0011-component-query-dsl.md)

## Goal

Query entities by which components they have, so `Post.with(PublishState)` from
the proposal has a real, correct implementation. Surfaced by the demo: every
list view hand-rolls a cross-component subquery whose correctness silently rides
the entity's `default_scope`.

## Rules

- `Entity.with_component(ComponentClass, **conditions)` returns a relation of
  entities that **have a row** for that component. With `conditions`, the row
  must also match them (equality/hash, like `where`).
- `Entity.without_component(ComponentClass)` returns entities with **no row**.
  (No conditions form — "without a matching row" is ambiguous and unneeded; see
  Non-goals.)
- Both return an `ActiveRecord::Relation`, chainable with `where`, `order`,
  `limit`, and each other. Multiple `with_component` calls **AND** together.
- Both compile to `EXISTS` / `NOT EXISTS` correlated subqueries
  ([ADR-0011](../adr/0011-component-query-dsl.md)).
- The entity-model scope is applied automatically — not by the DSL, but because
  the method runs on the entity's own relation, which already carries
  `model = '<plural>'`. **A shared component must not leak across entity types.**
- `ComponentClass` must be a concrete `EcsRails::Component`; otherwise
  `EcsRails::InvalidComponent` (this covers a non-component *and* an abstract
  component, which owns no table). It need **not** be declared on the entity:
  `Post.with_component(Avatar)` when Post has no Avatar is a valid, (usually)
  empty query, not an error — a component table can hold a row for any
  entity_id. This is deliberately asymmetric with `has?`
  ([ADR-0009](../adr/0009-component-presence.md)), which raises for an undeclared
  component; the ADR explains why.
- Available on both the class (`Post.with_component`) and a relation
  (`Post.where(...).with_component(...)`), since AR delegates class methods to
  relations.

## Tests

```ruby
describe "with_component" do
  it "returns entities that have the component row" do
    p1 = Post.create!; p1.publish_state.state = "published"; p1.save!
    p2 = Post.create!  # no publish_state row
    expect(Post.with_component(PublishState)).to contain_exactly(p1)
  end

  it "filters by component attribute conditions" do
    pub = Post.create!; pub.publish_state.state = "published"; pub.save!
    dft = Post.create!; dft.publish_state.state = "draft"; dft.save!
    expect(Post.with_component(PublishState, state: "published")).to contain_exactly(pub)
  end

  it "does not leak a shared component across entity types" do
    # PublishState on both Post and Group (the demo's exact trap).
    post  = Post.create!;  post.publish_state.state  = "published"; post.save!
    group = Group.create!; group.publish_state.state = "published"; group.save!
    expect(Post.with_component(PublishState, state: "published")).to contain_exactly(post)
    expect(Post.with_component(PublishState, state: "published")).not_to include(group)
  end

  it "compiles to EXISTS, not a join (no duplicate rows)" do
    p = Post.create!; p.publish_state.state = "published"; p.save!
    expect(Post.with_component(PublishState).to_sql).to match(/EXISTS/i)
    expect(Post.with_component(PublishState).count).to eq 1
  end

  it "chains and ANDs" do
    a = Post.create!; a.publish_state.state = "published"; a.likes.count = 1; a.save!
    b = Post.create!; b.publish_state.state = "published"; b.save!  # no likes row
    result = Post.with_component(PublishState, state: "published").with_component(Likes)
    expect(result).to contain_exactly(a)
  end

  it "composes with ordinary AR" do
    expect(Post.with_component(PublishState).order(created_at: :desc)).to be_a ActiveRecord::Relation
  end

  it "rejects a non-component" do
    expect { Post.with_component(String) }.to raise_error(EcsRails::InvalidComponent)
  end
end

describe "without_component" do
  it "returns entities with no row for the component" do
    with    = Post.create!; with.publish_state.state = "x"; with.save!
    without = Post.create!
    expect(Post.without_component(PublishState)).to contain_exactly(without)
  end

  it "compiles to NOT EXISTS" do
    # Allow a paren: the Arel-negation form renders `NOT (EXISTS (...))`. The
    # string-embedding form used here renders `NOT EXISTS`. Either is correct;
    # don't over-pin the whitespace. See the ADR's implementation trade-off.
    expect(Post.without_component(Avatar).to_sql).to match(/NOT\s*\(?\s*EXISTS/i)
  end

  it "treats a virtual (unpersisted) component as absent" do
    p = Post.create!
    p.publish_state   # read it — still no row (RFC-0006)
    expect(Post.without_component(PublishState)).to include(p)
  end
end
```

## Non-goals

- **Preloading.** These filter; they do not load component data. Separate
  backlog item, composes on top.
- **Non-equality conditions** (`count > 5`, ranges, `IN`). Hash equality only in
  v1. A block or a relation argument is the likely later shape.
- **Conditions on `without_component`.** "Entities without a *matching* row" is
  ambiguous (no row at all? a row that fails to match?) and unneeded.
- **Query optimisation** (architecture.md §7). `EXISTS` on an indexed
  `entity_id` is fine; no planner is promised.
- **`or` / disjunction across components.** All `with_component` calls AND. `OR`
  can wait for evidence it is needed.

## Follow-on

Rewrite the demo's `Post.published`:

```ruby
def self.published
  with_component(PublishState, state: "published").order(created_at: :desc)
end
```

removing the hand-rolled subquery and its implicit-scope trap.
