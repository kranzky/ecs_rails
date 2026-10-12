# Focused preloads in the demo's read paths (ECS-38)

## Summary — 12 October 2026

The demo's list pages preloaded component *types*:
`includes_components(Text, Counter)` loads every Text and Counter slot an
entity declares, whether or not the view shows it. Six pages now preload by
association name exactly the slots their views read, and the geocoder's
address table, which read each owner's label once per row, preloads each owner
type's label. No gem API changed; `preload(:title_text, ...)` is ordinary
Rails.

On the demo's own seed data the benefit is small but consistent: one or two
fewer reads per changed page, 3–10% fewer allocations, and median times within
noise — except the geocoder page, whose N+1 removal cut reads from 20 to 15
and the median from 17.8 to 13.5 ms. On the ECS-33 stress fixture, where each
product deliberately declares six Text and six Counter slots, the catalogue
drops from 20 to 11 reads, allocations fall by 42–45% and the median by
19–37%. **The stress gain does not carry over to ordinary pages**; it measures
what a type-wide preload costs as an entity gains slots of one type.

Every page rendered byte-identical HTML before and after (UUIDs, tokens and
times normalised), and the two control pages did not move.

## Inventory

What each growing read path loaded, what its view shows, and the change.
"Type-wide" lists the slots `includes_components` loaded.

| Page | Records | Loaded type-wide | Shown | Change |
|---|---|---|---|---|
| Market `/products` | Product | Text (title, body), Money (price), Rating, Counter (stock, review count), Tags; seller → name | title, price, stars, stock, review count, tags, seller name | named; body no longer loaded |
| Product page | Review | Text (body), Rating, Counter (likes); author → name, avatar | body, stars, author | named; likes no longer loaded |
| Profile `/users/:id` | Post | Text (title, body), Counter (likes), State (publish) | title, draft badge, likes | named; body no longer loaded |
| Seller `/companies/:id` | Product | Text (title, body), Money, Counter (stock, review count), State (listing), Rating | title, price, listing badge, stars, stock | named; body and review count no longer loaded |
| Groups `/groups` | Group | Text (name, description, rules) | name, description | named; rules no longer loaded |
| Orders `/users/:id/orders` | Order | Identifier (checkout request, order number), Money (total), State (fulfilment) | number, total, status | named; checkout request key no longer loaded |
| Geocoder `/geocoder` | Address → owner | the owner entity only | owner label: User name, Company name, Order and Invoice numbers | each owner type's label preloaded; N+1 removed |

Already exact, unchanged: the posts list and a post's comments (each Text and
Counter slot shown), the people list (Name, Email, avatar and both markers),
the sellers list (name, description, logo, address), group members and
company staff (Role plus the user's name and avatar), order, invoice and
basket items (one slot of each type), and the acting-as bar (Name).

Not changed: the group page's "add a member" select loads every user with
`User.all.includes_components(Name)`. The preload is right; the list is
unbounded, which is a pagination question for the demo, not a preload one.

The geocoder's owners are of four types, each labelled from a different
component, so one nested `preload` cannot name them. The controller groups the
page's owners by class and runs Rails' `ActiveRecord::Associations::Preloader`
(the API behind `preload`) once per class. It keys the label slots by class
name so the controller loads no entity constants.

Virtual components are unaffected: a preload that finds no row leaves the
reader to build its default. A product with only a title still shows $0.00,
"Not yet rated" and "Out of stock"; a review without a body or rating, and an
untitled draft, still render.

## Regression coverage

[`demo/spec/focused_preloads_spec.rb`](../../demo/spec/focused_preloads_spec.rb)
pins, for each changed page:

- **No N+1.** Twice the rows cost the same number of reads. Removing any
  shown slot from a preload fails this (checked: dropping `:tags` from the
  market made the larger page cost 20 reads instead of 17).
- **Unshown slots stay unloaded**, by `association(name).loaded?` on the
  controller's records. Only unshown slots are checked this way: a slot the
  view reads reports loaded whether or not it was preloaded.
- **Virtual defaults render** for records missing components.

Against the previous controllers, the six "not loaded" examples and the
geocoder's query-count example fail; the rest pass on both.

## Measurements

Apple M1 Pro (10 logical CPUs, 32 GiB), Darwin 25.6.0, Ruby 3.4.5, Rails
8.1.3, PostgreSQL 17.11 (Homebrew), `ecs_on_rails` 0.3.0. Warm latency is
p50 / p95 over twenty samples after three warmups; allocations and SQL reads
are warm medians. Raw results, with every sample, are checked in beside this
document.

### The demo's pages, on its seed data

`compare_performance.rb --pages` (added for this issue) seeds the ordinary
demo in an owned database and times each page as a whole request through
routing, controller and views, in-process (no network). "Before" is commit
`9491930` with the six controllers restored from `c584dea`, recorded as
uncommitted files in its JSON; "after" is `9491930` itself. The two ran back
to back on an otherwise idle machine.

| Page | p50 ms before / after | p95 ms before / after | SQL reads | Allocations | Same HTML |
|---|---:|---:|---:|---:|:---:|
| Market | 17.47 / 16.75 | 22.61 / 18.17 | 17 / 16 | 10,431 / 9,825 | yes |
| Product page | 24.87 / 24.11 | 36.33 / 26.13 | 34 / 33 | 13,287 / 12,888 | yes |
| Profile | 17.30 / 17.02 | 22.00 / 20.06 | 24 / 23 | 9,946 / 9,564 | yes |
| Seller | 23.68 / 22.97 | 29.19 / 24.69 | 30 / 28 | 12,516 / 11,704 | yes |
| Groups | 8.24 / 7.84 | 9.19 / 8.27 | 9 / 8 | 4,295 / 3,938 | yes |
| Geocoder | 17.83 / 13.50 | 27.39 / 15.10 | 20 / 15 | 9,163 / 8,271 | yes |
| Orders | 11.24 / 10.10 | 13.29 / 13.43 | 13 / 12 | 5,540 / 5,186 | yes |
| Posts *(control)* | 13.31 / 13.44 | 14.57 / 16.57 | 13 / 13 | 7,023 / 7,023 | yes |
| People *(control)* | 9.55 / 9.73 | 11.64 / 11.53 | 10 / 10 | 5,576 / 5,576 | yes |

The seed is small (twelve products, four people, three sellers, eleven
addresses), so most pages hold a few rows: a skipped slot saves one query and its rows, not a query per row.
Latency differences under a millisecond are within run-to-run noise; the read
and allocation counts are deterministic. The geocoder's saving is per row, so
it grows with the page, up to the 24-row page size.

### The ECS-33 stress fixture

The same harness without `--pages`. Its catalogue and review workloads copy
the demo controllers' preload policy, so they were updated with them; the
other workloads did not change. "Before" is `c584dea`, "after" `24cb1bc`. The
14 September run remains the original baseline in
[performance-comparison.md](performance-comparison.md).

| Products | Workload | ECS p50 ms | ECS p95 ms | ECS reads | ECS allocations | Conventional p50 ms |
|---:|---|---:|---:|---:|---:|---:|
| 100 | Catalogue | 39.56 / 24.86 | 44.74 / 35.13 | 20 / 11 | 17,224 / 9,508 | 4.87 / 4.81 |
| 1,000 | Catalogue | 48.16 / 36.75 | 54.30 / 43.60 | 20 / 11 | 18,277 / 10,340 | 10.19 / 10.24 |
| 5,000 | Catalogue | 42.79 / 34.52 | 48.25 / 51.51 | 20 / 11 | 18,742 / 10,805 | 21.36 / 21.42 |
| 100 | Detail | 18.36 / 17.73 | 22.23 / 20.56 | 22 / 22 | 11,124 / 11,066 | 5.05 / 4.66 |
| 1,000 | Detail | 17.47 / 18.04 | 20.00 / 23.64 | 22 / 22 | 11,124 / 11,066 | 4.75 / 5.70 |
| 5,000 | Detail | 17.79 / 19.19 | 19.38 / 24.12 | 22 / 22 | 11,124 / 11,066 | 4.57 / 5.21 |

The catalogue saves the four extra Text and four extra Counter slots the
fixture declares, plus the body. Unlike the demo's product page, the stress
review view shows likes, and a review has one Text and one Counter, so its
named preload issues the same queries: the detail workload is a control, and
its medians moved within noise. Conventional Rails did not change. ECS remains
slower than conventional Rails on every workload.

### Limitations

One run per representation and size, on a shared developer machine, warm
database, no network. During the stress "after" run two short `rails runner`
traces ran for a few seconds, which may have widened some p95 values (the
5,000-product catalogue p95 rose while its median fell); compare medians,
reads and allocations. The pages run measures in-process requests including
middleware, not browser or network latency. No timing threshold is asserted in
CI.

An earlier page run in this issue loaded the stress fixture's models, which
declare those extra slots on the demo's `Product`, and so overstated the
market, product and seller savings (it reported 25 → 16 reads for the
market). The worker now loads only the measurement code in page mode; those
results were discarded and both page runs repeated.

## Reproduce

From `demo/`, with its bundle installed and PostgreSQL running:

```sh
bundle exec ruby script/compare_performance.rb --pages --output ../tmp/pages.json
bundle exec ruby script/compare_performance.rb --output ../tmp/stress.json
```

`--pages` accepts `--warmups` and `--samples`. Both modes create and drop
their own uniquely named database; `DATABASE_URL` names the server.

Raw results: [pages before](focused-preloads-pages-before.json),
[pages after](focused-preloads-pages-after.json),
[stress before](focused-preloads-stress-before.json),
[stress after](focused-preloads-stress-after.json).
