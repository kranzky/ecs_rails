# ECS Rails

An Entity–Component–System reimagining of ActiveRecord that stays idiomatic to
Ruby on Rails.

> **Published as [`ecs_on_rails`](https://rubygems.org/gems/ecs_on_rails)
> (0.2.2).** The v0.1 API is implemented and tested on real PostgreSQL, and the
> companion bulletin board runs live at
> [ecs-rails.kranzky.com](https://ecs-rails.kranzky.com). See the
> [v0.1 retrospective](docs/retrospective-v0.1.md) and the launch post,
> ["Composing Rails"](docs/blog/composing-rails.md). **v2 is under way** on
> `main`: *zero migrations for composition from the installed catalogue* —
> [ADR-0017](docs/adr/0017-shared-relationships-table.md),
> [ADR-0018](docs/adr/0018-catalogue-in-the-gem.md) — tracked in Linear team
> ECS and released once, as 0.3.0.

## The idea

Replace one-table-per-model with **one-table-per-component**. An entity is a
lightweight identity row. All state and behaviour live in small, reusable
components composed onto it.

```ruby
class User < ApplicationEntity
  component Name
  component Email
  component Image, prefix: :avatar
end

```

```ruby
user = User.create!            # one row in `entities`, no component rows
user.email                     # => #<Email> — virtual, not persisted
user.email_address = "a@b.com" # delegated to the Email component, prefixed
user.save!                     # now `emails` gets a row

user.name.initials            # behaviour lives on the component
Email.where(verified: false)   # components are queried directly

User.create!(name_given: "Ada", email_address: "a@b.com")  # flat keys route too
```

Components are **lazy**: reading an absent component returns virtual defaults;
only a value differing from its default needs a new row. The first read may
query. Components are shared by type: a Counter can serve a Post's likes or a
Product's stock in different labelled slots.

Systems are plain Ruby objects operating on components across entity types.
Follow the executable **[contacts quickstart](gem/README.md#quickstart-a-contacts-directory)**
to install, compose, query, run a system and render a page. For the full sample
application, use **[the demo setup](demo/README.md)**.

## Layout

| | |
|---|---|
| **[`docs/`](docs/)** | The specification. Architecture, ADRs, RFCs, backlog. |
| **[`gem/`](gem/)** | The `ecs_rails` gem. |
| **[`demo/`](demo/)** | A bulletin board and marketplace built entirely from the catalogue — one migration in `db/migrate` — via `path: "../gem"` during a build; pinned to the published gem at each release. |

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

Start with the [quickstart](gem/README.md#quickstart-a-contacts-directory) or
[demo guide](demo/README.md). Read the [source walkthrough](docs/source-walkthrough.md)
when you want to follow the implementation.

The [architecture](docs/architecture.md), [ADRs](docs/adr/) and [RFCs](docs/rfc/)
provide the invariants, design decisions and feature contracts.

Worth knowing up front, because the honest version is more useful than the pitch:

- **[ADR-0002](docs/adr/0002-single-entities-table.md)** — entity identity still
  uses a discriminator column. What ECS Rails eliminates is STI for *state and
  behaviour*, not for identity.
- **[ADR-0003](docs/adr/0003-virtual-components-skip-validation.md)** — a
  component can't require its own presence. That's the entity's business.
- **[ADR-0005](docs/adr/0005-one-component-per-entity.md)** — one component
  instance per entity **per slot**. Labels allow the same type to be reused.

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
