# Design: Marketplace demo

**Status:** Draft — revised 2026-09-02 for the **zero-migrations** goal
**Depends on:** [RFC-0014](../rfc/0014-plural-components.md) (labelled components — *not yet built*),
[ADR-0017](../adr/0017-shared-relationships-table.md) (shared relationships table — *not yet built*),
[ADR-0018](../adr/0018-catalogue-in-the-gem.md) (the catalogue in the gem — *not yet built*),
[RFC-0015](../rfc/0015-inverse-relationships.md) (inverse relationships — *not yet built*)

> **The v2 goal, 2026-09-02.** The marketplace is now the proof of a sharper
> claim than "exercise every feature": **after `rails g ecs_rails:install` and
> one `db:migrate`, the whole marketplace is built with no further migrations.**
> Every component below comes from the catalogue ([ADR-0018](../adr/0018-catalogue-in-the-gem.md)),
> every `relates_to` is a row in the shared `relationships` table
> ([ADR-0017](../adr/0017-shared-relationships-table.md)), every marker a row in
> `markers`, and `demo/db/migrate` contains exactly one file. Linear: ECS-3
> (epic), ECS-14 (design). Sections below that predate the revision are marked.

The bulletin board is the smallest thing that proved ECS is pleasant on Rails.
The marketplace is the next question: does the model *scale up* to a real
transactional domain — sellers, inventory, baskets, checkout, payment, invoices,
orders, reviews — without the composition story falling apart? It is also the
first demo that consumes **best-of-breed standard components** rather than
one-off local ones, which is the whole point of the blog's closing argument.

The existing forum survives as a subset: a `Review` is a `Comment` with a rating,
and a `Product` page's discussion is the bulletin board, re-skinned.

---

## 1. What the demo must show off

The brief is "as much of the framework and as many bundled components as
possible." Mapped to concrete features:

| Framework capability | Where the marketplace exercises it |
|---|---|
| Singular components | `Product` price, `Company` description, everywhere |
| Marker components (ADR-0009) | `PublishState`-style listing state, `Moderator` reused |
| **Plural / labelled components (RFC-0014)** | `User` and `Order` carry `billing_address` + `shipping_address`; `User` carries `mobile_phone` + `work_phone` |
| Relationships (`relates_to`, ADR-0013) | `Product → Company`, `Review → Product/User`, order lines |
| Join entities (ADR-0005) | `BasketItem`, `OrderItem` — the *unbounded* collections |
| Query DSL (`with_component`/`with_related`, RFC-0010/0013) | "my orders", "a company's products", "listed products" |
| Preloading (RFC-0011/0013) | product grid renders price + seller + review count |
| **Standard components (the catalogue)** | `Money`, `PostalAddress`, `Phone`, `Geolocation`, `Text`, `Identifier`, `Counter`, `Rating`, `Timestamp`, `State`, … — **every** component, from the catalogue ([ADR-0018](../adr/0018-catalogue-in-the-gem.md)); nothing demo-local |
| **Zero migrations after install** | `ls demo/db/migrate` → one file |
| Behaviour-carrying components (ADR-0001) | `OrderState` state machine transitions itself |
| Composition over inheritance | one `User` is **customer and employee at once** — no `Customer`/`Employee` subclass; `Employment` layers on the seller capability |
| Component reuse across entity types | the forum's `Role` component serves both `Membership` (groups) and `Employment` (companies) |
| **Entity-blind systems** | `Geocoder` fills `Geolocation` from `PostalAddress` in one sweep over the component table — users and companies alike, no entity class named |
| Systems (the "S", still POROs) | `Checkout` — validate basket, take payment, place order, issue invoice; `CompanyPolicy` — role-based authorization; `Geocoder` — geocoding |

---

## 2. Domain model

Nouns are entities; everything an entity *has* is a component or a relationship.
The rule that governs every "many" here is **ADR-0005 / ADR-0015**: a fixed,
named role is a *labelled component slot*; an unbounded collection is a *join
entity*. Getting that split right is most of the design.

### Entities

```
User        (existing, extended)
Company     seller / storefront
Product     a listing owned by a Company
Review      a Product's rating + prose (a Comment with stars)
Basket      a User's current, unplaced selection
BasketItem  join: Basket × Product (+ quantity)          ← unbounded collection
Order       a placed, paid Basket — frozen
OrderItem   join: Order × Product (+ quantity + price snapshot) ← unbounded
Invoice     the document issued for an Order
Employment  join: User × Company (+ role)  — who may sell for a company
```

### Components per entity

```ruby
class User < ApplicationEntity          # existing + additions
  component Name
  component Email
  component Avatar
  component Bio
  component Moderator
  component Administrator
  # NEW — requires RFC-0014:
  component PostalAddress, prefix: :shipping   # user.shipping_address
  component PostalAddress, prefix: :billing    # user.billing_address
  component Phone,         prefix: :mobile      # user.mobile_phone
  component Phone,         prefix: :work        # user.work_phone
end

class Company < ApplicationEntity
  component Name
  component Description
  component Avatar                              # logo
  component Email
  component Phone
  component PostalAddress                       # registered address (singular)
end

class Product < ApplicationEntity
  component Text,       prefix: :title          # product.title_text (catalogue Text, ADR-0018)
  component Text,       prefix: :body           # product.body_text
  component Money                               # the price (singular)
  component Identifier, prefix: :sku
  component Counter,    prefix: :stock          # available quantity
  component State,      prefix: :listing        # draft / listed / delisted
  relates_to :seller, Company
end

class Review < ApplicationEntity
  component Body                                # review.body_text (prefixed, ADR-0016)
  component Rating                              # 1..5 stars
  component Likes                               # reused from forum
  relates_to :author,  User
  relates_to :product, Product
end

class Basket < ApplicationEntity
  relates_to :customer, User, unique: true      # one open basket per user (has_one inverse)
end

class BasketItem < ApplicationEntity            # join entity, unbounded
  relates_to :basket,  Basket
  relates_to :product, Product
  component Quantity
end

class Order < ApplicationEntity
  component OrderNumber
  component Money                               # total, frozen at checkout
  component OrderState                          # pending → paid → shipped → …
  component PostalAddress, prefix: :shipping    # snapshot at time of order
  component PostalAddress, prefix: :billing     # snapshot at time of order
  relates_to :customer, User
end

class OrderItem < ApplicationEntity             # join entity, unbounded
  relates_to :order,   Order
  relates_to :product, Product
  component Quantity
  component Money                               # unit price snapshot
end

class Invoice < ApplicationEntity
  component InvoiceNumber
  component Money                               # total (mirrors the order)
  component IssuedAt
  component PostalAddress, prefix: :billing     # snapshot
  relates_to :order, Order, unique: true        # one invoice per order (has_one inverse)
end

class Employment < ApplicationEntity            # join entity (like Membership)
  relates_to :user,    User
  relates_to :company, Company
  component Role
end
```

### How an unbounded "many" works today — and why it hurts

The forum already has unbounded manys (a post's comments, a group's members),
and it is worth being precise about how they are built, because the marketplace
has far more of them and they carry money.

A "many" is expressed **only from the child side**. `Comment` declares
`relates_to :post, Post`, which creates a backing relationship component in a
`comment_posts` table — one row per comment, `entity_id` (the comment, UNIQUE)
pointing at `post_id` (the post). That gives the *forward* reader `comment.post`.
There is **no inverse**: a `Post` has no `comments` reader and does not know its
comments exist. To get them you query from the child:

```ruby
@comments = Comment.with_related(:post, @post)   # a class-level EXISTS query
```

This works, but it is materially weaker than a Rails `has_many`, and every
weakness compounds in a transactional domain:

1. **No collection object.** `with_related` returns a fresh relation, not a
   mutable association. There is no `post.comments <<`, no `basket.items.build`,
   no ordering or counter owned by the parent. Adding a child is always: create
   the child entity, then wire the link explicitly
   (`item.relate(:basket, basket)`).
2. **The parent can't see its children.** "Children of X" knowledge lives at
   every call site, naming both the child class and the relationship
   (`OrderItem.with_related(:order, order)`). Nothing on `Order` advertises that
   `OrderItem`s point at it. Rename or add a child type and there is no one place
   to update.
3. **Counts and aggregates are separate queries.** A product's review count is
   `Review.with_related(:product, p).count` — one query per product, not a
   preloadable counter cache. A product grid showing review counts is an N+1 the
   preload DSL cannot fold in.
4. **No `dependent: :destroy` — and the FKs actively orphan.** This is the sharp
   edge. The `comment_posts` table has *two* FKs to `entities`: `entity_id` (the
   comment) is `ON DELETE CASCADE`, but the *target* `post_id` is
   `ON DELETE **NULLIFY**`. So destroying a `Post` does **not** destroy its
   comments; it sets each `comment_posts.post_id` to `NULL`, leaving orphaned
   `Comment` entities that point at nothing and no longer answer any
   `with_related` query. For a forum that is untidy. For an `Order` whose
   `OrderItem`s nullify away — or a `Product` still referenced by live orders —
   it is a data-integrity bug. Parent→child lifecycle must be driven by hand (a
   System destroying the children first), because the framework offers no
   cascade from the parent side.

None of this blocks the demo — the forum runs on it — but the marketplace is
where the missing inverse-association ergonomics and the nullify-on-target
lifecycle stop being cosmetic. Its manys — `basket.items`, `order.items`,
`product.reviews`, `company.products` — and its one-to-one inverses —
`order.invoice`, `user.basket` — are exactly the `has_many` / `has_one` the
parent side is missing today.

> **Revised 2026-09-02.** This section originally said to build on the raw
> child-side query first and let friction justify RFC-0015. The list above *is*
> the friction, on record; waiting would mean rewriting checkout and the basket
> pages. [RFC-0015](../rfc/0015-inverse-relationships.md) is built **up front**,
> over the shared `relationships` table ([ADR-0017](../adr/0017-shared-relationships-table.md)),
> before the marketplace pages (Linear ECS-6). The per-relationship `comment_posts`
> table described above no longer exists under ADR-0017; the nullify-on-target
> behaviour is unchanged, and `dependent: :destroy` on the link rows is the fix.

### Why the "manys" are join entities, not plural components

This is the single most important modelling call, and the one most likely to be
argued with (ADR-0005 predicted exactly this):

- A basket holds an **arbitrary** number of products → `BasketItem` entities.
  RFC-0014's non-goals are explicit: *"Anonymous unbounded collections … is a
  has-many to child entities — a relationship — not a labelled component."*
- An order holds an arbitrary number of lines → `OrderItem`.
- A company lists an arbitrary number of products → `Product` is its own entity
  with `relates_to :seller`.
- A product accrues an arbitrary number of reviews → `Review` is its own entity.

Plural components appear **only** where the roles are *fixed and named*:
`billing_address` vs `shipping_address`, `mobile_phone` vs `work_phone`. Two
slots, known at class-definition time — never "N of them."

### Employees, roles, and the user who is also a customer

This is the marketplace's cleanest demonstration of the whole premise, and the
blog's headline claim made concrete. The person selling on the platform and the
person buying on it are the **same `User` entity**. Being a *customer* is
emergent — you are one the moment you have a `Basket` or place an `Order`; there
is no `Customer` type to be. Being an *employee* is having an `Employment` — a
join entity linking you to a `Company` with a `Role`. The two coexist on one
entity with nothing to reconcile: exactly the "a customer who is also a member of
staff" case that has no branch to sit on in an inheritance tree. No
`Customer < User`, no `Employee < User`, no diamond.

`Employment` is the seller-side twin of the forum's `Membership` —
`User × Company × Role`, same proven shape:

```ruby
class Employment < ApplicationEntity
  relates_to :user,    User
  relates_to :company, Company
  component   Role                 # name: "owner" | "manager" | "staff"
end
```

Both directions are unbounded: a company has many employees, and a user may be
employed by more than one company (and shop from all of them). So
`company.employees` and `user.employments` are two more `has_many`s — RFC-0015
again — and the *authorization* lookup is a two-hop `with_related` today,
mirroring the forum's `group.show` member list:

```ruby
# may this user act for this company, and in what capacity?
Employment.with_related(:user, current_user)
          .with_related(:company, company)
          .includes_components(Role)
          .first&.role
```

**Roles gate capability, not identity.** A proposed default set (adjustable):

| Role | Can |
|---|---|
| `owner` | everything, incl. manage employees and the company profile |
| `manager` | list / edit / delist products, adjust stock, view and fulfil orders |
| `staff` | view inventory (incl. drafts and stock), fulfil orders — no listing or pricing |

Authorization is an **app-layer System** — a plain `CompanyPolicy` PORO that
reads `Employment.role`. It is not an ECS feature and needs no gem support. The
`Role` component stays generic (a `name` string, reused verbatim from the forum
— itself a tidy demonstration of one component type shared across two different
join entities); the marketplace meaning of each name lives in the policy, not the
component, keeping the component ignorant of any entity subclass (architecture
§1). Customer-side shopping stays ungated; employment is the *extra* capability
layered on the same user.

Optional audit hook: `Product relates_to :listed_by, User` records which employee
created a listing, distinct from `relates_to :seller, Company` (who owns it).
Nice-to-have, not required.

---

## 3. New components

### Standard (catalogue-grade — the ones worth sharing)

| Component | Shape | Standard |
|---|---|---|
| `Money` | `amount_cents:integer`, `currency:string(3)` | ISO 4217; integer minor units, never a float |
| `PostalAddress` | `line1, line2, locality, region, postcode, country` | schema.org `PostalAddress` |
| `Phone` | `e164:string`, `extension:string` | E.164 |
| `Geolocation` | `lat:decimal`, `lng:decimal`, `geocoded_at:datetime` | WGS 84; filled by the Geocoder system (§4), paired to a `PostalAddress` by slot |

These are the components the blog promises: *"installed rather than written."*
They are authored **demo-first for shape** (friction-driven, per PROCESS.md),
then promoted to **gem concerns** — not generators — and created by the install
migration ([ADR-0018](../adr/0018-catalogue-in-the-gem.md), revised 2026-09-02).
A `Money` that carries `+`, formatting, and a currency-mismatch guard is the
first real test of behaviour-carrying components pulling their weight (ADR-0001).

`Geolocation` is deliberately a *separate* component from `PostalAddress` rather
than columns on it: it is derived, populated asynchronously by a system, and
pairs with its address by **sharing the same slot** (RFC-0014) — so
`company.registered_address` has a `company.registered_geolocation` beside it.
That pairing is what lets one entity-blind system geocode every address in the
system regardless of who owns it (§4).

### ~~Small, demo-local~~ — now generic catalogue components under slots

*Revised 2026-09-02.* Under the zero-migrations goal there are **no demo-local
components**. What this section listed as one-offs are catalogue shapes under
slots ([ADR-0018](../adr/0018-catalogue-in-the-gem.md) §5): `Sku`,
`OrderNumber`, `InvoiceNumber` → `Identifier` under slots `sku` /
`order_number` / `invoice_number`; `Stock`, `Quantity` → `Counter`; `Rating`
stays `Rating`; `IssuedAt` → `Timestamp` under slot `issued_at`;
`ListingState`, `OrderState`, the forum's `PublishState` → one `State`
component (status + transitions log) under slots `listing` / `order` /
`publish`. The forum's `Title`, `Body`, `Bio`, `Description` → `Text`;
`Likes` → `Counter`; `Moderator`, `Administrator` → `marker`. The forum is
rebuilt on the catalogue first (Linear ECS-17) so that generic naming is judged
before the marketplace multiplies it.

### `State` — the state-machine component

The catalogue's `State`, made concrete: a `status:string` plus a
`transitions:jsonb` log of `{at, from, to, event}`. Behaviour lives on the
component (ADR-0001). The catalogue concern carries `transition!` and the log;
the *vocabulary* of states for an order is the entity's business, declared
where the slot is (`component State, prefix: :order, states: %w[…]` or a
per-entity module — decided when built). Sketched as a bespoke class for
legibility:

```ruby
class OrderState < ApplicationComponent   # illustrative; really State under slot :order
  STATES = %w[pending paid shipped delivered cancelled].freeze

  def pay!    = transition!("paid")
  def ship!   = transition!("shipped")
  def cancel! = transition!("cancelled")

  private

  def transition!(to)
    self.transitions = transitions + [{ at: Time.current, from: status, to:, }]
    self.status = to
  end
end
```

`order.pay!` delegates in; the entity never learns the transition table.

---

## 4. Checkout — the first real System

Checkout is where the "S" earns its place. It is a plain PORO (the gem still
offers no system base class — see backlog), operating over components:

```ruby
class Checkout
  def self.call(basket:, payment_method:)
    ApplicationEntity.transaction do
      order = Order.create!
      order.relate(:customer, basket.customer)
      order.shipping_address.assign_attributes(basket.customer.shipping_address.attributes)
      order.billing_address.assign_attributes(basket.customer.billing_address.attributes)

      total = 0
      basket.items.each do |item|
        line = OrderItem.create!
        line.relate(:order, order)
        line.relate(:product, item.product)
        line.quantity.count = item.quantity.count
        line.money.assign_attributes(item.product.money.attributes)  # freeze price
        line.save!
        total += line.money.amount_cents * item.quantity.count
      end

      order.money.amount_cents = total
      PaymentGateway.charge!(order, payment_method)   # simulated, deterministic
      order.order_state.pay!
      order.save!

      Invoice.issue_for(order)
      basket.clear!
      order
    end
  end
end
```

Two things this surfaces deliberately:

1. **Price snapshotting.** `OrderItem` copies the product's `Money` at checkout.
   Components are mutable rows; a later price edit must not rewrite history. The
   snapshot is a copy, never a `relates_to` back to the live price.
2. **The systems gap.** There is no scheduling, idempotency, or retry convention
   for `Checkout`. That is honest and is exactly the friction that would justify
   promoting Systems off the backlog.

### A second system: entity-blind geocoding

If `Checkout` shows a system orchestrating one transaction, the geocoder shows
the property that makes ECS systems distinctive — and is the demo's clearest
argument for the whole approach. A component table is **blind to entity type**,
so a system that queries the *component* processes every entity's instance in a
single sweep, without ever naming an entity class.

`PostalAddress` sits on both `User` (one, the default slot) and `Company`
(several — `registered`, `warehouse` — via RFC-0014 slots). Each address has a
`Geolocation` beside it in the *same* slot. The geocoder fills them all:

```ruby
class Geocoder
  def self.run
    # one query over the shared table — users and companies alike
    PostalAddress.where(geocoded: false).find_each do |addr|
      point = lookup(addr)                             # simulated, deterministic
      loc = addr.entity.geolocation(slot: addr.slot)   # the sibling, same slot
      loc.lat, loc.lng = point.lat, point.lng
      loc.save!
    end
  end
end
```

It never mentions `User` or `Company`. It reads the component, and reaches the
owner only through `component.entity` (architecture §3) to find the sibling
`Geolocation` in the matching slot. Whether an address belongs to a user with one
or a company with five is invisible to it — which is precisely the point, and the
thing an inheritance-shaped model cannot do without a base class or a visitor.
Like payment, the lookup is **simulated and deterministic** — no external
service, no keys.

---

## 5. Issues that may block or shape implementation

### Hard prerequisites — must land before the demo can be built

*Revised 2026-09-02:* the critical path is now ECS-12 (prefixed delegation) →
ECS-4 (slots) → ECS-15 (shared relationships table, [ADR-0017](../adr/0017-shared-relationships-table.md))
+ ECS-16 (markers) → ECS-9 (the catalogue in the gem, [ADR-0018](../adr/0018-catalogue-in-the-gem.md))
→ ECS-6 (inverse relationships) → ECS-5 (query filtering/ordering) → ECS-17
(forum rebuilt on the catalogue). Items 1–2 below stand; 3–5 are amended in
place.

1. **RFC-0014 (plural components) is designed but unimplemented.** Billing vs
   shipping addresses and mobile vs work phones are core to the demo and cannot
   be expressed today. This is the critical-path dependency: the gem work comes
   first. Its **three open questions must be closed before coding**: the keyword
   (`prefix:` vs `slot:`), the delegated-name shape
   (`billing_address_line1` vs `billing_line1`), and the default slot value
   (`""`). Recommendation: proceed with the RFC's current answers
   (`prefix:`, reader-prefixed, `""`).

2. **The standard components don't exist yet.** `Money`, `PostalAddress` and
   `Phone` are catalogue *ideas*, not code. None carries validation (no E.164
   parse, no ISO-4217 check, no currency-mismatch guard). They must be authored
   — in the demo first — before checkout has anything to price with.

### Structural constraints — not blockers, but they dictate the model

3. **No anonymous collections (ADR-0005/0015).** Every "many" is a join entity.
   This is the demo's real stress test. *Revised:* `basket.items` is a real
   `has_many` (RFC-0015, built up front), so the remaining friction to watch is
   the join entity's own lifecycle (`BasketItem` has components of its own) and
   `build`/`<<` ergonomics over a `through` association.

4. **No aggregation primitive.** An order total, a product's average rating, a
   review count — none is something the component DSL computes. They are plain
   Ruby/SQL over the related entities (as in `Checkout` above). Fine, but the
   demo should not pretend the framework does it.

5. **Query DSL is equality-only (RFC-0010) — and the demo needs filters.**
   "Products under $50", "sort by price", "4-star-and-up" all need
   range/comparison conditions, which are on the backlog ("non-equality query
   conditions") and *not built*. **Decision: the demo ships with price/rating
   filters**, so that backlog item becomes a hard prerequisite — a small query
   RFC (block or relation-arg conditions) lands before the catalogue pages.

### External-integration decisions — settled

6. **Payment is simulated only.** A `PaymentGateway` PORO that validates a fake
   card and always succeeds (with a deterministic failure path for a magic
   "declined" number, to exercise the rollback). No Stripe, no keys, no secrets,
   no network — free, deploy-safe, and dependency-light, consistent with the
   portfolio's cheap-infra rule. Real card capture is out of scope for a
   framework demo.

7. **Single currency: USD.** `Money` still stores an ISO-4217 currency code (so
   the component stays honest and reusable), but the demo fixes everything to
   `USD` and asserts one currency per basket/order — deferring FX and
   mixed-currency checkout entirely.

8. **Invoice numbering.** Sequential, unique invoice/order numbers need a
   counter or DB sequence — entities have UUID PKs, so there is no natural
   incrementing number. Minor, but decide: a Postgres sequence, or a
   `max + 1` inside the checkout transaction.

### Ergonomic risks worth watching

9. **Delegated-name length under plural components.** `billing_address_line1`,
   `billing_address_postal_code`, `shipping_address_country` — the prefixed
   delegation gets verbose fast. RFC-0014's `delegate: false` opt-out (reach
   through `order.billing_address.line1`) is the escape valve; the demo is the
   first place to judge whether prefixed delegation is worth keeping on by
   default.

10. **N+1 across components *and* relationships.** A product grid touches
    `Title`, `Money`, `seller`, and a review aggregate per row.
    `includes_components` + `includes_related` cover the first three; the review
    count is a separate query. Watchable, not blocking.

---

## 6. Build order — revised 2026-09-02

Gem first, in dependency order; each step one PR with green tests.

1. **ECS-18** — demo back on a path dependency (restores the gem→demo loop).
2. **ECS-12** — prefixed delegation (ADR-0016).
3. **ECS-4** — slots (RFC-0014): the slot-scoped `has_one` and lazy-reader
   presets, built generally because 4 and 5 reuse them.
4. **ECS-15** — relationships on the shared table (ADR-0017); delete the
   relationship generator. **ECS-16** — markers on a shared table, `marker`.
5. **ECS-9 + ECS-7** — the catalogue as gem concerns, the install migration,
   `ecs_rails:upgrade`. Components authored demo-first for shape.
6. **ECS-6** — inverse relationships (RFC-0015) over the shared table.
7. **ECS-5** — non-equality query conditions and ordering.
8. **ECS-17** — the forum rebuilt on the catalogue only. One file in
   `db/migrate`. First verdict on generic component naming.
9. **Marketplace** (issues cut when ECS-17 lands): sellers & catalogue pages
   with filters; reviews; basket & checkout with the simulated gateway; orders &
   invoices; **ECS-8** geocoder.
10. **ECS-11** entity generator (slot syntax in the first cut).
11. **ECS-19** release 0.3.0, repin and redeploy the demo.
12. **ECS-20** blog post "The Last Migration"; **ECS-10** video.

## 7. Decisions — settled

- **Payment:** simulated only, no Stripe/secrets (§6 of issues).
- **Filters:** price/rating filtering is in scope → non-equality query
  conditions become a prerequisite (build-order step 2).
- **Currency:** USD, single-currency, code still stored on `Money`.
- **Standard components:** authored **demo-first for shape**, promoted to
  **gem concerns** created by the install migration — not generators
  ([ADR-0018](../adr/0018-catalogue-in-the-gem.md); revised 2026-09-02).
- **Relationships:** one shared `relationships` table
  ([ADR-0017](../adr/0017-shared-relationships-table.md)); `has_one` uniqueness
  DB-enforced by a partial unique index created at install.
- **Inverse relationships:** built up front (RFC-0015), not after friction.
- **Zero migrations after install** is the claim the demo exists to prove.
</content>
</invoke>
