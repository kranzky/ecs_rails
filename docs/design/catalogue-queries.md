# Catalogue query rewrites (ECS-42)

## Decision — 26 October 2026: no change

The catalogue keeps the demo's own scopes: one correlated `EXISTS` per
component filter (`with_component`, RFC-0010/0018) and a slot-scoped left join
for the price, so a missing price filters and sorts as zero. Two plain-Rails
rewrites were measured against them on the ECS-33 fixture at 100 and 5,000
products. Neither is faster where it matters, and both are several times
slower on a selective search. Most of a catalogue request is not the filter
query anyway: at 5,000 products the page and count queries together take
2.5–16.4 ms of a 13–35 ms request; the rest is preloading and building the
page's objects.

One shared index, `entities (model, created_at DESC, id)`, makes the
unfiltered "newest" listing's page query twenty times faster at 5,000
products. That is a catalogue schema change — every app's install migration
and an upgrade — for one sort order at a scale past the gem's hobbyist range,
so it is recorded in the [backlog](../backlog.md) with these numbers rather
than shipped.

## What was compared

[`demo/script/catalogue_query_experiment.rb`](../../demo/script/catalogue_query_experiment.rb)
creates an owned database per size, loads the ECS-33 fixture through the
harness's own worker (which runs `ANALYZE`), and measures three versions of
the same filters in a fresh Rails process:

- **v0, today:** `Product.listed.searching(q).priced_at_most(max).rated_at_least(stars).in_category(category).sorted(sort)`.
- **v1, IN subqueries:** each component filter as
  `where(id: Rating.where("stars >= ?", 3).select(:entity_id))`.
- **v2, inner joins:** `joins(:listing_state, :rating, ...)` on the
  slot-scoped `has_one`s, which are unique per `(entity_id, slot)`, so still
  one row per product.

Then, in the same database, v0 again after creating the index above.

Five scenarios: **broad** (the ECS-33 filters: listed, search "common", at
most USD 15, three stars and up, category books, price ascending), **selective
search** (a term one product contains, newest first), **unfiltered** (listed,
newest first), **price ties** (at most USD 15, price ascending; one product in
thirteen has no price row and sorts as zero) and **top rated** (four stars and
up, rating descending). Every variant had to return the same 24 ids in the
same order and the same total as v0, or the run stopped; all did.

For each: the page and count queries' `EXPLAIN (ANALYZE, BUFFERS)` (median of
five runs), and a warm "request" — the page with the demo controller's
ECS-38 preload policy, plus its total count — over 30 samples. Apple M1 Pro,
Ruby 3.4.5, Rails 8.1.3, PostgreSQL 17.11, at `d2663fb` with the experiment
script uncommitted. Raw results: [catalogue-queries-results.json](catalogue-queries-results.json).

## Results at 5,000 products

Page query / count query in ms (median of five plans), and the request median:

| Scenario (matches) | v0 `EXISTS` | v1 `IN` | v2 joins | v0 + entities index |
|---|---:|---:|---:|---:|
| Broad (1,152) | 8.21 / 8.18 · 28.7 | 9.53 / 8.93 · 29.3 | 9.52 / 9.42 · 31.2 | 8.74 / 8.61 · 29.0 |
| Selective search (1) | 1.29 / 1.18 · 13.3 | 5.00 / 1.26 · 14.0 | 5.05 / 1.39 · 13.2 | 1.33 / 1.56 · 14.5 |
| Unfiltered (4,545) | 2.58 / 1.93 · 34.8 | 2.22 / 1.53 · 33.4 | 3.01 / 1.45 · 33.7 | 0.12 / 5.84 · 25.6 |
| Price ties (3,495) | 3.37 / 2.70 · 32.9 | 3.35 / 2.61 · 34.9 | 3.06 / 2.59 · 34.6 | 3.67 / 2.67 · 33.3 |
| Top rated (1,818) | 6.15 / 3.76 · 29.4 | 7.08 / 3.94 · 31.7 | 6.03 / 3.48 · 32.8 | 7.14 / 3.79 · 30.9 |

Request allocations, at both sizes: v1 within 1.5% of v0, v2 3–13% more, the
index none.

At 100 products every page and count query is under a millisecond for every
variant, and requests differ by noise.

## Reading the results

- **`EXISTS` is the right default.** On the selective search both rewrites
  took about four times as long (1.3 → 5.0 ms) while reading the same 572
  buffers; the plans were not examined further, because the result already
  rules them out. On the broad filters, where `EXISTS` probes the component
  indexes once per candidate (about 15,000 of its 16,000 buffer hits), the
  rewrites read more buffers, not fewer, and were no faster. A large-case
  micro-win would have hidden a harmful default; there was not even the win.
- **The filters are not where a catalogue request spends its time.** Even the
  slowest page plus count is about half of the request; preloading the shown
  slots and instantiating 24 products and their components are the rest.
  ECS-38 and ECS-41 are where that cost was examined.
- **The index helps one order.** It turns the unfiltered newest-first page
  query from a sort of 4,545 rows into an index walk (2.58 → 0.12 ms). The
  request median fell by more than that (34.8 → 25.6 ms), but the pass ran
  last, its p95 was the widest of the run (59 ms) and its count query was
  slower, so only the page-query figure is evidence. It does nothing for
  filtered or price- or rating-sorted pages, whose order comes from a
  component.

## If the index is proposed

It belongs in the catalogue's install schema, so it would reach existing apps
through `ecs_rails:upgrade`, cost one more index write per entity insert, and
take index space proportional to all entities, not only the type being
listed. The evidence for it is one sort order at thousands of entities of one
type; the trigger to propose it is a real app's newest-first list at that
scale.
