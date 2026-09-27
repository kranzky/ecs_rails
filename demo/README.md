# ECS Rails demo

A bulletin board and marketplace composed from the gem's catalogue. Explore
people, posts, groups, companies, products, baskets, orders and invoices without
adding a migration for each entity type.

This checkout uses the sibling `../gem` source and the unreleased 0.3.0 API.
The published 0.2.2 gem and deployed demo belong to the earlier release. Start
with the [gem quickstart](../gem/README.md#quickstart-a-contacts-directory) if you
want to build a small app of your own.

## Prerequisites

- Ruby **3.4.5** (see `.ruby-version`) and Bundler; the demo uses Rails 8.1.
- PostgreSQL, with a local role that can create databases. CI uses PostgreSQL 16.
- The whole repository: the Gemfile loads `../gem` through a local path.

There is no Node build step, Redis service, external search service or payment
account to configure. JavaScript uses import maps; search uses PostgreSQL.

## Set up and launch

From the repository root:

```sh
cd demo
bundle install
RAILS_ENV=development bin/rails db:prepare
RAILS_ENV=development DEMO_RESET_ENABLED=false bin/rails server -p 3021
```

Open <http://localhost:3021>. `db:prepare` creates/migrates `demo_development`
and seeds a newly initialized database. On an already prepared database, it
applies pending migrations without reseeding. The default database settings
are in [config/database.yml](config/database.yml); set `DATABASE_URL` per command
if your PostgreSQL host, role or database differs.

For example, use a separate development database:

```sh
RAILS_ENV=development DATABASE_URL=postgresql:///ecs_demo_local bin/rails db:prepare
RAILS_ENV=development DATABASE_URL=postgresql:///ecs_demo_local DEMO_RESET_ENABLED=false bin/rails server -p 3021
```

The only checked-in application migration installs `core` and `commerce`.
Adding an entity or a slot composed from those components requires no new table.

## Seeds and resets

[Demo::Seed](lib/demo/seed.rb) creates example people, posts, groups, marketplace
listings, relationships and commerce records, then indexes their text. The seed
is **not additive/idempotent**: running `db:seed` repeatedly can duplicate records
or hit uniqueness constraints. To restore the examples in your disposable local
development database, stop the server and run:

```sh
RAILS_ENV=development bin/rails demo:reset
```

This command **truncates all application tables** in the selected database and
seeds them again. It preserves migration metadata, but replaces record IDs and
invalidates old detail-page URLs. If using a custom database, supply the same
`DATABASE_URL` as your server.

`DEMO_RESET_ENABLED=false` disables the web server's scheduled resets, not the
explicit `demo:reset` command. Setting it to `true` starts the scheduler whenever
Puma boots, including locally. `DEMO_RESET_INTERVAL_MINUTES` defaults to 60;
resets align to wall-clock boundaries. Keep it disabled for hands-on work you
want to retain.

## A short guided journey

The root page is a four-step tour — compose, use, inspect, extend — that quotes
the declaration behind each step and links to the live page. In order:

1. **Compose.** Open the acting person's profile (Ada by default). The name,
   email, addresses, phones and avatar are catalogue components; the two
   addresses are one component under two slots. Fill in an address.
2. **Use.** Open **Market**, combine category, price and rating filters, add a
   stocked product to the basket and check out. Use the simulated card
   `4242424242424242` for success, or `4000000000000002` for a decline, which
   rolls back the order and stock. The gateway makes no network call.
3. **Inspect.** Open the order and its invoice. Their copied addresses, titles
   and prices preserve the sale even when the source product changes.
4. **Extend.** Open **/geocoder**. One address is waiting and one is a place
   the simulated gazetteer does not know. Run it: the address from step 1 is
   located, for users and sellers alike, and `db/migrate` still holds one file.
   The map filters by entity type (`Geolocation.where(entity: User.all)`).

The bulletin board (`/posts`), groups and moderator/admin markers cover the
rest of the gem.

**Acting as.** There are no accounts. The bar under the navigation picks who
you act as, kept in the session and defaulting to Ada; that person writes
posts, comments and reviews, fills the basket, and is judged by the seller
policy (an owner or manager may list and edit products; the page names who can
when you cannot). It is labelled as simulated and needs no password. It is
example software, not a production storefront. Follow
[the source walkthrough](../docs/source-walkthrough.md) for the declarations,
query/render path, checkout locks and generic indexer.

To run the entity-independent systems from the command line:

```sh
RAILS_ENV=development bin/rails runner 'puts Demo::Indexer.call'
RAILS_ENV=development bin/rails demo:geocode
```

The indexer rebuilds complete Text documents for owners that declare
SearchVector; the geocoder fills each Geolocation paired with an Address in
the same slot. Each prints the number processed. New eligible entity types need
no changes to either system's code.

## Compose another entity

From `demo/`, the catalogue is already installed. Generate a Person with two
Phone slots and an Address:

```sh
RAILS_ENV=development bin/rails generate ecs_rails:entity Person name email mobile:phone work:phone home:address
RAILS_ENV=development bin/rails runner 'person = Person.create!(name_given: "Grace", mobile_phone_e164: "+12025550101", work_phone_e164: "+12025550102"); puts person.reload.mobile_phone'
RAILS_ENV=development bin/rails zeitwerk:check
```

This adds `app/entities/person.rb` and no migration. Use the same `DATABASE_URL`
as your development server if you configured one. The new type is available in
the console; the existing People page lists User records and does not acquire a
new interface automatically. Remove the example records with `Person.destroy_all`
in the console before `bin/rails destroy ecs_rails:entity Person` removes the
class file. The generator does not delete data.

## Rendered and accessibility review

`script/qa/` screenshots every page at desktop and phone widths in light and
dark schemes, runs axe-core (WCAG 2.1 AA) on each, checks phone overflow and
walks the keyboard focus order; `states.js` covers validation errors, a
declined checkout and empty states. See
[the review and how to rerun it](../docs/design/demo-qa.md). It needs Node and
a local Chrome; it is not part of CI.

## Tests and checks

Use a **separate test database**. The tests reset data and include committed
concurrency cases; do not point them at development or production. From `demo/`:

```sh
RAILS_ENV=test DATABASE_URL=postgresql:///demo_test bin/rails db:prepare
RAILS_ENV=test DATABASE_URL=postgresql:///demo_test DEMO_RESET_ENABLED=false bundle exec rspec
RAILS_ENV=test DATABASE_URL=postgresql:///demo_test bin/rails zeitwerk:check
```

The test helper rejects a non-test `RAILS_ENV`; it cannot tell whether a custom
`DATABASE_URL` points at valuable data. The explicit URL above also avoids an
inherited development URL being reused accidentally.

Run the gem suite and documentation check separately from `gem/`:

```sh
cd ../gem
bundle install
createdb ecs_rails_test # once, if it does not already exist
DATABASE_URL=postgresql:///ecs_rails_test bundle exec rspec
bundle exec ruby script/check_documentation.rb
DATABASE_URL=postgresql:///ecs_rails_test bundle exec ruby script/package_smoke.rb
```

Package checks create and remove their own temporary databases and execute the
gem README's tutorial, bespoke-component example and published-0.2.2 upgrade.
For the demo benchmark and its limits, see
[the performance comparison](../docs/design/performance-comparison.md).

## Deployment

The current local-path gem dependency reaches outside the demo's Docker build
context. Deployment resumes at the 0.3.0 release after the Gemfile is repinned to
the published gem. The Fly configuration belongs to that release workflow;
local setup does not require Fly credentials or a deployment.
