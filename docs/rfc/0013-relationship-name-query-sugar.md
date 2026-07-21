# RFC-0013: Relationship-name query & preload sugar

**Status:** Implemented
**Depends on:** RFC-0010, RFC-0011, RFC-0012
**Decision:** [ADR-0014](../adr/0014-relationship-name-query-sugar.md)

## Goal

Query and preload relationships by their declared name, so the backing component
class never appears in application code. Surfaced by the full UI.

## Rules

- `Entity.with_related(name, target = <unset>)` returns a relation of entities
  whose `name` relationship points at `target`.
  - `target` may be an **entity** (its `id` is used) or a bare **id**.
  - With **no** `target`, filters to entities that have the relationship set
    (a backing row exists).
  - Sugar for `with_component(backing, foreign_key => id)` (or
    `with_component(backing)` with no target). Inherits its entity-model scoping
    and `EXISTS` correctness ([ADR-0011](../adr/0011-component-query-dsl.md)).
- `Entity.without_related(name)` — entities with no backing row. Sugar for
  `without_component(backing)`.
- `Entity.includes_related(*names)` — preloads each relationship's backing
  component and its target entity (one hop): `preload(<backing_reader> =>
  <name>)`. Chainable; returns a relation.
- All resolve `name` via relationship metadata recorded by `relates_to`
  (RFC-0012), walked across the entity's ancestry (subclasses inherit).
- An unknown relationship name raises `EcsRails::InvalidRelationship`, naming the
  relationship and the entity's declared relationships.
- Available on the class and a relation (like the component verbs).

## Metadata

`relates_to :author, User` records, for the declaring entity:
`{ name: :author, backing_class_name: "Post::AuthorRelationship",
   foreign_key: :author_id, target_class_name: "User" }`.

Stored by **name** (strings) and resolved via `constantize` on read — reload-safe
in the same way as the component registry (RFC-0002). Ancestry is walked so a
subclass sees its parents' relationships.

## Tests

```ruby
describe "with_related" do
  it "filters by target entity" do
    post = Post.create!; ada = User.create!; post.author = ada; post.save!
    other = Post.create!; other.author = User.create!; other.save!
    expect(Post.with_related(:author, ada)).to contain_exactly(post)
  end

  it "accepts a bare id" do
    post = Post.create!; ada = User.create!; post.author = ada; post.save!
    expect(Post.with_related(:author, ada.id)).to contain_exactly(post)
  end

  it "with no target, filters to entities that have the relationship set" do
    set   = Post.create!; set.author = User.create!; set.save!
    unset = Post.create!
    expect(Post.with_related(:author)).to contain_exactly(set)
  end

  it "is sugar over with_component on the backing class" do
    ada = User.create!
    expect(Post.with_related(:author, ada).to_sql)
      .to eq(Post.with_component(Post::AuthorRelationship, author_id: ada.id).to_sql)
  end

  it "returns only the queried entity type" do
    # NB: this is leak-proof by construction, not by the model scope. Post's and
    # Comment's :author live in DISJOINT backing tables (post_authors vs
    # comment_authors, ADR-0013), so a Post query physically can't return a
    # Comment. Kept as a routing check, not an ADR-0011-style shared-table guard.
    ada = User.create!
    post = Post.create!; post.author = ada; post.save!
    c = Comment.create!; c.author = ada; c.save!
    expect(Post.with_related(:author, ada)).to contain_exactly(post)
  end

  it "raises a named error for an unknown relationship" do
    expect { Post.with_related(:nope, User.create!) }
      .to raise_error(EcsRails::InvalidRelationship, /nope/)
  end

  it "chains with ordinary AR" do
    expect(Post.with_related(:author).order(created_at: :desc)).to be_a ActiveRecord::Relation
  end
end

describe "without_related" do
  it "returns entities with no backing row" do
    set   = Post.create!; set.author = User.create!; set.save!
    unset = Post.create!
    expect(Post.without_related(:author)).to contain_exactly(unset)
  end
end

describe "includes_related" do
  it "preloads the relationship so the target costs no extra query" do
    3.times { p = Post.create!; p.author = User.create!; p.save! }
    rel = Post.all.includes_related(:author)
    expect { rel.each { |p| p.author } }.to issue_queries(3)  # posts + backings + targets
  end

  it "raises for an unknown relationship" do
    expect { Post.includes_related(:nope) }.to raise_error(EcsRails::InvalidRelationship)
  end
end
```

## Non-goals

- **Preloading the target's own components** (`author.name`). `includes_related`
  preloads one hop (backing + target). Deeper stays an explicit nested
  `preload(author_relationship: { author: :name })`, or a later enhancement.
- **Conditions on the target** (`with_related(:author, active: true)`). Filter is
  by identity only. Chain a further `with_component` on the target if needed.
- **`related?` presence predicate.** `entity.author.present?` already answers it.

## Notes from implementation

- **`includes_related` re-derives the backing reader name.** It preloads
  `:"#{name}_relationship" => name`, which hardcodes the `<name>_relationship`
  derivation a second time — strictly at odds with ADR-0014's "one source of
  truth". It is safe only because [ADR-0013](../adr/0013-relationship-dsl.md)
  pins the backing `model_name`, so the reader is always `<name>_relationship`.
  Acceptable, and noted so a future change to the backing reader derivation
  updates both places.
- **`with_related(:author, nil)`** (an explicit nil target, distinct from the
  no-arg form) routes to `with_component(backing, author_id: nil)` — "a backing
  row exists but the target is cleared". Defensible, not a goal; pinned only
  in-code.

## Follow-on

Rewrite the demo controllers to use `with_related` (a post's comments, a user's
posts, a group's members) and `includes_related` where it reads better. Confirm
no `*Relationship` backing class name remains in `app/controllers`.
