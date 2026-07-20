# ECS Rails — v0.1 Retrospective

**Date:** 2026-07-20
**Milestone:** v0.1 — feature-complete, demo-validated, tagged. Not yet published
to RubyGems.

---

## The hypothesis

ECS Rails started as a one-page [proposal](../../proposal.html): reimagine
ActiveRecord around an Entity–Component–System model. One `entities` table of
bare identity rows; all state and behaviour in small, reusable **components**,
one table each; entities *composed* from components rather than inheriting from a
base class.

The proposal was a sketch, not a spec. It made claims — "No STI", "reuse without
inheritance", `Post.with(PublishState)` — without saying how any of them worked.
So the v0.1 question was never "can this be built?" but:

> **Is modelling a real Rails app out of components actually pleasant?**

Everything else was in service of answering that honestly.

## The outcome

**Yes** — with the friction concentrated in places we could name and fix, not in
the core idea.

- **11 RFCs**, each one feature and roughly one commit, all implemented.
- **12 ADRs**, several amended by the very demo meant to validate them.
- **468 passing examples** against real PostgreSQL.
- A **working bulletin board** — users, posts, comments, groups, memberships,
  markers, a browsable UI — built entirely on the gem.

The proposal's headline claims held up, once made precise:

| Proposal claim | v0.1 reality |
|---|---|
| No STI | True for *state and behaviour*. Identity keeps a discriminator ([ADR-0002](adr/0002-single-entities-table.md)) — the honest version. |
| Marker components (`Moderator`) | Work, via an explicit presence API ([ADR-0009](adr/0009-component-presence.md)) the proposal never specified. |
| Reuse without inheritance | `Likes` behaves identically on `Post` and `Comment`. Clean. |
| `Post.with(PublishState)` | Shipped as `with_component` — `.with` collides with ActiveRecord ([ADR-0011](adr/0011-component-query-dsl.md)). |
| Lazy components | `user.email` is never `nil`; a row appears only when a value differs from its default. |

## What the process got right

Three things, worth keeping.

**Specify before building.** [architecture.md](architecture.md) fixed the
invariants first; every RFC referred back to it. When an RFC and the architecture
disagreed, that disagreement was the signal — and it fired often.

**Build the demo *alongside* the gem, not after.** [PROCESS.md](../PROCESS.md)'s
loop — implement, use in the demo, log friction, fix the gem — is where the real
findings came from. The [friction log](friction-log.md) is the actual product of
this project as much as the gem is.

**Delegate implementation, but make the spec adversarial.** Each RFC was
implemented by a sub-agent told to *push back* rather than code around problems.
That single instruction paid for itself many times over.

## What the demo and the sub-agents found

The design was wrong, or under-specified, far more often than the code was. A
running tally of what only surfaced by *executing* the thing:

- **Two approved ADRs were falsified by their own dependencies.**
  [ADR-0008](adr/0008-subclass-resolution-on-read.md) assumed a Rails hook that
  is dead code unless you opt into the STI machinery it was trying to avoid.
  [ADR-0003](adr/0003-virtual-components-skip-validation.md) claimed the dirty
  rule "follows ActiveModel" — but a virtual component sets `entity_id`, which
  ActiveModel counts as a change, so following it would insert a row for every
  component ever *read*. Both ADRs were internally coherent and would have passed
  review. Only running the code caught them.

- **An infinite recursion in the gem's own worked example.**
  [ADR-0006](adr/0006-relationships-are-plain-components.md) showed
  `class Author; belongs_to :author`. On a `component Author`, that collided the
  reader with the delegated association and `post.author` recursed forever. The
  fix (raise at declaration) pointed at a *better* model — `Authorship` with
  `belongs_to :author`, so `post.author` returns the User.

- **A test harness that silently swallowed rollbacks.** Every atomicity
  assertion in the suite had been passing whether the code rolled back or not,
  because the wrapping transaction was joinable. One flag fixed it; the bug was
  invisible until someone looked.

- **The proposal's entire query syntax collides with ActiveRecord.** `.with`
  (CTEs), `.without` (excluding), `.composed_of` (aggregations) — all taken.

- **Two features the proposal *implied* but never specified**: the presence API
  (markers don't work without it) and the query DSL's automatic entity-model
  scoping (without it, a shared component leaks across entity types — a latent
  production bug).

The pattern: a spec written by reasoning about Rails is confidently wrong in ways
review won't catch. Execution is the only reliable oracle.

## What v0.1 deliberately is not

- **Not published.** The gem is tagged and works; extraction to its own repo and
  a RubyGems release are a separate, deliberate step
  ([ADR-0007](adr/0007-monorepo-and-licensing.md)).
- **Not optimised.** [architecture.md §7](architecture.md) disclaims query
  tuning. `EXISTS` on an indexed column, `preload` to bound query counts — but no
  planner.
- **Not a general ECS.** No tick loop, no archetype storage. This is a
  persistence architecture, not a game engine.

## Where it goes next

The [backlog](backlog.md) is now sorted into *shipped*, *confirmed need*, and
*speculative*. Nothing remaining is a blocker; all of it is enhancement.

The most compelling next item is the **relationship DSL**. The demo's
`Authorship`, `MemberUser`, and `MemberGroup` all reinvent the same
`belongs_to`-in-a-component boilerplate; a Flecs-style
`relates_to :author, User` would absorb it, and would also enable a
relationship-aware nested preloader (closing the last N+1 the demo left — the
author's name, two hops out). It was deferred on purpose
([ADR-0006](adr/0006-relationships-are-plain-components.md)) until the demo
showed what it should look like. It now has.

After that: required components, non-equality query conditions, Systems as a
first-class concept. Each waits for the demo to prove it needs them — the same
discipline that got v0.1 here.

## The one-line verdict

The idea is sound, the API is pleasant, and the design is only as good as the
demo that stress-tests it. Build the demo first, and let it argue back.
