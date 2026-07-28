# RFC-0015: Inverse relationships — `has_many` / `has_one`

**Status:** Sketch — *not triggered.* The marketplace demo is expected to force
it; this exists so the shape is on record, not as a build commitment.
**Depends on:** [RFC-0012](0012-relationship-dsl.md) (`relates_to`),
[RFC-0013](0013-relationship-name-query-sugar.md) (query sugar)

## Goal

Give the **parent side** of a `relates_to` link a Rails-shaped reader — a
collection (`has_many`) or a scalar (`has_one`) — over the *same* join table,
adding **no new storage**. Turn today's child-side query

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

- **Not `belongs_to`.** `relates_to :author, User` already *is* belongs_to — FK
  on this side, one target. Covered since RFC-0012.
- **Not `has_one` to a component.** A singular `component Email` is already a
  has_one to the `emails` table. Covered since RFC-0004/0006.
- **Not a new storage model.** No change to [ADR-0005](../adr/0005-one-component-per-entity.md)
  or [ADR-0015](../adr/0015-plural-components-via-slot.md). This is *sugar over
  relationships that already exist* — the inverse view of a `relates_to`, never a
  revival of anonymous plural components (`component many: true`, rejected).

The only genuinely new capability is the **entity → entity inverse**: reaching
from the pointed-at entity back to whoever points at it.

## Mechanism

A `relates_to` relationship is a real join table with a real backing AR model
(`comment_posts`: `entity_id` → the child, UNIQUE; `post_id` → the target). The
parent's primary key *is* the `entities.id` that the target column references, so
the parent can register native ActiveRecord associations over it. `has_many
:comments, Comment, via: :post` expands to:

```ruby
has_many :comment_post_links, class_name: "<Comment's :post relationship model>",
         foreign_key: :post_id
has_many :comments, through: :comment_post_links, source: :entity
```

Because it is native `has_many :through`, the reader is Rails' actual
`CollectionProxy` — `<<`, `build`, `create`, scopes, and **real preloading**
(`Post.includes(:comments)`). The `model = 'comments'` scope comes for free: only
comments ever write a `comment_posts` row, and
[ADR-0008](../adr/0008-subclass-resolution-on-read.md) read-time resolution makes
the source yield `Comment` instances, not generic entities.

`has_one :invoice, Invoice, via: :order` is the same expansion with a `has_one
:through`, returning a scalar (or nil) plus `build`/`create`.

**`has_one` enforces uniqueness at the database.** A true at-most-one guarantee
cannot rest on `.first` — the relationship's target column must be unique. The
constraint is declared on the **child** (which owns the join table):
`relates_to :order, Order, unique: true` adds a unique index on `order_id`, so at
most one `Invoice` can point at a given `Order`. `has_one :invoice, Invoice, via:
:order` on the parent **requires** that the named relationship was declared
`unique: true`, and raises at class-load time otherwise — a missing guarantee
fails loudly, per the [ADR-0004](../adr/0004-delegation-conflicts-raise.md)
declaration-time ethos, rather than silently returning an arbitrary row. Zero
children is still fine (no row); the unique index only forbids a second.

## What you get vs. what you don't

**Get (from AR, ~no custom code):** collection/scalar reader, `<<`, `build`,
`create`, ordering scopes, `includes`/preload, `where` chaining.

**Don't get — state these honestly:**

1. **Counter caches.** AR `counter_cache` is `belongs_to`-only. A cached review
   count still needs a component + callbacks; uncached `.count`/`.size` are just
   queries.
2. **`dependent: :destroy` of the child *entities*.** Rails restricts `dependent`
   on a `through` association. You *can* `dependent: :destroy` the **link** —
   which fixes today's orphan bug, where destroying a parent *nullifies*
   `post_id` and strands the child (see [marketplace design §2](../design/marketplace-demo.md)).
   Destroying the child entities themselves stays an explicit domain choice
   (unlink vs. cascade); for orders/invoices you usually want unlink, not
   destroy.

## Open questions

- **DSL surface.** `has_many :comments, Comment, via: :post` (child + relationship
  name) vs. inferring the child from the reader name. Explicit `via:` is safer
  while a component may be pointed at by several relationships.
- **`dependent` default.** `:nullify` the link (unlink), `:destroy` the link
  (remove the pointer row), or leave it off. Unlink is the conservative default;
  the marketplace's verdict decides.

## Trigger

Build only once the marketplace demo has produced the friction firsthand —
per [PROCESS.md](../../PROCESS.md), "it's in the design" is not a trigger. The
baskets/orders/reviews manys, and the `order.invoice` / `user.basket`
one-to-ones, are the expected forcing functions.
