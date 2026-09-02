# RFC-0015: Inverse relationships — `has_many` / `has_one`

**Status:** Proposed — rewritten 2026-09-02 over the shared `relationships` table.
Previously a sketch gated on demo friction; the [marketplace design](../design/marketplace-demo.md)
already lists six unbounded manys, two one-to-one inverses and a data-integrity
bug, so it is built up front (Linear ECS-6).
**Depends on:** [RFC-0012](0012-relationship-dsl.md) (`relates_to`),
[RFC-0013](0013-relationship-name-query-sugar.md) (query sugar),
[RFC-0014](0014-plural-components.md) (slots), Linear ECS-15 (relationships on
the shared table)
**Decision:** [ADR-0017](../adr/0017-shared-relationships-table.md)

## Goal

Give the **parent side** of a `relates_to` link a Rails-shaped reader — a
collection (`has_many`) or a scalar (`has_one`) — over the shared
`relationships` table, adding **no new storage**. Turn today's child-side query

```ruby
Comment.with_related(:post, @post)          # works, but weak (see below)
```

into

```ruby
class Post < ApplicationEntity
  has_many :comments, Comment, via: :post   # names the child's `relates_to :post`
end

@post.comments                              # a real CollectionProxy
```

## What this is *not*

- **Not `belongs_to`.** `relates_to :author, User` already *is* belongs_to — the
  link is owned by this side, one target. Covered since RFC-0012.
- **Not `has_one` to a component.** A singular `component Email` is already a
  has_one to the `emails` table. Covered since RFC-0004/0006.
- **Not a new storage model.** No change to
  [ADR-0005](../adr/0005-one-component-per-entity.md),
  [ADR-0015](../adr/0015-plural-components-via-slot.md) or
  [ADR-0017](../adr/0017-shared-relationships-table.md). This is *sugar over
  rows that already exist* — the inverse view of a `relates_to`, never a revival
  of anonymous plural components (`component many: true`, rejected).

The only genuinely new capability is the **entity → entity inverse**: reaching
from the pointed-at entity back to whoever points at it.

## Why the child-side query is weak

1. **No collection object.** `with_related` returns a fresh relation, not a
   mutable association: no `post.comments <<`, no `basket.items.build`.
2. **The parent can't see its children.** "Children of X" lives at every call
   site, naming both the child class and the relationship.
3. **Counts are separate queries** that the preload DSL cannot fold in.
4. **Destroying the parent nullifies the link and strands the child.** The
   `target_id` foreign key is `ON DELETE NULLIFY`, so destroying a `Post` leaves
   its `Comment`s pointing at nothing. Parent → child lifecycle must be driven by
   hand.

## Mechanism

Under [ADR-0017](../adr/0017-shared-relationships-table.md) every `relates_to`
is a row in `relationships`: `entity_id` → the child, `slot` = the relationship
name, `target_id` → the parent, `owner_model` = the child's discriminator. The
parent's primary key *is* the `entities.id` that `target_id` references, so the
parent can register native ActiveRecord associations over it.
`has_many :comments, Comment, via: :post` expands to:

```ruby
has_many :comments_post_links,
         -> { where(slot: "post", owner_model: "comments") },
         class_name: "Relationship", foreign_key: :target_id
has_many :comments, through: :comments_post_links, source: :entity
```

**One expansion shape for every inverse.** Because it is native `has_many
:through`, the reader is Rails' actual `CollectionProxy` — `<<`, `build`,
`create`, scopes, and real preloading (`Post.includes(:comments)`).
[ADR-0008](../adr/0008-subclass-resolution-on-read.md) read-time resolution
makes the source yield `Comment` instances, not generic entities.

**`owner_model` on the link scope is load-bearing.** Without it,
`has_many :comments … via: :post` would also collect `Review` rows that use a
slot named `post` on the same table. Pinned with a spec.

**`build` / `<<` must preset the link row.** Appending a child creates a
`relationships` row; the expansion sets `slot`, `owner_model` and `exclusive`
on it (via the link association's scope and a `before_add` callback), or the
row is invalid. The child's own lifecycle — its components — stays separate.

### `has_one`

`has_one :invoice, Invoice, via: :order` is the same expansion with a `has_one
:through`, returning a scalar (or nil) plus `build`/`create`.

**`has_one` enforces uniqueness at the database.** A true at-most-one guarantee
cannot rest on `.first`. The constraint is declared on the **child**, which
owns the row: `relates_to :order, Order, unique: true` writes `exclusive =
true` on that relationship's rows, and the install-time partial unique index
`(target_id, slot, owner_model) WHERE exclusive`
([ADR-0017](../adr/0017-shared-relationships-table.md)) rejects a second
`Invoice` pointing at the same `Order`. `has_one … via: :order` on the parent
**requires** that the named relationship was declared `unique: true`, and
raises at class-load time otherwise — a missing guarantee fails loudly, per the
[ADR-0004](../adr/0004-delegation-conflicts-raise.md) declaration-time ethos,
rather than silently returning an arbitrary row. Zero children is still fine.

No migration is involved at any point: the index exists from install.

### Wildcard: who points at me?

The shared table makes the Flecs `(*, target)` query expressible, which
per-relationship tables could not answer without enumerating every table:

```ruby
Relationship.where(target_id: entity.id)    # every link to this entity, any name
entity.referrers                            # minimal class-level sugar, no DSL
```

Exposed minimally because a safe-destroy check and an orphan audit both want
it. Not a `has_many`; a query.

## What you get vs. what you don't

**Get (from AR, ~no custom code):** collection/scalar reader, `<<`, `build`,
`create`, ordering scopes, `includes`/preload, `where` chaining.

**Don't get — stated honestly:**

1. **Counter caches.** AR `counter_cache` is `belongs_to`-only. A cached review
   count still needs a component (`Counter` under a slot) plus callbacks;
   uncached `.count`/`.size` are just queries.
2. **`dependent: :destroy` of the child *entities*.** Rails restricts
   `dependent` on a `through` association. You *can* `dependent: :destroy` the
   **link rows**, which fixes the orphan bug above: destroying a parent removes
   its links rather than nullifying them. Destroying the child entities
   themselves stays an explicit domain choice (unlink vs. cascade); for orders
   and invoices you usually want unlink, not destroy.

## Tests

```ruby
describe "inverse relationships" do
  it "reads the collection through the shared table" do
    post = Post.create!; c = Comment.create!(post: post)
    expect(post.comments).to contain_exactly(c)
    expect(post.comments.first).to be_a(Comment)          # ADR-0008 through :through
  end

  it "does not collect another entity type using the same slot name" do
    post = Post.create!; Review.create!(post: post)       # Review also relates_to :post
    expect(post.comments).to be_empty
  end

  it "builds a child with the link row preset" do
    c = Post.create!.comments.build
    c.save!
    link = Relationship.find_by!(entity_id: c.id)
    expect(link.slot).to eq "post"
    expect(link.owner_model).to eq "comments"
  end

  it "enforces has_one at the database" do
    order = Order.create!; Invoice.create!(order: order)
    expect { Invoice.create!(order: order) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "refuses has_one over a relationship not declared unique" do
    expect {
      stub_const("Bad", Class.new(ApplicationEntity)).has_one :comment, Comment, via: :post
    }.to raise_error(EcsRails::InvalidRelationship, /unique: true/)
  end

  it "preloads without N+1" do
    expect { Post.includes(:comments).each { |p| p.comments.to_a } }
      .to make_database_queries(count: 2)
  end
end
```

## Open questions

- **DSL surface.** `has_many :comments, Comment, via: :post` (child + relationship
  name) vs. inferring the child from the reader name. Explicit `via:` is safer
  while a target may be pointed at by several relationships. Keep explicit.
- **`dependent` default.** `:nullify` the link (today's behaviour), `:destroy`
  the link (remove the pointer row), or leave it off. Unlink is the conservative
  default; the marketplace's verdict decides.
- **Spike first: subclass resolution through the source.** The `through` source
  targets the shared `entities` table; AR's preload/through construction must
  honour the read-time discriminator ([ADR-0008](../adr/0008-subclass-resolution-on-read.md)'s
  `instantiate_instance_of` override) or `product.reviews` returns generic
  entities. The one new path leaning on private AR internals — verify before
  committing to the expansion.

## Trigger

No longer gated on friction. The marketplace's manys (`basket.items`,
`order.items`, `product.reviews`, `company.products`, `company.employees`,
`user.employments`), its one-to-one inverses (`order.invoice`, `user.basket`)
and the nullify-on-destroy bug are on record; building the demo without this
would mean rewriting checkout and the basket pages afterwards. Lands right after
the shared table (Linear ECS-15).
