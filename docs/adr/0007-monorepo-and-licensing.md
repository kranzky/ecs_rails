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

**Names.** One name across every context, in the casing each one wants:

| | Name |
|---|---|
| GitHub repo | `ecs_rails` |
| RubyGems gem | `ecs_rails` |
| Ruby module | `EcsRails` |
| `require` path | `ecs_rails` |

> **Amended 2026-07-17.** As originally written this ADR said the demo "carries
> no licence and stays private". That is superseded — see
> [Amendment](#amendment). The naming section was added at the same time.
>
> **Amended 2026-07-22.** The RubyGems name was `ecs-rails` (hyphen), which
> needed a `lib/ecs-rails.rb` shim. At publish time `ecs-rails` turned out to be
> taken by an unrelated gem, so the gem is **`ecs_rails`** (underscore) — which
> matches the module and require path exactly and needs no shim. See the
> [naming amendment](#naming-amendment).
>
> **Amended 2026-07-23.** The GitHub repo was originally `rails-ecs`; it was
> renamed to **`ecs_rails`** so the repo, gem, and require path all match. Only
> the module keeps Ruby's constant casing, `EcsRails`.

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
the repository was created public at `github.com/kranzky/ecs_rails`, with a root
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

<a id="three-different-names"></a>
### One name: `ecs_rails`

The gem, the GitHub repo, and the require path are all `ecs_rails`; the module
is its Ruby constant form `EcsRails`. Two nearby names were rejected on the way
here.

The `rails-` **prefix** is out: every `rails-*` gem on RubyGems is published by
Rails Core Team (`rails-html-sanitizer`, `rails-dom-testing`), so it reads as
*official Rails org* and raises a trademark question. Bundler's dash convention
would also read `rails-ecs` as the namespace `Rails::Ecs`, squatting inside
Rails' own module.

The hyphen form `ecs-rails` is out too — it was taken on RubyGems and needed a
require shim (see the naming amendment below).

> **Repo rename (2026-07-23).** The repo was first created as `rails-ecs`, on
> the reasoning that a repo name is cosmetic and could keep the descriptive
> `rails-ecs` ordering even where the gem could not. Keeping the repo out of
> step with everything else proved to be needless friction, so it was renamed to
> `ecs_rails` — the names now align everywhere but the module's casing.

<a id="naming-amendment"></a>
**Naming amendment (2026-07-22).** This originally chose the *hyphen* form
`ecs-rails`, to follow the third-party suffix convention (`rspec-rails`,
`turbo-rails`, meaning "for Rails"). That form has a cost — Bundler requires a
gem by its own name, so `Bundler.require` would attempt `require "ecs-rails"`,
which Ruby maps to `lib/ecs-rails.rb`; the gem shipped a one-line shim there
requiring the canonical `ecs_rails`, or a host app raised `LoadError` on boot.

At publish time `ecs-rails` turned out to be **taken** on RubyGems by an
unrelated gem. The fix was also the cleaner name: `ecs_rails` (underscore)
matches the `EcsRails` module and the `ecs_rails` require path exactly, so
`Bundler.require` loads `lib/ecs_rails.rb` directly and the shim is deleted. The
loss of the "for Rails" suffix reading is a fair trade for one name that is
correct everywhere.
