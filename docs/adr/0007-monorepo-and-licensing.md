# ADR-0007: Monorepo now, split at publish; MIT licence

**Status:** Accepted (amended 2026-07-17)
**Date:** 2026-07-17

## Decision

**Layout.** `gem/` and `demo/` live side by side in this repo. The demo depends
on the gem via `gem "ecs-rails", path: "../gem"`. The gem is extracted to its own
public repository when it is ready to publish to RubyGems.

**Licence.** The whole repository is MIT, under a root `LICENSE`. The gem also
carries `gem/LICENSE.txt` and sets `spec.license = "MIT"` in the gemspec, so it
stays self-contained when extracted.

**Names.** Three names, deliberately different:

| | Name |
|---|---|
| GitHub repo | `rails-ecs` |
| RubyGems gem | `ecs-rails` |
| Ruby module | `EcsRails` |
| `require` path | `ecs_rails` (with an `ecs-rails.rb` shim) |

> **Amended 2026-07-17.** As originally written this ADR said the demo "carries
> no licence and stays private". That is superseded — see
> [Amendment](#amendment). The naming section was added at the same time.

## Reason

**Layout.** PROCESS.md prescribes a tight loop: implement in the gem → use it in
the demo → note friction → improve the gem. Two repos put a `bundle update` and
a cross-repo PR inside every iteration of that loop, which is exactly the wrong
place for friction. A `path:` dependency makes gem changes visible to the demo
instantly.

**Licence.** The portfolio `CLAUDE.md` states all projects are proprietary with
no licence files. ECS Rails is in the **labs** category and is explicitly an
open-source gem in `project.json`. An unlicensed public gem is legally unusable,
so "no licence file" and "open-source gem" cannot both hold. MIT is the Rails
ecosystem default and the lowest-friction choice for adoption.

## Consequences

- This is a **documented exception** to the portfolio-wide proprietary rule,
  scoped to this whole repository. See the amendment.
- The gem's git history will be rewritten or squashed at extraction time. Keep
  gem commits scoped to `gem/` so the split stays clean — do not mix gem and
  demo changes in one commit.
- CI must run the gem's suite and the demo's suite separately.
- Until extraction, the gem is not published and its version stays `0.x`.

---

## Amendment

### The demo is public and MIT, not private

Originally: *"The demo carries no licence and stays private."* Superseded when
the repository was created public at `github.com/kranzky/rails-ecs`, with a root
MIT `LICENSE` covering everything.

**Reason.** A public gem whose reference application is secret helps nobody. The
demo is a teaching artefact — its entire job is to show what modelling a real
Rails app out of components looks like, and to be the place friction gets
noticed (PROCESS.md). Hiding it removes most of its value while protecting
nothing commercially: it is a bulletin board, not a product.

**Consequence.** The exception to the portfolio-wide proprietary rule now covers
the whole repository, not just `gem/`. Nothing here should be treated as
confidential. No secrets, credentials, or customer data — the demo seeds fake
data only.

### Three different names

The repo is `rails-ecs` but the gem is `ecs-rails`, which is not a typo.

Every `rails-*` gem on RubyGems is published by Rails Core Team
(`rails-html-sanitizer`, `rails-dom-testing`, `rails-controller-testing`), so a
`rails-` **prefix** reads as *official Rails org* and raises a Rails trademark
question at publish time. The ecosystem convention for third-party gems is the
**suffix** — `rspec-rails`, `turbo-rails` — meaning "for Rails", not "by Rails".
Bundler's dash convention would also read `rails-ecs` as the namespace
`Rails::Ecs`, i.e. squatting inside Rails' own module.

So: `ecs-rails` on RubyGems, module `EcsRails` (not `Ecs::Rails`, for the same
squatting reason). The GitHub repo name is cosmetic and stays `rails-ecs`.

**Consequence.** Bundler requires a gem by its own name, so a host app's
`Bundler.require` attempts `require "ecs-rails"` — with the hyphen — which Ruby
maps to `lib/ecs-rails.rb`, not `lib/ecs_rails.rb`. The gem therefore ships a
one-line `lib/ecs-rails.rb` shim requiring the canonical `ecs_rails`. Without
it, a host Rails app raises `LoadError` on boot. Verified against the demo.
