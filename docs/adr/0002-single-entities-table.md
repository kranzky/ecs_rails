# ADR-0002: A single `entities` table with a `model` discriminator

**Status:** Accepted
**Date:** 2026-07-17

## Context

An entity subclass has to mean *something* at query time. `User.all` must return
users and not posts. Two options were considered.

**A. `model` discriminator.** One `entities` table with a `model` column.
`User.all` filters `WHERE model = 'users'`.

**B. Pure ECS.** No discriminator. A `User` *is* any entity carrying the
Name + Email components. `User.all` joins the required component tables.

## Decision

Option A. One `entities` table, one indexed `model` string column, set at
creation and immutable thereafter.

## Reason

Option B is the theoretically purer ECS and it is what Flecs actually does — but
it makes every entity query a multi-table join, and it makes "which subclass is
this row?" genuinely ambiguous once two entity classes declare the same
component set. That ambiguity is fine in a game engine that only ever queries by
component, and hostile in a Rails app that needs `User.find(params[:id])` to
either work or 404.

Option A keeps the common query a single indexed table scan and keeps the entity
subclass a real, answerable question.

## Consequences

- **This is STI-flavoured, and the proposal's headline is "No STI".** Be honest
  about it: what RoRECS eliminates is STI *for behaviour and state* — the wide
  sparse table, the subclass hierarchy, the `type`-column conditionals. Identity
  still has a discriminator. The `entities` table stays narrow (3 columns)
  precisely because it holds no domain state, which is the actual STI pathology.
- Renaming an entity class requires backfilling `entities.model`.
- Two entity classes may legitimately declare identical component sets and
  remain distinct. Under option B they would have been indistinguishable.
- The door to option B stays open: `model` can become advisory later without a
  schema change.
