# ECS and conventional Rails workload comparison (ECS-33)

## Observations — 14 September 2026

Conventional Rails was faster and allocated fewer Ruby objects for every measured
workload at all three sizes. ECS provides composition and shared catalogue storage;
it does not achieve performance parity in this experiment. Selecting only consumed
slots reduces its projection cost substantially using existing Rails APIs.

This local run used an Apple M1 Pro (10 logical CPUs, 32 GiB RAM), Darwin 25.6.0,
Ruby 3.4.5, Rails 8.1.3, pg 1.6.3 and PostgreSQL 14.15 (Homebrew). The candidate
gem still reports version 0.2.2; it is the unreleased source identified in the JSON,
not the published 0.2.2 gem. PostgreSQL had fsync and synchronous_commit enabled,
128 MiB shared buffers and 4 MiB work_mem. CI smoke uses PostgreSQL 16.

Warm latency below is **p50 / p95 milliseconds**, twenty samples after three
discarded warmups. Min/max and every sample are retained in the raw JSON.

| Products | Workload | ECS p50 / p95 ms | Conventional p50 / p95 ms |
|---:|---|---:|---:|
| 100 | Catalogue render | 39.55 / 46.26 | 4.74 / 6.28 |
| 100 | Detail render | 18.55 / 22.99 | 4.56 / 4.91 |
| 100 | All-slot projection | 19.56 / 21.73 | 1.98 / 2.24 |
| 100 | Selected-slot projection | 4.93 / 5.88 | 0.90 / 1.54 |
| 100 | Full indexing sweep | 67.59 / 70.63 | 35.20 / 37.25 |
| 100 | Committed checkout | 53.63 / 60.05 | 13.64 / 18.15 |
| 1,000 | Catalogue render | 47.13 / 57.83 | 10.90 / 14.74 |
| 1,000 | Detail render | 18.68 / 21.28 | 4.85 / 5.71 |
| 1,000 | All-slot projection | 17.37 / 22.00 | 2.32 / 2.54 |
| 1,000 | Selected-slot projection | 4.94 / 5.48 | 1.01 / 1.29 |
| 1,000 | Full indexing sweep | 676.32 / 687.50 | 341.50 / 352.94 |
| 1,000 | Committed checkout | 52.64 / 57.81 | 12.52 / 15.64 |
| 5,000 | Catalogue render | 40.05 / 46.64 | 18.15 / 24.73 |
| 5,000 | Detail render | 20.53 / 28.25 | 5.08 / 12.45 |
| 5,000 | All-slot projection | 20.20 / 23.69 | 2.04 / 4.72 |
| 5,000 | Selected-slot projection | 5.68 / 10.92 | 1.15 / 3.41 |
| 5,000 | Full indexing sweep | 2973.74 / 3276.26 | 1541.85 / 1619.26 |
| 5,000 | Committed checkout | 55.59 / 60.96 | 14.32 / 19.19 |

The 100-product filtered catalogue has 23 matches; larger sizes fill the 24-row
page. The detail target always renders 24 of 30 reviews. Both projections always
consume 24 products. Page query counts remain bounded while filtering/sorting
costs and database plans can change with data size. These timings are not monotonic
scaling guarantees; the run uses a shared development machine.

At 5,000 products, first-invocation latency and median warm allocations/SQL are:

| Workload | First ms ECS / plain | Allocated objects ECS / plain | SQL reads ECS / plain | SQL writes ECS / plain |
|---|---:|---:|---:|---:|
| Catalogue render | 89.30 / 46.82 | 18,742 / 2,387 | 20 / 3 | 0 / 0 |
| Detail render | 74.88 / 51.01 | 11,124 / 2,366 | 22 / 5 | 0 / 0 |
| All-slot projection | 35.25 / 14.60 | 11,378 / 763 | 13 / 1 | 0 / 0 |
| Selected-slot projection | 33.45 / 13.03 | 2,626 / 418 | 3 / 1 | 0 / 0 |
| Full indexing sweep | 3342.28 / 1561.75 | 2,053,415 / 693,166 | 5,609 / 51 | 5,000 / 5,000 |
| Committed checkout | 98.74 / 50.60 | 21,725 / 3,843 | 60 / 9 | 40 / 14 |

Checkout additionally emits two transaction-control statements (BEGIN/COMMIT)
in both implementations. The indexing sweep uses one autocommitted update per
product. Warm samples have no schema or cached-query notifications. First calls
are reported separately because they include remaining metadata/view setup; the
exact cold/warm boundary is described below.

Installed-empty application storage totals **0.680 MiB for ECS** (26 tables)
and **0.266 MiB for conventional Rails** (9 tables). Populated sizes before
measurement, including TOAST and all application indexes:

| Products | ECS tables / indexes / total MiB | Conventional tables / indexes / total MiB |
|---:|---:|---:|
| 100 | 1.070 / 1.070 / 2.141 | 0.547 / 0.320 / 0.867 |
| 1,000 | 6.148 / 4.469 / 10.617 | 4.367 / 0.914 / 5.281 |
| 5,000 | 29.180 / 19.500 / 48.680 | 21.367 / 3.234 / 24.602 |

### What the plans explain

At 5,000 products, both catalogue plans find 1,152 matches and sort to return
24 rows. The ECS plan joins states/tags to entity identities, then probes the
component identity indexes for price, rating and search. It reports 18,249 shared
buffer hits and 19.295 ms execution in this EXPLAIN invocation. The conventional
plan scans its product table and sorts, with 2,500 hits and 4.859 ms execution.
Neither reports shared-buffer reads. A broadly matching term/category makes the
existing GIN indexes less attractive than these plans; adding an index alone
is not evidence of an improvement.

The detail-review query uses the shared relationship lookup plus entity identities
for ECS (94 hits, 0.101 ms), compared with the conventional product foreign-key
lookup (3 hits, 0.026 ms). These are principal-query plan observations, not the
whole rendering latency; preloads, model allocations and the count query also
contribute. Each full plan, SQL statement and planning time is in the raw JSON.

### Focused follow-ups justified by this run

1. Document association-name preloads and apply them where views consume only a
   subset of slots. In this stress case, selecting title/stock cuts ECS reads
   from 13 to 3, allocations by 77%, and median projection latency by 72%. The
   real demo has fewer slots; measure its actual field needs before changing it.
   This result does not justify a new selective-preload API.
2. Profile a batched vector-update path while preserving complete documents and
   current `reindex!` semantics. ECS performs 5,000 per-vector reloads in addition
   to owner/text/vector discovery. Both systems still issue 5,000 writes; the
   generic ECS sweep is about 1.93 times the conventional median here.
3. Profile checkout reads within its existing lock/transaction contract. ECS
   uses 60 reads and 40 writes versus 9 and 14, with about 5.7 times the Ruby
   allocations. Any batching/preloading change must preserve validation, virtual
   defaults, replay and stock safety; this benchmark is a baseline for that work.
4. Use the captured catalogue plans to test focused changes to the existing
   query/index strategy on selective and broad filters. A single common search
   term and warm, small database do not justify a query-DSL rewrite.

The fixture is deliberately slot-heavy and mostly populated, with modest text
values. It does not measure a sparse-domain storage benefit, production traffic,
network latency, concurrent throughput, peak RSS, a cold database, or data larger
than RAM. It is one independently seeded run per size with repeated operations;
do not turn its ratios or p95 values into universal claims.

## Reproduce

From the repository root, with the demo bundle installed and PostgreSQL running:

```sh
cd demo
bundle exec ruby script/compare_performance.rb --output ../tmp/ecs33-results.json
```

The default run uses 100, 1,000 and 5,000 products, three warmups and twenty
measured warm repetitions per workload/representation. Override them with
`--sizes 100,1000,5000 --warmups 3 --samples 20`. For behavioral verification
and a short timing smoke run, use `--smoke`. CI runs that command and uploads
its JSON artifact; it does not assert machine-dependent timing thresholds.

`DATABASE_URL` optionally supplies a PostgreSQL connection with permission to
create databases (default `postgresql:///postgres`). The runner creates a
random `ecs_performance_*` database for each size. It installs the actual demo
migration, adds conventional benchmark tables, generates data, verifies the
workloads, clears only its owned tables, regenerates data, captures read plans,
and measures. It drops its database after each size and on normal exceptions.
It never invokes the demo reset/seed task or writes a schema dump. A forced
process kill can leave the printed temporary database name for manual cleanup.

The checked-in [raw results](performance-comparison-results.json) include
every first call, discarded warmup, measured sample, summary, schema/index
definition, table/index size and EXPLAIN plan. They record the base commit,
SHA-256 of each benchmark source file and the demo lockfile, resolved versions,
hardware and selected PostgreSQL settings. The source hashes identify the
uncommitted benchmark addition on top of that base commit.

## Measurement contract

Compare equivalent observable behavior, not identical SQL or table counts.
Use the demo's actual ECS Product, Review, Basket and Checkout code and a
conventional ActiveRecord implementation with product fields on the product
row, ordinary foreign keys, and equivalent transactional checkout outcomes.
The benchmark alone adds Text/Counter slots to Product to make the cost of
preloading every declared slot visible. No production entity or gem API changes.

Generate deterministic identities and values at several product counts in an
owned temporary PostgreSQL database. Keep equivalent foreign-key lookup and
uniqueness indexes, GIN tag/search indexes, pagination, filters, sort ties and
consumer fields; do not add speculative covering indexes to either model.
Report installed schema size and populated table/index sizes separately.

Measure these workloads for each representation:

1. A filtered, price-sorted catalogue page of 24 products, including seller
   names, rating, tags and counters, rendered through one shared Rails view.
2. A product detail with its seller and up to 24 ordered reviews/authors,
   rendered through the same shared view machinery.
3. A committed simulated checkout of three lines: stock locks, immutable
   snapshots, numbering, paid transition history, invoice and basket clearing.
   Prepare each basket outside the timed call; include transaction commit.
4. A full search-system sweep over the same slot-ordered text values.
5. A 24-product title/stock projection with all Text/Counter slots preloaded,
   then with existing Rails APIs restricted to the two consumed slots.

Verify rendered/projection equivalence and checkout replay, decline rollback,
stock and snapshots before measuring. Each workload/representation runs in a
fresh Ruby process: record its first call separately, then warm repetitions
with p50/p95/min/max latency, Ruby allocations and SQL read/write counts.
First-call means the first **workload invocation** after Rails boot and eager
loading, including any remaining lazy metadata/view compilation. Checkout's
basket preparation necessarily loads some models before its first timed call.
These samples are not cold application startup measurements. PostgreSQL and OS
buffers are warm from setup/verification/EXPLAIN and are not flushed on the
shared developer machine; no disk-cold result is claimed. These are in-process
model/view workloads, not full HTTP/network latency or concurrent throughput
measurements.

Capture `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for the actual principal read
queries and document the schema/index differences that explain plans. Never
run mutating EXPLAIN outside an owned transaction/database. Keep fixture setup
and verification outside measured samples. Record versions, hardware, data
shape, warm-up policy and limitations alongside raw results.

Use one orchestrator command to create, migrate, seed, verify, measure, write
results and remove only its own database. Small CI smoke data checks behavioral
equivalence; local representative sizes provide the published observations.
Results can justify focused follow-ups, including unfavorable ECS results,
without implying parity from query counts or requesting a new query API.

## What is held equivalent

Both representations have the same deterministic entity UUIDs, text, counters,
prices, tags, ratings, sellers, authors and date ties. Each product has six
Text values and six Counter values. One in thirteen has a zero price: ECS
leaves its Money row absent and conventional Rails stores the default zero.
One in eleven products is a draft. Categories alternate books/hardware, prices
cycle through twenty values, ratings through five. There is one seller per
twenty products and twenty users. Products have three reviews each except the
detail target, which has thirty to exercise its 24-review page. Component-row
UUIDs and persistence timestamps use ordinary database/Rails defaults; the
consumer-facing identities, creation dates and values are deterministic.

Catalogue filtering uses listed state, search for `common`, at most USD 15,
at least three stars and category books. It sorts by displayed price ascending,
creation date descending, then UUID ascending. Both count all matches and
load page one with Kaminari before rendering identical HTML. The ECS preload
policy is the demo controller's type-wide Text/Money/Rating/Counter/Tags policy
plus seller names. Conventional Rails selects its product row and preloads
sellers. The detail workload uses the demo's lazy product access and bounded
review preloads; both render the same consumed values through the same ERB
template. Management forms, layout, middleware and HTTP are outside this test.

Checkout uses the actual `Demo::Checkout` and a conventional transactional
service with row locks, ordinary foreign keys, unique document/request indexes
and advisory locks for numbering. Each call buys quantities 1, 2 and 3 of three
products. Basket preparation is untimed; the order, immutable lines, addresses,
paid transition history, invoice, stock decrement, basket clearing and commit
are timed. Both start with no orders after verification; repetitions accumulate
the same number of orders and reduce stock equally. This is a successful
serial checkout measurement, not a contention benchmark. Verification also
checks decline rollback, replay without additional rows or stock consumption,
later product edits leaving snapshots unchanged, and commit visibility through
a second connection. Existing ECS-28 specs cover the demo's concurrent lifecycle.

The system workload runs `Demo::Indexer` over the actual shared Text table,
including companies and reviews that do not declare SearchVector. Its generic
eligibility discovery is part of its cost. The conventional system knows its
Product table, reads six text columns in batches of 100, and updates one vector
per product. Both use PostgreSQL's `simple` dictionary and slot/column order,
and commit one UPDATE per vector even when unchanged. ECS's existing
`reindex!` also reloads each vector; conventional Rails does not need that
reload. Verification compares all persisted vector values and checks repeats.

The projection experiment consumes just ID, title and stock for 24 products:

```ruby
# Type-wide: every declared Text and Counter slot (12 per product).
Product.order(:id).limit(24).includes_components(Text, Counter)

# Existing Rails API: only the two consumed slots.
Product.order(:id).limit(24).preload(:title_text, :stock_counter)
```

Both feed the identical `[id, title, stock]` projection. The conventional
counterparts use `SELECT *` and `select(:id, :title, :stock)`. No preload API
or production entity declaration changes are introduced.

## Timing and storage boundaries

The timer is monotonic. Ruby allocations come from `GC.stat`; GC stays enabled
during each sample, with a forced collection outside timing before each call.
SQL notifications are counted inside the timed section, so instrumentation
overhead is included for both representations. The Rails query cache is
disabled. Reads, writes, transaction controls, schema queries, other statements
and cached notifications have separate counters. Autocommit UPDATEs do not
emit explicit BEGIN/COMMIT notifications. First-call schema traffic remains
visible rather than silently excluded. Warm summaries use nearest-rank p50/p95
and min/max; twenty samples do not establish a reliable production tail SLO.

Each workload/representation has one fresh Ruby process at each size. The
execution order alternates ECS-first/plain-first across sizes. This reduces a
fixed ordering bias but does not replace repeated independent experiments.
EXPLAIN runs before measurements on the reset fixture, outside the timer.
Only read queries are explained. Plans cover the actual catalogue/count and
review relations, system batch discovery, and slot/projection reads.

Storage is `pg_table_size` (including TOAST), `pg_indexes_size`, and their sum,
per public application table. Installed-empty and populated-before-measurement
sizes are recorded separately. ECS installs its full core/commerce catalogue
(including unused tables); conventional Rails installs just the nine tables
needed for these workloads. Both have UUID primary keys, foreign-key lookup
indexes, required uniqueness and tag/search GIN indexes. ECS additionally pays
for component identities, slots, entity-model filtering and shared relationship
indexes. Conventional Rails puts fields directly on product/review rows and
foreign keys directly on owners. The JSON includes the exact structures; these
are workload-equivalent schemas, not identical indexing or storage layouts.
