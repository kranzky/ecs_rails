# ECS Rails

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Ruby on Rails.

> **v0.1 — working, not yet published to RubyGems.** The full v0.1 API is
> implemented and tested (468 examples), with a companion bulletin-board app
> built entirely on it. Publishing is a deliberate later step. See the
> [v0.1 retrospective](docs/retrospective-v0.1.md).

## The idea

Replace one-table-per-model with **one-table-per-component**. An entity is a
lightweight identity row. All state and behaviour live in small, reusable
components composed onto it.

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

Components are **lazy**: if every attribute equals its default, no row exists.
They are shared by *type*, so `Likes` behaves identically on a `Post` and a
`Comment` — no STI for state, no polymorphic associations, no inheritance.

Systems are plain Ruby objects that process components without ever loading an
entity:

```ruby
Email.pending.find_each(&:send_welcome_email)
```

## Layout

| | |
|---|---|
| **[`docs/`](docs/)** | The specification. Architecture, ADRs, RFCs, backlog. |
| **[`gem/`](gem/)** | The `ecs_rails` gem. |
| **[`demo/`](demo/)** | A bulletin board built with it, via `path: "../gem"`. |

The demo is built **alongside** the gem, not after it. If a feature feels
awkward in the demo, that's the signal the API is wrong. See
[PROCESS.md](PROCESS.md).

## Names

`ecs_rails` everywhere except the Gemfile — see
[ADR-0007](docs/adr/0007-monorepo-and-licensing.md#three-different-names).

| GitHub repo | RubyGems gem | Ruby module | `require` |
|---|---|---|---|
| `ecs_rails` | `ecs_on_rails` | `EcsRails` | `ecs_rails` |

```ruby
gem "ecs_on_rails"   # Gemfile — the packaging name
require "ecs_rails"  # everything else
```

Only the published gem name differs. RubyGems collapses `-`, `_` and case when
comparing names, so `ecs-rails`, `ecs_rails` and `ecsrails` are one name — and
it belongs to an unrelated, still-maintained gem. `ecs_on_rails` keeps the
`rails` keyword without the `rails-` prefix that convention reserves for Rails
Core Team gems.

## Start here

**[docs/architecture.md](docs/architecture.md)** — the invariants. Everything
else refers back to it.

Then [the ADRs](docs/adr/) for why the design is the way it is, and
[the RFCs](docs/rfc/) for what's built and what's next.

Worth knowing up front, because the honest version is more useful than the pitch:

- **[ADR-0002](docs/adr/0002-single-entities-table.md)** — entity identity still
  uses a discriminator column. What ECS Rails eliminates is STI for *state and
  behaviour*, not for identity.
- **[ADR-0003](docs/adr/0003-virtual-components-skip-validation.md)** — a
  component can't require its own presence. That's the entity's business.
- **[ADR-0005](docs/adr/0005-one-component-per-entity.md)** — one component
  instance per entity, always. The biggest constraint the design imposes.

## Development

Requires Ruby >= 3.2 and PostgreSQL.

```sh
cd gem
createdb ecs_rails_test
bundle install
bundle exec rspec
```

## Licence

MIT. See [LICENSE](LICENSE).
