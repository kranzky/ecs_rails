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

1. Open **People**, then Ada. Inspect the name, email, addresses and avatar;
   toggle a marker to see presence as behavior.
2. Open the bulletin board, create a post and publish it. The title/body are
   Text slots; authorship is a relationship and publication is a State slot.
3. Open **Market**, combine category, price and rating filters, then open a
   product and its seller. An absent Money row displays as zero; filters and
   ordering use that same displayed value.
4. Add a priced, stocked product to a person's basket and check out. Use the
   simulated card `4242424242424242` for success, or `4000000000000002` for a
   decline. A decline rolls back the order and stock changes. The gateway makes
   no network call and charges no real card; a zero total is also declined.
5. Open the resulting order and invoice. Their copied addresses, titles and
   prices preserve the sale even when the source product changes.

The app uses an **acting-as picker**, not authenticated sessions. It is example
software, not a production storefront. Follow
[the source walkthrough](../docs/source-walkthrough.md) for the declarations,
query/render path, checkout locks and generic indexer.

To run the entity-independent system from the command line:

```sh
RAILS_ENV=development bin/rails runner 'puts Demo::Indexer.call'
```

It indexes complete Text documents for owners that declare SearchVector and
prints the number processed. New eligible entity types need no changes to the
system's code.

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
