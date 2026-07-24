# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] — 2026-07-23

### Added

- **YARD API documentation across the whole public API** — `@param`, `@return`,
  `@raise`, `@example` and `@see` tags on every public module, class, attribute
  and method (100% documented, verified by `yard stats`). The existing prose
  rationale is kept; the tags are additive, so
  [rubydoc.info/gems/ecs_on_rails](https://rubydoc.info/gems/ecs_on_rails) now
  renders a real API reference rather than bare comments.
- A `.yardopts`, shipped in the gem so rubydoc.info honours it. Notably
  `--embed-mixins`, without which the DSL that `EcsRails::Entity` gains by
  `extend`ing {EcsRails::DSL}, `Querying`, `Preloading` and `Relationships`
  would not appear on `Entity` at all — which is where users look for it.
- `documentation_uri` in the gemspec, pointing at the rubydoc.info API
  reference. The narrative documentation (architecture, ADRs, RFCs) is reached
  via the homepage and `source_code_uri`.

### Fixed

- `changelog_uri` in the gemspec pointed at `<repo>/blob/main/CHANGELOG.md`,
  which 404s: the gem lives in `gem/` of a monorepo and there is no changelog at
  the repo root, so the Changelog link on the 0.2.1 RubyGems page was broken.
  Gem metadata is immutable once published, so this needed a release to correct.
- `source_code_uri` now points at the `gem/` subtree rather than the repo root.

No code change — 0.2.2 is identical to 0.2.1 apart from gemspec metadata.

## [0.2.1] — 2026-07-23

First RubyGems release.

### Changed

- The gem is published as **`ecs_on_rails`**. Both `ecs-rails` and `ecs_rails`
  are unavailable: an unrelated `ecs-rails` gem already exists, and RubyGems
  treats `-`, `_` and case as equivalent when comparing names, so every spelling
  of "ecs rails" collides with it.
- **No API change.** The require path is still `ecs_rails`, the module is still
  `EcsRails`, and the generators are still `ecs_rails:install`,
  `ecs_rails:component` and `ecs_rails:relationship`. Only the name you put in
  your Gemfile differs:

  ```ruby
  gem "ecs_on_rails"   # Gemfile
  require "ecs_rails"  # everywhere else
  ```

  A `lib/ecs_on_rails.rb` shim requires `ecs_rails`, so a bare `gem
  "ecs_on_rails"` works under `Bundler.require`.

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
