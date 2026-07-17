# ECS Rails

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Ruby on Rails.

> **Status: pre-alpha, not published.** Half of v0.1 is landed — entities,
> components, and the registry work; the `component` DSL, delegation, and lazy
> components do not exist yet, so the example below is the *target* API, not
> what ships today. Being built RFC by RFC against a settled design
> ([docs/](../docs/)).

## The idea

Replace one-table-per-model with one-table-per-component. An entity is a
lightweight identity row; all state and behaviour live in small, reusable
components that are composed onto it.

```ruby
class User < ApplicationEntity
  component Name
  component Email
  component Avatar
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
user.email.address = "a@b.com"
user.save!                     # now `emails` gets a row

user.send_welcome_email        # delegated to the Email component
Email.where(verified: false)   # components are queried directly
```

Components are lazy: if every attribute equals its default, no row exists.
Components are shared by *type*, so `Likes` behaves identically on a `Post` and
a `Comment`, without STI and without polymorphic associations.

## Documentation

- **[Architecture](../docs/architecture.md)** — the invariants. Start here.
- **[ADRs](../docs/adr/)** — why the design is the way it is.
- **[RFCs](../docs/rfc/)** — the build order.
- **[Backlog](../docs/backlog.md)** — what deliberately isn't being built.

## Development

Requires Ruby >= 3.2 and a running PostgreSQL.

```sh
createdb ecs_rails_test
bundle install
bundle exec rspec
```

Set `DATABASE_URL` to point the suite at a different database.

## Names

Three, deliberately different — see
[ADR-0007](../docs/adr/0007-monorepo-and-licensing.md#three-different-names).

| | |
|---|---|
| GitHub repo | [`rails-ecs`](https://github.com/kranzky/rails-ecs) |
| RubyGems gem | `ecs-rails` |
| Ruby module | `EcsRails` |
| `require` | `ecs_rails` |

The suffix (`ecs-rails`, like `rspec-rails`) means "for Rails". A `rails-`
prefix is reserved by convention for Rails Core Team gems.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
