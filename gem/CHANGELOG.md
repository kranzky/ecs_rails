# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] — 2026-07-22

### Changed

- Renamed the gem from `ecs-rails` to **`ecs_rails`** for its first RubyGems
  release: `ecs-rails` was already taken by an unrelated gem. The underscore form
  matches the `EcsRails` module and the `ecs_rails` require path exactly, so the
  `lib/ecs-rails.rb` require shim is removed. No API change — the module, the
  require, and every class are unchanged.

## [0.2.0] — 2026-07-22

Adds cross-entity relationships. Demo-validated by the bulletin-board app.

### Added

- Relationship query & preload sugar (RFC-0013). `Entity.with_related(:author, user)` /
  `without_related(:author)` / `includes_related(:author)` query and preload a
  relationship by its declared name, so the backing component class never appears in
  application code. Thin sugar over the component verbs.
- Relationship DSL (RFC-0012). `relates_to :author, User` on an entity declares a
  cross-entity link with no relationship component file — the DSL defines the
  backing component dynamically. `post.author` / `post.author =` reach the target;
  `rails g ecs_rails:relationship Post author:User` emits the migration. Deleting
  the target nullifies the link; deleting the owner cascades.

## [0.1.0] — 2026-07-20

Feature-complete, demo-validated. Not yet published to RubyGems. See the
[v0.1 retrospective](../docs/retrospective-v0.1.md).

### Added

- Component preloading (RFC-0011). `Entity.includes_components(*Components)` batches
  component loads (all declared, or a named subset) so a list view issues a bounded
  number of queries instead of one per component per row. A thin wrapper over
  ActiveRecord's native `preload`, which already works with lazy components.
- Component query DSL (RFC-0010). `Entity.with_component(Component, **conditions)` /
  `Entity.without_component(Component)` query entities by which components they
  have, compiling to correlated `EXISTS` / `NOT EXISTS` subqueries that apply the
  entity-model scope automatically (a shared component can't leak across entity
  types). Chainable with ordinary ActiveRecord. Avoids `.with` (AR's CTEs).
- Component presence (RFC-0009). `entity.add(Component)` / `entity.has?(Component)` /
  `entity.remove(Component)` and a generated `entity.<component>?` predicate, so
  marker components (Moderator, Administrator) — which carry no state and so are
  never persisted by the lazy save cascade — work.
- Validation error merging (RFC-0007). `entity.valid?` reflects its touched
  components' validity; component errors merge under `entity.errors[:"email.address"]`
  and read naturally in a form. A non-dirty virtual component is not validated.
- Method delegation (RFC-0005). Component methods and attribute accessors are
  callable on the entity — `user.send_welcome_email`, `user.address = "x"`.
  Name clashes between two components raise `DelegationConflict` at load time;
  `except:`/`only:` are the escape hatch.
- Lazy / virtual components (RFC-0006). `entity.email` always returns an
  `Email`, never `nil` — a missing row yields an in-memory component with every
  attribute at its database default. `entity.save` cascades to the components
  you touched, inserting a row only for those that are dirty, in one
  transaction. Reading a component costs a `SELECT` and nothing else.
- The `component` DSL (RFC-0004). `component Name` on an entity declares what it
  is composed from, generates the reader, and wires the `has_one`.
- `ApplicationComponent` (RFC-0003) and entity subclass resolution — a loaded
  entity comes back as its real subclass (`User`, not `ApplicationEntity`).
- `ApplicationEntity` (RFC-0001) — immutable identity rows in one shared
  `entities` table, discriminated by `model`.
- The component registry (RFC-0002), reload-safe by keying on class name.
- `ecs_rails:install` and `ecs_rails:component` generators (RFC-0008).
- Gem scaffold, MIT licence, and RSpec + PostgreSQL test harness.
