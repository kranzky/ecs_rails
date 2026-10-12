# The Last Migration

*Composing a Rails application from a catalogue of ready-made components — one
migration at install, and none after it. What that buys, and what it costs.*

**Jason Hutchens · October 2026**

---

In July I wrote about [composing
Rails](https://github.com/kranzky/ecs_rails/blob/main/docs/blog/composing-rails.md):
an experiment in building a Rails application out of Entity–Component–System
parts instead of an inheritance hierarchy. That post ended with three intentions.
Components would gain labelled *slots*, so that an entity could hold a home
address and a work address. There would be a *catalogue* of well-made
components to assemble applications from. And the third letter, *systems*, would
get some honest attention.

All three are in [ecs_on_rails 0.3.0](https://rubygems.org/gems/ecs_on_rails),
and together they add up to something I did not set out to build. Once the
catalogue is installed and migrated, building with it needs no further
migrations. New kinds of entity, new slots, relationships between entities,
flags on them: all of it is Ruby. The `db/migrate` directory holds one file, and
it goes on holding one file.

This post builds a small contacts app to show what that looks like, opens the
database to show how it works, and then measures what it costs — because it is
not free.

## Every migration is a decision made early

Most Rails applications gather migrations at about the rate they gather
features. Each one is small and sensible — a `phone` column here, a `company_id`
there — and each one fixes the shape of the data at the moment that shape is
least understood. By the time an idea has found its form, the migrations
directory is a record of every form it tried first.

Version 0.1 moved each component's data into a table of its own, which kept the
entity tables narrow. But every component still needed that table written, so
each new one was a generator and a migration, and so was every relationship.
Composition happened in Ruby; storage still happened in migrations.

The change in 0.3.0 is to stop asking each application to write those tables. A
phone number, a postal address and a person's name have the same shape in every
application that stores them. So the gem ships them, as a catalogue, and the
install generator creates all of their tables at once.

## One migration

Start with an empty Rails application on PostgreSQL:

<!-- verify:commands -->
```sh
rails new contacts --minimal --database=postgresql
cd contacts
bundle add ecs_on_rails --version "~> 0.3.0"
bin/rails generate ecs_rails:install
bin/rails db:create db:migrate
```

<!-- verify:commands -->
```sh
ls db/migrate
```

<!-- verify:output -->
```text
20261012023722_ecs_rails_install.rb
```

That migration creates 25 tables. One is `entities`, which holds nothing but
identities. Twenty-two hold the catalogue's core components — names, emails,
phones, addresses, geolocations, text, counters, tags, ratings, tokens and the
rest — each with its own typed columns. The last two, `relationships` and
`markers`, are shared tables I will come back to. The generator also writes one
small class per component into `app/entities/components`:

```ruby
class Address < ApplicationComponent
  include EcsRails::Catalogue::Address
end
```

The behaviour and validations live in the gem; the constant belongs to the
application. That split is deliberate. A gem that defined a top-level `Address`
would collide with somebody's model, and one that made you write
`EcsRails::Catalogue::Address` at every use would be tiresome. With a one-line
class of your own, the name stays short, and when you want an address to behave
differently — a postcode rule for your country, a method that prints a mailing
label — you edit your file instead of forking the gem.

## Two kinds of thing

A contacts app has people and companies. The entity generator writes their
classes from the components they are composed of:

<!-- verify:commands -->
```sh
bin/rails generate ecs_rails:entity Person name email mobile:phone work:phone home:address home:geolocation
bin/rails generate ecs_rails:entity Company name:text phone address geolocation
```

It writes Ruby and nothing else. There is no migration, because there is nothing
to migrate:

```ruby
class Person < ApplicationEntity
  component Name
  component Email
  component Phone, prefix: :mobile
  component Phone, prefix: :work
  component Address, prefix: :home
  component Geolocation, prefix: :home
end
```

The `mobile` and `work` prefixes are slots. Both phones are rows in the one
`phones` table, told apart by a `slot` column, and each is a component in its
own right: `person.mobile_phone` and `person.work_phone` are separate objects,
validated separately. A company's name has no given and family parts, so it is
not a `Name`; it is the catalogue's generic `Text`, in the slot `name`. Because
`Text` declares `value` as its primary attribute, a company also gets a plain
`company.name` that returns the string.

Relationships and flags are declarations too. A person works for a company, and
I would like to mark a few people as favourites, so I add three lines by hand:

<!-- verify:file app/entities/person.rb -->
```ruby
class Person < ApplicationEntity
  component Name
  component Email
  component Phone, prefix: :mobile
  component Phone, prefix: :work
  component Address, prefix: :home
  component Geolocation, prefix: :home
  relates_to :employer, Company
  marker :favourite
end
```

<!-- verify:file app/entities/company.rb -->
```ruby
class Company < ApplicationEntity
  component Text, prefix: :name
  component Phone
  component Address
  component Geolocation
  has_many :employees, "Person", via: :employer
end
```

Before 0.3.0, a relationship like `employer` needed a table and a migration of
its own, and so did a marker like `favourite`. Now every relationship in the
application is a row in the one `relationships` table, and every marker a row in
`markers`, both created at install. `has_many ... via:` reads the same
relationships from the other side, so `company.employees` needs no storage of
its own either. (`"Person"` is a string for two reasons: `employees` does not
name the class, and a constant would make the two files load each other in a
circle, since `Person` already names `Company`.)

## Using it

Open `bin/rails console`. An entity starts as an identity and nothing else:

<!-- verify:console -->
```ruby
ada = Person.create!
ada.email.persisted?  # => false
ada.email.verified    # => false
```

`Person.create!` wrote one row, to `entities`. Asking for Ada's email did not
return `nil`; it returned an `Email` with every column at its default, held in
memory only. Components are *lazy*: a row is written only once a value differs
from its default, so a thousand people without a work phone cost nothing in the
`phones` table.

That laziness is not free, and it is worth being exact about where the cost
falls. Ada has been saved, so the gem cannot know whether she has an email
without asking:

```text
Email Load  SELECT "emails".* FROM "emails"
            WHERE "emails"."entity_id" = '8d72dd86-…' AND "emails"."slot" = '' LIMIT 1
```

An absent component is answered by a query that finds nothing. The answer is
cached on the entity, and a page that lists many people should preload the
components it shows — `Person.preload(:name, :email)` — exactly as it would any
association.

Writing is ordinary Rails. Each component's attributes are delegated to the
entity under the component's name, and one `update!` saves every component it
touches, in one transaction:

<!-- verify:console -->
```ruby
ada.update!(name_given: "Ada", name_family: "Lovelace",
            email_address: "ada@example.com",
            mobile_phone_e164: "+61491570156",
            home_address_locality: "Perth", home_address_country: "AU")
ada.name.to_s              # => "Ada Lovelace"
ada.mobile_phone.to_s      # => "+61491570156"
ada.work_phone.persisted?  # => false
```

```text
BEGIN
Name Load       SELECT "names".*     FROM "names"     WHERE … AND "names"."slot" = ''          LIMIT 1
Phone Load      SELECT "phones".*    FROM "phones"    WHERE … AND "phones"."slot" = 'mobile'   LIMIT 1
Address Load    SELECT "addresses".* FROM "addresses" WHERE … AND "addresses"."slot" = 'home'  LIMIT 1
Email Create    INSERT INTO "emails"    (…, "slot", "address", …)  VALUES (…, '', 'ada@example.com', …)
Name Create     INSERT INTO "names"     (…, "slot", "given", "family", …)  VALUES (…, '', 'Ada', 'Lovelace', …)
Phone Create    INSERT INTO "phones"    (…, "slot", "e164", …)  VALUES (…, 'mobile', '+61491570156', …)
Address Create  INSERT INTO "addresses" (…, "slot", "locality", "country", …)  VALUES (…, 'home', 'Perth', 'AU', …)
COMMIT
```

Three reads for the components not yet loaded, four inserts for the ones that
now hold something. The work phone was never touched and is still not a row.

Companies, relationships and markers work the same way:

<!-- verify:console -->
```ruby
engines = Company.create!(name: "Analytical Engines",
                          address_locality: "London", address_country: "GB")
ada.update!(employer: engines)
ada.add(:favourite)

engines.name                                          # => "Analytical Engines"
engines.employees.map { |person| person.name.to_s }   # => ["Ada Lovelace"]
ada.favourite?                                        # => true
Person.with_component(Address, prefix: :home, country: "AU").count  # => 1
```

That last line asks a question about composition — which people have a home
address in Australia? — and it compiles to one `EXISTS` against the `addresses`
table, scoped to people:

```sql
SELECT COUNT(*) FROM "entities"
WHERE "entities"."model" = 'people'
  AND EXISTS (SELECT 1 FROM "addresses"
              WHERE "addresses"."slot" = 'home' AND "addresses"."country" = 'AU'
                AND "addresses"."entity_id" = "entities"."id")
```

## Under the hood

Everything so far is stored in ordinary tables. Here is `addresses`, joined to
the entities that own its rows:

```text
   model   | slot | locality | country
-----------+------+----------+---------
 companies |      | London   | GB
 people    | home | Perth    | AU
```

A person's home address and a company's address sit in one table, distinguished
by their owner's `model` and their own `slot`. The table knows nothing about
people or companies. That is a property the geocoder below depends on.

Each component table has real types and real constraints. This is `phones`,
slightly abridged:

```text
   Column   |            Type             | Nullable |      Default
------------+-----------------------------+----------+-------------------
 id         | uuid                        | not null | gen_random_uuid()
 entity_id  | uuid                        | not null |
 slot       | character varying           | not null | ''
 e164       | character varying(16)       |          |
 extension  | character varying(8)        |          |
 created_at | timestamp(6)                | not null |
 updated_at | timestamp(6)                | not null |
Indexes:
    "phones_pkey" PRIMARY KEY, btree (id)
    "index_phones_on_entity_id_and_slot" UNIQUE, btree (entity_id, slot)
Foreign-key constraints:
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
```

The unique index on `(entity_id, slot)` is what makes a slot a singleton: the
database itself refuses Ada a second mobile phone. The cascading foreign key
means deleting an entity deletes its components without Rails loading any of
them. This is not an entity–attribute–value store, where every value is a string
in one big table waiting to be cast. Each shape has its own table and its own
columns.

The `relationships` table is the least self-describing of them. Ada's employer
is a row with `slot = 'employer'`, `owner_model =
'people'`, and a `target_id` that is a real foreign key into `entities`. A
relationship declared `unique: true` — an order's single invoice, say — sets an
`exclusive` column covered by a partial unique index, so that "only one" is
enforced by the database rather than by a validation two requests could race
past. The shape has a precedent in Rails itself: Active Storage keeps every
attachment in one table, keyed by record and name. The cost is legibility. Read
the database directly and you see `target_id` under `slot = 'employer'`, not a
column called `employer_id`.

## A system

Now the third letter. In Entity–Component–System, a *system* is code that runs
over every entity carrying some component, whatever kind of entity that is. Here
is a geocoder, in a file of its own:

<!-- verify:file app/systems/geocoder.rb -->
```ruby
# Gives every Address a Geolocation in the same slot, whichever kind of
# entity owns it. PLACES stands in for a geocoding service: approximate
# city centres, and anywhere else is "not found".
class Geocoder
  PLACES = {
    %w[AU Perth]    => [-31.9523, 115.8613],
    %w[GB London]   => [51.5074, -0.1278],
    %w[NZ Auckland] => [-36.8485, 174.7633]
  }.freeze

  def self.call
    Address.preload(:entity).find_each.count { |address| geocode(address) }
  end

  def self.geocode(address)
    owner = address.entity
    return false unless owner.class.declaration_for(Geolocation, prefix: address.slot)

    geolocation = Geolocation.find_or_initialize_by(entity: owner, slot: address.slot)
    return false if geolocation.geocoded_at && geolocation.geocoded_at >= address.updated_at

    lat, lng = PLACES[[address.country, address.locality]]
    geolocation.locate(lat, lng, at: address.updated_at)
    geolocation.save!
  end
end
```

It reads the `addresses` table directly, so one pass finds Ada's home address
and the company's address without the word `Person` or `Company` appearing
anywhere. Three decisions in it are worth explaining.

**Pairing by slot.** An address is geocoded only if its owner declares a
`Geolocation` in the same slot: a person pairs `home` with `home`, and a company
pairs the two in its default slot. `declaration_for` is how a system asks an
entity class what it is made of. A new kind of entity takes part by declaring
the pair, and the geocoder does not change.

**Staleness by version.** A geolocation is stamped with its address's
`updated_at`, not with the clock. If the stamp is at least as new as the address,
the work is done and the address is skipped; edit the address and its
`updated_at` moves past the stamp. Stamping with the clock instead would miss an
edit that landed while a lookup was in flight.

**Not found is an answer.** An unknown place is recorded as `locate(nil, nil)`:
no coordinates, but a stamp. It is not retried until the address changes, and
an old coordinate never outlives the address it described.

The lookup is simulated: three approximate city centres in a hash, where a real
application would call a geocoding service. Rails picks up a new directory under
`app` only at boot, so restart the console, find Ada again, and run it:

<!-- verify:console -->
```ruby
ada = Person.with_marker(:favourite).sole

Geocoder.call                                         # => 2
ada.reload.home_geolocation.coordinates.map(&:to_f)  # => [-31.9523, 115.8613]
Geocoder.call                                         # => 0

ada.update!(home_address_locality: "Auckland", home_address_country: "NZ")
Geocoder.call                                         # => 1
ada.reload.home_geolocation.coordinates.map(&:to_f)  # => [-36.8485, 174.7633]
```

The first run geocodes both addresses. The second does nothing, because nothing
has changed. Ada's move to Auckland is noticed and redone, and nothing else is.
The [demo's version of this
system](https://github.com/kranzky/ecs_rails/blob/main/demo/lib/demo/geocoder.rb)
adds batching and survives two runs overlapping, and the [live
demo](https://ecs-rails.kranzky.com/geocoder) has a page that runs it and plots
the results on a map.

Two kinds of entity, ten components between them, a relationship, a marker and
a system later:

<!-- verify:commands -->
```sh
ls db/migrate
```

<!-- verify:output -->
```text
20261012023722_ecs_rails_install.rb
```

## What it costs

The question I most wanted answered for this release was not whether the
approach works but what it costs, so I measured it. The demo includes a [small
marketplace](https://ecs-rails.kranzky.com/products) — sellers,
products, reviews, a basket and a checkout — and the
[benchmark](https://github.com/kranzky/ecs_rails/blob/main/docs/design/performance-comparison.md)
runs its real code against a conventional Rails implementation of the same
features: product fields on the product row, ordinary foreign keys, equivalent
indexes, identical rendered HTML. Both are seeded with the same deterministic
data, and each workload is timed over twenty warm samples in a fresh Ruby
process.

At 5,000 products, on my laptop (an Apple M1 Pro, with PostgreSQL 14, Ruby 3.4
and Rails 8.1), the median latencies in milliseconds were:

| Workload | ECS | Conventional | Ratio |
|---|---:|---:|---:|
| Catalogue page: filtered, sorted, 24 products | 40.1 | 18.2 | 2.2× |
| Product page with 24 reviews | 20.5 | 5.1 | 4.0× |
| Checkout of three items, committed | 55.6 | 14.3 | 3.9× |
| Search-indexing sweep over every product | 2,974 | 1,542 | 1.9× |
| Title and stock of 24 products, every slot preloaded | 20.2 | 2.0 | 9.9× |
| The same, preloading only those two slots | 5.7 | 1.2 | 4.9× |

Conventional Rails was faster for every workload at every size — 100, 1,000
and 5,000 products — by between about two and ten times. It allocated far fewer
Ruby objects as well: the catalogue page took 18,742 allocations against 2,387,
and a checkout made 60 reads and 40 writes where the conventional one made 9 and
14. Fully populated, the ECS database was about twice the size, 48.7 MiB against
24.6, partly because it holds the whole installed catalogue, used or not. Those
figures were measured in September, on the source that became 0.3.0. Rerunning
the benchmark against the published gem this month gave identical allocation
and query counts, and ratios within 13 per cent of the first run's.

The query plans explain most of the gap. A conventional product is one row. An
ECS product's state, tags, price, rating and search vector are rows in separate
tables, so the catalogue query joins the state and tag tables to find its
candidates, then probes the price, rating and search tables' indexes for each
one: 18,249 buffer hits and 19.3 ms of execution, against 2,500 hits and 4.9 ms
for a single table scanned and sorted. That is the
loss of wide-row locality, and it is structural. A model composed from separate
tables cannot also keep everything on one row.

Some of the gap is not structural. The last two lines of the table are the same
projection — the titles and stock of 24 products — once preloading every `Text`
and `Counter` slot a product declares (the benchmark deliberately gives each
product six of each, to make that cost visible), and once preloading only the
two it reads, using nothing but Rails' own `preload`. That cut the time by nearly
three-quarters. The checkout's 60 reads, and the indexer's habit of reloading
every vector it writes, are the same kind of target.

Stated plainly, then, here is what composition costs:

- **Virtual is not stored.** A component you have not set reads as its
  defaults, but queries see only rows. A virtual `Counter` reads zero and does
  not match `with_component(Counter, count: 0)`. Presence is asked about with
  `has?` and recorded with markers, deliberately.
- **Reads you did not write.** Every component not yet loaded costs a `SELECT`
  the first time it is read, even when the answer is "no row". Preload what a
  page shows.
- **Less locality.** A record is spread across tables, and wide reads pay for it,
  as above.
- **Shared tables, shared indexes.** Every entity type's addresses live in one
  table, and every link in the application lives in `relationships`. Queries
  filter by slot and entity model, and one set of indexes serves every type at
  once. Tuning an index for one entity type means writing a migration after all.
- **Lifecycle boundaries.** Deleting an entity removes its components by
  database cascade, so component `destroy` callbacks do not run. Removing a
  person from `company.employees` deletes the link, not the person. Setting a
  component back to its defaults leaves its row in place.

## Where the promise ends

The title oversells a little, and the qualification is precise: *composition
from the installed catalogue needs no migration.* Two things still do.

A new version of the catalogue — a component added, a column changed — arrives
in a gem release, and `bin/rails generate ecs_rails:upgrade` writes a migration
for the difference. So does adopting a set you skipped at install: the
marketplace needs `Money`, which lives in the `commerce` set, not `core`.

And a component the catalogue does not have is still a component you can write.
`bin/rails generate ecs_rails:component Temperature celsius:decimal` writes a
class and a migration, just as in version 0.1, and the README [walks through
one](https://github.com/kranzky/ecs_rails/blob/main/gem/README.md#when-another-migration-is-needed).
The catalogue is the default, not a cage.

## Where it goes next

The next release is about the numbers above. The plan for 0.4.0 is to preload
only what a page reads, batch the search indexer's writes instead of reloading
every vector, and trim the checkout's reads without loosening its locks — each
change measured against the same benchmark. None of that will close the gap. A
product spread across nine tables will not read as fast as a product on one
row, and I would rather say so now than promise otherwise later.

So it is worth being plain about who this is for. It is for the stage of a
project when the shape of the data is still the open question — a hobby
project, a prototype, an idea you want in front of people by the weekend — and
not having to settle the schema is worth more than the milliseconds. The data
lives in ordinary, typed PostgreSQL tables, so nothing stops a hot path from
being given a conventional model once it has earned one.

In July I said the shelf was nearly bare. It now holds two dozen components,
each one a small, considered decision about one shape of data — a phone number
in E.164, a currency amount in minor units, an address shaped like schema.org's
`PostalAddress`. The most useful thing you could do, if the idea interests you,
is still to write one. A catalogue component is a module and a schema
declaration in the gem, and the [source](https://github.com/kranzky/ecs_rails)
shows how the existing ones are made.

The [live demo](https://ecs-rails.kranzky.com) shows the approach at the scale
of a bulletin board and a marketplace, with one migration between them, and the
[tutorial](https://github.com/kranzky/ecs_rails/blob/main/gem/README.md) is the
place to start your own.

I'll let you know how I get on.

---

## References

- **[The gem](https://rubygems.org/gems/ecs_on_rails)** — `ecs_on_rails` 0.3.0,
  on RubyGems.
- **[The live demo](https://ecs-rails.kranzky.com)** — a bulletin board and
  marketplace composed from the catalogue, with one migration.
- **[The tutorial](https://github.com/kranzky/ecs_rails/blob/main/gem/README.md)**
  — a contacts directory, step by step, plus upgrading and the bespoke-component
  escape hatch.
- **[The source](https://github.com/kranzky/ecs_rails)** — code, ADRs, RFCs and
  the friction log, on GitHub.
- **[The benchmark](https://github.com/kranzky/ecs_rails/blob/main/docs/design/performance-comparison.md)**
  — method, raw results, query plans and how to reproduce them.
- **[This post's code](https://github.com/kranzky/ecs_rails/blob/main/docs/blog/verify.rb)**
  — every command and console line above, replayed against the published gem.
- **[Composing Rails](https://github.com/kranzky/ecs_rails/blob/main/docs/blog/composing-rails.md)**
  — the first post, on why components rather than inheritance.
