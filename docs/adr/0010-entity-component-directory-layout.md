# ADR-0010: Entities live in app/entities, components in app/entities/components

**Status:** Accepted
**Date:** 2026-07-19
**Surfaced by:** the demo (a layout question while building the UI)

## Context

Until now the generators put entities and components in `app/models`, alongside
ordinary ActiveRecord models. In a real app that mixes three kinds of class —
plain AR models, entities, and components — under one directory, and gives no
visual signal of which is which.

The question raised: can entities live in `app/entities` and components in
`app/entities/components`, leaving `app/models` for ordinary Rails models?

## Decision

Yes, and it becomes the gem's **default** layout.

```
app/models/                     ordinary ActiveRecord models
app/entities/                   entities        (User, Post, ApplicationEntity)
app/entities/components/        components      (Email, Name, ApplicationComponent)
```

- `EcsRails.config.entities_path` (default `"app/entities"`) is the single knob.
  Components live in `#{entities_path}/components`.
- `EcsRails.configure { |c| c.entities_path = "app/models" }` relocates the tree
  back under `app/models` — but see the correction below: this is **not** the
  original flat layout.
- `ecs_rails:install` generates a `config/initializers/ecs_rails.rb` that sets
  the config **and** collapses the components directory. `ecs_rails:component`
  reads `entities_path` to place new files.

## How it works

Rails auto-adds every immediate subdirectory of `app/` as an autoload root, so
`app/entities` is a root for free: `app/entities/user.rb` → `User`. The problem
is the nested `components/` — Zeitwerk would namespace it as `Components::Name`,
but components are top-level classes (`Name`, `Email`).

The fix is one line, the same mechanism Rails uses for `app/models/concerns`:

```ruby
Rails.autoloaders.main.collapse(Rails.root.join("app/entities/components"))
```

`collapse` makes the `components/` segment transparent, so
`app/entities/components/name.rb` → `Name`. Verified: the app boots, a full
round-trip works, and `bin/rails zeitwerk:check` (eager loading, production-mode
semantics) passes.

An **initializer** is the right home for the collapse, not `config/application.rb`
or the gem's Railtie:
- An initializer was verified to work under both lazy autoloading and eager
  loading — it runs before `eager_load`.
- The Railtie was rejected: it would need `entities_path` before app
  initializers run, forcing an ordering dependency and reading the default too
  early. A generated initializer is explicit, discoverable, and editable.

## Reason

**Zero runtime cost.** Class names are unchanged, so the registry (keyed by
name, RFC-0002) and the `model` discriminator (ADR-0002) do not notice where a
class lives. This is purely organisational.

**The separation is worth having.** The gem's whole pitch is that entities and
components are a different modelling primitive from ActiveRecord models. Putting
them in their own tree makes that legible at a glance, and keeps `app/models`
meaning what a Rails developer expects.

**Default, not opt-in**, because the gem is unpublished (0.x) with one consumer
(the demo), so there is no compatibility cost to changing it, and a gem should
ship its recommended layout rather than make everyone configure it.

## Consequences

- The generators change: base classes and components land under
  `entities_path`, and install writes the initializer. RFC-0008's file
  locations are superseded; its invariants (UUID PK, unique `entity_id`, cascade
  FK, explicit defaults) are unchanged.
- **Generated specs mirror the layout**: `spec/entities/…` and
  `spec/entities/components/…`. rspec-rails infers `type: :model` from
  `spec/models/`, which these no longer match, so the generated component spec
  declares `type: :model` explicitly.
- Migrations stay in `db/migrate` — unaffected.
- The demo is the reference implementation of this layout.

## Correction (during implementation)

The original draft claimed `entities_path = "app/models"` "restores the old
single-directory layout" and "needs no collapse (nothing is nested)." **Both are
false**, caught by implementing it.

`components_path` is *always* `#{entities_path}/components`, so
`entities_path = "app/models"` puts components in `app/models/components` — still
nested, still needing the collapse (which the generated initializer always
emits, so it works). That is a *third* layout, not the pre-ADR-0010 one where
components sat directly in `app/models`.

**The single `entities_path` knob relocates the whole tree; it cannot express a
flat, single-directory layout.** That is accepted, not a bug to fix: the flat
layout is the thing this ADR exists to move away from, so there is no reason to
make it reachable. If a genuine need appears, `components_path` becomes
independently settable — backlog, not now.

One asymmetry is left standing deliberately: the generated component **spec**
always lands in `spec/entities/components/`, regardless of `entities_path`, while
the **model** follows the config. Under the default layout they agree. Under a
relocated `entities_path` they diverge, which is harmless — the generated spec
declares `type: :model` explicitly, so rspec-rails does not depend on its path —
but it is an inconsistency, noted here rather than hidden. Deriving the spec path
from the config is a cheap later change if the divergence ever bites.
