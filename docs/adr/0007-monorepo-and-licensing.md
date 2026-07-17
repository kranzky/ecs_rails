# ADR-0007: Monorepo now, split at publish; MIT licence

**Status:** Accepted
**Date:** 2026-07-17

## Decision

**Layout.** `gem/` and `demo/` live side by side in this repo. The demo depends
on the gem via `gem "rorecs", path: "../gem"`. The gem is extracted to its own
public repository when it is ready to publish to RubyGems.

**Licence.** The gem is MIT. `gem/LICENSE.txt` exists and
`spec.license = "MIT"` is set in the gemspec. The demo carries no licence and
stays private.

## Reason

**Layout.** PROCESS.md prescribes a tight loop: implement in the gem → use it in
the demo → note friction → improve the gem. Two repos put a `bundle update` and
a cross-repo PR inside every iteration of that loop, which is exactly the wrong
place for friction. A `path:` dependency makes gem changes visible to the demo
instantly.

**Licence.** The portfolio `CLAUDE.md` states all projects are proprietary with
no licence files. RoRECS is in the **labs** category and is explicitly an
open-source gem in `project.json`. An unlicensed public gem is legally unusable,
so "no licence file" and "open-source gem" cannot both hold. MIT is the Rails
ecosystem default and the lowest-friction choice for adoption.

## Consequences

- This is a **documented exception** to the portfolio-wide proprietary rule,
  scoped to `gem/` only. The demo remains proprietary and unlicensed.
- The gem's git history will be rewritten or squashed at extraction time. Keep
  gem commits scoped to `gem/` so the split stays clean — do not mix gem and
  demo changes in one commit.
- CI must run the gem's suite and the demo's suite separately.
- Until extraction, the gem is not published and its version stays `0.x`.
