# Demo rendered and accessibility review (ECS-35)

**Date:** 2026-09-27 · **Scope:** the demo as a visitor sees it, after the
acting-as bar, the tour and the geocoder map landed · **Tools:** Chrome
(headless, via puppeteer-core 23.11.1) and axe-core 4.13.0

The September review read templates and CSS; it never looked at a rendered
page. This one did, on every page, and records what it found.

## Method

`demo/script/qa/pages.rb` lists 21 pages from a freshly reset seed: the tour,
posts (list, show, new), people (list, show, new), groups (list, show), the
market (list, show, edit as an owner), sellers (list, show), basket, checkout,
orders, order, invoice, the geocoder and How it works.

`demo/script/qa/pages.js` visits each one four times — desktop (1280 wide)
and phone (390 wide, emulated as a mobile device) in light and dark schemes —
and:

- saves a full-page screenshot of each (84 in all), which were reviewed by eye;
- runs axe-core with the WCAG 2.1 A and AA rule sets plus best practice, once
  per colour scheme (contrast differs between them);
- on the phone, reports any element wider than the viewport outside the
  deliberately scrolling table and code containers;
- on the desktop in light mode, presses Tab up to 45 times and records each
  focused element and whether it shows a focus ring.

`demo/script/qa/states.js` reaches states a URL alone does not: an invalid
new person, a product with a taken SKU, a declined card at checkout, empty
post and product searches, an empty basket, and the geocoder filtered to
users. For each it runs axe, checks phone overflow and records the
`role="alert"` / `role="status"` messages a screen reader would announce.

## Results

| Check | Before | After |
|---|---|---|
| Pages returning 200 (21 × 4 renders) | 84 | 84 |
| axe violations, 21 pages × 2 schemes | 8 rules, on every page | **0** |
| axe violations, 7 states × 2 schemes | not run | **0** |
| Phone horizontal overflow | 0 pages | 0 pages |
| Tab stops without a visible focus ring | 0 of 514 | 0 of 541 |
| Validation errors and failed actions announced | no | yes (`role="alert"`) |

The "before" rules, all fixed:

| Rule | Impact | Where | Fix |
|---|---|---|---|
| `color-contrast` | serious | every page | five colour tokens (below) |
| `html-has-lang` | serious | every page | `<html lang="en">` |
| `link-in-text-block` | serious | tour, person, seller, order, geocoder, about | links in running text are underlined |
| `region` | moderate | every page (the acting-as bar) | acting-as bar and reset banner are labelled `<aside>` landmarks; flash moved into `<main>` |
| `heading-order` | moderate | 8 pages | top-level sections promoted from `h3` to `h2` |
| `label` | critical | basket | per-row quantity inputs have unique ids and visually hidden labels |
| `empty-table-header` | minor | basket | the empty Remove column is gone (Remove sits beside Update) |
| `scrollable-region-focusable` | serious | about | code blocks take focus (`tabindex="0"`) and show a ring |

Colour tokens changed (same hues; every text colour now clears 4.5:1 on
every surface it sits on, computed for both schemes):

| Token | Light before → after | Dark before → after | Worst case before |
|---|---|---|---|
| `--faint` | `#8b94a3` → `#646d7b` | `#6b7686` → `#8d97a8` | 2.70 (light, on brand-soft) |
| `--brand` | unchanged | `#7c78ff` → `#8f8bff` | 4.42 (dark, on brand-soft) |
| `--ok` | `#0f9d63` → `#047a4c` | unchanged | 3.07 (on ok-soft) |
| `--warn` | `#b7791f` → `#8a5a12` | unchanged | 3.24 (on warn-soft) |
| `--danger` | `#d9432f` → `#b3321f` | unchanged | 3.87 (on brand-soft); 4.43 on the alert flash tint |
| `--accent` | `#e11d73` → `#c2185b` | unchanged | 4.01 (on brand-soft) |

## Found by eye, not by tools

- **The header took a third of a phone screen**: the navigation wrapped to
  three rows and stayed pinned, and the acting-as bar added three more. On
  phones the navigation now scrolls away, its links are tighter, and the bar
  fits in two rows.
- **Market filters filled the first phone screen**: the four selects now pair
  up.
- **Basket, order and invoice tables were clipped** on phones: the unit price
  column hides below 620px (the line total stays). The totals row used
  `colspan="3"`, which counted the hidden column and pushed the total into a
  column that did not exist; it now has one cell per column.
- **Code blocks boxed every line** because the inline `code` chip style
  applied inside `pre`; and the tour's two-column grid let a wide code block
  push past the page. Code blocks now scroll inside a single-column card.
- **Thirteen Tab stops before any content**: the recorded focus order on the
  tour, product, basket and checkout pages was sensible (navigation, the
  acting-as bar, then the page in visual order), but every page began with
  the same 13 header stops. A "Skip to content" link is now the first stop
  and focuses `<main>`.
- **"Nanosecond Supply Co.."**: a refusal message added a full stop after a
  name that already ended with one.

## Limits

Automated checks catch perhaps a third to a half of accessibility problems.
This review did not use a screen reader (VoiceOver, NVDA), a real phone, zoom
to 200%, or Windows high-contrast mode, and the keyboard pass checked that
focus is visible on every page; the order itself was read from the recorded
stops for the tour, product, basket and checkout only. Those
are worth doing before anything beyond a demo.

## Reproducing

```sh
cd demo
bin/rails demo:reset && bin/rails server -p 3021      # in another terminal
bin/rails runner script/qa/pages.rb                    # after every reset: IDs change
cd script/qa && npm install
node pages.js final                                    # tmp/qa/final/
node states.js final-states                            # tmp/qa/final-states/
```

`CHROME=/path/to/chrome` selects another browser; puppeteer-core downloads
none.
