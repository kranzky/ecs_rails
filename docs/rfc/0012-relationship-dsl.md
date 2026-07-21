# RFC-0012: Relationship DSL — relates_to

**Status:** Implemented
**Depends on:** RFC-0004, RFC-0005, RFC-0008
**Decision:** [ADR-0013](../adr/0013-relationship-dsl.md)

## Goal

Declare a cross-entity link in one line on the entity, with no relationship
component file. Replaces the demo's `Authorship` / `MemberUser` / `MemberGroup`
boilerplate.

## Rules

- `relates_to(name, target_class)` is a class method on `EcsRails::Entity`.
- It dynamically defines a backing component class
  `Entity::<Name>Relationship` (a real named constant), with:
  - `self.table_name = "#{model_name.singular}_#{name.to_s.pluralize}"` —
    `post_authors`, `membership_users`.
  - `belongs_to name, class_name: target_class.name, foreign_key: :"#{name}_id",
    optional: true`.
- It then declares that component (`component <backing>`), so the whole stack
  applies: registry, lazy reader, delegation, `with_component`, presence,
  `includes_components`.
- Delegation surfaces the target: `entity.<name>` and `entity.<name>=`.
- `target_class` must be a concrete `EcsRails::Entity`; otherwise
  `EcsRails::InvalidComponent` (or a dedicated `InvalidRelationship` — pick one,
  see Open below). A component or a plain class is rejected.
- `name` must not collide with an existing reader/delegated method on the entity
  (the reader-collision rule, RFC-0005). Two `relates_to :author` on one entity,
  or `relates_to :author` plus a component exposing `author`, raises
  `DelegationConflict`.
- Subclasses inherit `relates_to` declarations (same as `component`).
- Reload-safe: the backing class is defined in the entity body and recreated on
  reload; the registry resolves by name.

## Generator

`rails g ecs_rails:relationship OWNER name:Target` —
`rails g ecs_rails:relationship Post author:User`:

- Emits a migration creating `post_authors`:
  - uuid PK,
  - `entity_id` uuid **not-null**, unique index, `on_delete: :cascade` FK to
    `entities` (the owner side — architecture.md §2 / ADR-0005),
  - `author_id` uuid, indexed, `on_delete: :nullify` FK to `entities` (the
    target side — deleting the target nullifies, does not cascade),
  - timestamps.
- Does **not** write a component file.
- Prints: add `relates_to :author, User` to `app/entities/post.rb`.

## Tests

```ruby
describe "relates_to" do
  # A `posts_editors`-style table exists in the test schema for a fixture entity.
  it "reads and writes the target" do
    post = Post.create!; user = User.create!
    post.author = user
    post.save!
    expect(post.reload.author).to eq user
  end

  it "returns nil when unset (belongs_to, not a lazy component target)" do
    expect(Post.create!.author).to be_nil
  end

  it "defines a backing component that with_component sees" do
    post = Post.create!; post.author = User.create!; post.save!
    expect(Post.with_component(Post::AuthorRelationship)).to include(post)
  end

  it "nullifies on target deletion, does not cascade to the owner" do
    post = Post.create!; user = User.create!
    post.author = user; post.save!
    user.destroy
    expect(Post.exists?(post.id)).to be true
    expect(post.reload.author).to be_nil
  end

  it "rejects a non-entity target" do
    expect { Class.new(ApplicationEntity).relates_to(:x, String) }
      .to raise_error(EcsRails::InvalidComponent)   # or InvalidRelationship
  end

  it "raises on a name collision" do
    klass = stub_const("Dup", Class.new(ApplicationEntity))
    klass.relates_to :author, User
    expect { klass.relates_to :author, User }.to raise_error(/author/)
  end

  it "the join entity reads cleanly" do
    m = Membership.create!; u = User.create!; g = Group.create!
    m.user = u; m.group = g; m.save!
    expect([m.reload.user, m.group]).to eq [u, g]
  end
end
```

## Non-goals

- **Relationship-name query/preload sugar** — `with_related(:author)`,
  `includes_related(:author)`. Use the backing class
  (`with_component(Post::AuthorRelationship)`) for now. Backlog.
- **`has_many`-style relationships.** A relationship is singular (ADR-0005);
  many-to-many is a join entity. No plural `relates_to`.
- **Polymorphic targets** (`relates_to :subject, [User, Post]`). One target class.
- **Nullify/cascade configurability.** Fixed: cascade on the owner side, nullify
  on the target side.

## Resolved during implementation

- **Error class:** added `InvalidRelationship < InvalidComponent`. Strictly
  better than either posed option — the message is relationship-shaped, while a
  `rescue InvalidComponent` (and the contract test) still matches, because a
  relationship *is* a component underneath.
- **The backing reader name** is `author_relationship`, but only because
  `relates_to` pins the backing class's `model_name` to the demodulized element.
  The naive derivation yields `post_author_relationship` (namespace leaks in).
  See the [ADR-0013 note](../adr/0013-relationship-dsl.md). It is the correct
  key for `includes_components(Post::AuthorRelationship)` and
  `preload(author_relationship: { author: :name })`.
- **Exact-duplicate collision** (`relates_to :author` twice) is caught by a
  dedicated pre-flight check *before* `const_set`, naming `:author` — the
  existing `detect_delegation_conflict!` skips it (its self-conflict guard sees
  the same backing class name) and the registry's `DuplicateComponent` would
  name the CamelCase class instead. A `component`-then-`relates_to` name clash is
  caught by the same guard.

## Follow-on

Delete the demo's `authorship.rb`, `member_user.rb`, `member_group.rb`; rewrite
`Post`, `Comment`, `Membership` with `relates_to`. Regenerate the migrations
(`post_authors`, `comment_authors`, `membership_users`, `membership_groups`).
Update the index's nested preload to the new backing-reader name. Confirm the
demo still serves and the query counts hold.
