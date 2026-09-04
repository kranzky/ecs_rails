# ADR-0018: The catalogue ships in the gem; install is the last migration

**Status:** Accepted — implemented 2026-09-04 (Linear ECS-9 / ECS-7, [RFC-0017](../rfc/0017-catalogue.md); §4 earlier as ECS-16, [RFC-0016](../rfc/0016-markers.md))
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

Components are grouped into **sets** (§5); `rails g ecs_rails:install --sets
core,commerce` selects which are created. `core` is the default. The video
shows the whole shelf arriving; a prototype need not carry every table.

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

> **Implemented 2026-09-04** (Linear ECS-16, [RFC-0016](../rfc/0016-markers.md)),
> with one addition: `user.moderator = true` / `false` as a Boolean writer, so a
> checkbox routes through flat mass assignment. `Relationship` (§5) landed the
> same week (ECS-15); the rest of the catalogue is ECS-9.

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
and adjusted as the forum rebuild and the marketplace argue. Grouped into
**sets** so that install can take `--sets core,commerce,social,saas` (`core` is
the default) and a prototype need not carry every table.

**`core`** — identity, content, time, ordering, search:

| Component | Shape | Slots the demos use / notes |
|---|---|---|
| `Name` | given, family, full | schema.org `givenName` / `familyName`; an organisation's name is `Text` under slot `name` |
| `Email` | address, verified | — |
| `Password` | password_digest | `has_secure_password`; with a `Session` entity (`Token` + `Timestamp` + `relates_to :user`) this is Rails 8's generated authentication, from the catalogue |
| `Phone` | e164, extension | mobile, work |
| `PostalAddress` | line1, line2, locality, region, postcode, country | shipping, billing, registered, warehouse |
| `Geolocation` | lat, lng, geocoded_at | paired to an address slot |
| `Link` | url, label | website, github, webhook |
| `Text` | value | title, body, bio, description |
| `Identifier` | value — `UNIQUE (slot, value)` | sku, order_number, invoice_number, slug, stripe_customer |
| `Counter` | count | likes, stock, quantity |
| `Rating` | stars | — |
| `Timestamp` | at | issued_at, published_at |
| `CalendarDate` | date | birthdays, due dates — a date is not a timestamp; named so as never to shadow Ruby's `Date` |
| `Period` | starts_at, ends_at, time_zone, all_day | events, bookings, availability; `overlaps?`, `current?` |
| `Position` | position | ordering within a list — kanban columns, checklist items; one slot per list |
| `State` | status, transitions | publish, listing, order — the transitions log is **optional per slot** (`history: false`), so visibility / priority / severity enums use the same table without a log |
| `Tags` | names (text[], GIN) | free tagging; an unbounded set of *strings* is a value, not a collection of entities |
| `SearchVector` | document (tsvector, GIN) | Postgres full-text search, no dependency; rebuilt by an entity-blind `Indexer` system from the entity's `Text` slots — the second system showcase beside the geocoder (needs RFC-0010's non-equality conditions, Linear ECS-5) |
| `Discard` | discarded_at | soft delete as presence: `discard!`, `undiscard!`; `without_component(Discard)` is "kept" |
| `Image` | attachment | avatar, logo (Active Storage) |
| `Role` | name | — |
| `Token` | digest, expires_at, purpose | reset, invite, api — **stores a digest, never the value** (the `generates_token_for` shape: generate once, show once, verify against the digest) |
| `Marker` | — | one per marker name (§4) |
| `Relationship` | target_id, owner_model, exclusive | one per relationship name ([ADR-0017](0017-shared-relationships-table.md)) |

**`commerce`** — `Money` (amount_cents, currency; price, total, unit_price).
Later: `Rate` (basis points), `Measurement` (value + UCUM unit),
`Subscription`, `Quota`.

**`social`**, **`saas`** — empty in 0.3.0; named so the sets exist. Candidates
below.

The catalogue carries **no third-party dependencies** (no `phonelib`, no
`money`): it ships in the gem, so any dependency is imposed on every user.
Validation is regex and enum.

#### Deferred — wait for a demo to ask

| Component | Shape | Trigger |
|---|---|---|
| `Rate` | basis_points | tax, discount, commission, progress — when the marketplace prices a discount |
| `Measurement` | value, unit (UCUM) | shipping weight, recipes |
| `Recurrence` | rrule (RFC 5545) | repeating events; storing is trivial, expanding without a dependency is not |
| `Consent` | document, version, accepted_at | terms / privacy acceptance — a marker cannot record *which version* |
| `Locale` | locale, time_zone | per-user formatting; two `Text` slots until it earns behaviour |
| `Subscription` | plan, status, current_period_end | a mirror of the Stripe subscription object |
| `Quota` | used, limit, resets_at | metering and rate limits |
| `Document` | data (jsonb) | the deliberate schemaless blob — webhook payloads, imports, drafts; to be named honestly as the one place the catalogue lets you defer typing |
| `Embedding` | vector | AI apps; only when the `pgvector` extension is present |
| `IpAddress` | address (inet) | sessions and audit |

**Not catalogue components, and the docs should say so:** versioning and audit
history are unbounded per entity — child entities driven by a system.
Reactions and follows are join entities. A boolean preference is a marker named
for the non-default case (`marker :emails_muted`), not a toggle with a default
of `true`.

#### Naming rule

A catalogue name must never shadow a Ruby core constant (`Date`, `Time`,
`Set`, `Range`, `String`, …), and should avoid the constants of popular gems
where a short name is available. Some collisions are unavoidable — `Money`
collides with the `money` gem, `Geocoder` (the demo's system) with the
`geocoder` gem — and the one-line app class is the remedy: the install
generator accepts a rename, and the documented idiom is

```ruby
class Price < ApplicationComponent
  include EcsRails::Catalogue::Money
end
```

The application owns the constant; the gem owns the standard.

#### Declaration-time slot configuration

Several components need per-slot options — `State` its vocabulary and
`history:`, `Measurement` its unit, `Tags` an optional allow-list. These are
passed through the `component` declaration to the concern,
`component State, prefix: :order, states: %w[pending paid shipped], history: true`,
and settled once in the slot work (Linear ECS-4) because four or five
components depend on the same mechanism.

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
- **The application's components directory holds ~25 one-liners** after a
  full install (fewer with `--sets`). That is visible and slightly noisy; it is
  also the eject-by-default that makes the catalogue legible, and it is what
  makes renaming a component a one-line edit.
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

## Implementation notes (2026-09-04, ECS-9 / ECS-7)

- The catalogue module is `EcsRails::Catalogue`; a component `extend`s
  `Catalogue::Definition` (not `ActiveSupport::Concern`, which cannot tell
  *which* concern is being included) and declares `table`, `set`, `schema` and
  `included`. The schema recording has two outputs — a live table and migration
  source — and the gem's test schema uses the first, so the tables the suite
  runs against are the declarations.
- `PostalAddress` is `Address` (ADR-0016's payoff, and the slot reader rule).
- `Image` is `url` + `alt`, gaining `has_one_attached :file` only when Active
  Storage is present; a component with no columns is never dirty, so an
  attachment-only Image would need `add` before `attach`.
- `Token` drops `purpose` (the slot is the purpose) and keeps `digest`,
  `expires_at`.
- `ecs_rails:upgrade` has four jobs in order — slots, catalogue (create or
  diff), relationships data move, markers data move — each a migration file
  only when needed. The upgrade also writes missing one-line classes for the
  selected sets and never touches an existing file.
- The demo was rebuilt on the catalogue in ECS-17 the same day:
  `demo/db/migrate` holds one file, `demo/spec/zero_migrations_spec.rb` pins
  it, and the friction log records the first verdict on generic naming — the
  reader reads well, the trailing attribute (`title_text_value`) does not; a
  slot-named bare delegation of a component's primary attribute is the
  recommended remedy, awaiting a decision.
- **The escape hatch is part of the story, not an embarrassment.** The blog
  should show a slot being promoted to a bespoke component, because "when do
  you stop?" is the first question a serious reader asks.
