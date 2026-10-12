# Bounded component indexer (ECS-32)

Keep `Demo::Indexer` a component-driven PORO with no concrete entity names.
Select base entities with at least one Text through an SQL subquery and use
ActiveRecord's primary-key batches (default 100 owners). Entity identity is
the batch boundary: component-row batches would split one entity's slots and
overwrite a full document with its last fragment.

Within each batch, check each concrete class's SearchVector declaration once.
Read all Text slots of eligible owners in slot order, and read their existing
default-slot SearchVectors in one query. Reuse those components or build a
virtual one for an eligible owner. Keep the catalogue's `reindex!` behavior,
including its normal validation, persistence and refresh; avoid an alternate
bulk-write path. *(Superseded for writes by the ECS-39 amendment below: one
upsert per batch, with what it skips stated.)* Group text values only inside this bounded batch.

Preserve eligibility: owners without Text rows are untouched, owners that do
not declare SearchVector are skipped even if they have a stray vector row,
and all persisted Text slots contribute (including undeclared labelled slots).
Nil values remain omitted by SearchVector; ordering is deterministic by slot.
Repeated runs preserve vector identity and yield the same document.

Memory is bounded by the owners and text bytes in a batch, not total dataset
size. One unusually large entity can still require substantial text memory.
The run is not a snapshot: concurrent text changes may be seen by a later
batch, and a subsequent run reconciles changes behind the cursor.

Test small and uneven batch boundaries, many slots on one owner, mixed entity
types, preexisting/missing vectors, repeated runs and owner-query growth.
Measure separate processes on two fixture sizes, recording peak RSS, time and
query categories for the previous and batched implementations. Fixture setup
must occur outside those measured processes in an owned test database.

## Local measurements

2026-09-12, macOS arm64, Ruby 3.4.5, Rails 8.1.3, PostgreSQL 14.15. Each
owner has three text slots; 20% are ineligible groups and the rest are posts
or products with existing default-slot vectors. Each slot repeats four words
80 times. Batch size is 100. Both modes use a fresh Ruby process; fixture
creation is separate. Peak RSS includes Rails boot and the bounded checksum
pass; indexing time and SQL counts cover only the indexer call.

| Owners | Implementation | Owner reads | Total queries | Index seconds | Peak RSS MiB |
| ---: | --- | ---: | ---: | ---: | ---: |
| 250 | Previous | 250 | 851 | 1.231 | 108.1 |
| 250 | Batched | 3 | 409 | 0.671 | 115.5 |
| 2,500 | Previous | 2,500 | 8,501 | 10.141 | 182.8 |
| 2,500 | Batched | 26 | 4,076 | 6.776 | 123.3 |

The extra owner read at 2,500 is the empty final batch probe. Updates and
`reindex!`'s refresh still cost one query each per indexed owner; only discovery
and initial vector/text reads are batched. Document checksums match between
implementations at both sizes. See [raw results](indexer-benchmark-results.json).

These are single local observations, not release performance claims. Small-case
RSS is higher for batching, while the larger case shows much less growth;
allocator state, caches and machine load affect timing and memory peaks. The
bound is per-batch text volume, not a universal byte ceiling or a constant
total number of allocations. Broader comparative measurements belong to ECS-33.

To reproduce from `demo/`, create a dedicated database and migrate it once:

```sh
export RAILS_ENV=test
export DATABASE_URL=postgresql:///ecs_indexer_bench_local
export DEMO_RESET_ENABLED=false
createdb ecs_indexer_bench_local
bin/rails db:migrate

bundle exec ruby script/benchmark_indexer.rb prepare 250
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb baseline
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb batched

bundle exec ruby script/benchmark_indexer.rb prepare 2500
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb baseline
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb batched
```

`prepare` replaces only the benchmark fixture; the script refuses non-test
environments and database names outside `ecs_indexer_bench_*`. macOS reports
RSS in bytes; on Linux use `/usr/bin/time -v` and convert its KiB value. The
JSON reports query categories, allocations, elapsed time and output checksum.

## Amendment — one upsert per batch (ECS-39, 12 October 2026)

ECS-32 batched discovery and reads but kept `reindex!` per owner: an UPDATE,
then a reload the system never read, plus a SELECT and an INSERT first when
the vector was missing. ECS-33 measured 5,609 reads and 5,000 writes for a
5,000-product sweep. `Demo::Indexer` now writes each batch with one
statement:

```sql
INSERT INTO search_vectors (entity_id, slot, document, created_at, updated_at)
SELECT batch.entity_id, '', to_tsvector('simple', batch.text), :now, :now
FROM unnest(ARRAY[:entity_ids]::uuid[], ARRAY[:texts]::text[]) AS batch(entity_id, text)
ON CONFLICT (entity_id, slot) DO UPDATE SET document = EXCLUDED.document
```

Discovery, eligibility (`components.include?(SearchVector)`), whole-owner
batches, slot order, nil handling and the `simple` dictionary are unchanged,
and so are the documents. What the bulk path keeps and skips is explicit, in
the code and in `spec/indexer_spec.rb`:

- **Kept:** an existing vector's id (the unique `(entity_id, slot)` index is
  the conflict target), the default slot `""`, and — as with `reindex!`, which
  used `update_all` — an existing vector's `updated_at`. A new vector gets
  `created_at` and `updated_at`. Ineligible owners, owners without texts and
  their stray vectors are untouched. Repeat runs give the same documents and
  ids.
- **Skipped:** no SearchVector model is built, so the application class's
  validations and callbacks do not run. Before, they ran only when a missing
  vector was created; updates already bypassed them. An application that adds
  callbacks to its SearchVector and needs them here should call `reindex!` per
  owner. `reindex!` itself, the public path for ordinary callers (the demo's
  post and product forms), is unchanged; no gem code changed.
- **Atomicity:** each batch is one statement, so a batch is written entirely
  or not at all. A concurrent insert of the same vector is resolved by the
  conflict clause rather than raising, as `save!` could.

Memory is still bounded by one batch's owners and their text, now including
the SQL string that carries that text. One enormous owner is still held whole.

### Candidates measured first

Five write paths on the ECS-32 fixture, all with the same batched discovery,
three runs each in fresh processes, batch size 100. Medians; every write path
produced identical documents ([raw results](indexer-candidates-results.json)).
The `batch_transaction` runs used a re-prepared fixture of the same shape;
an `upsert` run on that fixture produced the same checksum.

| Owners | Write path | Seconds | Queries | Vector reads | Writes | Allocations |
|---:|---|---:|---:|---:|---:|---:|
| 250 | `reindex!` per owner (ECS-32) | 1.238 | 409 | 203 | 200 | 194,375 |
| 250 | the same, one transaction per batch | 1.068 | 415 | 203 | 200 | 197,473 |
| 250 | UPDATE per owner, no reload | 0.503 | 406 | 200 | 200 | 180,008 |
| 250 | UPDATE … FROM unnest per batch | 0.315 | 12 | 3 | 3 | 125,361 |
| 250 | **INSERT … ON CONFLICT per batch** | 0.323 | 9 | 0 | 3 | 123,081 |
| 2,500 | `reindex!` per owner (ECS-32) | 10.837 | 4,076 | 2,025 | 2,000 | 947,868 |
| 2,500 | the same, one transaction per batch | 9.216 | 4,126 | 2,025 | 2,000 | 978,296 |
| 2,500 | UPDATE per owner, no reload | 10.787 | 4,051 | 2,000 | 2,000 | 828,857 |
| 2,500 | UPDATE … FROM unnest per batch | 1.423 | 101 | 25 | 25 | 282,316 |
| 2,500 | **INSERT … ON CONFLICT per batch** | 1.466 | 76 | 0 | 25 | 260,733 |

Per-statement round trips dominated, not commits: one transaction per batch
saved about 15%, and dropping the reload alone did not change the 2,500-owner
median (its three runs varied from 7.7 to 10.9 s). Both batch statements were
about seven times faster with about 70% fewer allocations. The upsert was
chosen over UPDATE … FROM: it needs no vector read and creates missing vectors
in the same statement, for the same time.

To repeat, use the reproduction steps above with these modes:
`batched` (now the upsert, since it runs `Demo::Indexer`),
`batch_transaction`, `no_reload`, `update_from` and `upsert`.

### The ECS-33 sweep

The full harness ran on `main` (`0245e0a`) and then on `ca25e35`, back to back
on an otherwise idle machine; the "before" run used a separate worktree so
its workers could not load the changed indexer. Ruby 3.4.5, Rails 8.1.3,
PostgreSQL 17.11, `ecs_on_rails` 0.3.0; twenty warm samples after three
warmups. Raw results: [before](indexer-upsert-stress-before.json),
[after](indexer-upsert-stress-after.json).

| Products | ECS p50 ms | ECS p95 ms | Reads | Writes | Allocations | Conventional p50 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 72.77 / 47.02 | 132.72 / 56.94 | 115 / 10 | 100 / 5 | 42,151 / 15,304 | 34.63 / 35.24 |
| 1,000 | 688.03 / 496.38 | 704.11 / 582.66 | 1,123 / 82 | 1,000 / 41 | 411,425 / 143,416 | 342.92 / 337.50 |
| 5,000 | 3,661.95 / 3,092.86 | 3,742.21 / 3,423.75 | 5,609 / 406 | 5,000 / 203 | 2,053,415 / 713,468 | 2,069.91 / 2,253.74 |

Reads fall by 91–93%, writes by 95–96% and allocations by 64–65%.
Median latency falls by 35%, 28% and 16%: far less than on the ECS-32
fixture. The sweep discovers every entity with a Text — 15,000 reviews and
the sellers as well as the products — and the discovery query is cheap (the
captured plan executes in 0.3 ms). What remains is mostly work the
conventional sweep also does: building each document with `to_tsvector` and
maintaining the GIN index, which is all its 2.1–2.3 s consists of. That is an
interpretation of the two timings, not a separate measurement.

Two cautions for comparisons. The conventional sweep still writes one UPDATE
per product, as the ECS-33 contract specified, so the ECS/conventional ratio
for this workload (now about 1.4×) compares a batched system with a per-row
one and is no longer like-for-like. And the other workloads, which this
change does not touch, moved within noise in both representations. The 14
September run remains the original baseline in
[performance-comparison.md](performance-comparison.md).
