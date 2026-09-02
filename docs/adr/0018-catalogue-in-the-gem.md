# ADR-0018: The catalogue ships in the gem; install is the last migration

**Status:** Accepted
**Date:** 2026-09-02
**Amends:** [ADR-0009](0009-component-presence.md) (its rejection of a `marker` keyword)
**Builds on:** [ADR-0015](0015-plural-components-via-slot.md) (slots), [ADR-0016](0016-prefixed-delegation-by-default.md) (prefixed delegation), [ADR-0017](0017-shared-relationships-table.md) (shared relationships)
**Surfaced by:** the v2 goal (Linear ECS-14). The blog's closing argument — *"you stop designing the data model, and begin assembling it"* — taken to its conclusion.

## Context

[Composing Rails](../blog/composing-rails.md) argued that the approach is at its
most useful before an idea has earned its schema: compose something from
ready-made parts, put it in front of people, and see. The v2 goal sharpens that
into a claim that can be demonstrated and falsified:

> **After `rails g ecs_rails:install` and one `rails db:migrate`, building an
> application requires no further migrations.** Entities, relationships, markers
> and systems are all pure Ruby. The tables already exist.

Three things generate a migration after install today:

| Source | Today | Under this ADR |
|---|---|---|
| A new component | `rails g ecs_rails:component` — one table each | The catalogue's tables exist from install; a slot names the role |
| A `relates_to` | `rails g ecs_rails:relationship` — one table each | One `relationships` table ([ADR-0017](0017-shared-relationships-table.md)) |
| A marker | one empty table each | One `markers` table, slot = marker name |

The mechanism that makes a *finite* set of tables cover an *open* set of domains
is the slot ([ADR-0015](0015-plural-components-via-slot.md)). A generic
component plus a slot label is a typed, named field that needs no table of its
own: `Text` under slots `title`, `body` and `bio`; `Counter` under `likes` and
`stock`; `State` under `publish` and `order`; `PostalAddress` under `billing`
and `shipping`. Slots were designed for the last of these. This ADR makes them
the load-bearing primitive of the whole thesis.

The previous plan (Linear ECS-9, original form) shipped the standard components
as **per-component generators**, each emitting a class and a migration. That is
"installed rather than written" for the *code*, but it still costs a migration
per component, and anything added to the catalogue in a later gem version
arrives as more of them. It does not deliver the claim.

## Decision

### 1. Standard components are concerns in the gem

Each catalogue component lives in the gem as a concern —
`EcsRails::Catalogue::Money`, `EcsRails::Catalogue::PostalAddress` — carrying
its behaviour, its validations, and a **schema declaration** (columns, indexes)
that the generators read:

```ruby
module EcsRails::Catalogue::Money
  extend ActiveSupport::Concern
  include EcsRails::Catalogue::Component

  schema do |t|
    t.integer :amount_cents, null: false, default: 0
    t.string  :currency,     null: false, default: "USD", limit: 3
  end

  included do
    validates :currency, format: /\A[A-Z]{3}\z/
  end

  def +(other) = ...     # currency-mismatch guard, formatting, etc.
end
```

The schema declaration is the single source of truth for the table: the install
and upgrade generators derive migrations from it, and the lazy reader's defaults
come from the same columns as today.

### 2. Install writes the app classes and one migration

`rails g ecs_rails:install` emits, in addition to today's output:

- **One one-line app class per catalogue component**, in the components
  directory ([ADR-0010](0010-entity-component-directory-layout.md)):

  ```ruby
  class Money < ApplicationComponent
    include EcsRails::Catalogue::Money
  end
  ```

  The application owns the constant and the table name, can add behaviour
  locally, and can read the code. This is the "eject" the generator design
  wanted, already done.

- **One migration** creating every catalogue table — each with `slot`,
  `UNIQUE (entity_id, slot)` and a cascading foreign key
  ([ADR-0015](0015-plural-components-via-slot.md)) — plus `relationships`
  ([ADR-0017](0017-shared-relationships-table.md)) and `markers` (§4) with their
  indexes.

An optional `--only money,postal_address` selects a subset. The default is the
whole shelf; the point is that it is all already there.

### 3. `ecs_rails:upgrade` is the only migration a user ever runs afterwards

`rails g ecs_rails:upgrade` compares the gem's schema declarations against the
database and emits **one migration** for whatever is missing: new catalogue
tables in a newer gem version, new columns, the slot column on pre-0.3
component tables, the data move from per-relationship tables
([ADR-0017](0017-shared-relationships-table.md)). It runs on a gem upgrade and
at no other time.

`rails g ecs_rails:component` **stays**, unchanged apart from the slot column,
as the documented escape hatch: *once the idea has earned its schema*, promote a
slot to a bespoke component. Because the catalogue tables are already
normalised per shape, that promotion is a copy, not a redesign.
`rails g ecs_rails:relationship` is removed.

### 4. Markers are slots of one `Marker` component, declared with `marker`

```ruby
class User < ApplicationEntity
  marker :moderator          # slot "moderator" on the markers table
  marker :administrator
end

user.add(:moderator)         # a row in markers
user.moderator?              # => true
user.remove(:moderator)
User.with_marker(:moderator)
```

`marker :moderator` is sugar for `component Marker, prefix: :moderator` that
generates the predicate and presence forms under the **bare** name. Without it
the reader would be `user.moderator_marker?`, which is worse than what the demo
has today. Presence semantics are exactly [ADR-0009](0009-component-presence.md)'s:
a user *is* a moderator when the `(entity_id, "moderator")` row exists.

**This amends ADR-0009's rejection of a `marker` keyword.** That rejection was
right for its reason — a keyword would have "forked the model into two concepts
the developer must choose between", a marker being nothing but an empty
component. That reason no longer applies: a marker is still a component
(`Marker`) under a slot, and the keyword adds no second concept. It only names
the slot and restores the bare predicate that prefixing would otherwise take
away.

### 5. The first catalogue

Provisional — authored demo-first for shape, per [PROCESS.md](../../PROCESS.md),
and adjusted as the forum rebuild and the marketplace argue. Roughly seventeen
tables:

| Component | Shape | Slots the demos use |
|---|---|---|
| `Name` | first, last | — |
| `Email` | address, verified | — |
| `Phone` | e164, extension | mobile, work |
| `PostalAddress` | line1, line2, locality, region, postcode, country | shipping, billing, registered, warehouse |
| `Geolocation` | lat, lng, geocoded_at | paired to an address slot |
| `Money` | amount_cents, currency | price, total, unit_price |
| `Text` | value | title, body, bio, description |
| `Identifier` | value | sku, order_number, invoice_number, slug |
| `Counter` | count | likes, stock, quantity |
| `Rating` | stars | — |
| `Timestamp` | at | issued_at, published_at |
| `State` | status, transitions | publish, listing, order |
| `Image` | attachment | avatar, logo |
| `Role` | name | — |
| `Token` | value, expires_at | reset, invite |
| `Marker` | — | one per marker name |
| `Relationship` | target_id, owner_model, exclusive | one per relationship name |

The catalogue carries **no third-party dependencies** (no `phonelib`, no
`money`): it ships in the gem, so any dependency is imposed on every user.
Validation is regex and enum.

## Reason

**Why one migration, not per-component generators.** See Context. The claim is
the product; a design that leaves a migration per component does not make it.

**Why concerns, not classes in the gem.** A gem defining a top-level `Money`
pollutes the application's namespace. A namespaced gem class forces `component
EcsRails::Catalogue::Money` at every call site. An abstract gem superclass
fights ActiveRecord's table-name inference and single-table-inheritance
machinery. A concern included into a one-line app class avoids all three and
preserves every existing invariant: a component is still an application-owned
ActiveRecord class that owns one table.

**Why the app owns the class.** It keeps the constant short (`Money`), lets the
application extend it, and means the friction-log answer to "I need to change
this component" is *edit the file*, not *fork the gem*.

**Why a schema declaration, not migration files shipped by an engine.** Rails
engines ship migrations that `rails <engine>:install:migrations` copies into the
app, and Active Storage installs that way. It is proven and simple, and it is
the fallback if the diffing generator proves fiddly. It was not chosen because
it creates two sources of truth (the concern's expectations and the migration's
columns) that can drift, it puts one file per gem version into the app's
migrate directory rather than one file in total, and it cannot do subsets.

**This is not entity–attribute–value.** Every catalogue table is typed per
shape, with real columns, real foreign keys, real indexes and real validations.
There is no values blob and no type column to cast. The shared
`relationships` table is the one place a row's meaning depends on a string
column, and it has the same shape as `active_storage_attachments`.

## Consequences

- **The claim is now a testable property of the gem.** A spec asserts that the
  bulletin board and the marketplace both load and pass against a database
  built from the install migration alone. `demo/db/migrate` contains exactly
  one file, and that listing is a screenshot in the launch blog post.
- **The gem grows a catalogue** and takes on the standards behind it (E.164,
  ISO 4217, schema.org `PostalAddress`, WGS 84). Catalogue additions are gem
  releases with an upgrade migration.
- **The application's components directory holds ~17 one-liners** after
  install. That is visible and slightly noisy; it is also the eject-by-default
  that makes the catalogue legible.
- **Generic component naming is the ergonomic risk.** `component Text, prefix:
  :title` yields the reader `post.title_text`, and the string is a hop further.
  [RFC-0014](../rfc/0014-plural-components.md) rejected per-slot reader renaming
  as scope creep. The forum rebuild (Linear ECS-17) is the first real test; if
  it reads badly in views and forms, an `as:` keyword for the reader name earns
  its way in there, before the marketplace multiplies the problem.
- **`Identifier` wants `UNIQUE (slot, value)`** at install so that order numbers
  and slugs are honest. Cheap; decided when the component is authored.
- **`architecture.md` §1 gains the invariant** ("after install, no migration is
  required to build from the catalogue"), §2 gains the shared tables, and §6
  ("Scope of v0.1") is retired, all at implementation time (Linear ECS-9), as
  [ADR-0016](0016-prefixed-delegation-by-default.md) does for §4.
- **"Standard components built demo-first then promoted to gem generators"** in
  the [marketplace design](../design/marketplace-demo.md) §7 is superseded:
  demo-first for *shape*, then promoted to **gem concerns**.
- **The escape hatch is part of the story, not an embarrassment.** The blog
  should show a slot being promoted to a bespoke component, because "when do
  you stop?" is the first question a serious reader asks.
