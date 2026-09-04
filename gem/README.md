# ECS Rails

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Ruby on Rails.

> The full API below is implemented and tested (534 examples on real
> PostgreSQL). A companion bulletin-board app is built entirely on it and runs
> live at **[ecs-rails.kranzky.com](https://ecs-rails.kranzky.com)**. See the
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
  component Avatar
  marker :moderator            # a marker: no data, presence is the meaning
end

class Email < ApplicationComponent
  validates :address, presence: true

  def send_welcome_email
    # self is the Email, never the User
  end
end
```

```ruby
user = User.create!            # one row in `entities`, no component rows
user.email                     # => #<Email> — virtual, not persisted
user.email_address = "a@b.com" # delegated: the Email component, prefixed
user.save!                     # now `emails` gets a row

user.email.send_welcome_email  # behaviour lives on the component
user.errors[:"email.address"]  # component errors merge onto the entity

User.create!(name_first: "Ada", email_address: "a@b.com")  # flat keys route too
```

Delegated methods carry the component's name — `user.email_address`,
`user.name_first` — so two components can share an attribute without a clash.
`component PublishState, prefix: false` opts a declaration back to bare names.

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
class Product < ApplicationEntity
  component Text,       prefix: :title      # product.title_text
  component Money,      prefix: :price      # product.price_money.to_s => "USD 19.99"
  component Identifier, prefix: :sku        # unique per slot
  component State,      prefix: :listing, states: %w[draft listed delisted]
  relates_to :seller, Company
  marker :featured
end
```

Cross-entity links are rows in one `relationships` table, created at install,
so declaring one is pure Ruby:

```ruby
class Post < ApplicationEntity
  relates_to :author, User                  # post.author, post.author=, post.author_id
end

class Invoice < ApplicationEntity
  relates_to :order, Order, unique: true    # at most one Invoice per Order, DB-enforced
end

Post.with_related(:author, user).includes_related(:author)
```

Every v0.1 capability, working today:

```ruby
# Lazy components — no row until a value differs from its default.
user.avatar.persisted?                       # => false, costs no INSERT

# Presence / markers — a user IS a moderator when the row exists.
user.add(:moderator); user.moderator?        # => true
user.remove(:moderator)
User.with_marker(:moderator)

# Query by composition — avoids AR's .with (CTEs); scopes to the entity model.
Post.with_component(PublishState, state: "published")
User.without_component(Avatar)

# Preload to bound the query count on a list view.
Post.with_component(PublishState).includes_components(Title, Body, Likes)
```

Components are shared by *type*, so `Likes` behaves identically on a `Post` and
a `Comment` — reuse without STI and without polymorphic associations.

## Getting started

```ruby
# Gemfile — note the packaging name differs from the require path (see Names)
gem "ecs_on_rails"
```

```sh
bundle install
rails g ecs_rails:install                    # the core set; --sets core commerce for more
rails db:migrate                             # the last migration you need
```

Entities go in `app/entities`, components in `app/entities/components`
([configurable](https://github.com/kranzky/ecs_rails/blob/main/docs/adr/0010-entity-component-directory-layout.md)); the
install generator wires the autoloading and writes a one-line class per
catalogue component. `rails g ecs_rails:component Widget size:integer` is the
escape hatch for a bespoke table.

## Documentation

- **[Architecture](https://github.com/kranzky/ecs_rails/blob/main/docs/architecture.md)** — the invariants. Start here.
- **[v0.1 retrospective](https://github.com/kranzky/ecs_rails/blob/main/docs/retrospective-v0.1.md)** — what was built, what
  the demo found, what's next.
- **[ADRs](https://github.com/kranzky/ecs_rails/tree/main/docs/adr)** — why the design is the way it is (14 decisions,
  several amended by their own demo).
- **[RFCs](https://github.com/kranzky/ecs_rails/tree/main/docs/rfc)** — the 13 features, each one commit.
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
