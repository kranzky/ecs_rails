# ECS Rails — Agent Instructions

## What this is

An Entity–Component–System reimagining of ActiveRecord, shipped as the gem
`ecs_on_rails` (module `EcsRails`, `require "ecs_rails"`, repo `ecs_rails` —
see [ADR-0007](docs/adr/0007-monorepo-and-licensing.md) for why the names
differ). A **Labs** project in the portfolio: open source (MIT), no revenue
metric. Read the parent `../CLAUDE.md` for portfolio conventions; this file is
the project-specific rule set.

- **v0.1 shipped** (gem 0.2.2, demo live at https://ecs-rails.kranzky.com,
  blog post `docs/blog/composing-rails.md`).
- **v2 is in progress**: *zero migrations after install*. After
  `rails g ecs_rails:install` and one `db:migrate`, entities, relationships,
  markers and systems are pure Ruby. Design of record:
  [ADR-0017](docs/adr/0017-shared-relationships-table.md) (one shared
  `relationships` table) and [ADR-0018](docs/adr/0018-catalogue-in-the-gem.md)
  (the catalogue ships in the gem). Ends in gem 0.3.0, the marketplace demo
  (`docs/design/marketplace-demo.md`) and a blog post, "The Last Migration".

## Read in this order

1. `docs/architecture.md` — the invariants. Every task refers back to it.
2. `docs/adr/` — why. Read the relevant ADR before touching a design.
3. `docs/rfc/` — what, one feature at a time, each with its tests.
4. `docs/friction-log.md` — the demo's running verdict on the API.
5. `PROCESS.md` — how: architecture first, an RFC per feature, tests before
   implementation, tiny commits, build the demo alongside the gem.

## Layout

```
gem/    the gem (lib/, spec/, generators). Specs run on real PostgreSQL.
demo/   a Rails 8 bulletin board built on the gem. Deployed to Fly.io.
docs/   architecture, ADRs, RFCs, backlog, friction log, design, blog.
```

The demo uses the gem via `path: "../gem"` during a build so gem changes are
felt in the demo the same day. Each release repins the published gem, so the
Docker build context stays self-contained. Fly deploys pause in between.

## Workflow

Work is tracked in Linear team **ECS Rails** (key `ECS`, workspace
`future-factory`) — **not** the portfolio's LM team. The Linear MCP connector
needs the user to authenticate via `/mcp` each session.

1. The user hands you an issue number. Read it, then the ADR/RFC it cites.
2. Branch from `main` using the issue's `gitBranchName`.
3. Implement gem first, then apply it to the demo, then record the verdict in
   `docs/friction-log.md`. Update `docs/architecture.md` if an invariant moved,
   and add an amendment section to the RFC/ADR rather than rewriting history.
4. Verify: gem suite green, YARD at 100%, demo boots and its pages render.
5. Commit with a conventional message and `Resolves ECS-XX` in the body.
   Update `gem/CHANGELOG.md` under Unreleased and append a `project.json` log
   entry.
6. Push and open a PR with `gh pr create`. **The user reviews and merges.**
   Never commit to `main`.

Release once, at the end of a milestone, never per feature. `gem push` needs the
user's RubyGems credentials and MFA — you cannot do it. Gem metadata is
immutable once published: check every URI in the gemspec first.

## Running things

```sh
# gem
cd gem && createdb ecs_rails_test   # once
bundle exec rspec                   # DATABASE_URL overrides the default
bundle exec yard stats --list-undoc # must stay 100% documented

# demo (rbenv shims must be on PATH)
cd demo && bin/rails db:prepare && bin/rails demo:reset
bin/rails server -p 3021            # matches .claude/launch.json
bundle exec rspec                   # component specs are placeholders
```

## Design rules that bite

- **Component methods bind `self` to the component**, never the entity
  (ADR-0001). A component never references an entity subclass.
- **Components are lazy** (RFC-0006): no row until a value differs from its
  column default. `""` is not `nil` — a blank form field writes a row unless
  you `.presence` it.
- **Delegation is reader-prefixed** (ADR-0016): `component Email` gives
  `user.email_address`, `user.email_send_welcome_email`. Uniform for
  attributes and verbs; reach an ugly verb through the reader or rename it.
  `prefix: false` opts one declaration back to bare names. `only:`/`except:`
  name the component's methods, never the prefixed name. `relates_to` is bare
  so `post.author` keeps its shape. Flat mass assignment
  (`User.create!(name_first: ...)`) falls out of this and is pinned by spec.
- **Slots** (RFC-0014 / ADR-0015): `component Address, prefix: :business` is a
  second singleton of the same component, reader `business_address`, stored in
  the same table under `slot = "business"`. Every component table has `slot`
  and a unique `(entity_id, slot)` index; every `has_one` is slot-scoped. Slot
  is identity: never delegated, never dirt. Per-slot options are declared on
  the component with `slot_option` and passed as extra keywords on `component`.
  `rails g ecs_rails:upgrade` brings an older schema forward.
- **Relationships share one table** (ADR-0017): `relates_to :author, User` is
  `component Relationship, prefix: :author, delegate: false` plus four
  hand-defined accessors; the app's `Relationship` class includes
  `EcsRails::Catalogue::Relationship` and is found via
  `config.relationship_class_name`. Target type is checked in Ruby on
  assignment; `unique: true` writes `exclusive` for the partial unique index.
  Nested preloads name `target`, not the relationship. There is no relationship
  generator any more.
- **Conflicts raise at declaration time** (ADR-0004). Never a silent winner.
- **Presence is explicit** (ADR-0009): markers persist via `add`/`remove`.
- **Reload safety**: the registry and relationship metadata store class
  *names*, never Class objects. Keep it that way.
- **The DSL reads private ActiveRecord internals** in two places, pinned by
  exact-set specs so a Rails upgrade fails loudly. Do not add a third casually.
- Present pros and cons before an ADR-level change; the user decides, then
  commit fully to the decision.

## Documentation conventions

- YARD tags on every public method; `.yardopts` is read as binary — keep it
  pure ASCII, kramdown markup, `--embed-mixins`.
- Comments explain *why*, with the ADR/RFC number. Long comments are the norm
  in this codebase; match them.
- Spec files open with a paragraph saying which RFC they pin and what would
  break downstream if the pinned behaviour changed.
