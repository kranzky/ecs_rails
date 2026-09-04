# RFC-0017: The catalogue — standard components in the gem

**Status:** Implemented (2026-09-04, Linear ECS-9 / ECS-7)
**Depends on:** [RFC-0014](0014-plural-components.md) (slots, `slot_option`), [RFC-0012](0012-relationship-dsl.md) as amended (Relationship), [RFC-0016](0016-markers.md) (Marker)
**Decision:** [ADR-0018](../adr/0018-catalogue-in-the-gem.md)

## Goal

After `rails g ecs_rails:install` and one `rails db:migrate`, an application is
built from the catalogue with no further migration. The tables exist; a slot
names the role.

```ruby
class Product < ApplicationEntity
  component Text,       prefix: :title
  component Text,       prefix: :body
  component Money,      prefix: :price
  component Identifier, prefix: :sku
  component Counter,    prefix: :stock
  component State,      prefix: :listing, states: %w[draft listed delisted]
  component Tags,       prefix: :topics
  relates_to :seller, Company
  marker :featured
end
```

## Rules

- **A catalogue component is a module in the gem** — `EcsRails::Catalogue::Money`
  — that `extend`s `EcsRails::Catalogue::Definition` and declares its `table`,
  its `set`, a `schema` block (columns beyond `id`, `entity_id`, `slot` and
  timestamps, plus extra indexes and foreign keys) and an `included` block
  (validations, `slot_option`s, associations). Instance methods are ordinary
  module methods. Not an `ActiveSupport::Concern`: Ruby's `Module#included(base)`
  knows *which* module is being included, which a concern's block does not, and
  the table name is per component.
- **The application owns the constant.** `include EcsRails::Catalogue::Money`
  in a one-line class sets the table name and runs the included block. The class
  may then override `self.table_name` (an app whose `emails` table is taken) and
  add behaviour. Renaming is the collision remedy: `class Price <
  ApplicationComponent; include EcsRails::Catalogue::Money; end`.
- **One declaration, two outputs.** `Schema#apply(target, table_name:)` creates
  the table on a connection or in an `ActiveRecord::Schema.define`; `#to_ruby`
  renders the equivalent migration source; `#to_ruby_diff` renders only what an
  existing table lacks. The gem's own test schema is built with `apply`, so the
  table the suite runs against and the table a user's migration creates cannot
  drift.
- **Every catalogue table has the invariants of architecture.md §2** — UUID
  primary key, non-null `entity_id`, `slot` defaulting to `""`, `UNIQUE
  (entity_id, slot)`, a cascading foreign key to `entities` — added by `apply`
  and `to_ruby`, never by the declaration.
- **Column types are limited** to what every supported PostgreSQL has and
  ActiveRecord maps natively: `string text integer bigint float decimal boolean
  date datetime uuid jsonb tsvector`. Anything else is a `NoMethodError` in the
  declaration.
- **Sets.** `set :commerce` in a declaration; `:core` otherwise. Known sets are
  `core`, `commerce`, `social`, `saas` (the last two empty in 0.3.0).
  `Catalogue.in_sets(:core, :commerce)`, `Catalogue[:money]`,
  `Catalogue.components`.
- **Naming.** Never a Ruby core constant (`CalendarDate`, not `Date`).
  `Address`, not `PostalAddress`: ADR-0016 freed the short name and the slot
  reader rule needs it (`billing_address`).
- **The catalogue carries no third-party dependencies.** Validation is regex and
  enum. `Password` needs `bcrypt` in the *application*, as `has_secure_password`
  always has; `Image` gains `has_one_attached :file` only when Active Storage is
  loaded.

## The shelf (0.3.0)

`core` — `Relationship`, `Marker`, `Name` (given, family, full), `Email`
(address, verified), `Password` (password_digest), `Phone` (e164, extension),
`Address` (line1, line2, locality, region, postcode, country), `Geolocation`
(lat, lng, geocoded_at), `Link` (url, label), `Text` (value), `Identifier`
(value, `UNIQUE (slot, value)`), `Counter` (count), `Rating` (stars),
`Timestamp` (at), `CalendarDate` (date), `Period` (starts_at, ends_at,
time_zone, all_day), `Position` (position), `State` (status, transitions;
`states:`, `history:`), `Tags` (names text[], GIN; `allow:`), `SearchVector`
(document tsvector, GIN), `Discard` (discarded_at), `Image` (url, alt), `Role`
(name), `Token` (digest, expires_at).

`commerce` — `Money` (amount_cents, currency).

Each carries the behaviour ADR-0018 §5 sketched: `Money#+`/`-`/`*` with a
`CurrencyMismatch` guard, `State#transition!` with an optional log,
`Counter#increment!` atomic once persisted, `Token#generate!`/`verify` over a
digest, `Period#overlaps?`/`current?`, `Tags#add`/`remove`/`tagged`,
`SearchVector#reindex!`/`matching`, `Discard#discard!`, `Geolocation#locate`,
and so on.

## Generators

- **`rails g ecs_rails:install [--sets core commerce] [--rename money:Price]`**
  writes `ApplicationEntity`, `ApplicationComponent`, the initializer, **one
  one-line class per component in the selected sets**, and **one migration**
  (`ecs_rails_install`) creating `entities` and every selected catalogue table,
  rendered from the declarations.
- **`rails g ecs_rails:upgrade [--sets ...]`** writes any missing one-line
  classes (never touching an existing file) and up to four migrations, in order:
  `ecs_rails_add_slots` (pre-0.3 component tables), `ecs_rails_catalogue`
  (missing catalogue tables, and missing columns or indexes on existing ones —
  for the selected sets plus every catalogue table already present),
  `ecs_rails_shared_relationships` and `ecs_rails_shared_markers` (the data
  moves, which now assume the catalogue migration created their tables). Each
  is written only when it has something to do.
- **`rails g ecs_rails:component`** stays, as the escape hatch for a bespoke
  table once an idea has earned its schema.

## Tests

`spec/catalogue_spec.rb` (registry, sets, definition, schema recording and its
two outputs, the live-table-equals-declaration guarantee),
`spec/catalogue/components_spec.rb` (each component's shape, validations and
behaviour, declared on throwaway entities), and the generator specs (install
writes every class and table for a set, `--rename`, upgrade creates a missing
table and adds a missing column, and the data moves run after it).

## Non-goals

- Anything in ADR-0018 §5's deferred tier (`Rate`, `Measurement`,
  `Recurrence`, `Consent`, `Locale`, `Subscription`, `Quota`, `Document`,
  `Embedding`, `IpAddress`).
- Removing or altering a column on upgrade. The diff adds; it never drops.
- The Indexer system for `SearchVector` (needs RFC-0010's non-equality
  conditions, Linear ECS-5).

## Notes from implementation

- The gem's test schema builds every catalogue table from the declarations.
  Three catalogue tables collide with bespoke fixture tables the core specs
  depend on (`emails`, `names`, `addresses`); those three are created under a
  `catalogue_` prefix and their spec classes override `table_name` — the
  app-owns-the-table-name idiom, exercised.
- `Money`'s table is `monies` — Rails' inflection of "money". The one-line class
  can rename it.
- A Thor file conflict in a generator spec hangs the suite waiting on stdin;
  the generator helper now gives Thor an empty stdin so a collision fails
  instead. It bit once: install writes a catalogue `email.rb`, and the migration
  execution spec used to generate a bespoke `Email`.
- The demo is untouched here. ECS-17 rebuilds the forum on the catalogue and
  is where these components meet real views.
