# ECS Rails

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Ruby on Rails.

> This README describes the **unreleased 0.3.0 API on `main`**, tested on real
> PostgreSQL. Published 0.2.2 has the earlier API; use a source checkout for
> the examples below. The companion demo is in `demo/`. See the
> [v0.1 retrospective](https://github.com/kranzky/ecs_rails/blob/main/docs/retrospective-v0.1.md)
> for the full story of how it was designed.

## The idea

Replace one-table-per-model with one-table-per-component. An entity is a
lightweight identity row; all state and behaviour live in small, reusable
components that are composed onto it.

```ruby
class User < ApplicationEntity
  component Name
  component Email
  component Image, prefix: :avatar
  marker :moderator            # a marker: no data, presence is the meaning
end
```

```ruby
user = User.create!            # one row in `entities`, no component rows
user.email                     # => #<Email> — virtual, not persisted
user.email_address = "a@b.com" # delegated: the Email component, prefixed
user.save!                     # now `emails` gets a row

user.name.initials            # behaviour lives on the component
user.errors[:"email.address"]  # component errors merge onto the entity

User.create!(name_given: "Ada", email_address: "a@b.com")  # flat keys route too
```

Delegated methods carry the component's name — `user.email_address`,
`user.name_given` — so two components can share an attribute without a clash.
`component Email, prefix: false` opts a declaration back to bare names.

To update a component, use ordinary attribute assignment through its reader:

```ruby
user.email.assign_attributes(address: "new@example.com")
user.save!  # validates and saves touched components together
# Or: user.update!(email_address: "new@example.com")
```

`user.email = Email.new(address: "replacement@example.com")` replaces the row
atomically on a saved user; on a new user it waits for `user.save!`. Default-only
components stay virtual. Assigning `nil` removes the row; the reader still returns
a virtual Email. Components cannot move between owners or persisted slots.
Replacement validation failure raises `ActiveRecord::RecordInvalid` and keeps
the previous row; after an outer transaction rollback, reload the user.

`reload_email` and `reset_email` clear both caches. The generated `build_email`,
`create_email` and `create_email!` helpers raise `EcsRails::InvalidComponent`
with guidance to use the reader, because those separate persistence paths bypass
the lazy lifecycle. Inverse relationship APIs such as `user.posts.create!` remain
ordinary Rails associations.

A component can be declared more than once, under labels — a *slot*:

```ruby
class User < ApplicationEntity
  component Address                      # user.address, user.address_line1
  component Address, prefix: :business   # user.business_address, user.business_address_line1
  component Phone,   prefix: :mobile     # user.mobile_phone
end

user.business_address.line1 = "1 St Georges Tce"
user.save!                               # one row per slot, in one `addresses` table
User.with_component(Address, prefix: :business, region: "WA")
```

**The catalogue.** Twenty-five standard components ship in the gem —
`Name`, `Email`, `Address`, `Phone`, `Text`, `Money`, `State`, `Counter`,
`Tags`, `Token`, `Period`, ... — and `rails g ecs_rails:install` creates every
one of their tables in a single migration. After that, composing entities from
them needs no migration at all: a slot names the role.

```ruby
class Company < ApplicationEntity
  component Text, prefix: :name
end

class Product < ApplicationEntity
  component Text,       prefix: :title      # product.title (the String); product.title_text (the Text)
  component Money,      prefix: :price      # product.price_money.to_s => "USD 19.99"
  component Identifier, prefix: :sku        # product.sku, unique per slot
  component Rating                         # product.rating_stars
  component State,      prefix: :listing, states: %w[draft listed delisted]
  relates_to :seller, Company
  marker :featured
end
```

Cross-entity links are rows in one `relationships` table, created at install,
so declaring one is pure Ruby:

```ruby
class Post < ApplicationEntity
  component Text, prefix: :title
  component Text, prefix: :body
  component Counter, prefix: :likes
  component State, prefix: :publish, states: %w[draft published]
  relates_to :author, User                  # post.author, post.author=, post.author_id
end

class User < ApplicationEntity
  has_many :posts, via: :author             # the parent side: a real collection of Posts
end

class Order < ApplicationEntity
  has_one :invoice, via: :order             # needs the child's unique: true
end

class Invoice < ApplicationEntity
  relates_to :order, Order, unique: true    # at most one Invoice per Order, DB-enforced
end

user.posts.create!(title: "Hello")
Post.with_related(:author, user).includes_related(:author)
```

Presence, querying and preloading compose with these declarations:

```ruby
# Lazy components — no row until a value differs from its default.
user.avatar_image.persisted?                  # => false, costs no INSERT

# Presence / markers — a user IS a moderator when the row exists.
user.add(:moderator)
user.moderator?                              # => true
user.remove(:moderator)
User.with_marker(:moderator)

# Query by composition — avoids AR's .with (CTEs); scopes to the entity model.
Post.with_component(State, prefix: :publish, status: "published")
User.without_component(Image, prefix: :avatar)
Product.with_component(Money, prefix: :price) { where("amount_cents < ?", 5000) }
Product.order_by_component(Rating, :stars, :desc)   # sort by a component's value

# Inverses: `dependent:` removes link rows, never the child entities.
# Destroy children as entities: basket.items.each(&:destroy)

# Preload to bound the query count on a list view.
Post.with_component(State, prefix: :publish, status: "published")
    .includes_components(Text, Counter)
```

Components are shared by *type*, so a `Counter` in the `likes` slot behaves
identically on a `Post` and a `Comment`. Entity identity uses a model
discriminator; state and behaviour live in the reusable components.

## Getting started

```ruby
# Gemfile — point at the gem directory in your local main checkout.
# The source is needed for the unreleased API documented above.
gem "ecs_on_rails", path: "/path/to/ecs_rails/gem"
```

```sh
bundle install
rails g ecs_rails:install                    # the core set; --sets core commerce for more
rails db:migrate                             # one install migration for catalogue composition
```

Entities go in `app/entities`, components in `app/entities/components`
([configurable](https://github.com/kranzky/ecs_rails/blob/main/docs/adr/0010-entity-component-directory-layout.md)); the
install generator wires the autoloading and writes a one-line class per
catalogue component. `rails g ecs_rails:component Widget size:integer` is the
escape hatch for a bespoke table.
Gem upgrades and bespoke components can require further migrations.

After updating the gem, run `rails g ecs_rails:upgrade` and review its migrations.
Run the generator in an environment with eager loading disabled (development by
default): an old app needs the generated component classes before it can fully
boot with the new gem. After migrating and updating marker declarations, verify
the completed app with `bin/rails zeitwerk:check`.
It verifies the existing catalogue's columns, unique/partial indexes and foreign
keys, then generates compatible additions. An incompatible definition reports
its table, actual properties and expected properties before writing files;
prepare an explicit repair/backfill migration and rerun upgrade. It never
converts existing values or replaces constraints automatically. New constraints
still validate existing rows when the generated migration runs.

## Compatibility checks

The gem requires Ruby >= 3.2 and Rails >= 7.1, < 9. The representative CI matrix
covers Ruby/Rails 3.2/7.1, 3.2/7.2, 3.3/8.0, 3.2/8.1, 3.4/8.1 and 4.0/8.1,
resolving current patches within each Rails minor. It runs PostgreSQL gem specs
and packaged fresh-install/0.2.2-upgrade checks for each entry. The demo suite,
eager loading and a 100% public-API documentation gate run separately.

JSON is constrained to version 2 because supported Rails decoders still use
positional option hashes incompatible with JSON 3. This is a runtime dependency,
so a packaged consumer receives the same constraint as the test suite.

To reproduce a Rails series locally from `gem/`:

```sh
export BUNDLE_GEMFILE="$PWD/gemfiles/rails_7.1.gemfile"
bundle install
DATABASE_URL=postgresql:///ecs_rails_test bundle exec rspec
DATABASE_URL=postgresql:///ecs_rails_test bundle exec ruby script/package_smoke.rb
```

The package smoke script creates its own uniquely named PostgreSQL databases;
its connection role needs permission to create databases. It removes only those
databases after the run. CI uploads each built gem with its resolved dependency
lockfile. This tests released versions, not future Ruby/Rails releases.

## Documentation

- **[Architecture](https://github.com/kranzky/ecs_rails/blob/main/docs/architecture.md)** — the invariants. Start here.
- **[v0.1 retrospective](https://github.com/kranzky/ecs_rails/blob/main/docs/retrospective-v0.1.md)** — what was built, what
  the demo found, what's next.
- **[Source walkthrough](https://github.com/kranzky/ecs_rails/blob/main/docs/source-walkthrough.md)** — follow composition, validation, checkout and indexing through the code.
- **[ADRs](https://github.com/kranzky/ecs_rails/tree/main/docs/adr)** — why the design is the way it is.
- **[RFCs](https://github.com/kranzky/ecs_rails/tree/main/docs/rfc)** — feature contracts and their amendments.
- **[Backlog](https://github.com/kranzky/ecs_rails/blob/main/docs/backlog.md)** — what deliberately isn't built yet.
- **[Friction log](https://github.com/kranzky/ecs_rails/blob/main/docs/friction-log.md)** — the demo's running verdict on
  the API.

## Development

Requires Ruby >= 3.2 and a running PostgreSQL.

```sh
createdb ecs_rails_test
bundle install
bundle exec rspec
```

Set `DATABASE_URL` to point the suite at a different database.

## Names

`ecs_rails` everywhere except the Gemfile — see
[ADR-0007](https://github.com/kranzky/ecs_rails/blob/main/docs/adr/0007-monorepo-and-licensing.md#three-different-names).

| | |
|---|---|
| GitHub repo | [`ecs_rails`](https://github.com/kranzky/ecs_rails) |
| RubyGems gem | `ecs_on_rails` |
| Ruby module | `EcsRails` |
| `require` | `ecs_rails` |
| Generators | `ecs_rails:install`, `:component`, `:upgrade` |

Only the published gem name differs. RubyGems collapses `-`, `_` and case when
comparing names, so `ecs-rails`, `ecs_rails` and `ecsrails` are one name — and
it belongs to an unrelated, still-maintained gem. `ecs_on_rails` keeps the
`rails` keyword without the `rails-` prefix that convention reserves for Rails
Core Team gems.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
