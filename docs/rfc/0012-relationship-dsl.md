# RFC-0012: Relationship DSL — relates_to

**Status:** Implemented — storage re-based by [ADR-0017](../adr/0017-shared-relationships-table.md) (see [the amendment](#amendment-the-shared-relationships-table-adr-0017))
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

## Amendment: the shared `relationships` table (ADR-0017)

*2026-09-04, Linear ECS-15.* The API above is unchanged. What changed is
everything under it: there is no backing class, no per-relationship table and
no generator. The Rules and Generator sections describe ADR-0013's storage and
are kept as history; the current rules are:

- **`relates_to :author, User` is `component Relationship, prefix: :author,
  delegate: false, target_class_name: "User", unique: false`.** The slot is the
  relationship name; the reader `author_relationship` is the slot-scoped
  `has_one` every labelled component gets (RFC-0014). The lazy reader presets
  `slot = "author"` on a virtual.
- **`Relationship` is the application's one-line catalogue class** including
  `EcsRails::Catalogue::Relationship` (ADR-0018's shape), written by
  `rails g ecs_rails:install` into the components directory, and found by name
  through `EcsRails.config.relationship_class_name` (default `"Relationship"`).
  `relates_to` without it raises a `NameError` that says what to run.
- **The DSL defines `author`, `author=`, `author_id` and `author_id=` itself**,
  forwarding to the reader's `target` / `target_id`. `delegate: false` keeps the
  component's own `target` off the entity. `Post.create!(author: user)` and
  `author_id:` route through them.
- **The target type is checked on assignment**, by the component, against the
  `target_class_name` slot option: `post.author = team` raises
  `InvalidRelationship` (subclasses of the target are accepted). `belongs_to
  class_name:` used to do this; with one generic `target` column the gem does,
  and must (ADR-0017). `author_id=` is not type-checked.
- **`owner_model` and `exclusive` are stamped in `before_save`**, from the
  owning entity's `model` and the `unique` slot option — not preset on the
  virtual, which would differ from the column defaults and make an untouched
  virtual look dirty (RFC-0006).
- **`unique: true`** (new) writes `exclusive = true`; the install-time partial
  unique index rejects a second owner of the same model pointing at the same
  target under the same slot — `ActiveRecord::RecordNotUnique` — at most one
  Invoice per Order, with no index per relationship.
- **The name is reserved.** `relates_to :author` claims `author`, `author=`,
  `author_id`, `author_id=` through the DSL's `ecs_reserved_names` hook, so a
  later bare component delegating any of them raises `DelegationConflict`; and
  `relates_to` itself refuses a name whose `name` or `name_id` an existing
  reader or delegated method owns.
- **Deletion semantics are unchanged** and now enforced by two foreign keys on
  one table: owner cascades, target nullifies. Two entity types relating the
  same name to the same target share the table and the slot; only `owner_model`
  (and the entity-model scope on queries) tells them apart.
- **`Entity.components` lists `Relationship` once**; `component_declarations`
  lists each relationship's slot. `includes_components(Relationship)` preloads
  every relationship.
- **`ecs_rails:relationship` is deleted.** `ecs_rails:upgrade` gains the data
  move: it creates `relationships` if missing and copies every ADR-0013 backing
  table — recognised by shape (`entity_id`, one `<name>_id`, timestamps) and
  name (`<owner>_<names>`) — into it under the relationship's slot with the
  owner's discriminator, then drops it. Irreversible, and written as `up`/`down`.
- **The install migration is `ecs_rails_install`** (class `EcsRailsInstall`),
  creating `entities` and `relationships`; previously `ecs_rails_create_entities`.

**Demo verdict.** The forum's five relationships moved onto one table with one
generated migration, and no controller, view or seed line changed except the two
raw nested preloads, which name `target` instead of the relationship
(`preload(author_relationship: { target: :name })`). See the
[friction log](../friction-log.md).
